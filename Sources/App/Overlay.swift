import SwiftUI
import AppKit

/// Floating, always-on-top subtitle window: the last few sentences, original and translation.
/// A non-activating panel so it never steals focus from the video / meeting app underneath.
@MainActor
final class OverlayController: ObservableObject {
    static let shared = OverlayController()
    @Published private(set) var isVisible = false
    /// Covers the whole screen (presentation / projector mode). Double-click, ⌘⇧F or Esc toggles.
    @Published private(set) var isFullScreen = false
    private var panel: NSPanel?
    private var windowedFrame: NSRect?
    private var handles: [NSView] = []
    fileprivate weak var model: AppModel?

    func toggle(model: AppModel) { isVisible ? hide(model: model) : show(model: model) }

    func show(model: AppModel) {
        if panel == nil { panel = makePanel(model: model) }
        applyClickThrough(model.overlayClickThrough)
        panel?.orderFrontRegardless()
        isVisible = true
        model.overlayVisible = true
    }

    func hide(model: AppModel) {
        if isFullScreen { toggleFullScreen() }
        panel?.orderOut(nil)
        isVisible = false
        model.overlayVisible = false
    }

    /// Click-through: mouse goes to the app below (the panel can't be moved/resized meanwhile).
    func applyClickThrough(_ on: Bool) { panel?.ignoresMouseEvents = on && !isFullScreen }

    func toggleFullScreen(model: AppModel) {
        if !isVisible { show(model: model) }
        toggleFullScreen()
    }

    private func toggleFullScreen() {
        guard let panel else { return }
        if isFullScreen {
            isFullScreen = false
            if let f = windowedFrame { panel.setFrame(f, display: true) }
            panel.setFrameAutosaveName("SubtitleOverlay")      // back to remembering the windowed frame
            panel.isMovableByWindowBackground = true
            handles.forEach { $0.isHidden = false }
            panel.resignKey()
        } else {
            guard let screen = panel.screen ?? NSScreen.main else { return }
            windowedFrame = panel.frame
            panel.setFrameAutosaveName("")                     // don't save the full-screen frame
            isFullScreen = true
            panel.isMovableByWindowBackground = false
            handles.forEach { $0.isHidden = true }
            panel.ignoresMouseEvents = false
            panel.setFrame(screen.frame, display: true)
            panel.makeKey()                                    // so Esc / Space reach us
        }
        model.map { applyClickThrough($0.overlayClickThrough) }
    }

    private func makePanel(model: AppModel) -> NSPanel {
        self.model = model
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 190),
                                 styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true                 // before `level`: this resets it to .floating
        panel.level = .statusBar                     // above full-screen video players too
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 320, height: 60)
        // The SwiftUI view lives inside a plain container: content changes can never resize the window,
        // only the user (edge handles) can.
        let host = NSHostingView(rootView: SubtitleOverlay().environmentObject(model))
        host.sizingOptions = []
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        for edge in ResizeHandle.Edge.allCases {
            let h = ResizeHandle(edge: edge, frame: edge.frame(in: container.bounds))
            h.autoresizingMask = edge.autoresizing
            container.addSubview(h)
            handles.append(h)
        }
        panel.contentView = container
        // Default spot: bottom center of the main screen, like movie subtitles.
        if !panel.setFrameUsingName("SubtitleOverlay"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + 60))
        }
        panel.setFrameAutosaveName("SubtitleOverlay")
        return panel
    }
}

/// Invisible strip along an edge/corner of the overlay: drag to resize, with the matching cursor.
private final class ResizeHandle: NSView {
    enum Edge: CaseIterable {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
        static let t: CGFloat = 8          // grab thickness
        static let c: CGFloat = 18         // corner size

        func frame(in b: NSRect) -> NSRect {
            let t = Self.t, c = Self.c
            switch self {
            case .left: return NSRect(x: 0, y: c, width: t, height: b.height - 2 * c)
            case .right: return NSRect(x: b.width - t, y: c, width: t, height: b.height - 2 * c)
            case .bottom: return NSRect(x: c, y: 0, width: b.width - 2 * c, height: t)
            case .top: return NSRect(x: c, y: b.height - t, width: b.width - 2 * c, height: t)
            case .bottomLeft: return NSRect(x: 0, y: 0, width: c, height: c)
            case .bottomRight: return NSRect(x: b.width - c, y: 0, width: c, height: c)
            case .topLeft: return NSRect(x: 0, y: b.height - c, width: c, height: c)
            case .topRight: return NSRect(x: b.width - c, y: b.height - c, width: c, height: c)
            }
        }
        var autoresizing: NSView.AutoresizingMask {
            switch self {
            case .left: [.height, .maxXMargin]
            case .right: [.height, .minXMargin]
            case .bottom: [.width, .maxYMargin]
            case .top: [.width, .minYMargin]
            case .bottomLeft: [.maxXMargin, .maxYMargin]
            case .bottomRight: [.minXMargin, .maxYMargin]
            case .topLeft: [.maxXMargin, .minYMargin]
            case .topRight: [.minXMargin, .minYMargin]
            }
        }
        var cursor: NSCursor {
            switch self {
            case .left, .right: .resizeLeftRight
            case .top, .bottom: .resizeUpDown
            case .topLeft, .bottomRight:
                NSCursor.frameResize(position: self == .topLeft ? .topLeft : .bottomRight, directions: .all)
            case .topRight, .bottomLeft:
                NSCursor.frameResize(position: self == .topRight ? .topRight : .bottomLeft, directions: .all)
            }
        }
        var movesLeft: Bool { [.left, .topLeft, .bottomLeft].contains(self) }
        var movesRight: Bool { [.right, .topRight, .bottomRight].contains(self) }
        var movesTop: Bool { [.top, .topLeft, .topRight].contains(self) }
        var movesBottom: Bool { [.bottom, .bottomLeft, .bottomRight].contains(self) }
    }

    let edge: Edge
    private var start: (mouse: NSPoint, frame: NSRect)?
    init(edge: Edge, frame: NSRect) { self.edge = edge; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: edge.cursor) }

    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        start = (NSEvent.mouseLocation, w.frame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window, let (m0, f0) = start else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - m0.x, dy = p.y - m0.y
        let minW = w.minSize.width, minH = w.minSize.height
        var f = f0
        if edge.movesRight { f.size.width = max(minW, f0.width + dx) }
        if edge.movesLeft { f.size.width = max(minW, f0.width - dx); f.origin.x = f0.maxX - f.width }
        if edge.movesTop { f.size.height = max(minH, f0.height + dy) }
        if edge.movesBottom { f.size.height = max(minH, f0.height - dy); f.origin.y = f0.maxY - f.height }
        w.setFrame(f, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
        window?.saveFrame(usingName: "SubtitleOverlay")
    }
}

private final class OverlayPanel: NSPanel {
    // Windowed: keep the keyboard (Space = pause) with the main window. Full screen: take it (Esc exits).
    override var canBecomeKey: Bool { MainActor.assumeIsolated { OverlayController.shared.isFullScreen } }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // Double-click anywhere toggles full screen (handled here so it can't fight window dragging).
        if event.type == .leftMouseDown, event.clickCount == 2,
           let model = MainActor.assumeIsolated({ OverlayController.shared.model }) {
            MainActor.assumeIsolated { OverlayController.shared.toggleFullScreen(model: model) }
            return
        }
        super.sendEvent(event)
    }

    /// Full screen has the keyboard: + / - / 0 resize the subtitle text (Space still pauses, via AppDelegate).
    override func keyDown(with event: NSEvent) {
        let handled = MainActor.assumeIsolated { () -> Bool in
            guard let m = OverlayController.shared.model,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
            switch event.charactersIgnoringModifiers {
            case "+", "=": m.overlayFontSize = min(96, m.overlayFontSize + 2)
            case "-", "_": m.overlayFontSize = max(14, m.overlayFontSize - 2)
            case "0": m.overlayFontSize = 28
            default: return false
            }
            return true
        }
        if !handled { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {   // Esc
        MainActor.assumeIsolated {
            let c = OverlayController.shared
            if c.isFullScreen, let m = c.model { c.toggleFullScreen(model: m) }
        }
    }
}

enum OverlayLayout: String, CaseIterable, Identifiable {
    case sideBySide = "반반 (원문 | 번역)"
    case stacked = "위아래 (원문 위, 번역 아래)"
    case translationOnly = "번역만"
    var id: String { rawValue }
}

struct SubtitleOverlay: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var controller = OverlayController.shared
    @State private var hovering = false

    private struct Line: Identifiable {
        let id: String
        let source: String
        let translation: String   // "" while not translated yet
        var speaker: Int? = nil
        let pending: Bool         // translation queued / streaming
    }

    /// Windowed: the chosen number of lines. Full screen has room for more history.
    private var lineCount: Int { max(1, controller.isFullScreen ? max(model.overlayLines, 12) : model.overlayLines) }

    private var lines: [Line] {
        var out = model.segments.suffix(lineCount).map { seg in
            Line(id: seg.id.uuidString, source: seg.source, translation: seg.translation, speaker: seg.speaker,
                 pending: seg.translation.isEmpty || seg.state == .translating)
        }
        // Speech still being recognized: show it so the overlay doesn't feel frozen.
        let live = [model.heldText, model.volatileText].filter { !$0.isEmpty }.joined(separator: " ")
        if !live.isEmpty { out.append(Line(id: "live", source: live, translation: "", pending: true)) }
        return Array(out.suffix(lineCount))
    }

    var body: some View {
        let full = controller.isFullScreen
        let size = model.overlayFontSize * (full ? model.overlayFullScreenScale : 1)
        ZStack(alignment: .topTrailing) {
            // Bottom-anchored: the newest line is always fully visible; when there's more text than room,
            // the stack grows upward past the top edge (clipped + faded) instead of overflowing both ways.
            Color.clear.overlay(alignment: .bottom) {
              VStack(spacing: size * 0.3) {
                if lines.isEmpty {
                    Text(model.isRunning ? "…" : "Tongyeok 자막 — 시작(⌘R)하면 여기에 원문과 번역이 표시됩니다")
                        .font(model.font(size * 0.6))
                        .foregroundStyle(.white.opacity(0.6))
                }
                ForEach(lines) { line in
                    // Full height, never truncated: overflow pushes the oldest lines off the top (clipped).
                    row(line, size: size).fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                }
              }
              .animation(.easeOut(duration: 0.15), value: lines.map(\.id))
            }
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: full ? 0.12 : 0.18)],
                                 startPoint: .top, endPoint: .bottom))
            .padding(.horizontal, full ? 60 : 20).padding(.vertical, full ? 48 : 12)

            if hovering && full {
                Text("Esc 또는 더블클릭: 전체 화면 끝내기")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 14)
            }
            if hovering {
                Button { OverlayController.shared.hide(model: model) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain).padding(8)
                .help("자막 창 닫기 (⌘T)")
            }
        }
        .clipped()
        .background(RoundedRectangle(cornerRadius: full ? 0 : 14)
            .fill(.black.opacity(full ? max(model.overlayOpacity, 0.85) : model.overlayOpacity)))
        .overlay(alignment: .bottomTrailing) {
            if hovering && !full {   // hint: edges and corners resize (ResizeHandle), drag elsewhere moves
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    .padding(7).allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Picker("배치", selection: $model.overlayLayoutRaw) {
                ForEach(OverlayLayout.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("줄 수", selection: $model.overlayLines) {
                ForEach(1...4, id: \.self) { Text("\($0)줄").tag($0) }
            }
            Button("글자 크게") { model.overlayFontSize = min(96, model.overlayFontSize + 2) }
            Button("글자 작게") { model.overlayFontSize = max(14, model.overlayFontSize - 2) }
            Divider()
            Button(full ? "전체 화면 끝내기" : "전체 화면") { controller.toggleFullScreen(model: model) }
            Toggle("클릭 통과 (메뉴 > 전사에서 해제)", isOn: $model.overlayClickThrough)
            Button("자막 창 닫기") { OverlayController.shared.hide(model: model) }
        }
        .onChange(of: model.overlayClickThrough) { _, on in OverlayController.shared.applyClickThrough(on) }
    }

    /// "화자 1" in the speaker's color, in front of the line (separate view so head-truncation keeps it).
    @ViewBuilder
    private func who(_ line: Line, size: Double) -> some View {
        if let s = line.speaker {
            Text(AppModel.speakerLabel(s))
                .font(model.font(size * 0.62, weight: .bold))
                .foregroundStyle(SpeakerColor.of(s))
                .fixedSize()
        }
    }

    @ViewBuilder
    private func row(_ line: Line, size: Double) -> some View {
        let translation = Text(line.translation.isEmpty ? "…" : line.translation)
            .font(model.font(size, weight: .semibold))
            .foregroundStyle(.white.opacity(line.pending ? 0.65 : 1))
        switch model.overlayLayout {
        case .sideBySide:
            // Same row = same sentence, like the main window's table.
            HStack(alignment: .top, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    who(line, size: size)
                    Text(line.source)
                        .font(model.font(size * 0.9))
                        .foregroundStyle(.white.opacity(line.id == "live" ? 0.6 : 0.85))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(.white.opacity(0.25)).frame(width: 1)
                // Live row: nothing to translate yet, keep that side empty instead of a second "…".
                (line.id == "live" ? Text("") : translation)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .stacked:
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    who(line, size: size)
                    Text(line.source)
                        .font(model.font(size * 0.6))
                        .foregroundStyle(.white.opacity(0.75))
                }
                if line.id != "live" { translation }
            }
            .multilineTextAlignment(.center)
        case .translationOnly:
            // Until it's translated, show the original so the line isn't blank.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                who(line, size: size)
                Text(line.translation.isEmpty ? line.source : line.translation)
                    .font(model.font(size, weight: .semibold))
                    .foregroundStyle(.white.opacity(line.pending ? 0.65 : 1))
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Debug hook (`STTTRANS_SNAPSHOT_DIR`): every 2 s, writes each visible window's pixels to
/// `<dir>/<n>-<title>.png` and logs its frame (no screen-recording permission needed).
@MainActor
enum DebugSnapshots {
    static func startIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["STTTRANS_SNAPSHOT_DIR"] else { return }
        Task {
            while true {
                try? await Task.sleep(for: .seconds(2))
                for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let view = w.contentView?.superview ?? w.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = w.title.isEmpty ? (w is NSPanel ? "overlay" : "window") : w.title
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(i)-\(name).png"))
                    dlog("window \(name) frame=\(w.frame)")
                }
            }
        }
    }
}
