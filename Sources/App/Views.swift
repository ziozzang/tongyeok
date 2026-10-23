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
        guard let model else { return .terminateNow }
        guard model.isRunning else { MainActor.assumeIsolated { model.prepareForQuit() }; return .terminateNow }
        Task { @MainActor in
            await model.stopAndWait()
            model.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
enum Main {
    static func main() {
        Updater.handleCommandLineIfRequested()   // `--update [--check]`
        STTTransApp.main()
    }
}

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
                    if model.overlayVisible { OverlayController.shared.show(model: model) }
                    // Debug hook: open the subtitle window full screen.
                    if ProcessInfo.processInfo.environment["STTTRANS_OVERLAY_FULLSCREEN"] != nil {
                        OverlayController.shared.toggleFullScreen(model: model)
                    }
                    DebugSnapshots.startIfRequested()
                    // Debug hook: answer the crash-recovery prompt automatically ("restore" / "discard").
                    switch ProcessInfo.processInfo.environment["STTTRANS_AUTO_RECOVER"] {
                    case "restore": model.restoreSession()
                    case "discard": model.discardRecoverable()
                    default: break
                    }
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
    @ObservedObject private var overlay = OverlayController.shared
    @State private var appleConfig: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            TranscriptTable()
            Divider()
            StatusBar()
        }
        .alert("이전 세션 복구", isPresented: Binding(get: { model.recoverable != nil }, set: { _ in })) {
            Button("복구") { model.restoreSession() }
            Button("버리기", role: .destructive) { model.discardRecoverable() }
        } message: {
            if let s = model.recoverable {
                Text("앱이 정상적으로 종료되지 않았습니다. \(s.savedAt.formatted(date: .abbreviated, time: .shortened))까지의 \(s.segments.count)문장을 복구할까요? 버려도 사본은 저장 폴더에 남습니다.")
            }
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
    /// Sized to fit the 960 pt minimum window width: pickers show only their value (tooltips explain).
    var controlBar: some View {
        HStack(spacing: 8) {
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
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill").frame(width: 16)
                }
                .controlSize(.large)
                .help(model.isPaused ? "재개 (Space 또는 ⌘P)" : "일시정지 (Space 또는 ⌘P) — 녹음은 계속됩니다")
            }
            VStack(alignment: .leading, spacing: 3) {
                LevelMeter(db: model.levelDB, speech: model.isSpeech).frame(width: 90, height: 6)
                if model.isRunning { ListeningBadge() } else { Text("대기").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(width: 96, alignment: .leading)

            Divider().frame(height: 22)

            Group {
                Picker("입력", selection: $model.inputKindRaw) {
                    ForEach(InputKind.allCases) { Image(systemName: $0.symbol).help($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .help("입력: 마이크 · 시스템 소리 (인식 중에는 변경 불가)")

                Picker("음성 인식", selection: $model.sttEngineRaw) {
                    ForEach(STTEngineKind.allCases) { Text($0.short).tag($0.rawValue) }
                }
                .help("음성 인식 엔진: Apple(온디바이스, 실시간) · Whisper(API, 조금 늦지만 정확) — 인식 중에는 변경 불가")
            }
            .disabled(model.isRunning)

            Picker("듣기", selection: $model.listenModeRaw) {
                ForEach(ListenMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .onChange(of: model.listenModeRaw) { model.isPaused = false; model.pttHeld = false; model.updateGate() }
            .help("상시: 계속 인식 (Space = 일시정지) · 누를 때만: Space를 누르고 있을 때만 인식")

            Picker("번역", selection: $model.translatorRaw) {
                ForEach(TranslatorKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .help("번역 엔진: LLM(OpenAI 호환) · Apple(온디바이스) · Google")
            if model.translatorKind == .apple {
                Button {
                    let cfg = TranslationSession.Configuration(
                        source: Locale.Language(identifier: model.source.code),
                        target: Locale.Language(identifier: model.target.code))
                    if appleConfig == cfg { appleConfig?.invalidate() } else { appleConfig = cfg }
                } label: { Image(systemName: "arrow.down.circle") }
                .help("Apple 온디바이스 번역 언어 팩 다운로드")
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Toggle(isOn: Binding(get: { overlay.isVisible }, set: { _ in OverlayController.shared.toggle(model: model) })) {
                    Image(systemName: "captions.bubble")
                }
                .help("떠 있는 자막 창 (⌘T)")
                Toggle(isOn: $model.autoScroll) { Image(systemName: "arrow.down.to.line") }
                    .help("새 문장이 오면 항상 맨 아래로 스크롤 (⌘J)")
            }
            .toggleStyle(.button)

            HStack(spacing: 4) {
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
                Button { Task { await model.makeMinutes() } } label: {
                    if model.isMakingMinutes { ProgressView().controlSize(.small).frame(width: 16) }
                    else { Image(systemName: "doc.text.magnifyingglass") }
                }
                .disabled(model.isMakingMinutes || model.segments.isEmpty)
                .help("회의록 만들기 (⇧⌘M): 요약·결정 사항·할 일 → Markdown 저장 + 메일 초안")
                Button { model.requestReset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("리셋: 화면·번역 맥락 초기화, 인식 중이면 새 세션으로 재시작 (⌘K)")
                    .disabled(model.isBusy)
                SettingsLink { Image(systemName: "gearshape") }
                    .help("설정 (⌘,)")
            }
        }
        .labelsHidden()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

/// Menu bar: 전사 menu with the same actions + shortcuts.
struct TranscriptCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject private var overlay = OverlayController.shared
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(before: .toolbar) {
            Button("글자 크게") { model.transcriptFontSize = min(32, model.transcriptFontSize + 1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("글자 작게") { model.transcriptFontSize = max(10, model.transcriptFontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("기본 글자 크기") { model.transcriptFontSize = 15 }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("자막 글자 크게") { model.overlayFontSize = min(96, model.overlayFontSize + 2) }
                .keyboardShortcut("=", modifiers: [.command, .option])
            Button("자막 글자 작게") { model.overlayFontSize = max(14, model.overlayFontSize - 2) }
                .keyboardShortcut("-", modifiers: [.command, .option])
            Button(overlay.isFullScreen ? "자막 전체 화면 끝내기" : "자막 전체 화면") {
                OverlayController.shared.toggleFullScreen(model: model)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
        }
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
            Toggle("화자 구분 (목소리)", isOn: $model.diarize)
                .onChange(of: model.diarize) { model.restartIfRunning() }
            Divider()
            Picker("입력 소스", selection: $model.inputKindRaw) {
                ForEach(InputKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .disabled(model.isRunning)
            Picker("음성 인식 엔진", selection: $model.sttEngineRaw) {
                ForEach(STTEngineKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .disabled(model.isRunning)
            Picker("번역 엔진", selection: $model.translatorRaw) {
                ForEach(TranslatorKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Divider()
            Button(overlay.isVisible ? "자막 창 숨기기" : "자막 창 보기") { OverlayController.shared.toggle(model: model) }
                .keyboardShortcut("t", modifiers: .command)
            Toggle("자막 창 클릭 통과", isOn: $model.overlayClickThrough)
                .onChange(of: model.overlayClickThrough) { _, on in OverlayController.shared.applyClickThrough(on) }
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
            Button(model.isMakingMinutes ? "회의록 작성 중…" : "회의록 만들기") { Task { await model.makeMinutes() } }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.isMakingMinutes || model.segments.isEmpty)
            Toggle("정지하면 회의록 자동 작성", isOn: $model.autoMinutes)
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
                                                    ? seg.sourceLang.uppercased() : nil,
                                                speaker: seg.speaker)
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
                                        .font(model.font(model.transcriptFontSize))
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
            // Drag to resize both columns together.
            Rectangle().fill(.separator).frame(width: 1)
                .padding(.horizontal, 3).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    ratio = min(0.8, max(0.2, (leftWidth + v.translation.width) / max(total, 1)))
                })
                .padding(.horizontal, -3)
            HStack(spacing: 0) {
                Button { model.swapLanguages() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.borderless)
                    .help("원문 ⇄ 번역 언어 바꾸기 (⌘E)")
                    .disabled(model.isBusy)
                    .padding(.leading, 10)
                ColumnHeader(title: "번역", langCode: $model.targetCode, lockWhileRunning: model.autoDetect,
                             copy: { model.copy(model.translationText) })
            }
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
            Button { copy() } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("\(title) 전체를 클립보드로 복사")
        }
        .padding(.leading, 12).padding(.trailing, 14)
    }
}

struct SegmentText: View {
    let text: String
    let time: Date
    var showTime = true
    var badge: String? = nil
    var speaker: Int? = nil
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showTime {
                Text(AppModel.timeFormatter.string(from: time))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if let speaker {
                Text(AppModel.speakerLabel(speaker))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(SpeakerColor.of(speaker).opacity(0.2)))
                    .foregroundStyle(SpeakerColor.of(speaker))
                    .fixedSize()
            }
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }
            Text(text)
                .font(model.font(model.transcriptFontSize))
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
                    .font(model.font(model.transcriptFontSize + 1, weight: .medium))
                    .foregroundStyle(seg.state == .translating ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shows whether audio is currently being recognized (pause / push-to-talk).
enum SpeakerColor {
    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red]
    static func of(_ i: Int) -> Color { palette[i % palette.count] }
}

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
            let backlog = model.translationBacklog
            if backlog > 0 { Text("번역 대기 \(backlog)").foregroundStyle(.orange) }
            Text("\(model.segments.count) 문장").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

// MARK: - Settings

/// "▾" next to a model field: lists the endpoint's models (`GET /models`) on open.
struct ModelMenu: View {
    let baseURL: String
    let apiKey: String
    @Binding var selection: String
    var filter: (String) -> Bool = { _ in true }
    @EnvironmentObject var model: AppModel
    @State private var models: [String] = []
    @State private var loading = false

    var body: some View {
        Menu {
            if loading { Text("불러오는 중…") }
            else if models.isEmpty { Button("목록 불러오기") { load() } }
            ForEach(models.filter(filter), id: \.self) { m in
                Button(m) { selection = m }
            }
            if !models.isEmpty { Divider(); Button("새로 고침") { load() } }
        } label: { Image(systemName: "list.bullet") }
        .menuIndicator(.hidden).fixedSize()
        .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
        .help("엔드포인트의 모델 목록에서 고르기")
        .onAppear { if models.isEmpty && !baseURL.isEmpty { load() } }
    }

    private func load() {
        loading = true
        Task { models = await model.fetchModels(baseURL: baseURL, apiKey: apiKey); loading = false }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView {
            Form {
                Section("OpenAI 호환 LLM API") {
                    TextField("Base URL", text: $model.llmBaseURL, prompt: Text("https://host/v1"))
                    SecureField("API Key", text: $model.llmAPIKey)
                    HStack {
                        TextField("Model", text: $model.llmModel)
                        ModelMenu(baseURL: model.llmBaseURL, apiKey: model.llmAPIKey, selection: $model.llmModel)
                    }
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
                Section {
                    Button("~/env 의 LiteLLM 설정 불러오기") { model.loadLiteLLMEnv(overwrite: true) }
                    Text("LITELLM_OPENAI_BASE_URL / LITELLM_OPENAI_API_KEY 를 LLM 번역과 Whisper 양쪽에 채웁니다. 비어 있는 칸은 앱 시작 시 자동으로 채워집니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("번역", systemImage: "globe") }

            Form {
                Section("엔진") {
                    Picker("음성 인식", selection: $model.sttEngineRaw) {
                        ForEach(STTEngineKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .disabled(model.isRunning)
                    Text("Apple: 온디바이스·실시간 미리보기. Whisper: 말이 끊길 때마다 구간을 API로 보내 인식합니다 (1~2초 늦지만 정확, 언어 자동 감지도 Whisper가 직접 합니다).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("화자 구분 (실험적)") {
                    Toggle("목소리로 화자를 구분해서 '화자 1/2/3' 표시", isOn: $model.diarize)
                    HStack {
                        Text("같은 사람 판정 기준 \(model.speakerThreshold, specifier: "%.2f")")
                        Slider(value: $model.speakerThreshold, in: 0.5...0.9)
                    }
                    .disabled(!model.diarize)
                    Text("발화마다 기기 안에서 목소리 특징(CAM++, 약 17MB, 처음 켤 때 다운로드)을 뽑아 비슷한 목소리끼리 묶습니다. 한 사람이 여러 화자로 나뉘면 기준을 낮추고, 다른 사람이 한 화자로 합쳐지면 높이세요. 다음 시작부터 적용됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Whisper API (OpenAI 호환 /audio/transcriptions)") {
                    TextField("Base URL", text: $model.whisperBaseURL, prompt: Text("https://host/v1"))
                    SecureField("API Key", text: $model.whisperAPIKey)
                    HStack {
                        TextField("Model", text: $model.whisperModel)
                        ModelMenu(baseURL: model.whisperBaseURL, apiKey: model.whisperAPIKey,
                                  selection: $model.whisperModel, filter: { $0.localizedCaseInsensitiveContains("whisper") })
                    }
                    Button("~/env 에서 불러오기") { model.loadLiteLLMEnv(overwrite: true) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("음성 인식", systemImage: "waveform.badge.mic") }

            Form {
                Section("회의록") {
                    Toggle("정지하면 자동으로 회의록 작성", isOn: $model.autoMinutes)
                    Stepper("최소 \(model.minutesMinSegments)문장 이상일 때만", value: $model.minutesMinSegments, in: 1...100)
                        .disabled(!model.autoMinutes)
                    Picker("작성 언어", selection: $model.minutesLang) {
                        ForEach(Language.all) { Text($0.label).tag($0.code) }
                    }
                    HStack {
                        TextField("모델", text: $model.minutesModel)
                        ModelMenu(baseURL: model.llmBaseURL, apiKey: model.llmAPIKey, selection: $model.minutesModel)
                    }
                    Text("번역 탭의 LLM 엔드포인트·키를 사용합니다. 요약 · 주요 논의 · 결정 사항 · 할 일(화자별) · 미해결 질문을 Markdown으로 저장 폴더에 저장합니다 (⇧⌘M으로 언제든 다시 만들기).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("추가 지시 (선택)") {
                    TextEditor(text: $model.minutesInstructions)
                        .font(.system(size: 13)).frame(minHeight: 60)
                    Text("예: \"할 일은 기한 순으로\", \"화자 1은 김팀장\", \"기술 용어는 영어 그대로\"")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("메일") {
                    Toggle("회의록이 만들어지면 메일 초안 열기 (보내기는 직접)", isOn: $model.minutesEmail)
                    TextField("받는 사람 (쉼표로 구분)", text: $model.minutesRecipients, prompt: Text("a@example.com, b@example.com"))
                        .disabled(!model.minutesEmail)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("회의록", systemImage: "doc.text") }

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
                Section("글꼴") {
                    Picker("글꼴", selection: $model.fontFamily) {
                        Text("시스템 기본").tag("")
                        Divider()
                        ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { f in
                            Text(f).font(.custom(f, size: 13)).tag(f)
                        }
                    }
                    HStack { Text("대본 글자 크기 \(Int(model.transcriptFontSize)) pt (⌘= / ⌘-)"); Slider(value: $model.transcriptFontSize, in: 10...32, step: 1) }
                    Text("원문·번역 텍스트와 자막 창에 같이 적용됩니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("자막 창 (⌘T)") {
                    HStack { Text("글자 크기 \(Int(model.overlayFontSize)) pt (⌥⌘= / ⌥⌘-)"); Slider(value: $model.overlayFontSize, in: 14...96, step: 1) }
                    HStack { Text("전체 화면 배율 ×\(model.overlayFullScreenScale, specifier: "%.1f") (⌘⇧F, 더블클릭)"); Slider(value: $model.overlayFullScreenScale, in: 1...3, step: 0.1) }
                    Picker("표시 줄 수", selection: $model.overlayLines) {
                        Text("자동 (창 크기에 맞춤)").tag(0)
                        ForEach(1...6, id: \.self) { Text("\($0)줄").tag($0) }
                    }
                    HStack { Text("배경 불투명도 \(Int(model.overlayOpacity * 100))%"); Slider(value: $model.overlayOpacity, in: 0...1) }
                    Picker("배치", selection: $model.overlayLayoutRaw) {
                        ForEach(OverlayLayout.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    Toggle("클릭 통과 (아래 앱을 그대로 조작)", isOn: $model.overlayClickThrough)
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
        .frame(width: 580, height: 480)
    }
}
