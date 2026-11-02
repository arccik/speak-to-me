import AppKit
import SwiftUI

struct SpeakToMeApp: App {
    private let session = VoiceSession.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--snapshot"), args.indices.contains(flag + 1) {
            let dir = args[flag + 1]
            Task { @MainActor in Snapshots.run(to: dir) }
            return
        }
        if args.contains("--micdiag") {
            Task.detached { await MicDiagnostics.run() }
            return
        }
        if let flag = args.firstIndex(of: "--selftest") {
            let model = args.indices.contains(flag + 1) ? args[flag + 1] : nil
            Task.detached { await SelfTest.run(model: model) }
            return
        }
        if let flag = args.firstIndex(of: "--uidrive"), args.indices.contains(flag + 1) {
            let dir = args[flag + 1]
            Task { @MainActor in await UIDrive.run(to: dir) }
        }
        if args.contains("--uibench") {
            Task { @MainActor in await UIBench.run() }
        }
        // Launched via `swift run` there is no app bundle; make it a normal foreground app anyway.
        NSApplication.shared.setActivationPolicy(.regular)

        let session = VoiceSession.shared
        MainActor.assumeIsolated {
            Shortcuts.shared.install(.talk) {
                guard session.canToggle else { return }
                session.toggle()
                // Working in another app? Show the floating face so you can see it listening.
                if UserDefaults.standard.object(forKey: "orbOnHotKey") as? Bool ?? true,
                   !NSApp.isActive || !AppActions.mainWindowVisible {
                    MiniOrbController.shared.show(session: session)
                }
            }
            Shortcuts.shared.install(.floatingOrb) { MiniOrbController.shared.toggle(session: session) }
        }
    }

    var body: some Scene {
        WindowGroup("Speak to Me", id: "main") {
            ContentView()
                .environment(session)
                .frame(minWidth: 440, minHeight: 640)
                .task { await session.bootOnce() }
                .onAppear {
                    AppActions.openMainWindow = openWindow
                    NSApp.activate(ignoringOtherApps: true)
                    if UserDefaults.standard.bool(forKey: "miniOrbVisible") {
                        MiniOrbController.shared.show(session: session)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 520, height: 800)

        Settings {
            SettingsView().environment(session)
        }

        MenuBarExtra {
            MenuBarContent().environment(session)
        } label: {
            MenuBarIcon().environment(session)
        }
    }
}

/// A view of its own, so it follows the session's state as it changes.
private struct MenuBarIcon: View {
    @Environment(VoiceSession.self) private var session

    var body: some View {
        Image(systemName: session.isActive ? "eye.fill" : "eye")
    }
}

private struct MenuBarContent: View {
    @Environment(VoiceSession.self) private var session
    @ObservedObject private var shortcuts = Shortcuts.shared

    var body: some View {
        Button(session.isActive ? "Stop Listening" : "Start Listening") { session.toggle() }
            .disabled(!session.canToggle)
        if let talk = shortcuts.talk { Text("\(talk.display) toggles from any app") }
        Divider()
        Button("Show Window") { AppActions.showMainWindow() }
        Button(MiniOrbController.shared.isVisible ? "Hide Floating Face" : "Show Floating Face") {
            MiniOrbController.shared.toggle(session: session)
        }
        Divider()
        Button("Quit Speak to Me") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
