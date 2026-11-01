import AppKit
import SwiftUI

/// `SpeakToMe --snapshot <dir>` renders the main window in several states to PNGs,
/// for checking the design without a screen recording.
@MainActor
enum Snapshots {
    static var isRendering = false

    static func run(to directory: String) {
        isRendering = true
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let conversation: [VoiceSession.Line] = [
            .init(role: "user", text: "What's the tallest mountain in Europe?"),
            .init(role: "assistant", text: "That's Mount Elbrus in the Caucasus, at about 5,642 metres. It's a dormant volcano with two summits."),
            .init(role: "user", text: "Have people skied down it?"),
            .init(role: "assistant", text: "Yes, plenty! There's a ski resort on its southern slopes, and", interrupted: true),
            .init(role: "user", text: "What's the weather there right now?"),
            .init(role: "assistant", text: "It's about minus eight at the summit, with strong winds and clear skies.", note: "Searched the web: weather Mount Elbrus"),
        ]
        let states: [(String, VoiceSession.Phase, [VoiceSession.Line], Float, Float, Bool)] = [
            ("1-ready-empty", .ready, [], 0, 0, false),
            ("2-hearing-live", .hearing, Array(conversation.prefix(2)), 0.7, 0, false),
            ("3-thinking", .thinking, Array(conversation.prefix(5)) + [.init(role: "assistant", text: "")], 0, 0, false),
            ("4-speaking", .speaking, conversation, 0, 0.75, false),
            ("4b-speaking-chat", .speaking, conversation, 0, 0.75, true),
            ("5-error", .failed("Can't reach oMLX at http://127.0.0.1:8000. Is the oMLX app running?"), [], 0, 0, false),
        ]
        let chatWasOpen = UserDefaults.standard.object(forKey: "chatOpen")
        defer { UserDefaults.standard.set(chatWasOpen, forKey: "chatOpen") }
        for (name, phase, lines, mic, speaker, chatOpen) in states {
            UserDefaults.standard.set(chatOpen, forKey: "chatOpen")
            let session = VoiceSession()
            session.phase = phase
            session.lines = lines
            if phase == .hearing { session.liveText = "And how long does it take to climb" }
            session.lastLatencyMs = lines.isEmpty ? nil : 912
            session.models = [.init(id: "gemma-4-26b-a4b-it-4bit", sizeBytes: 16_108_266_064)]
            session.modelID = "gemma-4-26b-a4b-it-4bit"
            session.levels.mic = mic
            session.levels.speaker = speaker
            let view = ContentView().environment(session).frame(width: 520, height: 800)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        renderOrbs(to: dir)
        renderSettings(to: dir)
    }

    /// The Metal orb next to the Canvas one it imitates (left), over the window's background.
    private static func renderOrbs(to dir: URL) {
        guard let metal = OrbRenderer.shared else { return }
        let points = 460, scale = 2
        for (name, phase, level) in [("ready", VoiceSession.Phase.ready, 0.0), ("listening", .listening, 0.5),
                                     ("thinking", .thinking, 0.2), ("speaking", .speaking, 0.7)] {
            let animator = MoodAnimator()
            animator.step(to: .of(phase), level: level, now: 0)
            let canvas = Canvas { context, size in MistOrb.draw(animator, in: &context, size: size) }
                .frame(width: CGFloat(points), height: CGFloat(points))
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = CGFloat(scale)
            let pixels = points * scale
            guard let reference = renderer.cgImage, let shaded = metal.image(of: animator, pixels: pixels),
                  let context = CGContext(data: nil, width: pixels * 2, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            context.setFillColor(CGColor(srgbRed: 0x10 / 255, green: 0x13 / 255, blue: 0x2A / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixels * 2, height: pixels))
            context.draw(reference, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            context.draw(shaded, in: CGRect(x: pixels, y: 0, width: pixels, height: pixels))
            guard let image = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: dir.appendingPathComponent("orb-\(name).png"))
        }
    }

    /// Forms and lists are AppKit-backed, which ImageRenderer can't draw, so these go
    /// through a real (offscreen) window instead.
    private static func renderSettings(to dir: URL) {
        let session = VoiceSession()
        session.models = [.init(id: "gemma-4-26b-a4b-it-4bit", sizeBytes: 16_108_266_064)]
        session.modelID = "gemma-4-26b-a4b-it-4bit"
        session.showEngineForSnapshot(.f5Russian, for: .russian, state: .downloading(0.42))
        session.showF5VoiceForSnapshot(.init(id: "sample", name: "Recording 1", transcript: VoiceSession.f5VoiceScript))
        let panes = SettingsView.Pane.allCases
        let original = UserDefaults.standard.string(forKey: "settingsPane")
        SettingsView.height = 1050
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: 0, width: 720, height: 1050),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)

        func capture(_ index: Int) {
            guard index < panes.count else {
                UserDefaults.standard.set(original, forKey: "settingsPane")
                exit(0)
            }
            UserDefaults.standard.set(panes[index].rawValue, forKey: "settingsPane")
            window.contentView = NSHostingView(rootView: SettingsView().environment(session))
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: dir.appendingPathComponent("settings-\(panes[index].rawValue).png"))
                    }
                    capture(index + 1)
                }
            }
        }
        capture(0)
    }
}
