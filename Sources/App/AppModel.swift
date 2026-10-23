import SwiftUI
import AppKit

enum ListenMode: String, CaseIterable, Identifiable {
    case always = "상시 듣기"
    case pushToTalk = "누를 때만"
    var id: String { rawValue }
}

struct Segment: Identifiable, Equatable, Codable {
    var id = UUID()
    let time: Date
    var source: String
    var sourceLang: String   // detected / selected language of `source`
    var targetLang: String
    var translation: String = ""
    var state: State = .queued
    var speaker: Int?        // 0-based voice cluster (speaker labeling), nil = unknown / off
    enum State: Equatable, Codable { case queued, translating, done, failed(String) }
}

@MainActor
final class AppModel: ObservableObject {
    // Settings
    @AppStorage("inputKind") var inputKindRaw = InputKind.microphone.rawValue
    @AppStorage("sourceLang") var sourceCode = "en"
    @AppStorage("targetLang") var targetCode = "ko"
    @AppStorage("translator") var translatorRaw = TranslatorKind.llm.rawValue
    @AppStorage("llmBaseURL") var llmBaseURL = ProcessInfo.processInfo.environment["STTTRANS_API_BASE"] ?? ""
    // API keys: Keychain (SecretStore), loaded asynchronously at launch -- see loadSecrets().
    @Published var llmAPIKey = "" { didSet { secretsChanged() } }
    @AppStorage("llmModel") var llmModel = ProcessInfo.processInfo.environment["STTTRANS_MODEL"] ?? "gemma-4-31b-it"
    @AppStorage("llmTemperature") var llmTemperature = 0.2
    @AppStorage("llmHistory") var llmHistory = 6
    @AppStorage("llmSystemAsUser") var llmSystemAsUser = false
    @Published var googleAPIKey = "" { didSet { secretsChanged() } }
    // Meeting minutes (LLM, uses the LLM endpoint/key)
    @AppStorage("autoMinutes") var autoMinutes = true
    @AppStorage("minutesMinSegments") var minutesMinSegments = 5
    @AppStorage("minutesModel") var minutesModel = "deepseek-v4.1-flash"
    @AppStorage("minutesLang") var minutesLang = "ko"
    @AppStorage("minutesInstructions") var minutesInstructions = ""
    @AppStorage("minutesEmail") var minutesEmail = true
    @AppStorage("minutesRecipients") var minutesRecipients = ""
    /// Voice-based speaker labeling (CAM++ embedding per utterance + online clustering).
    @AppStorage("diarize") var diarize = false
    @AppStorage("speakerThreshold") var speakerThreshold = 0.7
    @AppStorage("sttEngine") var sttEngineRaw = STTEngineKind.apple.rawValue
    var sttEngine: STTEngineKind { STTEngineKind(rawValue: sttEngineRaw) ?? .apple }
    @AppStorage("whisperBaseURL") var whisperBaseURL = ""
    @Published var whisperAPIKey = "" { didSet { secretsChanged() } }
    @AppStorage("whisperModel") var whisperModel = "openai/whisper-large-v3"
    @AppStorage("userContext") var userContext = ""
    @AppStorage("vadMargin") var vadMargin = 9.0
    @AppStorage("vadHangoverMs") var vadHangoverMs = 700.0
    @AppStorage("vadMaxSec") var vadMaxSec = 14.0
    @AppStorage("autoScroll") var autoScroll = true
    @AppStorage("copyTimestamps") var copyTimestamps = true
    @AppStorage("sentenceMerge") var sentenceMerge = true
    @AppStorage("mergeHoldSec") var mergeHoldSec = 2.5
    @AppStorage("showTimestamps") var showTimestamps = true
    // Fonts ("" = system font)
    @AppStorage("fontFamily") var fontFamily = ""
    @AppStorage("transcriptFontSize") var transcriptFontSize = 15.0
    func font(_ size: Double, weight: Font.Weight = .regular) -> Font {
        fontFamily.isEmpty ? .system(size: size, weight: weight) : .custom(fontFamily, size: size).weight(weight)
    }
    @AppStorage("showMenuBarIcon") var showMenuBarIcon = true
    // Floating subtitle overlay
    @AppStorage("overlayFullScreenScale") var overlayFullScreenScale = 1.6
    @AppStorage("overlayVisible") var overlayVisible = false
    @AppStorage("overlayFontSize") var overlayFontSize = 28.0
    /// 0 = auto: as many recent lines as fit the window (the rest fade out at the top).
    @AppStorage("overlayRows") var overlayLines = 0
    @AppStorage("overlayLayout") var overlayLayoutRaw = OverlayLayout.sideBySide.rawValue
    var overlayLayout: OverlayLayout { OverlayLayout(rawValue: overlayLayoutRaw) ?? .sideBySide }
    @AppStorage("overlayOpacity") var overlayOpacity = 0.55
    @AppStorage("overlayClickThrough") var overlayClickThrough = false
    /// Listen for both the source and target languages; translate each utterance into the other one.
    @AppStorage("autoDetect") var autoDetect = false
    @AppStorage("listenMode") var listenModeRaw = ListenMode.always.rawValue
    var listenMode: ListenMode { ListenMode(rawValue: listenModeRaw) ?? .always }
    @AppStorage("recordFormat") var recordFormatRaw = RecordFormat.m4a.rawValue
    @AppStorage("saveDir") var saveDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("STTTrans").path

    // Live state
    @Published var segments: [Segment] = [] { didSet { scheduleAutosave() } }
    /// Unclean exit detected at launch: the session that can be restored (asks the user first).
    @Published var recoverable: SavedSession?
    private var autosavePending = false
    /// Restored speakers keep their numbers; new voice clusters are numbered after them.
    private var speakerOffset = 0
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
    @Published var isMakingMinutes = false
    @Published var lastMinutes: URL?
    /// One file name per session (since the last reset): regenerating minutes overwrites them.
    private var sessionStamp: String?
    private var sessionStart: Date?

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

    private var engine: RecognitionEngine?
    private var diarizer: Diarizer?
    private static var embedder: SpeakerEmbedder?
    /// Wall-clock spans of labeled utterances; recognized text is matched to them by start time.
    private var speakerSpans: [(start: Date, end: Date, speaker: Int)] = []
    private var translateQueue: [UUID] = []
    /// Translation workers: 1 normally (keeps context ordered), up to 3 to catch up on a backlog.
    private var translateWorkers: [Task<Void, Never>] = []
    private var activeWorkers = 0
    private var workerGeneration = 0
    /// Debug hook (`STTTRANS_FAIL_TRANSLATIONS=n`): the first n translation attempts fail with HTTP 503.
    private var injectedFailures = Int(ProcessInfo.processInfo.environment["STTTRANS_FAIL_TRANSLATIONS"] ?? "") ?? 0
    /// Debug hook (`STTTRANS_TRANSLATE_DELAY=sec`): slow every translation down, to build a backlog.
    private let injectedDelay = Double(ProcessInfo.processInfo.environment["STTTRANS_TRANSLATE_DELAY"] ?? "") ?? 0
    var translationBacklog: Int { segments.filter { $0.state == .queued }.count }
    private var translator: Translator?
    private var appleTranslator = AppleTranslator()

    var source: Language { Language.byCode(sourceCode) }
    var target: Language { Language.byCode(targetCode) }
    var inputKind: InputKind { InputKind(rawValue: inputKindRaw) ?? .microphone }
    var translatorKind: TranslatorKind { TranslatorKind(rawValue: translatorRaw) ?? .llm }
    var recordFormat: RecordFormat { RecordFormat(rawValue: recordFormatRaw) ?? .m4a }


    // MARK: Secrets (Keychain)

    private static let secretKeys = ["llmAPIKey", "googleAPIKey", "whisperAPIKey"]
    private var secretsReady = false
    private var secretsLoad: Task<Void, Never>?
    private var secretsSaveTask: Task<Void, Never>?

    init() {
        secretsLoad = Task { await loadSecrets() }
        if let s = SessionStore.load(), !s.segments.isEmpty { recoverable = s }
    }

    /// Keychain -> fields; first run after the update moves keys out of the preferences plist.
    /// Then fills still-empty endpoints/keys from ~/env.
    private func loadSecrets() async {
        var s = await Task.detached { SecretStore.load() }.value
        let defaults = UserDefaults.standard
        var migrated = false
        for k in Self.secretKeys {
            if let old = defaults.string(forKey: k), !old.isEmpty {
                if (s[k] ?? "").isEmpty { s[k] = old }
                migrated = true
            }
        }
        if (s["llmAPIKey"] ?? "").isEmpty, let env = ProcessInfo.processInfo.environment["STTTRANS_API_KEY"] {
            s["llmAPIKey"] = env
        }
        llmAPIKey = s["llmAPIKey"] ?? ""
        googleAPIKey = s["googleAPIKey"] ?? ""
        whisperAPIKey = s["whisperAPIKey"] ?? ""
        secretsReady = true
        if migrated, !SecretStore.disabled, await Task.detached(operation: { [s] in SecretStore.save(s) }).value {
            for k in Self.secretKeys { defaults.removeObject(forKey: k) }   // only once the Keychain has them
            dlog("API keys migrated from preferences to Keychain")
        }
        loadLiteLLMEnv()
    }

    private func secretsChanged() {
        guard secretsReady else { return }
        let s = ["llmAPIKey": llmAPIKey, "googleAPIKey": googleAPIKey, "whisperAPIKey": whisperAPIKey]
        secretsSaveTask?.cancel()
        secretsSaveTask = Task {   // typing in a SecureField: write once it settles
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            _ = await Task.detached { SecretStore.save(s) }.value
        }
    }

    // MARK: Autosave / recovery

    private func scheduleAutosave() {
        guard !autosavePending, recoverable == nil else { return }   // don't overwrite what's waiting to be restored
        autosavePending = true
        Task {
            try? await Task.sleep(for: .seconds(2))   // at most every 2 s, also while translations stream in
            autosavePending = false
            writeAutosave()
        }
    }

    private func writeAutosave() {
        guard recoverable == nil else { return }
        if segments.isEmpty { SessionStore.clear(); return }
        let s = SavedSession(savedAt: Date(), sessionStamp: sessionStamp, sessionStart: sessionStart,
                             sourceCode: sourceCode, targetCode: targetCode, segments: segments)
        Task.detached { SessionStore.save(s) }
    }

    /// Bring back the crashed session; anything not translated yet goes back in the queue.
    func restoreSession() {
        guard let s = recoverable else { return }
        recoverable = nil
        segments = s.segments.map { seg in
            var seg = seg
            if seg.state == .translating { seg.state = .queued; seg.translation = "" }
            return seg
        }
        sessionStamp = s.sessionStamp; sessionStart = s.sessionStart
        speakerOffset = (segments.compactMap(\.speaker).max() ?? -1) + 1
        status = "이전 세션 복구됨: \(segments.count)문장"
        let pending = segments.filter { $0.state == .queued }.map(\.id)
        Task {
            await secretsLoad?.value
            translateQueue.append(contentsOf: pending)
            pumpTranslations()
        }
    }

    /// Don't restore -- but keep a Markdown copy in the save folder so nothing is lost silently.
    func discardRecoverable() {
        guard let s = recoverable else { return }
        recoverable = nil
        let saved = segments
        segments = s.segments
        let dir = URL(fileURLWithPath: saveDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(s.sessionStamp ?? Self.stamp())-recovered-transcript.md")
        try? transcriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
        segments = saved
        SessionStore.clear()
        status = "이전 세션을 버렸습니다 (사본: \(url.lastPathComponent))"
    }

    /// Normal quit: transcript -> save folder, then drop the crash autosave.
    func prepareForQuit() {
        guard recoverable == nil else { return }   // user hasn't decided yet: keep it for next launch
        if !segments.isEmpty {
            let dir = URL(fileURLWithPath: saveDir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? transcriptMarkdown().write(to: dir.appendingPathComponent("\(sessionStamp ?? Self.stamp())-transcript.md"),
                                            atomically: true, encoding: .utf8)
        }
        SessionStore.clear()
    }

    // MARK: LiteLLM (~/env)

    /// Fills empty endpoint/key fields from `LITELLM_OPENAI_BASE_URL` / `LITELLM_OPENAI_API_KEY`
    /// in ~/env (or the process environment). `overwrite` = the settings button.
    @discardableResult
    func loadLiteLLMEnv(overwrite: Bool = false) -> Bool {
        guard let env = LiteLLMEnv.load() else {
            if overwrite { lastError = "~/env 에서 LITELLM_OPENAI_BASE_URL 을 찾지 못했습니다." }
            return false
        }
        // Also fill a missing key when the endpoint is already the LiteLLM one.
        if overwrite || llmBaseURL.isEmpty || (llmAPIKey.isEmpty && llmBaseURL == env.baseURL) {
            llmBaseURL = env.baseURL; llmAPIKey = env.apiKey
        }
        if overwrite || whisperBaseURL.isEmpty || (whisperAPIKey.isEmpty && whisperBaseURL == env.baseURL) {
            whisperBaseURL = env.baseURL; whisperAPIKey = env.apiKey
        }
        if overwrite { status = "LiteLLM 설정을 ~/env 에서 불러왔습니다." }
        return true
    }

    /// Model ids served by an OpenAI-compatible endpoint (`GET /models`), for the settings pickers.
    func fetchModels(baseURL: String, apiKey: String) async -> [String] {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/models") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            lastError = "모델 목록을 가져오지 못했습니다: \(url.absoluteString)"
            return []
        }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: Control

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        lastError = nil
        // Keys come from the Keychain asynchronously; don't build engines/translators with empty ones.
        if !secretsReady, let load = secretsLoad {
            Task { await load.value; self.startEngine() }
        } else {
            startEngine()
        }
    }

    private func startEngine() {
        let callbacks = SpeechEngine.Callbacks(
            volatile: { t in Task { @MainActor in self.volatileText = t } },
            finalSegment: { t, lang, at in Task { @MainActor in self.receive(t, lang: lang, at: at) } },
            level: { db, sp in Task { @MainActor in self.levelDB = db; self.isSpeech = sp } },
            status: { s in Task { @MainActor in self.status = s } },
            utterance: { audio, s, e in Task { @MainActor in self.labelSpeaker(audio, start: s, end: e) } }
        )
        let engine: RecognitionEngine = switch sttEngine {
        case .apple: SpeechEngine(callbacks: callbacks)
        case .whisper: WhisperEngine(config: .init(baseURL: whisperBaseURL, apiKey: whisperAPIKey, model: whisperModel),
                                     callbacks: callbacks)
        }
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
                if self.diarize { await self.prepareDiarizer() }
                engine.captureUtterances = self.diarizer != nil
                let src: AudioSource
                if let testFile = ProcessInfo.processInfo.environment["STTTRANS_TEST_FILE"] {
                    // Debug hook: feed an audio file in real time instead of a live source;
                    // when it ends, stop like the user would (so the minutes run too).
                    let file = FileSource(url: URL(fileURLWithPath: testFile))
                    file.onFinished = { Task { @MainActor in try? await Task.sleep(for: .seconds(4)); self.stop() } }
                    src = file
                } else {
                    src = input == .microphone ? MicrophoneSource() : SystemAudioSource()
                }
                try await engine.start(source: src, languages: languages, contextualStrings: terms,
                                       vadConfig: vad, recorder: recorder)
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

    /// User-initiated stop: also writes the minutes (if enabled and the session is long enough).
    func stop() {
        guard isRunning, !isBusy else { return }
        Task {
            await stopAndWait()
            if autoMinutes && segments.count >= minutesMinSegments { await makeMinutes() }
        }
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
        translateWorkers.forEach { $0.cancel() }
        translateWorkers.removeAll()
        activeWorkers = 0; workerGeneration += 1
        translateQueue.removeAll()
        segments.removeAll()
        volatileText = ""
        held = nil; heldText = ""; holdGeneration += 1; lastSoft = nil
        speakerSpans.removeAll(); speakerOffset = 0
        sessionStamp = nil; sessionStart = nil; lastMinutes = nil
        if let d = diarizer { Task { await d.reset() } }
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

    // MARK: Speakers

    private func prepareDiarizer() async {
        if diarizer == nil {
            do {
                if Self.embedder == nil { Self.embedder = try await SpeakerEmbedder.load { s in self.status = s } }
                diarizer = Diarizer(embedder: Self.embedder!, threshold: Float(speakerThreshold))
            } catch {
                lastError = "화자 구분을 켤 수 없습니다: \(error.localizedDescription)"
                return
            }
        }
        await diarizer?.setThreshold(Float(speakerThreshold))
    }

    private func labelSpeaker(_ audio: [Float], start: Date, end: Date) {
        guard let d = diarizer else { return }
        Task {
            guard let cluster = await d.speaker(for: audio) else { return }
            let spk = cluster + speakerOffset
            speakerSpans.append((start, end, spk))
            if speakerSpans.count > 2000 { speakerSpans.removeFirst(500) }
            // Text that arrived before its speaker was known.
            for i in segments.indices.reversed() where segments[i].speaker == nil {
                if segments[i].time < start.addingTimeInterval(-30) { break }
                if speaker(at: segments[i].time) == spk { segments[i].speaker = spk }
            }
        }
    }

    /// Speaker of the utterance that was going on at `t` (recognizer times are approximate).
    func speaker(at t: Date) -> Int? {
        speakerSpans.last { $0.start.addingTimeInterval(-0.5) <= t && t <= $0.end.addingTimeInterval(0.3) }?.speaker
    }

    private func differentSpeakers(_ a: Date, _ b: Date) -> Bool {
        guard let x = speaker(at: a), let y = speaker(at: b) else { return false }
        return x != y
    }

    static func speakerLabel(_ i: Int) -> String { "화자 \(i + 1)" }

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
        if let h = held, differentSpeakers(h.at, at) { emitHeld() }   // someone else is talking now

        // Retroactive merge: previous row ended with a period but this chunk continues it
        // ("...results." + "And decided..."), so fold it back in and retranslate.
        if held == nil, let soft = lastSoft, soft.lang == lang,
           !differentSpeakers(segments.last?.time ?? at, at),
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
        if sessionStamp == nil { sessionStamp = Self.stamp(); sessionStart = at }
        var seg = Segment(time: at, source: text, sourceLang: lang, targetLang: target)
        seg.speaker = speaker(at: at)
        segments.append(seg)
        translateQueue.append(seg.id)
        pumpTranslations()
        dlog("ROW+ [\(lang)] spk=\(seg.speaker.map { "\($0 + 1)" } ?? "?") \(text)")
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
        // Apple's on-device session is one shared object: keep it serial.
        let maxWorkers = translatorKind == .apple ? 1 : (translateQueue.count >= 3 ? 3 : 1)
        while activeWorkers < maxWorkers && !translateQueue.isEmpty {
            activeWorkers += 1
            let gen = workerGeneration
            if activeWorkers > 1 { dlog("translation backlog \(translateQueue.count): worker \(activeWorkers)") }
            translateWorkers.append(Task {
                while !translateQueue.isEmpty, !Task.isCancelled {
                    let id = translateQueue.removeFirst()
                    await translate(id)
                }
                if gen == workerGeneration {
                    activeWorkers -= 1
                    translateWorkers.removeAll { $0.isCancelled }
                }
            })
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
        let delays: [Double] = [1, 3]   // retries for transient failures (network, 429, 5xx)
        for attempt in 0...delays.count {
            do {
                if injectedDelay > 0 { try? await Task.sleep(for: .seconds(injectedDelay)) }
                if injectedFailures > 0 {
                    injectedFailures -= 1
                    throw HTTPStatusError(service: "LLM", status: 503, body: "injected")
                }
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
                return
            } catch {
                guard current(id, source: seg.source) != nil, !Task.isCancelled else { return }  // merged / reset
                if attempt < delays.count && RetryPolicy.isTransient(error) {
                    dlog("TR  retry \(attempt + 1) after: \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(delays[attempt]))
                    continue
                }
                if let i = current(id, source: seg.source) { segments[i].state = .failed(error.localizedDescription) }
                return
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
        (copyTimestamps ? "[\(Self.timeFormatter.string(from: seg.time))] " : "")
            + (seg.speaker.map { Self.speakerLabel($0) + ": " } ?? "")
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

    func transcriptMarkdown() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        var md = "# Transcript (\(source.label) → \(target.label))\n\n"
        for s in segments {
            let who = s.speaker.map { " \(Self.speakerLabel($0))" } ?? ""
            md += "**[\(f.string(from: s.time))]\(who)** \(s.source)\n\n> \(s.translation)\n\n"
        }
        return md
    }

    func saveTranscript() {
        let dir = URL(fileURLWithPath: saveDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionStamp ?? Self.stamp())-transcript.md")
        try? transcriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
        status = "저장됨: \(url.lastPathComponent)"
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Minutes

    /// Writes `<session>-minutes.md` (+ the transcript next to it) and optionally opens a Mail draft.
    func makeMinutes() async {
        guard !isMakingMinutes, !segments.isEmpty else { return }
        isMakingMinutes = true
        defer { isMakingMinutes = false }
        var gen = MinutesGenerator(baseURL: llmBaseURL, apiKey: llmAPIKey, model: minutesModel,
                                   language: Language.byCode(minutesLang), extraInstructions: minutesInstructions)
        // Debug hook: small chunks to exercise the long-meeting (map-reduce) path.
        if let c = ProcessInfo.processInfo.environment["STTTRANS_MINUTES_CHUNK"].flatMap(Int.init) { gen.chunkChars = c }
        let lines = segments.map {
            MinutesGenerator.Line(time: $0.time, speaker: $0.speaker.map(Self.speakerLabel), lang: $0.sourceLang,
                                  source: $0.source, translation: $0.translation)
        }
        let t0 = Date()
        do {
            let body = try await gen.generate(lines) { s in self.status = s }
            let dir = URL(fileURLWithPath: saveDir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = sessionStamp ?? Self.stamp()
            let url = dir.appendingPathComponent("\(stamp)-minutes.md")
            try (minutesHeader() + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try? transcriptMarkdown().write(to: dir.appendingPathComponent("\(stamp)-transcript.md"),
                                            atomically: true, encoding: .utf8)
            lastMinutes = url
            status = String(format: "회의록 저장됨: %@ (%.0f초)", url.lastPathComponent, Date().timeIntervalSince(t0))
            dlog("minutes -> \(url.path)")
            if minutesEmail { openMailDraft(body: body, attachment: url) }
        } catch {
            lastError = "회의록 작성 실패: \(error.localizedDescription)"
            status = "회의록 실패"
        }
    }

    private func minutesHeader() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let start = sessionStart ?? segments.first?.time ?? Date()
        let mins = Int(((segments.last?.time ?? start).timeIntervalSince(start) / 60).rounded())
        let speakers = Set(segments.compactMap(\.speaker)).count
        var h = "# 회의록 — \(df.string(from: start))\n\n"
        h += "- 길이: 약 \(max(mins, 1))분 · \(segments.count)문장"
        if speakers > 0 { h += " · 화자 \(speakers)명 (목소리 자동 구분)" }
        h += "\n- 자동 생성 (\(minutesModel)) — 음성 인식 기반이라 오류가 있을 수 있습니다.\n\n"
        return h
    }

    var minutesSubject: String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        return "회의록 \(df.string(from: sessionStart ?? segments.first?.time ?? Date()))"
    }

    /// New message in the default mail app (recipients, subject, minutes as body, .md attached). Never sends.
    func openMailDraft(body: String, attachment: URL) {
        guard let service = NSSharingService(named: .composeEmail) else {
            NSWorkspace.shared.activateFileViewerSelecting([attachment]); return
        }
        service.recipients = minutesRecipients.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map(String.init).filter { $0.contains("@") }
        service.subject = minutesSubject
        let items: [Any] = [body, attachment]
        if service.canPerform(withItems: items) {
            service.perform(withItems: items)
        } else {
            lastError = "메일 앱으로 초안을 열 수 없습니다. 회의록 파일을 Finder에서 보여 드립니다."
            NSWorkspace.shared.activateFileViewerSelecting([attachment])
        }
    }

    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }
}
