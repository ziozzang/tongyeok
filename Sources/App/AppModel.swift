import SwiftUI
import AppKit

enum ListenMode: String, CaseIterable, Identifiable {
    case always = "상시 듣기"
    case pushToTalk = "누를 때만"
    var id: String { rawValue }
}

struct Segment: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    var source: String
    var sourceLang: String   // detected / selected language of `source`
    var targetLang: String
    var translation: String = ""
    var state: State = .queued
    enum State: Equatable { case queued, translating, done, failed(String) }
}

@MainActor
final class AppModel: ObservableObject {
    // Settings
    @AppStorage("inputKind") var inputKindRaw = InputKind.microphone.rawValue
    @AppStorage("sourceLang") var sourceCode = "en"
    @AppStorage("targetLang") var targetCode = "ko"
    @AppStorage("translator") var translatorRaw = TranslatorKind.llm.rawValue
    @AppStorage("llmBaseURL") var llmBaseURL = ProcessInfo.processInfo.environment["STTTRANS_API_BASE"] ?? ""
    @AppStorage("llmAPIKey") var llmAPIKey = ProcessInfo.processInfo.environment["STTTRANS_API_KEY"] ?? ""
    @AppStorage("llmModel") var llmModel = ProcessInfo.processInfo.environment["STTTRANS_MODEL"] ?? "gemma-4-31b-it"
    @AppStorage("llmTemperature") var llmTemperature = 0.2
    @AppStorage("llmHistory") var llmHistory = 6
    @AppStorage("llmSystemAsUser") var llmSystemAsUser = false
    @AppStorage("googleAPIKey") var googleAPIKey = ""
    @AppStorage("userContext") var userContext = ""
    @AppStorage("vadMargin") var vadMargin = 9.0
    @AppStorage("vadHangoverMs") var vadHangoverMs = 700.0
    @AppStorage("vadMaxSec") var vadMaxSec = 14.0
    @AppStorage("autoScroll") var autoScroll = true
    @AppStorage("copyTimestamps") var copyTimestamps = true
    @AppStorage("sentenceMerge") var sentenceMerge = true
    @AppStorage("mergeHoldSec") var mergeHoldSec = 2.5
    @AppStorage("showTimestamps") var showTimestamps = true
    /// Listen for both the source and target languages; translate each utterance into the other one.
    @AppStorage("autoDetect") var autoDetect = false
    @AppStorage("listenMode") var listenModeRaw = ListenMode.always.rawValue
    var listenMode: ListenMode { ListenMode(rawValue: listenModeRaw) ?? .always }
    @AppStorage("recordFormat") var recordFormatRaw = RecordFormat.m4a.rawValue
    @AppStorage("saveDir") var saveDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("STTTrans").path

    // Live state
    @Published var segments: [Segment] = []
    @Published var volatileText = ""
    /// Incomplete sentence waiting for its continuation (shown in the live row).
    @Published var heldText = ""
    private var held: (text: String, lang: String, at: Date)?
    private var holdGeneration = 0
    @Published var isRunning = false
    @Published var isBusy = false
    @Published var status = "대기"
    @Published var levelDB: Float = -100
    @Published var isSpeech = false
    @Published var lastError: String?
    @Published var lastRecording: URL?
    @Published var confirmReset = false
    @Published var isPaused = false      // 상시 mode: temporarily not recognizing
    @Published var pttHeld = false       // push-to-talk key is down

    /// Whether audio currently goes to the recognizer.
    var isListening: Bool { listenMode == .always ? !isPaused : pttHeld }

    func updateGate() { engine?.setListening(isListening) }

    func togglePause() {
        guard isRunning, listenMode == .always else { return }
        isPaused.toggle()
        updateGate()
        if isPaused {
            // Give the engine a moment to finalize, then close the pending sentence.
            Task { try? await Task.sleep(for: .seconds(2)); if self.isPaused { self.emitHeld() } }
        }
        status = isPaused ? "일시정지됨 (Space 또는 ⌘P로 재개)" : "듣는 중"
    }

    func setPushToTalk(_ down: Bool) {
        guard pttHeld != down else { return }
        pttHeld = down
        updateGate()
    }

    /// Reset from UI/menu: asks first when there is content to lose.
    func requestReset() {
        if segments.isEmpty { reset() } else { confirmReset = true }
    }

    private var engine: SpeechEngine?
    private var translateQueue: [UUID] = []
    private var translateTask: Task<Void, Never>?
    private var translator: Translator?
    private var appleTranslator = AppleTranslator()

    var source: Language { Language.byCode(sourceCode) }
    var target: Language { Language.byCode(targetCode) }
    var inputKind: InputKind { InputKind(rawValue: inputKindRaw) ?? .microphone }
    var translatorKind: TranslatorKind { TranslatorKind(rawValue: translatorRaw) ?? .llm }
    var recordFormat: RecordFormat { RecordFormat(rawValue: recordFormatRaw) ?? .m4a }


    // MARK: Control

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        lastError = nil
        let engine = SpeechEngine(callbacks: .init(
            volatile: { t in Task { @MainActor in self.volatileText = t } },
            finalSegment: { t, lang, at in Task { @MainActor in self.receive(t, lang: lang, at: at) } },
            level: { db, sp in Task { @MainActor in self.levelDB = db; self.isSpeech = sp } },
            status: { s in Task { @MainActor in self.status = s } }
        ))
        engine.setListening(isListening)
        var vad = EnergyVAD.Config()
        vad.marginDB = Float(vadMargin)
        vad.hangoverMs = vadHangoverMs
        vad.maxSegmentSec = vadMaxSec

        let recorder: AudioRecorder?
        if recordFormat != .none {
            recorder = try? AudioRecorder(directory: URL(fileURLWithPath: saveDir), format: recordFormat,
                                          stamp: Self.stamp())
            lastRecording = recorder?.url
        } else { recorder = nil }

        let codes = autoDetect && sourceCode != targetCode ? [sourceCode, targetCode] : [sourceCode]
        let languages = codes.map { (code: $0, localeID: Language.byCode($0).speechLocaleID) }
        let terms = userContext.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count < 40 }
        let input = inputKind
        Task {
            do {
                if let testFile = ProcessInfo.processInfo.environment["STTTRANS_TEST_FILE"] {
                    // Debug hook: feed an audio file in real time instead of a live source.
                    try await engine.start(source: FileSource(url: URL(fileURLWithPath: testFile)), languages: languages,
                                           contextualStrings: terms, vadConfig: vad, recorder: recorder)
                } else {
                    try await engine.start(input: input, languages: languages, contextualStrings: terms,
                                           vadConfig: vad, recorder: recorder)
                }
                self.engine = engine
                self.isRunning = true
                self.isPaused = false
                self.updateGate()
            } catch {
                await engine.stop()
                self.lastError = error.localizedDescription
                self.status = "오류"
            }
            self.isBusy = false
        }
    }

    /// ⇄ Swap original/translation languages. Restarts recognition if the listened language changes.
    func swapLanguages() {
        guard !isBusy else { return }
        (sourceCode, targetCode) = (targetCode, sourceCode)
        if isRunning && !autoDetect {
            Task { await stopAndWait(); start() }
        }
    }

    /// Changing auto-detect while running needs a new recognizer session.
    func restartIfRunning() {
        guard isRunning, !isBusy else { return }
        Task { await stopAndWait(); start() }
    }

    func stop() {
        guard isRunning, !isBusy else { return }
        Task { await stopAndWait() }
    }

    func stopAndWait() async {
        guard isRunning, let engine else { return }
        isBusy = true
        await engine.stop()
        try? await Task.sleep(for: .milliseconds(50))   // let the engine's last segment land
        emitHeld()
        self.engine = nil
        isRunning = false
        isBusy = false
        levelDB = -100; isSpeech = false
        if let r = lastRecording { status = "정지됨 · 녹음: \(r.lastPathComponent)" }
    }

    /// Clears transcript + translation context, cancels in-flight translations,
    /// and restarts the recognizer with a fresh session if it was running.
    func reset() {
        guard !isBusy else { return }
        translateTask?.cancel()
        translateTask = nil
        translateQueue.removeAll()
        segments.removeAll()
        volatileText = ""
        held = nil; heldText = ""; holdGeneration += 1; lastSoft = nil
        lastError = nil
        appleTranslator = AppleTranslator()
        if isRunning {
            Task {
                await stopAndWait()
                start()
            }
        } else {
            status = "리셋됨"
        }
    }

    // MARK: Translation pipeline (serial, ordered, context-aware)

    // MARK: Sentence assembly

    /// Last emitted segment that ended only with "." (possibly a fake end from a pause).
    private var lastSoft: (id: UUID, lang: String, emittedAt: Date)?

    /// Recognized chunk from the engine -> complete sentences go to translation, the tail waits.
    private func receive(_ rawText: String, lang: String, at: Date) {
        // ASR sometimes emits a stray "." for trailing silence that gets glued to the next chunk.
        let text = String(rawText.drop { $0.isPunctuation || $0.isWhitespace })
        guard !text.isEmpty else { return }
        guard sentenceMerge else { addSegment(text, lang: lang, at: at); return }
        if let h = held, h.lang != lang { emitHeld() }          // language switched: close previous

        // Retroactive merge: previous row ended with a period but this chunk continues it
        // ("...results." + "And decided..."), so fold it back in and retranslate.
        if held == nil, let soft = lastSoft, soft.lang == lang,
           Date().timeIntervalSince(soft.emittedAt) < 10,
           SentenceSplitter.isContinuation(text, lang: lang),
           let idx = segments.indices.last, segments[idx].id == soft.id {
            let merged = SentenceSplitter.mergeContinuation(segments[idx].source, text, lang: lang)
            let (complete, rest) = SentenceSplitter.split(merged, lang: lang)
            segments[idx].source = complete.isEmpty ? merged : complete
            dlog("ROW~ merged -> \(segments[idx].source)")
            retranslate(soft.id)
            held = (complete.isEmpty || rest.isEmpty) ? nil : (rest, lang, at)
            lastSoft = held == nil && SentenceSplitter.endsWithSoftPeriod(segments[idx].source)
                ? (soft.id, lang, Date()) : nil
            heldText = held?.text ?? ""
            scheduleHoldTimeout()
            return
        }

        let combined = held.map { SentenceSplitter.mergeContinuation($0.text, text, lang: lang) } ?? text
        let startedAt = held?.at ?? at
        let (complete, rest) = SentenceSplitter.split(combined, lang: lang)
        lastSoft = nil
        if !complete.isEmpty {
            let id = addSegment(complete, lang: lang, at: startedAt)
            if rest.isEmpty && SentenceSplitter.endsWithSoftPeriod(complete) { lastSoft = (id, lang, Date()) }
        }
        if rest.isEmpty {
            held = nil
        } else {
            // Tail came from the new chunk -> its start is (about) the new chunk's start.
            held = (rest, lang, complete.isEmpty ? startedAt : at)
            // Safety valve for endless run-ons.
            if rest.count > 280 { emitHeld() }
        }
        heldText = held?.text ?? ""
        scheduleHoldTimeout()
    }

    /// Emit the held tail once nobody has spoken for `mergeHoldSec`.
    private func scheduleHoldTimeout() {
        holdGeneration += 1
        let gen = holdGeneration
        guard held != nil else { return }
        // Unpunctuated but plausibly finished ("Any questions") -> shorter wait than a clear "... and".
        let h = held!
        let wait = SentenceSplitter.clearlyContinues(h.text, lang: h.lang) ? mergeHoldSec : min(mergeHoldSec, 1.2)
        Task {
            var quiet = 0.0
            while quiet < wait {
                try? await Task.sleep(for: .milliseconds(250))
                guard gen == holdGeneration, held != nil else { return }
                // Speech still going (or recognizer mid-hypothesis): the continuation is coming.
                quiet = (isSpeech || !volatileText.isEmpty) ? 0 : quiet + 0.25
            }
            if gen == holdGeneration { emitHeld() }
        }
    }

    private func emitHeld() {
        guard let h = held else { return }
        held = nil
        heldText = ""
        holdGeneration += 1
        addSegment(h.text, lang: h.lang, at: h.at)
    }

    @discardableResult
    private func addSegment(_ text: String, lang: String, at: Date) -> UUID {
        // Auto-detect: translate into whichever of the pair was NOT spoken.
        let target = autoDetect ? (lang == sourceCode ? targetCode : sourceCode) : targetCode
        let seg = Segment(time: at, source: text, sourceLang: lang, targetLang: target)
        segments.append(seg)
        translateQueue.append(seg.id)
        pumpTranslations()
        dlog("ROW+ [\(lang)] \(text)")
        return seg.id
    }

    func retranslate(_ id: UUID) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[i].translation = ""; segments[i].state = .queued
        guard !translateQueue.contains(id) else { return }   // not started yet: will pick up new text
        translateQueue.append(id)
        pumpTranslations()
    }

    private func makeTranslator() -> Translator {
        switch translatorKind {
        case .llm:
            return LLMTranslator(config: .init(baseURL: llmBaseURL, apiKey: llmAPIKey, model: llmModel,
                                               temperature: llmTemperature, historyTurns: llmHistory,
                                               systemAsUser: llmSystemAsUser))
        case .apple: return appleTranslator
        case .google: return GoogleTranslator(apiKey: googleAPIKey)
        }
    }

    private func pumpTranslations() {
        guard translateTask == nil else { return }
        translateTask = Task {
            while !translateQueue.isEmpty, !Task.isCancelled {
                let id = translateQueue.removeFirst()
                await translate(id)
            }
            if !Task.isCancelled { translateTask = nil }
        }
    }

    private func translate(_ id: UUID) async {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = segments[idx]
        let history = segments[..<idx].filter {
            $0.state == .done && !$0.translation.isEmpty
                && $0.sourceLang == seg.sourceLang && $0.targetLang == seg.targetLang
        }
            .map { (source: $0.source, translation: $0.translation) }
        let req = TranslationRequest(text: seg.source, source: Language.byCode(seg.sourceLang),
                                     target: Language.byCode(seg.targetLang),
                                     history: Array(history.suffix(20)), userContext: userContext)
        segments[idx].state = .translating
        let translator = makeTranslator()
        do {
            let result = try await translator.translate(req) { partial in
                Task { @MainActor in
                    if let i = self.current(id, source: seg.source) { self.segments[i].translation = partial }
                }
            }
            if let i = current(id, source: seg.source) {
                segments[i].translation = result
                segments[i].state = .done
                dlog("TR  \(seg.source) => \(result)")
            }
        } catch {
            if let i = current(id, source: seg.source) {
                segments[i].state = .failed(error.localizedDescription)
            }
        }
    }

    /// Index of the segment if its source is still what was sent (it may have been merged since).
    private func current(_ id: UUID, source: String) -> Int? {
        guard let i = segments.firstIndex(where: { $0.id == id }), segments[i].source == source else { return nil }
        return i
    }

    // MARK: Export

    static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    /// "[HH:mm:ss] " prefix for copied text (if enabled).
    func stampPrefix(_ seg: Segment) -> String {
        copyTimestamps ? "[\(Self.timeFormatter.string(from: seg.time))] " : ""
    }

    var sourceText: String { segments.map { stampPrefix($0) + $0.source }.joined(separator: "\n") }
    var translationText: String {
        segments.filter { !$0.translation.isEmpty }.map { stampPrefix($0) + $0.translation }.joined(separator: "\n")
    }
    var bilingualText: String { segments.map(bilingual).joined(separator: "\n\n") }
    func bilingual(_ seg: Segment) -> String { "\(stampPrefix(seg))\(seg.source)\n→ \(seg.translation)" }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func saveTranscript() {
        let dir = URL(fileURLWithPath: saveDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(Self.stamp())-transcript.md")
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        var md = "# Transcript (\(source.label) → \(target.label))\n\n"
        for s in segments { md += "**[\(f.string(from: s.time))]** \(s.source)\n\n> \(s.translation)\n\n" }
        try? md.write(to: url, atomically: true, encoding: .utf8)
        status = "저장됨: \(url.lastPathComponent)"
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }
}
