import SwiftUI
import Translation

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
    }

    /// Space bar: tap = pause/resume (상시 mode), hold = talk (push-to-talk mode).
    @MainActor private func handleKey(_ event: NSEvent) -> Bool {
        guard let model, model.isRunning, event.keyCode == 49,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !(NSApp.keyWindow?.firstResponder is NSText),   // typing in a field
              NSApp.keyWindow?.identifier?.rawValue.contains("Settings") != true
        else { return false }
        switch model.listenMode {
        case .pushToTalk:
            model.setPushToTalk(event.type == .keyDown)
        case .always:
            if event.type == .keyDown && !event.isARepeat { model.togglePause() }
        }
        return true
    }

    /// Stop capture and finalize the recording file before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isRunning else { return .terminateNow }
        Task { @MainActor in
            await model.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct STTTransApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Tongyeok") {
            ContentView().environmentObject(model)
                .frame(minWidth: 960, minHeight: 480)
                .updatePrompt()
                .onAppear {
                    appDelegate.model = model
                    Updater.shared.startAutomaticChecks()
                    // Debug hook: start listening on launch.
                    if ProcessInfo.processInfo.environment["STTTRANS_AUTOSTART"] != nil { model.start() }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
            TranscriptCommands(model: model)
        }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var appleConfig: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            TranscriptTable()
            Divider()
            StatusBar()
        }
        .confirmationDialog("리셋할까요?", isPresented: $model.confirmReset) {
            Button("리셋", role: .destructive) { model.reset() }
            Button("대본 저장 후 리셋") { model.saveTranscript(); model.reset() }
        } message: {
            Text("\(model.segments.count)개 문장과 번역 맥락이 지워집니다.")
        }
        .translationTask(appleConfig) { session in
            do { try await session.prepareTranslation(); model.status = "Apple 언어 팩 준비 완료" }
            catch { model.lastError = "Apple 언어 팩: \(error.localizedDescription)" }
        }
    }

    /// Custom control bar (NSToolbar hides items into an overflow menu when space runs out).
    var controlBar: some View {
        HStack(spacing: 10) {
            // Run control
            Button { model.toggle() } label: {
                Label(model.isRunning ? "정지" : "시작",
                      systemImage: model.isRunning ? "stop.fill" : "mic.fill")
                    .frame(minWidth: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? .red : .accentColor)
            .controlSize(.large)
            .disabled(model.isBusy)
            .help("시작/정지 (⌘R)")

            if model.isRunning && model.listenMode == .always {
                Button { model.togglePause() } label: {
                    Label(model.isPaused ? "재개" : "일시정지",
                          systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                .controlSize(.large)
                .help("일시정지/재개 (Space 또는 ⌘P) — 녹음은 계속됩니다")
            }
            VStack(alignment: .leading, spacing: 3) {
                LevelMeter(db: model.levelDB, speech: model.isSpeech).frame(width: 90, height: 6)
                if model.isRunning { ListeningBadge() } else { Text("대기").font(.caption).foregroundStyle(.secondary) }
            }

            Divider().frame(height: 22)

            Picker("입력", selection: $model.inputKindRaw) {
                ForEach(InputKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .disabled(model.isRunning)
            .help("입력 소스 (인식 중에는 변경 불가)")

            Picker(selection: $model.listenModeRaw) {
                ForEach(ListenMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
            } label: { Image(systemName: "ear") }
            .fixedSize()
            .onChange(of: model.listenModeRaw) { model.isPaused = false; model.pttHeld = false; model.updateGate() }
            .help("상시: 계속 인식 (Space = 일시정지) · Space 누르는 동안: 누르고 있을 때만 인식")

            Picker(selection: $model.translatorRaw) {
                ForEach(TranslatorKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            } label: { Image(systemName: "globe") }
            .fixedSize()
            .help("번역 엔진: LLM(Gemma 등, OpenAI 호환) · Apple(온디바이스) · Google")
            if model.translatorKind == .apple {
                Button("언어 팩") {
                    let cfg = TranslationSession.Configuration(
                        source: Locale.Language(identifier: model.source.code),
                        target: Locale.Language(identifier: model.target.code))
                    if appleConfig == cfg { appleConfig?.invalidate() } else { appleConfig = cfg }
                }
                .help("Apple 온디바이스 번역 언어 팩 다운로드")
            }

            Spacer(minLength: 8)

            Toggle("자동 스크롤", isOn: $model.autoScroll)
                .toggleStyle(.checkbox)
                .help("새 문장이 오면 항상 맨 아래로 스크롤 (⌘J)")
            Menu {
                Button("원문 복사") { model.copy(model.sourceText) }
                Button("번역 복사") { model.copy(model.translationText) }
                Button("원문 + 번역 복사") { model.copy(model.bilingualText) }
                Divider()
                Toggle("시간 포함", isOn: $model.copyTimestamps)
            } label: { Image(systemName: "doc.on.doc") }
            .menuIndicator(.hidden).fixedSize()
            .help("클립보드로 복사")
            Button { model.saveTranscript() } label: { Image(systemName: "square.and.arrow.down") }
                .help("대본을 Markdown으로 저장 (⌘S)")
            Button { model.requestReset() } label: { Image(systemName: "arrow.counterclockwise") }
                .help("리셋: 화면·번역 맥락 초기화, 인식 중이면 새 세션으로 재시작 (⌘K)")
                .disabled(model.isBusy)
            SettingsLink { Image(systemName: "gearshape") }
                .help("설정 (⌘,)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

/// Menu bar: 전사 menu with the same actions + shortcuts.
struct TranscriptCommands: Commands {
    @ObservedObject var model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("전사") {
            Button(model.isRunning ? "정지" : "시작") { model.toggle() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
            Button(model.isPaused ? "재개" : "일시정지") { model.togglePause() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!model.isRunning || model.listenMode != .always)
            Button("리셋…") { model.requestReset() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.isBusy)
            Divider()
            Picker("듣기 모드", selection: $model.listenModeRaw) {
                ForEach(ListenMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Button("원문 ⇄ 번역 언어 바꾸기") { model.swapLanguages() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.isBusy)
            Toggle("언어 자동 감지 (양방향)", isOn: $model.autoDetect)
            Divider()
            Picker("입력 소스", selection: $model.inputKindRaw) {
                ForEach(InputKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .disabled(model.isRunning)
            Picker("번역 엔진", selection: $model.translatorRaw) {
                ForEach(TranslatorKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Divider()
            Toggle("자동 스크롤", isOn: $model.autoScroll)
                .keyboardShortcut("j", modifiers: .command)
            Toggle("시간 표시", isOn: $model.showTimestamps)
            Toggle("복사 시 시간 포함", isOn: $model.copyTimestamps)
            Divider()
            Button("원문 복사") { model.copy(model.sourceText) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("번역 복사") { model.copy(model.translationText) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("원문 + 번역 복사") { model.copy(model.bilingualText) }
            Divider()
            Button("대본 저장") { model.saveTranscript() }
                .keyboardShortcut("s", modifiers: .command)
        }
    }
}

// MARK: - Panes

/// One scroll view; each row = [original | translation] so both sides always stay aligned.
struct TranscriptTable: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("splitRatio") private var ratio = 0.5
    private let bottomID = "bottom"

    var body: some View {
        GeometryReader { geo in
            let leftW = max(200, geo.size.width * ratio)
            VStack(spacing: 0) {
                header(leftWidth: leftW, total: geo.size.width)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.segments.enumerated()), id: \.element.id) { i, seg in
                                row(index: i, leftWidth: leftW) {
                                    SegmentText(text: seg.source, time: seg.time, showTime: model.showTimestamps,
                                                badge: model.autoDetect || seg.sourceLang != model.sourceCode
                                                    ? seg.sourceLang.uppercased() : nil)
                                } right: {
                                    TranslationRow(seg: seg)
                                }
                                .contextMenu {
                                    Button("원문 복사") { model.copy(model.stampPrefix(seg) + seg.source) }
                                    Button("번역 복사") { model.copy(model.stampPrefix(seg) + seg.translation) }
                                    Button("원문+번역 복사") { model.copy(model.bilingual(seg)) }
                                    Divider()
                                    Button("다시 번역") { model.retranslate(seg.id) }
                                }
                                .id(seg.id)
                            }
                            if !model.volatileText.isEmpty || !model.heldText.isEmpty {
                                row(index: model.segments.count, leftWidth: leftW) {
                                    // Held (waiting for sentence end) + live hypothesis.
                                    Text("\(Text(model.heldText).foregroundStyle(.secondary))\(model.heldText.isEmpty || model.volatileText.isEmpty ? "" : " ")\(Text(model.volatileText).italic().foregroundStyle(.tertiary))")
                                        .font(.system(size: 15))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } right: {
                                    Text("…").foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            Color.clear.frame(height: 1).id(bottomID)
                        }
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: model.segments) { scrollToBottom(proxy) }
                    .onChange(of: model.volatileText) { scrollToBottom(proxy) }
                    .onChange(of: model.heldText) { scrollToBottom(proxy) }
                    .onChange(of: model.autoScroll) { _, on in if on { scrollToBottom(proxy, force: true) } }
                }
            }
        }
    }

    // Zebra row: white / gray, with a column divider at the same x as the header.
    private func row<L: View, R: View>(index: Int, leftWidth: CGFloat,
                                       @ViewBuilder left: () -> L, @ViewBuilder right: () -> R) -> some View {
        HStack(alignment: .top, spacing: 0) {
            left().padding(.horizontal, 14).padding(.vertical, 9)
                .frame(width: leftWidth, alignment: .leading)
            Rectangle().fill(.separator).frame(width: 1)
            right().padding(.horizontal, 14).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.055))
    }

    private func header(leftWidth: CGFloat, total: CGFloat) -> some View {
        HStack(spacing: 0) {
            ColumnHeader(title: "원문", langCode: $model.sourceCode, lockWhileRunning: true,
                         showAutoDetect: true, copy: { model.copy(model.sourceText) })
                .frame(width: leftWidth)
                .overlay(alignment: .trailing) {
                    Button { model.swapLanguages() } label: { Image(systemName: "arrow.left.arrow.right") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("원문 ⇄ 번역 언어 바꾸기 (⌘E)")
                        .disabled(model.isBusy)
                        .offset(x: 16)
                        .zIndex(1)
                }
                .zIndex(1)
            // Drag to resize both columns together.
            Rectangle().fill(.separator).frame(width: 1)
                .padding(.horizontal, 3).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    ratio = min(0.8, max(0.2, (leftWidth + v.translation.width) / max(total, 1)))
                })
                .padding(.horizontal, -3)
            ColumnHeader(title: "번역", langCode: $model.targetCode, lockWhileRunning: model.autoDetect,
                         copy: { model.copy(model.translationText) })
                .padding(.leading, 18)
        }
        .frame(height: 38)
        .background(.bar)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard model.autoScroll || force else { return }
        proxy.scrollTo(bottomID, anchor: .bottom)
    }
}

struct ColumnHeader: View {
    let title: String
    @Binding var langCode: String
    let lockWhileRunning: Bool
    var showAutoDetect = false
    let copy: () -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Picker("", selection: $langCode) {
                ForEach(Language.all) { Text($0.label).tag($0.code) }
            }
            .labelsHidden().frame(maxWidth: 150)
            .disabled(lockWhileRunning && model.isRunning)
            if showAutoDetect {
                Toggle("자동 감지", isOn: $model.autoDetect)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("원문·번역 두 언어를 모두 듣고, 말한 언어를 감지해 반대 언어로 번역")
                    .onChange(of: model.autoDetect) { model.restartIfRunning() }
            }
            Spacer()
            Button { copy() } label: { Label("복사", systemImage: "doc.on.doc") }
                .controlSize(.small)
                .help("\(title) 전체를 클립보드로 복사")
        }
        .padding(.leading, 12).padding(.trailing, 24)
    }
}

struct SegmentText: View {
    let text: String
    let time: Date
    var showTime = true
    var badge: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showTime {
                Text(AppModel.timeFormatter.string(from: time))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }
            Text(text)
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .help(time.formatted(date: .omitted, time: .standard))
    }
}

struct TranslationRow: View {
    let seg: Segment
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch seg.state {
            case .queued:
                Text("…").foregroundStyle(.tertiary)
            case .failed(let msg):
                HStack(alignment: .top) {
                    Text("⚠︎ \(msg)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button("재시도") { model.retranslate(seg.id) }.controlSize(.small)
                }
            default:
                Text(seg.translation.isEmpty ? "…" : seg.translation)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(seg.state == .translating ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shows whether audio is currently being recognized (pause / push-to-talk).
struct ListeningBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let (text, color): (String, Color) = switch model.listenMode {
        case .always: model.isPaused ? ("일시정지", .orange) : ("인식 중", .green)
        case .pushToTalk: model.pttHeld ? ("● 말하세요", .red) : ("Space를 누르고 말하기", .secondary)
        }
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().strokeBorder(color.opacity(0.5)))
            .fixedSize()
    }
}

struct LevelMeter: View {
    let db: Float
    let speech: Bool
    var body: some View {
        GeometryReader { g in
            let frac = CGFloat(max(0, min(1, (db + 70) / 60)))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(speech ? Color.green : Color.gray).frame(width: g.size.width * frac)
            }
        }
        .help(speech ? "음성 감지됨 (VAD)" : "무음")
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(model.isRunning ? (model.isSpeech ? .green : .orange) : .gray).frame(width: 8, height: 8)
            Text(model.status).lineLimit(1)
            if let e = model.lastError {
                Text(e).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            Text("\(model.segments.count) 문장").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView {
            Form {
                Section("OpenAI 호환 LLM API") {
                    TextField("Base URL", text: $model.llmBaseURL, prompt: Text("https://host/v1"))
                    SecureField("API Key", text: $model.llmAPIKey)
                    TextField("Model", text: $model.llmModel)
                    HStack {
                        Text("Temperature \(model.llmTemperature, specifier: "%.2f")")
                        Slider(value: $model.llmTemperature, in: 0...1)
                    }
                    Stepper("맥락 이력 턴 수: \(model.llmHistory)", value: $model.llmHistory, in: 0...20)
                    Toggle("system 역할을 user 메시지에 합치기 (일부 Gemma 템플릿용)", isOn: $model.llmSystemAsUser)
                }
                Section("Google 번역") {
                    SecureField("Cloud Translation API Key (비우면 무료 엔드포인트)", text: $model.googleAPIKey)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("번역", systemImage: "globe") }

            Form {
                Section("대화 맥락 / 용어집") {
                    Text("주제, 참석자, 고유명사, 용어 대응 등을 적어주세요. LLM 프롬프트에 포함되고, 짧은 줄은 음성 인식 힌트로도 사용됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.userContext)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 220)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("맥락", systemImage: "text.book.closed") }

            Form {
                Section("VAD (음성 구간 감지)") {
                    HStack { Text("민감도 여유 \(Int(model.vadMargin)) dB"); Slider(value: $model.vadMargin, in: 3...20) }
                    HStack { Text("문장 끝 무음 \(Int(model.vadHangoverMs)) ms"); Slider(value: $model.vadHangoverMs, in: 300...2000) }
                    HStack { Text("최대 구간 \(Int(model.vadMaxSec)) s"); Slider(value: $model.vadMaxSec, in: 5...30) }
                }
                Section("문장 단위 번역") {
                    Toggle("문장이 끝날 때까지 이어 붙여서 번역", isOn: $model.sentenceMerge)
                    HStack {
                        Text("미완성 문장 대기 \(model.mergeHoldSec, specifier: "%.1f")초")
                        Slider(value: $model.mergeHoldSec, in: 1...8)
                    }
                    .disabled(!model.sentenceMerge)
                    Text("말이 멈춘 뒤 이 시간 동안 이어지는 말이 없으면 미완성 문장도 번역합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("표시 / 복사") {
                    Toggle("각 줄에 시간 표시", isOn: $model.showTimestamps)
                    Toggle("텍스트 복사 시 [HH:mm:ss] 포함", isOn: $model.copyTimestamps)
                }
                Section("녹음 / 저장") {
                    Picker("녹음 포맷", selection: $model.recordFormatRaw) {
                        ForEach(RecordFormat.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    TextField("저장 폴더", text: $model.saveDir)
                    Button("폴더 열기") {
                        let u = URL(fileURLWithPath: model.saveDir)
                        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(u)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("오디오", systemImage: "waveform") }
        }
        .frame(width: 560, height: 460)
    }
}
