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
        let russian: [VoiceSession.Line] = [
            .init(role: "user", text: "Какая самая высокая гора в Европе?"),
            .init(role: "assistant", text: "Эльбрус на Кавказе, примерно пять тысяч шестьсот сорок два метра."),
        ]
        let states: [(String, VoiceSession.Phase, [VoiceSession.Line], Float, Float, Bool, CGSize)] = [
            ("1-ready-empty", .ready, [], 0, 0, false, .standard),
            ("2-hearing-live", .hearing, Array(conversation.prefix(2)), 0.72, 0, false, .standard),
            ("3-thinking", .thinking, Array(conversation.prefix(5)) + [.init(role: "assistant", text: "")], 0, 0, false, .standard),
            ("4-speaking", .speaking, conversation, 0, 0.75, false, .standard),
            ("4b-speaking-chat", .speaking, conversation, 0, 0.75, true, .standard),
            ("5-error", .failed("Can't reach oMLX at http://127.0.0.1:8000. Is the oMLX app running?"), [], 0, 0, false, .standard),
            ("6-small", .speaking, conversation, 0, 0.75, false, CGSize(width: 440, height: 640)),
            ("7-wide", .hearing, conversation, 0.72, 0, false, CGSize(width: 1280, height: 800)),
            ("8-russian", .speaking, russian, 0, 0.7, false, .standard),
            ("9-ten-minutes-in", .hearing, conversation, 0.72, 0, false, .standard),
        ]
        let chatWasOpen = UserDefaults.standard.object(forKey: "chatOpen")
        defer { UserDefaults.standard.set(chatWasOpen, forKey: "chatOpen") }
        for (name, phase, lines, mic, speaker, chatOpen, size) in states {
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
            FaceEngine.shared = FaceEngine()
            FaceEngine.shared.sync(lines: lines)
            playIn(phase, levels: session.levels, frames: name.hasPrefix("9") ? 18_000 : 420)
            let view = ContentView().environment(session).frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        renderPuck(to: dir)
        renderMouths(to: dir)
        renderToolActions(to: dir)
    }

    private static func renderToolActions(to dir: URL) {
        let samples: [(CGFloat, ToolAction.State)] = [CGFloat(360), CGFloat(480)].flatMap { width in
            [ToolAction.State.waiting, .running, .succeeded, .failed, .unknown].map { (width, $0) }
        }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: 0, width: 480, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        func capture(_ index: Int) {
            guard index < samples.count else { window.close(); renderSettings(to: dir); return }
            let (width, state) = samples[index]
            var action = ToolAction(title: "Create calendar appointment", server: "Calendar", state: state,
                arguments: "{\n  \"title\": \"Discuss the project\",\n  \"date\": \"2026-11-06\"\n}")
            action.started = Date().addingTimeInterval(-3)
            if state != .running && state != .waiting { action.finished = Date() }
            action.result = state == .failed ? "The service refused the request. Check your account permissions." : nil
            let view = ActionHistory(actions: [action], initiallyExpanded: true)
                .padding(22).frame(width: width, height: 400, alignment: .topLeading)
                .background(Theme.abyss).preferredColorScheme(.dark)
            window.setContentSize(NSSize(width: width, height: 400))
            window.contentView = NSHostingView(rootView: view)
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated {
                    if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: dir.appendingPathComponent("tools-\(state.rawValue)-\(Int(width)).png"))
                    }
                    capture(index + 1)
                }
            }
        }
        capture(0)
    }

    /// A few seconds of syllables, so the ripples look the way they do mid-sentence.
    private static func playIn(_ phase: VoiceSession.Phase, levels: AudioLevels, frames: Int = 420) {
        let engine = FaceEngine.shared
        let mic = levels.mic, speaker = levels.speaker
        var now = 0.0
        engine.step(phase: .ready, muted: false, levels: levels, now: now)
        for frame in 0..<frames {
            now += 1.0 / 30
            // Ending mid-syllable, so a still of it talking has its mouth open.
            let syllable = frames - frame < 6 ? 1 : Float(max(0, sin(Double(frame) * 0.42) * sin(Double(frame) * 0.09 + 1)))
            levels.mic = mic * (0.25 + 0.75 * syllable)
            levels.speaker = speaker * (0.25 + 0.75 * syllable)
            levels.speakerBands = SIMD3(0.12, 0.03, 0.008) * (0.25 + 0.75 * syllable)
            engine.step(phase: phase, muted: false, levels: levels, now: now)
        }
        levels.mic = mic
        levels.speaker = speaker
    }

    /// The lips on each kind of sound, from made-up voice bands. Loudness and hiss come
    /// through as they would from the speaker; the first few frames learn this "voice".
    private static func renderMouths(to dir: URL) {
        guard let metal = FaceRenderer.shared else { return }
        let sounds: [(String, Float, SIMD3<Float>)] = [
            ("ah", 0.85, SIMD3(0.14, 0.05, 0.004)),
            ("ee", 0.65, SIMD3(0.07, 0.09, 0.004)),
            ("oo", 0.6, SIMD3(0.16, 0.012, 0.001)),
            ("ss", 0.55, SIMD3(0.012, 0.03, 0.09)),
            ("closed", 0, .zero),
        ]
        for (name, loudness, bands) in sounds {
            let levels = AudioLevels()
            FaceEngine.shared = FaceEngine()
            var now = 0.0
            FaceEngine.shared.step(phase: .ready, muted: false, levels: levels, now: now)
            levels.speaker = 0.6
            levels.speakerBands = SIMD3(0.14, 0.04, 0.004)
            for _ in 0..<90 { now += 1.0 / 30; FaceEngine.shared.step(phase: .speaking, muted: false, levels: levels, now: now) }
            levels.speaker = loudness
            levels.speakerBands = bands
            for _ in 0..<8 { now += 1.0 / 30; FaceEngine.shared.step(phase: .speaking, muted: false, levels: levels, now: now) }
            guard let frame = metal.image(of: .shared, layout: FaceLayout(style: .puck), points: CGSize(width: 340, height: 340), scale: 2),
                  let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: dir.appendingPathComponent("mouth-\(name).png"))
        }
    }

    /// The floating face, on a checker so its transparent corners show.
    private static func renderPuck(to dir: URL) {
        guard let metal = FaceRenderer.shared else { return }
        for (name, phase) in [("listening", VoiceSession.Phase.hearing), ("thinking", .thinking), ("speaking", .speaking)] {
            let levels = AudioLevels()
            levels.mic = 0.7
            levels.speaker = 0.7
            FaceEngine.shared = FaceEngine()
            playIn(phase, levels: levels)
            guard let frame = metal.image(of: .shared, layout: FaceLayout(style: .puck), points: CGSize(width: 150, height: 150), scale: 2),
                  let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: dir.appendingPathComponent("puck-\(name).png"))
        }
    }

    /// Forms and lists are AppKit-backed, which ImageRenderer can't draw, so these go
    /// through a real (offscreen) window instead.
    private static func renderSettings(to dir: URL) {
        let session = VoiceSession()
        session.models = [.init(id: "gemma-4-26b-a4b-it-4bit", sizeBytes: 16_108_266_064)]
        session.modelID = "gemma-4-26b-a4b-it-4bit"
        session.levels.mic = 0.46 // the meter mid-word, past the default mark
        session.showEngineForSnapshot(.f5Russian, for: .russian, state: .ready)
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

private extension CGSize {
    static let standard = CGSize(width: 520, height: 800)
}
