// CLI harness: feeds an audio file through VAD -> SpeechAnalyzer -> translator.
// usage: sttcli <audio-file> <locale> [google|apple|llm] [target-code]
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
let file = URL(fileURLWithPath: args[1])
let locale = args.count > 2 ? args[2] : "en-US"
let mode = args.count > 3 ? args[3] : "none"
let target = Language.byCode(args.count > 4 ? args[4] : "ko")
let source = Language.byCode(String(locale.prefix(2)))
let env = ProcessInfo.processInfo.environment

let translator: Translator? = switch mode {
case "google": GoogleTranslator(apiKey: "")
case "apple": AppleTranslator()
case "llm": LLMTranslator(config: .init(baseURL: env["STTTRANS_API_BASE"] ?? "", apiKey: env["STTTRANS_API_KEY"] ?? "",
                                         model: env["STTTRANS_MODEL"] ?? "gemma-4-31b-it", temperature: 0.2,
                                         historyTurns: 6, systemAsUser: false))
default: nil
}

let segs = AsyncStream<String>.makeStream()
let engine = SpeechEngine(callbacks: .init(
    volatile: { _ in }, finalSegment: { t, lang, at in
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.S"
        segs.continuation.yield("[\(lang)] (spoken \(f.string(from: at))) " + t) },
    level: { _, _ in }, status: { print("[status] \($0)") }))

let src = FileSource(url: file, speed: 1.0)
do {
        src.onFinished = { Task { try? await Task.sleep(for: .seconds(1)); await engine.stop(); segs.continuation.finish() } }
        let t0 = Date()
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss.S"; print("start \(tf.string(from: t0))")
        let langs = locale.split(separator: ",").map { l in (code: String(l.prefix(2)), localeID: String(l)) }
        try await engine.start(source: src, languages: langs, contextualStrings: [], vadConfig: .init(), recorder: nil)
        if env["STTTRANS_GATE_TEST"] != nil {   // pause between 4.5s and 10s of playback
            Task { try? await Task.sleep(for: .seconds(4.5 / src.speed)); print("[gate] paused"); engine.setListening(false)
                   try? await Task.sleep(for: .seconds(5.5 / src.speed)); print("[gate] resumed"); engine.setListening(true) }
        }
        var history: [(source: String, translation: String)] = []
        for await s in segs.stream {
            print(String(format: "[%5.1fs] SEG: %@", Date().timeIntervalSince(t0), s))
            if let translator {
                do {
                    let out = try await translator.translate(.init(text: s, source: source, target: target,
                                                                   history: history, userContext: "")) { _ in }
                    print("        TR : \(out)")
                    history.append((s, out))
                } catch { print("        ERR: \(error.localizedDescription)") }
            }
        }
    } catch { print("ERROR: \(error.localizedDescription)") }

