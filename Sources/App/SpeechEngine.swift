import AVFoundation
import Speech
import NaturalLanguage

final class SpeechEngine: @unchecked Sendable {
    struct Callbacks {
        var volatile: @Sendable (String) -> Void
        var finalSegment: @Sendable (_ text: String, _ languageCode: String, _ startedAt: Date) -> Void
        var level: @Sendable (Float, Bool) -> Void
        var status: @Sendable (String) -> Void
    }

    private enum Work { case speech(AVAudioPCMBuffer), segmentEnd }
    /// Silence fed after each segment: the model needs look-ahead audio to finish the last words.
    static var tailPadSec = Double(ProcessInfo.processInfo.environment["STTTRANS_TAILPAD"] ?? "") ?? 0.6
    /// Fraction of the pad placed before the finalize point (the rest is look-ahead after it).
    static var finalizeFrac = Double(ProcessInfo.processInfo.environment["STTTRANS_FINFRAC"] ?? "") ?? 0.67

    private let callbacks: Callbacks
    private let vad = EnergyVAD()
    private let lock = NSLock()

    private var source: AudioSource?
    private var analyzer: SpeechAnalyzer?
    /// One transcriber per candidate language, all fed by the same analyzer (language auto-detect).
    private final class Lane {
        let code: String                  // app language code (Language.code)
        let transcriber: SpeechTranscriber
        var pendingFinal = ""             // finalized text not yet emitted
        var lastVolatile = ""             // latest non-final hypothesis
        var confSum = 0.0, confWeight = 0.0
        var lastFinalEnd = CMTime.zero
        var firstStart: CMTime?           // audio time where the current utterance began
        var task: Task<Void, Never>?
        init(code: String, transcriber: SpeechTranscriber) { self.code = code; self.transcriber = transcriber }
        func clear() { pendingFinal = ""; lastVolatile = ""; confSum = 0; confWeight = 0; firstStart = nil }
        var candidate: String { SpeechEngine.join(pendingFinal, lastVolatile).trimmingCharacters(in: .whitespacesAndNewlines) }
        var avgConfidence: Double { confWeight > 0 ? confSum / confWeight : 0.5 }
    }
    private var lanes: [Lane] = []
    private var analyzerFormat: AVAudioFormat?
    private var inputCont: AsyncStream<AnalyzerInput>.Continuation?
    private var workCont: AsyncStream<Work>.Continuation?
    private var workTask: Task<Void, Never>?

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var monoConverter: AVAudioConverter?
    private var recorder: AudioRecorder?

    // Timeline of audio actually fed to the analyzer (silence skipped by VAD is not counted).
    private var fedFrames: Int64 = 0
    // Set when VAD closes a segment; flush once finalized results reach this time.
    private var flushTarget: CMTime?
    private var flushGeneration = 0
    // Audio time already emitted; late results that start before this belong to a flushed utterance.
    private var flushedThrough = CMTime.zero
    // Maps analyzer audio time -> wall clock (one anchor per VAD segment, since silence is skipped).
    private var timeAnchors: [(time: Double, date: Date)] = []
    private var needAnchor = true

    private func wallClock(for t: CMTime) -> Date {
        let sec = t.seconds
        guard let a = timeAnchors.last(where: { $0.time <= sec + 0.01 }) ?? timeAnchors.first else { return Date() }
        return a.date.addingTimeInterval(sec - a.time)
    }
    private var lastLevelEmit = Date.distantPast
    // Pause / push-to-talk gate. Closed = audio is still recorded but not recognized.
    private var gateOpen = true
    private var gateWasOpen = true

    func setListening(_ on: Bool) {
        lock.lock(); gateOpen = on; lock.unlock()
    }

    init(callbacks: Callbacks) { self.callbacks = callbacks }

    // MARK: Locales / assets

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
    }

    private func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed { return }
        if status == .unsupported { throw AppError.speech("\(locale.identifier) 음성 인식을 지원하지 않습니다.") }
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            callbacks.status("음성 모델 다운로드 중… (\(locale.identifier))")
            try await req.downloadAndInstall()
        }
    }

    // MARK: Start / stop

    /// `languages`: (app language code, speech locale id). More than one = auto-detect among them.
    func start(input: InputKind, languages: [(code: String, localeID: String)], contextualStrings: [String],
               vadConfig: EnergyVAD.Config, recorder: AudioRecorder?) async throws {
        let src: AudioSource = input == .microphone ? MicrophoneSource() : SystemAudioSource()
        try await start(source: src, languages: languages, contextualStrings: contextualStrings,
                        vadConfig: vadConfig, recorder: recorder)
    }

    func start(source src: AudioSource, languages: [(code: String, localeID: String)], contextualStrings: [String],
               vadConfig: EnergyVAD.Config, recorder: AudioRecorder?) async throws {
        var lanes: [Lane] = []
        for lang in languages {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: lang.localeID)) else {
                throw AppError.speech("\(lang.localeID) 음성 인식을 지원하지 않습니다.")
            }
            dlog("locale resolved: \(locale.identifier)")
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                      reportingOptions: [.volatileResults],
                                      attributeOptions: [.transcriptionConfidence])
            try await ensureAssets(for: t, locale: locale)
            lanes.append(Lane(code: lang.code, transcriber: t))
        }
        let modules: [any SpeechModule] = lanes.map(\.transcriber)
        let localeNames = lanes.map(\.code).joined(separator: "/")

        dlog("assets ok")
        let analyzer = SpeechAnalyzer(modules: modules,
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw AppError.speech("호환 오디오 포맷을 찾을 수 없습니다.")
        }
        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(ctx)
        }
        dlog("format: \(format)")
        callbacks.status("음성 모델 준비 중…")
        try await analyzer.prepareToAnalyze(in: format)

        dlog("prepared")
        let (inputSeq, inputCont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: inputSeq)

        dlog("analyzer started")
        self.lanes = lanes
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.inputCont = inputCont
        self.recorder = recorder
        vad.reset()
        vad.config = vadConfig

        for lane in lanes {
            lane.task = Task { [weak self] in
                do {
                    for try await result in lane.transcriber.results {
                        dlog(String(format: "[%@] final=%d range=%.2f-%.2f: %@", lane.code, result.isFinal ? 1 : 0,
                                     result.range.start.seconds, result.range.end.seconds, String(result.text.characters)))
                        self?.handle(result, lane: lane)
                    }
                } catch {
                    self?.callbacks.status("인식 오류: \(error.localizedDescription)")
                }
            }
        }

        // Serial worker: forwards speech to the analyzer and finalizes on VAD segment end.
        let (workSeq, workCont) = AsyncStream.makeStream(of: Work.self)
        self.workCont = workCont
        workTask = Task { [weak self] in
            for await item in workSeq {
                guard let self else { break }
                switch item {
                case .speech(let buf):
                    let start = CMTime(value: self.fedFrames, timescale: CMTimeScale(buf.format.sampleRate))
                    if self.needAnchor {
                        // First buffer of a segment is pre-roll: it was captured ~preRoll+onset ago.
                        let back = (self.vad.config.preRollMs + self.vad.config.onsetMs) / 1000
                        self.lock.withLock {
                            self.timeAnchors.append((start.seconds, Date().addingTimeInterval(-back)))
                            if self.timeAnchors.count > 500 { self.timeAnchors.removeFirst(100) }
                        }
                        self.needAnchor = false
                    }
                    self.fedFrames += Int64(buf.frameLength)
                    self.inputCont?.yield(AnalyzerInput(buffer: buf, bufferStartTime: start))
                case .segmentEnd:
                    self.needAnchor = true
                    dlog("VAD segment end -> finalize")
                    // Pad with real silence so the model sees a natural utterance end before finalizing.
                    if let fmt = self.analyzerFormat,
                       let pad = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fmt.sampleRate * Self.tailPadSec)) {
                        pad.frameLength = pad.frameCapacity
                        if let i = pad.int16ChannelData { memset(i[0], 0, Int(pad.frameLength) * 2) }
                        if let f = pad.floatChannelData { memset(f[0], 0, Int(pad.frameLength) * 4) }
                        let start = CMTime(value: self.fedFrames, timescale: CMTimeScale(fmt.sampleRate))
                        self.fedFrames += Int64(pad.frameLength)
                        self.inputCont?.yield(AnalyzerInput(buffer: pad, bufferStartTime: start))
                    }
                    // NB: finalize(through: nil) waits for end-of-input and would block forever on a live stream.
                    // Finalize only up to the middle of the silence pad: the analyzer waits for audio
                    // *after* the finalize point, so finalizing at the very end of input stalls.
                    let rate = self.analyzerFormat?.sampleRate ?? 16_000
                    let endFrames = self.fedFrames - Int64(rate * Self.tailPadSec * (1 - Self.finalizeFrac))
                    let end = CMTime(value: endFrames, timescale: CMTimeScale(rate))
                    // Fire and forget: never block the audio feed on finalization.
                    dlog(String(format: "flush point %.2f", end.seconds))
                    let gen = self.requestFlush(through: end)
                    if let analyzer = self.analyzer {
                        Task { [weak self] in
                            let t0 = Date(); try? await analyzer.finalize(through: end)
                            dlog("finalize returned after \(Date().timeIntervalSince(t0))s")
                            try? await Task.sleep(for: .milliseconds(100))  // let results be delivered
                            self?.flushIfCurrent(gen)
                        }
                    }
                }
            }
        }

        try await src.start { [weak self] buffer in self?.ingest(buffer) }
        source = src
        dlog("source started")
        callbacks.status(lanes.count > 1 ? "듣는 중 (자동 감지: \(localeNames))" : "듣는 중 (\(localeNames))")
    }

    func stop() async {
        dlog("stop: source"); await source?.stop()
        source = nil
        dlog("stop: work"); workCont?.finish()
        if let t = workTask { _ = await withTimeout(seconds: 6) { await t.value } }
        workTask?.cancel()
        dlog("stop: analyzer finish"); inputCont?.finish()
        if let analyzer {
            _ = await withTimeout(seconds: 5) { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        dlog("stop: results")
        for lane in lanes {
            if let t = lane.task { _ = await withTimeout(seconds: 3) { await t.value } }
            lane.task?.cancel()
        }
        if let analyzer { await analyzer.cancelAndFinishNow() }
        dlog("stop: done")
        flushPending()
        callbacks.volatile("")
        analyzer = nil; lanes = []; inputCont = nil; workCont = nil
        workTask = nil; fedFrames = 0; flushedThrough = .zero; timeAnchors = []; needAnchor = true
        converter = nil; monoConverter = nil
        recorder?.close()
        recorder = nil
        callbacks.status("정지됨")
    }

    // MARK: Audio path (audio thread)

    private var ingestCount = 0
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        ingestCount += 1
        if ingestCount == 1 || ingestCount % 200 == 0 {
            dlog("ingest #\(ingestCount) fmt=\(buffer.format) frames=\(buffer.frameLength) db=\(EnergyVAD.rmsDB(buffer)) gate=\(gateOpen) speech=\(vad.isSpeech) floor=\(vad.noiseFloorDB)")
        }
        guard let target = analyzerFormat, let mono = toMonoFloat(buffer) else { return }
        recorder?.write(mono)
        lock.lock(); let open = gateOpen; lock.unlock()
        if !open {
            // Gate just closed mid-utterance: finalize what was said so far.
            if gateWasOpen && vad.isSpeech { workCont?.yield(.segmentEnd) }
            if gateWasOpen { vad.reset() }
            gateWasOpen = false
            emitLevel(db: EnergyVAD.rmsDB(mono), speech: false)
            return
        }
        gateWasOpen = true
        guard let converted = convert(mono, to: target) else { return }
        let events = vad.process(analysisBuffer: mono, forwardBuffer: converted)
        for e in events {
            switch e {
            case .speech(let b): workCont?.yield(.speech(b))
            case .segmentEnd: workCont?.yield(.segmentEnd)
            }
        }
        emitLevel(db: vad.levelDB, speech: vad.isSpeech)
    }

    private func emitLevel(db: Float, speech: Bool) {
        let now = Date()
        if now.timeIntervalSince(lastLevelEmit) > 0.05 {
            lastLevelEmit = now
            callbacks.level(db, speech)
        }
    }

    /// Downmix to mono Float32 at the source rate (used for VAD energy + recording).
    private func toMonoFloat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let f = buffer.format
        if f.commonFormat == .pcmFormatFloat32 && f.channelCount == 1 && !f.isInterleaved { return buffer }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: f.sampleRate,
                                             channels: 1, interleaved: false) else { return nil }
        if monoConverter == nil || monoConverter?.inputFormat != f {
            monoConverter = AVAudioConverter(from: f, to: monoFormat)
        }
        guard let conv = monoConverter,
              let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { return nil }
        do { try conv.convert(to: out, from: buffer) } catch { return nil }
        return out
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
            converterInputFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return (error == nil && out.frameLength > 0) ? out : nil
    }

    // MARK: Results

    private func handle(_ result: SpeechTranscriber.Result, lane: Lane) {
        var text = String(result.text.characters)
        lock.lock()
        // A slower lane finishing an utterance that was already emitted: drop it.
        if CMTimeCompare(result.range.start, CMTimeSubtract(flushedThrough, CMTime(value: 1, timescale: 5))) < 0 {
            lock.unlock()
            dlog("[\(lane.code)] drop stale result")
            return
        }
        if lane.firstStart == nil, result.range.start.isNumeric { lane.firstStart = result.range.start }
        if result.isFinal {
            lane.lastFinalEnd = CMTimeMaximum(lane.lastFinalEnd, result.range.end)
            if Self.letterCount(text) * 2 < Self.letterCount(lane.lastVolatile) {
                dlog("degenerate final '\(text)' -> using volatile '\(lane.lastVolatile)'")
                text = lane.lastVolatile
            } else {
                for run in result.text.runs {
                    guard let c = run.transcriptionConfidence else { continue }
                    let w = Double(result.text[run.range].characters.count)
                    lane.confSum += c * w; lane.confWeight += w
                }
            }
            lane.lastVolatile = ""
            lane.pendingFinal = Self.join(lane.pendingFinal, text)
        } else {
            lane.lastVolatile = text
        }
        let runOn = lane.pendingFinal.count > 220
            && lane.pendingFinal.trimmingCharacters(in: .whitespaces).last.map { ".?!。？！".contains($0) } == true
        let live = liveText()
        lock.unlock()
        callbacks.volatile(live)
        // Long run-on speech: emit on sentence boundaries without waiting for VAD.
        if result.isFinal && runOn { flushPending(); return }
        // Segment already closed by VAD but results were late: flush shortly after they land.
        if result.isFinal && waitingForLate() {
            let delay = lanesCountDelay
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                self?.flushIfWaiting()
            }
        }
    }

    /// Live text of the lane that currently looks most plausible. Caller holds `lock`.
    private func liveText() -> String {
        let texts = lanes.map { (lane: $0, text: Self.join($0.pendingFinal, $0.lastVolatile)) }
        if lanes.count == 1 { return texts[0].text }
        return texts.max { LanguageID.match($0.text, $0.lane.code) < LanguageID.match($1.text, $1.lane.code) }?.text ?? ""
    }

    private var lanesCountDelay: Int { lanes.count > 1 ? 400 : 150 }

    /// True when VAD closed a segment and its flush attempts already ran without any text.
    private var lateWaiting = false
    private func waitingForLate() -> Bool { lock.withLock { lateWaiting && flushTarget != nil } }
    private func flushIfWaiting() { if waitingForLate() { flushPending() } }

    private func flushIfCurrent(_ gen: Int) {
        lock.lock()
        let current = flushTarget != nil && flushGeneration == gen
        lock.unlock()
        if current { flushPending() }
    }

    @discardableResult
    private func requestFlush(through end: CMTime) -> Int {
        lock.lock()
        // Model already finalized everything it heard -> nothing in flight, flush now.
        let nothingInFlight = lanes.allSatisfy { $0.lastVolatile.trimmingCharacters(in: .whitespaces).isEmpty }
            && lanes.contains { !$0.pendingFinal.isEmpty }
        flushTarget = end
        flushGeneration += 1
        let gen = flushGeneration
        lock.unlock()
        if nothingInFlight { flushPending(); return gen }
        // Fallback in case no finalized result arrives for this segment. With several lanes the slowest
        // one may hold back; stale late results are dropped, so we can flush early.
        let fallback = lanes.count > 1 ? 1.2 : 3.0
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(fallback))
            self?.flushIfCurrent(gen)
        }
        return gen
    }

    /// Emits the pending text of the best lane: confidence x "text really is in this lane's language".
    private func flushPending() {
        lock.lock()
        var best: (text: String, code: String, score: Double, date: Date, conf: Double)?
        for lane in lanes {
            let text = lane.candidate
            guard Self.letterCount(text) > 0 else { continue }
            let score = lanes.count == 1 ? 1 : lane.avgConfidence * LanguageID.match(text, lane.code)
            dlog(String(format: "lane %@ conf=%.2f score=%.3f | %@", lane.code, lane.avgConfidence, score, text))
            let date = lane.firstStart.map(wallClock(for:)) ?? Date()
            if best == nil || score > best!.score { best = (text, lane.code, score, date, lane.avgConfidence) }
        }
        guard best != nil else {
            // Nothing recognized yet (model can lag several seconds, e.g. while warming up):
            // keep waiting; do NOT mark this audio as emitted or late results would be dropped.
            lock.unlock()
            lateWaiting = true
            dlog("flush: nothing yet, waiting")
            return
        }
        lateWaiting = false
        flushedThrough = lanes.reduce(flushTarget ?? flushedThrough) { CMTimeMaximum($0, $1.lastFinalEnd) }
        lanes.forEach { $0.clear() }
        flushTarget = nil
        lock.unlock()
        callbacks.volatile("")
        guard let best else { return }
        // Multi-lane: a low winning score means neither language model believed it -> noise.
        let conf = lanes.count > 1 ? min(best.conf, best.score + 0.2) : best.conf
        if NoiseFilter.isNoise(best.text, confidence: conf) {
            dlog("noise dropped: '\(best.text)' conf=\(conf)")
            return
        }
        callbacks.finalSegment(best.text, best.code, best.date)
    }

    private static func letterCount(_ s: String) -> Int {
        s.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.count
    }

    fileprivate static func join(_ a: String, _ b: String) -> String {
        let b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

// MARK: - Low-quality recorder

enum RecordFormat: String, CaseIterable, Identifiable {
    case m4a = "M4A (AAC 32kbps)"
    case aiff = "AIFF (16kHz 16bit)"
    case none = "녹음 안 함"
    var id: String { rawValue }
}

/// Writes mono audio at 16 kHz. Thread-confined to the audio callback.
final class AudioRecorder: @unchecked Sendable {
    let url: URL
    private let file: AVAudioFile
    private var converter: AVAudioConverter?
    private let processingFormat: AVAudioFormat

    init(directory: URL, format: RecordFormat, stamp: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings: [String: Any]
        switch format {
        case .aiff, .none:
            url = directory.appendingPathComponent("\(stamp).aiff")
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsFloatKey: false]
        case .m4a:
            url = directory.appendingPathComponent("\(stamp).m4a")
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 32_000]
        }
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        processingFormat = file.processingFormat
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        var out = buffer
        if buffer.format != processingFormat {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: processingFormat)
            }
            guard let converter,
                  let o = AVAudioPCMBuffer(pcmFormat: processingFormat,
                                           frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * processingFormat.sampleRate / buffer.format.sampleRate + 64))
            else { return }
            var consumed = false
            var err: NSError?
            converter.convert(to: o, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }
            guard err == nil, o.frameLength > 0 else { return }
            out = o
        }
        try? file.write(from: out)
    }

    func close() { file.close() }
}
