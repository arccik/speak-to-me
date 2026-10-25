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
            .init(role: "user", text: "Wait, is it in Russia?"),
            .init(role: "assistant", text: "It is. Elbrus sits in southern Russia, near the border with Georgia."),
        ]
        let states: [(String, VoiceSession.Phase, [VoiceSession.Line], Float, Float)] = [
            ("1-ready-empty", .ready, [], 0, 0),
            ("2-listening-empty", .hearing, [], 0.7, 0),
            ("3-thinking", .thinking, Array(conversation.prefix(5)) + [.init(role: "assistant", text: "")], 0, 0),
            ("4-speaking", .speaking, conversation, 0, 0.75),
            ("5-error", .failed("Can't reach oMLX at http://127.0.0.1:8000. Is the oMLX app running?"), [], 0, 0),
        ]
        for (name, phase, lines, mic, speaker) in states {
            let session = VoiceSession()
            session.phase = phase
            session.lines = lines
            session.lastLatencyMs = lines.isEmpty ? nil : 912
            session.models = [.init(id: "gemma-4-26b-a4b-it-4bit", sizeBytes: 16_108_266_064)]
            session.modelID = "gemma-4-26b-a4b-it-4bit"
            session.levels.mic = mic
            session.levels.speaker = speaker
            let view = ContentView().environmentObject(session).frame(width: 520, height: 800)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        exit(0)
    }
}
