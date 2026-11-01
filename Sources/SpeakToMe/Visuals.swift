import AppKit
import SwiftUI

// MARK: - Mood

/// What the record looks like and how it moves in each phase. The vinyl itself changes
/// colour for the big moments, so you can read the state from across the room.
struct Mood {
    var vinyl: RGBA
    var label: RGBA
    /// Turns a second. Zero lets it coast to a stop.
    var speed: Double
    /// 0 is the tonearm parked, 1 is its head on the groove.
    var arm: Double
    var armLift: Double
    /// Starting this phase sends a wave across the disc.
    var strikes = false

    static let cherry = RGBA.hex(0xE5102B)
    static let cobalt = RGBA.hex(0x1420FF)
    static let youInk = RGBA.hex(0xFFFFFF)
    static let replyInk = RGBA.hex(0xF4FF3A)

    static func of(_ phase: VoiceSession.Phase, muted: Bool) -> Mood {
        switch phase {
        case .loading, .ready:
            return Mood(vinyl: cherry, label: cobalt, speed: 0, arm: 0, armLift: 0)
        case .listening where muted:
            return Mood(vinyl: .hex(0x7A0A1C), label: cobalt, speed: 0.06, arm: 0.9, armLift: 0.6)
        case .listening:
            return Mood(vinyl: cherry, label: cobalt, speed: 0.12, arm: 1, armLift: 0)
        case .hearing:
            return Mood(vinyl: cherry, label: cobalt, speed: 0.22, arm: 1, armLift: 0, strikes: true)
        case .transcribing, .thinking:
            return Mood(vinyl: cobalt, label: cherry, speed: 0.1, arm: 0.9, armLift: 0.8)
        case .speaking:
            return Mood(vinyl: cherry, label: cobalt, speed: 0.2, arm: 1, armLift: 0, strikes: true)
        case .failed:
            return Mood(vinyl: .hex(0x15131A), label: cherry, speed: 0, arm: 0, armLift: 0)
        }
    }

    /// Smooth while something's happening, gentle on the CPU while idle.
    static func frameInterval(for phase: VoiceSession.Phase) -> Double {
        isIdle(phase) ? 1.0 / 20 : 1.0 / 30
    }

    /// Nothing is happening: once the disc has coasted to a stop, it can hold still.
    static func isIdle(_ phase: VoiceSession.Phase) -> Bool {
        switch phase {
        case .loading, .ready, .failed: return true
        default: return false
        }
    }
}

extension RGBA: Equatable {}

struct RGBA {
    var r, g, b, a: Double

    static func hex(_ v: UInt32, _ a: Double = 1) -> RGBA {
        RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: a)
    }

    func color(_ opacity: Double = 1) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a * opacity)
    }
}

// MARK: - Record

/// The turning record, drawn by Metal. Snapshots get a still from the same shader, since
/// ImageRenderer can't capture a Metal view.
struct Record: View {
    let phase: VoiceSession.Phase
    let muted: Bool
    let levels: AudioLevels
    let layout: LatheLayout
    /// Keep drawing though nothing's playing: you're scratching it.
    var awake = false
    @State private var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if Snapshots.isRendering {
            GeometryReader { geo in
                if let frame = LatheRenderer.shared?.image(of: .shared, layout: layout, points: geo.size, scale: 2) {
                    Image(decorative: frame, scale: 2)
                }
            }
        } else {
            LatheView(phase: phase, muted: muted, levels: levels, layout: layout, paused: paused && !awake, reduceMotion: reduceMotion)
                .pausesWhenIdle(phase: phase, paused: $paused)
        }
    }
}

// MARK: - Pausing

extension View {
    /// Stops an every-frame animation when nobody can see it move: a few seconds after
    /// the conversation goes idle (once the disc has coasted to a stop), or while
    /// its window is hidden, minimised or fully covered (say, by a full-screen video).
    func pausesWhenIdle(phase: VoiceSession.Phase, paused: Binding<Bool>) -> some View {
        modifier(IdlePause(phase: phase, paused: paused))
    }

    /// Reports whether the view's window is actually on screen.
    @ViewBuilder func onWindowVisibilityChange(_ action: @escaping (Bool) -> Void) -> some View {
        // ImageRenderer draws any AppKit view as a placeholder, over whatever it's attached to.
        if Snapshots.isRendering {
            self
        } else {
            background(WindowVisibilityProbe(onChange: action))
        }
    }
}

private struct IdlePause: ViewModifier {
    let phase: VoiceSession.Phase
    @Binding var paused: Bool
    @State private var settled = false
    @State private var onScreen = true

    func body(content: Content) -> some View {
        content
            .onWindowVisibilityChange { onScreen = $0; update() }
            .task(id: Mood.isIdle(phase)) {
                settled = false
                update()
                guard Mood.isIdle(phase) else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                settled = true
                update()
            }
    }

    private func update() {
        let shouldPause = settled || !onScreen
        if paused != shouldPause { paused = shouldPause }
    }
}

private struct WindowVisibilityProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.onChange = onChange
    }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.report() }
            // Not during the SwiftUI update that attached us.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            onChange?(window.occlusionState.contains(.visible))
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
