import AppKit
import SwiftUI

@main
struct SpeakToMeApp: App {
    @StateObject private var session = VoiceSession()

    init() {
        let args = CommandLine.arguments
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
    }

    var body: some Scene {
        WindowGroup("Speak to Me") {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 420, minHeight: 560)
                .task { await session.boot() }
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 480, height: 720)

        Settings {
            SettingsView().environmentObject(session)
        }
    }
}
