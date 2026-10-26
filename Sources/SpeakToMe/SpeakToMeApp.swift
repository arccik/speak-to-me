import AppKit
import SwiftUI

struct SpeakToMeApp: App {
    @ObservedObject private var session = VoiceSession.shared
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
        // Launched via `swift run` there is no app bundle; make it a normal foreground app anyway.
        NSApplication.shared.setActivationPolicy(.regular)

        let session = VoiceSession.shared
        MainActor.assumeIsolated {
            Shortcuts.shared.install(.talk) {
                guard session.canToggle else { return }
                session.toggle()
                // Working in another app? Show the floating orb so you can see it listening.
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
                .environmentObject(session)
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
            SettingsView().environmentObject(session)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(session)
        } label: {
            Image(systemName: session.isActive ? "waveform.circle.fill" : "waveform.circle")
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var session: VoiceSession
    @ObservedObject private var shortcuts = Shortcuts.shared

    var body: some View {
        Button(session.isActive ? "Stop Listening" : "Start Listening") { session.toggle() }
            .disabled(!session.canToggle)
        if let talk = shortcuts.talk { Text("\(talk.display) toggles from any app") }
        Divider()
        Button("Show Window") { AppActions.showMainWindow() }
        Button(MiniOrbController.shared.isVisible ? "Hide Floating Orb" : "Show Floating Orb") {
            MiniOrbController.shared.toggle(session: session)
        }
        Divider()
        Button("Quit Speak to Me") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
