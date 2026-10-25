import AppKit
import SwiftUI

/// A small always-on-top orb you can keep in a corner of the screen while you work.
/// Click it to start/stop, drag it anywhere, right-click for options.
@MainActor
final class MiniOrbController {
    static let shared = MiniOrbController()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(session: VoiceSession) {
        isVisible ? hide() : show(session: session)
    }

    func show(session: VoiceSession) {
        if panel == nil { panel = makePanel(session: session) }
        panel?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: "miniOrbVisible")
    }

    func hide() {
        panel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "miniOrbVisible")
    }

    private func makePanel(session: VoiceSession) -> NSPanel {
        let size = NSSize(width: 200, height: 230)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName("MiniOrb")
        if !panel.setFrameUsingName("MiniOrb"), let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 24, y: frame.minY + 24))
        }
        panel.contentView = NSHostingView(rootView: MiniOrbView().environmentObject(session))
        return panel
    }
}

private struct MiniOrbView: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        VStack(spacing: 2) {
            MistOrb(phase: session.phase, levels: session.levels)
                .frame(width: 150, height: 150)
                .contentShape(Circle().inset(by: 30))
                .onTapGesture { if session.canToggle { session.toggle() } }
            Text(caption)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(.black.opacity(0.45), in: Capsule())
            if let snippet {
                Text(snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 200, height: 230)
        .contextMenu {
            Button(session.isActive ? "Stop Listening" : "Start Listening") { session.toggle() }
                .disabled(!session.canToggle)
            Button("Open Speak to Me") { AppActions.showMainWindow() }
            Divider()
            Button("Hide Floating Orb") { MiniOrbController.shared.hide() }
        }
        .help("Click to start or stop · ⌥Space from anywhere")
    }

    private var caption: String {
        switch session.phase {
        case .listening: return "LISTENING"
        case .hearing: return "HEARING YOU"
        case .transcribing, .thinking: return "THINKING"
        case .speaking: return "SPEAKING"
        case .loading: return "LOADING"
        case .failed: return "ERROR"
        case .ready: return "⌥SPACE TO TALK"
        }
    }

    /// The words in flight: yours while you speak, the reply while it's spoken.
    private var snippet: String? {
        if let live = session.liveText, !live.isEmpty { return live }
        guard session.phase == .speaking || session.phase == .thinking,
              let last = session.lines.last, last.role == "assistant", !last.text.isEmpty
        else { return nil }
        return String(last.text.suffix(90))
    }
}

/// Bridges SwiftUI's window actions to AppKit-hosted views (the panel lives outside the scene graph).
@MainActor
enum AppActions {
    static var openMainWindow: OpenWindowAction?

    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?(id: "main")
        }
    }

    static var mainWindowVisible: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible && !$0.isMiniaturized }
    }
}
