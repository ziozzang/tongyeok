import AVFoundation
import Foundation

enum STTEngineKind: String, CaseIterable, Identifiable {
    case apple = "Apple (온디바이스)"
    case whisper = "Whisper (API)"
    var id: String { rawValue }
    var short: String { self == .apple ? "Apple" : "Whisper" }
}

/// What AppModel needs from a recognizer, whichever backend it is.
protocol RecognitionEngine: AnyObject {
    func start(source: AudioSource, languages: [(code: String, localeID: String)], contextualStrings: [String],
               vadConfig: EnergyVAD.Config, recorder: AudioRecorder?) async throws
    func stop() async
    func setListening(_ on: Bool)
    var captureUtterances: Bool { get set }
}

extension SpeechEngine: RecognitionEngine {}

struct WhisperConfig {
    var baseURL: String
    var apiKey: String
    var model: String
}

/// Cloud recognizer: the energy VAD cuts utterances, each one goes to an OpenAI-compatible
/// `/audio/transcriptions` endpoint (Whisper via LiteLLM etc.). Requests run in parallel,
/// results are emitted in speech order. No live hypothesis, so the live row shows "…" meanwhile.
/// Auto-detect costs one request per candidate language per utterance (run in parallel).
final class WhisperEngine: RecognitionEngine, @unchecked Sendable {
    typealias Callbacks = SpeechEngine.Callbacks
    static let sampleRate = 16_000.0

    private let config: WhisperConfig
    private let callbacks: Callbacks
    private let vad = EnergyVAD()
    private let lock = NSLock()
    private var source: AudioSource?
    private var recorder: AudioRecorder?
    private var languages: [String] = []      // app language codes; >1 = auto-detect among them
    private var prompt = ""

    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var monoConverter: AVAudioConverter?
    private var converter: AVAudioConverter?

    // Current utterance (audio thread only).
    private var samples: [Float] = []
    private var startedAt: Date?

    /// One pending request per utterance, awaited in order by the emitter.
    private var jobCont: AsyncStream<Task<(text: String, lang: String, at: Date)?, Never>>.Continuation?
    private var emitTask: Task<Void, Never>?
    private var inFlight = 0

    private var gateOpen = true
    private var gateWasOpen = true
    private var lastLevelEmit = Date.distantPast
    var captureUtterances = false

    init(config: WhisperConfig, callbacks: Callbacks) { self.config = config; self.callbacks = callbacks }

    func setListening(_ on: Bool) { lock.withLock { gateOpen = on } }

    func start(source src: AudioSource, languages: [(code: String, localeID: String)], contextualStrings: [String],
               vadConfig: EnergyVAD.Config, recorder: AudioRecorder?) async throws {
        guard !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AppError.speech("Whisper API 엔드포인트가 설정되지 않았습니다 (설정 ⌘, > 음성 인식).")
        }
        self.languages = languages.map(\.code)
        // Whisper's prompt biases spelling of names/terms (it's a "previous text" hint, ~224 tokens max).
        prompt = String(contextualStrings.joined(separator: ", ").prefix(400))
        self.recorder = recorder
        vad.reset()
        var vc = vadConfig
        vc.maxSegmentSec = min(vc.maxSegmentSec, 25)   // Whisper works on ≤30 s windows
        vad.config = vc

        let (jobs, cont) = AsyncStream.makeStream(of: Task<(text: String, lang: String, at: Date)?, Never>.self)
        jobCont = cont
        emitTask = Task { [weak self] in
            for await job in jobs {
                let result = await job.value
                guard let self else { break }
                let busy = self.lock.withLock { self.inFlight -= 1; return self.inFlight }
                if busy == 0 { self.callbacks.volatile("") }
                if let r = result { self.callbacks.finalSegment(r.text, r.lang, r.at) }
            }
        }

        try await src.start { [weak self] buffer in self?.ingest(buffer) }
        source = src
        let names = self.languages.joined(separator: "/")
        callbacks.status(self.languages.count > 1 ? "듣는 중 · Whisper (자동 감지: \(names))" : "듣는 중 · Whisper (\(names))")
    }

    func stop() async {
        await source?.stop()
        source = nil
        flushUtterance()
        jobCont?.finish()
        if let t = emitTask { _ = await withTimeout(seconds: 20) { await t.value } }
        emitTask?.cancel(); emitTask = nil; jobCont = nil
        callbacks.volatile("")
        recorder?.close(); recorder = nil
        converter = nil; monoConverter = nil
        callbacks.status("정지됨")
    }

    // MARK: Audio path (audio thread)

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let mono = toMonoFloat(buffer) else { return }
        recorder?.write(mono)
        let open = lock.withLock { gateOpen }
        if !open {
            if gateWasOpen && vad.isSpeech { flushUtterance() }
            if gateWasOpen { vad.reset() }
            gateWasOpen = false
            emitLevel(db: EnergyVAD.rmsDB(mono), speech: false)
            return
        }
        gateWasOpen = true
        guard let converted = resample(mono) else { return }
        for e in vad.process(analysisBuffer: mono, forwardBuffer: converted) {
            switch e {
            case .speech(let b):
                if startedAt == nil {
                    // First buffer is pre-roll, captured ~preRoll+onset ago.
                    startedAt = Date().addingTimeInterval(-(vad.config.preRollMs + vad.config.onsetMs) / 1000)
                }
                if let d = b.floatChannelData { samples.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(b.frameLength))) }
            case .segmentEnd:
                flushUtterance()
            }
        }
        emitLevel(db: vad.levelDB, speech: vad.isSpeech)
    }

    private func flushUtterance() {
        let audio = samples, at = startedAt ?? Date()
        samples = []; startedAt = nil
        // Too short to be words (clicks, coughs) -> Whisper tends to hallucinate on these.
        guard Double(audio.count) / Self.sampleRate >= 0.4, let cont = jobCont else { return }
        if captureUtterances { callbacks.utterance(audio, at, Date()) }
        let wav = Self.wav(audio)
        lock.withLock { inFlight += 1 }
        callbacks.volatile("…")
        cont.yield(Task { [weak self] in await self?.recognize(wav).map { ($0.0, $0.1, at) } })
    }

    private func emitLevel(db: Float, speech: Bool) {
        let now = Date()
        if now.timeIntervalSince(lastLevelEmit) > 0.05 { lastLevelEmit = now; callbacks.level(db, speech) }
    }

    // MARK: Request

    /// (text, app language code), or nil for silence / noise / failure.
    private func recognize(_ wav: Data) async -> (String, String)? {
        let best: (r: Result, lang: String)?
        if languages.count == 1 {
            best = await request(wav, language: languages[0]).map { ($0, languages[0]) }
        } else {
            // Auto-detect: the server's own language ID isn't reliable (it may default to one language),
            // so transcribe pinned to each candidate and keep the one whose output really is in that
            // language. Pinned to the wrong one, Whisper either stays in the spoken language anyway or
            // translates with a low log-prob; either way that candidate loses.
            let results = await withTaskGroup(of: (Result, String)?.self) { group in
                for code in languages { group.addTask { await self.request(wav, language: code).map { ($0, code) } } }
                var out: [(Result, String)] = []
                for await r in group { if let r { out.append(r) } }
                return out
            }
            let scored = results.map { r, code in (r: r, lang: code, score: LanguageID.match(r.text, code) * r.confidence) }
            for c in scored { dlog(String(format: "whisper cand [%@] score=%.3f conf=%.2f: %@", c.lang, c.score, c.r.confidence, c.r.text)) }
            best = scored.max { $0.score < $1.score }.map { ($0.r, $0.lang) }
        }
        guard let (r, lang) = best else { return nil }
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isHallucination(text) || NoiseFilter.isNoise(text, confidence: r.confidence) {
            dlog("whisper noise dropped: '\(text)' conf=\(r.confidence) nospeech=\(r.noSpeech)")
            return nil
        }
        dlog(String(format: "whisper [%@] conf=%.2f: %@", lang, r.confidence, text))
        return (text, lang)
    }

    private struct Result { var text: String; var confidence: Double; var noSpeech: Double }

    private func request(_ wav: Data, language: String?, attempt: Int = 0) async -> Result? {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { base.removeLast("/chat/completions".count) }
        guard let url = URL(string: base.hasSuffix("/audio/transcriptions") ? base : base + "/audio/transcriptions") else {
            callbacks.status("Whisper: 잘못된 URL"); return nil
        }
        let boundary = "tongyeok-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        var fields = ["model": config.model, "response_format": "verbose_json", "temperature": "0"]
        if let language { fields["language"] = Self.whisperCode(language) }
        if !prompt.isEmpty { fields["prompt"] = prompt }
        req.httpBody = Self.multipart(fields: fields, file: wav, boundary: boundary)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                // 5xx / rate limit: one retry, the utterance is worth it.
                if attempt == 0, http.statusCode >= 500 || http.statusCode == 429 {
                    try? await Task.sleep(for: .milliseconds(600))
                    return await request(wav, language: language, attempt: 1)
                }
                callbacks.status("Whisper HTTP \(http.statusCode): \(body)")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let segs = json["segments"] as? [[String: Any]] ?? []
            // Drop segments Whisper itself thinks are silence (the classic hallucination source).
            let kept = segs.filter { s in
                let ns = s["no_speech_prob"] as? Double ?? 0, lp = s["avg_logprob"] as? Double ?? 0
                return !(ns > 0.6 && lp < -0.7)
            }
            let text = segs.isEmpty ? (json["text"] as? String ?? "")
                : kept.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            let logprobs = kept.compactMap { $0["avg_logprob"] as? Double }
            let conf = logprobs.isEmpty ? 0.8 : exp(logprobs.reduce(0, +) / Double(logprobs.count))
            let noSpeech = segs.compactMap { $0["no_speech_prob"] as? Double }.max() ?? 0
            return Result(text: text, confidence: conf, noSpeech: noSpeech)
        } catch {
            if attempt == 0, (error as? URLError)?.code != .cancelled {
                try? await Task.sleep(for: .milliseconds(600))
                return await request(wav, language: language, attempt: 1)
            }
            callbacks.status("Whisper 오류: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Language

    static func whisperCode(_ code: String) -> String { code.hasPrefix("zh") ? "zh" : String(code.prefix(2)) }

    /// Stock phrases Whisper produces from silence / music (YouTube-subtitle training data).
    private static let hallucinations: [String] = [
        "thank you for watching", "thanks for watching", "please subscribe", "subtitles by", "transcribed by",
        "시청해주셔서 감사합니다", "시청해 주셔서 감사합니다", "구독과 좋아요", "자막 제공", "mbc 뉴스",
        "ご視聴ありがとうございました", "请不吝点赞", "字幕",
    ]
    static func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased()
        return hallucinations.contains { t.contains($0) } && t.count < 60
    }

    // MARK: Audio helpers

    private func toMonoFloat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let f = buffer.format
        if f.commonFormat == .pcmFormatFloat32 && f.channelCount == 1 && !f.isInterleaved { return buffer }
        guard let mf = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: f.sampleRate, channels: 1, interleaved: false)
        else { return nil }
        if monoConverter == nil || monoConverter?.inputFormat != f { monoConverter = AVAudioConverter(from: f, to: mf) }
        guard let conv = monoConverter, let out = AVAudioPCMBuffer(pcmFormat: mf, frameCapacity: buffer.frameLength) else { return nil }
        do { try conv.convert(to: out, from: buffer) } catch { return nil }
        return out
    }

    private func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate + 64))
        else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        return (error == nil && out.frameLength > 0) ? out : nil
    }

    /// 16 kHz mono 16-bit PCM WAV.
    static func wav(_ samples: [Float]) -> Data {
        var d = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate), bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return d
    }

    static func multipart(fields: [String: String], file: Data, boundary: String) -> Data {
        var d = Data()
        for (k, v) in fields {
            d.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        d.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        d.append(file)
        d.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return d
    }
}
