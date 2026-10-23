import Foundation
import AVFoundation
import CoreMedia
import NaturalLanguage

// Shared by STT Trans and SAMI Gen.

/// Runs `op` in an unstructured task and stops waiting after `seconds` (the op may keep running).
@discardableResult
func withTimeout(seconds: Double, _ op: @escaping @Sendable () async -> Void) async -> Bool {
    final class Once: @unchecked Sendable {
        let lock = NSLock(); var done = false
        func fire(_ c: CheckedContinuation<Bool, Never>, _ v: Bool) {
            lock.lock(); defer { lock.unlock() }
            if !done { done = true; c.resume(returning: v) }
        }
    }
    let once = Once()
    return await withCheckedContinuation { c in
        Task { await op(); once.fire(c, true) }
        Task { try? await Task.sleep(for: .seconds(seconds)); once.fire(c, false) }
    }
}

private let debugLogging = ProcessInfo.processInfo.environment["STTTRANS_DEBUG"] != nil
    || ProcessInfo.processInfo.environment["SAMIGEN_DEBUG"] != nil

func dlog(_ s: String) {
    guard debugLogging else { return }
    FileHandle.standardError.write(("[\(String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))] " + s + "\n").data(using: .utf8)!)
}


enum LanguageID {
    /// Probability (0...1) that `text` is written in `code`, per Apple NaturalLanguage.
    static func match(_ text: String, _ code: String) -> Double {
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return 0 }
        let r = NLLanguageRecognizer()
        r.processString(text)
        let hyps = r.languageHypotheses(withMaximum: 6)
        if let p = hyps[NLLanguage(rawValue: code)] { return p }
        // NL uses zh-Hans / zh-Hant; match on the base language as a fallback.
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return hyps.first { $0.key.rawValue.hasPrefix(base) }?.value ?? 0
    }
}

extension Language {
    /// Locale used for SpeechTranscriber.
    var speechLocaleID: String {
        [
            "ko": "ko-KR", "en": "en-US", "ja": "ja-JP", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW",
            "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "pt": "pt-BR", "ru": "ru-RU",
            "vi": "vi-VN", "th": "th-TH", "id": "id-ID", "ar": "ar-SA", "hi": "hi-IN",
        ][code] ?? code
    }
}

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let desc = formatDescription,
              let asbd = desc.audioStreamBasicDescription else { return nil }
        var asbdCopy = asbd
        guard let format = AVAudioFormat(streamDescription: &asbdCopy) else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

enum AppError: LocalizedError {
    case permission(String), audio(String), speech(String), translate(String)
    var errorDescription: String? {
        switch self {
        case .permission(let s), .audio(let s), .speech(let s), .translate(let s): return s
        }
    }
}

/// LiteLLM proxy credentials from `~/env` (KEY=value lines, optional `export`, quotes) or the environment.
struct LiteLLMEnv {
    let baseURL: String
    let apiKey: String

    static func load(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("env")) -> LiteLLMEnv? {
        var vars = ProcessInfo.processInfo.environment
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for raw in text.split(whereSeparator: \.isNewline) {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { continue }
                if line.hasPrefix("export ") { line.removeFirst(7) }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let f = value.first, f == value.last, f == "\"" || f == "'" {
                    value = String(value.dropFirst().dropLast())
                }
                if key.hasPrefix("LITELLM_") { vars[key] = value }
            }
        }
        guard let base = vars["LITELLM_OPENAI_BASE_URL"], !base.isEmpty else { return nil }
        return LiteLLMEnv(baseURL: base, apiKey: vars["LITELLM_OPENAI_API_KEY"] ?? "")
    }
}

/// Two recognizers (e.g. EN + KO) on the same audio: when one *transliterates* the other language
/// ("Yes." -> "예스.", "Hello everyone" -> "헬로 에브리원"), both texts sound alike. The spoken language is then
/// the one whose text consists of real words / real grammar. Confidence alone can't tell these apart.
enum Transliteration {
    /// Rough pronunciation skeleton: romanize, keep consonant classes (b/p/f/v, t/d/th, k/g/c/q, s/z/j/ch, l/r…).
    static func skeleton(_ text: String) -> [Character] {
        let latin = (text.applyingTransform(.toLatin, reverse: false) ?? text)
            .applyingTransform(.stripDiacritics, reverse: false)?.lowercased() ?? text.lowercased()
        var out: [Character] = []
        var prev: Character = " "
        for c in latin {
            let k: Character?
            switch c {
            case "b", "p", "f", "v": k = "P"
            case "t", "d": k = "T"
            case "k", "g", "c", "q", "x": k = "K"
            case "s", "z", "j": k = "S"
            case "l", "r": k = "L"
            case "m": k = "M"
            case "n": k = "N"
            default: k = nil        // vowels, h, w, y, punctuation, digits
            }
            if let k, k != out.last || prev == " " { out.append(k) }   // collapse doubled consonants within a word
            prev = c
        }
        return out
    }

    /// 0…1 similarity of two pronunciation skeletons (1 - normalized edit distance).
    static func soundAlike(_ a: String, _ b: String) -> Double {
        let x = skeleton(a), y = skeleton(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var d = Array(0...y.count)
        for i in 1...x.count {
            var prevDiag = d[0]; d[0] = i
            for j in 1...y.count {
                let tmp = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prevDiag + (x[i - 1] == y[j - 1] ? 0 : 1))
                prevDiag = tmp
            }
        }
        return 1 - Double(d[y.count]) / Double(max(x.count, y.count))
    }

    private static let english = NLEmbedding.wordEmbedding(for: .english)

    /// Share of the words that are real English words (vocabulary lookup).
    static func englishWordRatio(_ text: String) -> Double {
        let words = text.lowercased().split { !$0.isLetter && $0 != "'" }.map { $0.replacingOccurrences(of: "'s", with: "") }
            .filter { !$0.isEmpty }
        guard !words.isEmpty, let e = english else { return 0 }
        return Double(words.filter { e.contains($0) }.count) / Double(words.count)
    }

    /// Korean particles / sentence endings that transliterated English never has.
    private static let koGrammar = ["은", "는", "을", "를", "에서", "에게", "이랑", "하고", "부터", "까지", "으로", "니다", "세요", "어요", "아요", "해요", "이에요", "예요", "죠", "까요", "네요", "었", "았", "겠"]
    static func hasKoreanGrammar(_ text: String) -> Bool {
        text.split { !$0.isLetter }.contains { w in w.count >= 2 && koGrammar.contains { w.hasSuffix($0) || w.contains($0) && $0.count >= 2 } }
    }

    /// Given the English lane's and another lane's text for the same audio: is the other lane just
    /// transliterating English speech?
    static func otherIsTransliteratedEnglish(en: String, other: String, otherCode: String) -> Bool {
        guard soundAlike(en, other) >= 0.4, englishWordRatio(en) >= 0.75 else { return false }
        if otherCode.hasPrefix("ko") && hasKoreanGrammar(other) { return false }
        return true
    }
}
