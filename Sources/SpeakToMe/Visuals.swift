import AppKit
import SwiftUI

// MARK: - Mood

/// How the apparition looks and feels in each phase. The whole sky changes colour for the
/// big moments, so you can read the state from across the room.
struct Mood {
    /// What the scene is multiplied by: white leaves the film as it is.
    var sky: RGBA
    var smile = 0.5
    /// How open the eyes are. 1 is wide awake, 0 shut.
    var eye = 1.0
    /// How brightly the eyes burn before the voice adds to it.
    var glow = 0.55
    var brow = 0.0
    var browAsymmetry = 0.0
    /// Positive droops the brows outward, sad; negative pulls them in, cross.
    var browTilt = 0.0
    /// How far the mouth rests open, and its shape: -1 pursed, 1 stretched.
    var mouth = 0.0
    var mouthWide = 0.0
    /// It draws back into the sky.
    var thought = 0.0
    /// A fixed direction to look, or nil to glance around and follow the pointer.
    var gaze: SIMD2<Double>?
    var followsPointer = 1.0
    var tilt = 0.0
    var cloudLight = 1.0
    /// How fast the film runs.
    var film: Float = 0.85
    /// Starting this phase sends a wave out of the mouth.
    var strikes = false

    static let void = RGBA.hex(0x07080C)
    static let cherry = RGBA.hex(0xB5122A)
    static let youInk = RGBA.hex(0xE9ECF1)
    static let replyInk = RGBA.hex(0xCFE8FA)

    // The sky in each mood, as a grade over the film.
    static let clear = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let violet = RGBA(r: 0.92, g: 0.62, b: 1.25, a: 1)
    static let hollow = RGBA(r: 0.72, g: 0.76, b: 0.86, a: 1)
    static let ember = RGBA(r: 1.2, g: 0.42, b: 0.48, a: 1)

    /// The colours of the voices rippling through the sky.
    static let saidWave = RGBA.hex(0x5FCBFF)
    static let heardWave = RGBA.hex(0xC9DCFF)

    static func of(_ phase: VoiceSession.Phase, muted: Bool) -> Mood {
        switch phase {
        case .loading:
            return Mood(sky: hollow, smile: 0, eye: 0, glow: 0.1, thought: 0.7, followsPointer: 0, film: 0.5)
        case .ready:
            // Barely parted, and it watches.
            return Mood(sky: clear, smile: 0.35, mouth: 0.04)
        case .listening where muted:
            return Mood(sky: hollow, smile: -0.1, eye: 0.35, glow: 0.2, browAsymmetry: 0.3, thought: 0.35, film: 0.5)
        case .listening:
            return Mood(sky: clear, smile: 0.1, eye: 1.05, glow: 0.8, brow: 0.2)
        case .hearing:
            return Mood(sky: clear, smile: 0, eye: 1.2, glow: 1.0, brow: 0.35, mouth: 0.03, tilt: 0.035, film: 1, strikes: true)
        case .transcribing, .thinking:
            // The light rolls up in its head and pulses.
            return Mood(sky: violet, smile: 0, eye: 0.8, glow: 0.5, browAsymmetry: 0.5, thought: 0.45, gaze: SIMD2(0, -1.5), tilt: -0.03, film: 0.6)
        case .speaking:
            return Mood(sky: clear, smile: 0.1, glow: 0.7, followsPointer: 0.6, film: 1, strikes: true)
        case .failed:
            return Mood(sky: ember, smile: -0.5, eye: 0.12, glow: 0.15, browTilt: 0.7, thought: 0.4, followsPointer: 0, cloudLight: 0.55, film: 0.35)
        }
    }

    /// Smooth while lips and ears are at work; the film's own pace the rest of the time, while
    /// the language model wants the GPU.
    static func frameInterval(for phase: VoiceSession.Phase) -> Double {
        isListeningOrTalking(phase) ? 1.0 / 30 : 1.0 / 24
    }

    static func isListeningOrTalking(_ phase: VoiceSession.Phase) -> Bool {
        switch phase {
        case .listening, .hearing, .speaking: return true
        default: return false
        }
    }

    /// Nothing is happening, so it can doze off and hold still.
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

// MARK: - Persona

/// The apparition, drawn by Metal. Snapshots get a still from the same shader, since
/// ImageRenderer can't capture a Metal view.
struct Persona: View {
    let phase: VoiceSession.Phase
    let muted: Bool
    let levels: AudioLevels
    let layout: FaceLayout
    /// Goes up when someone's around, which keeps it awake.
    var wake = 0
    var onRest: (Bool) -> Void = { _ in }
    @State private var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if Snapshots.isRendering {
            GeometryReader { geo in
                if let frame = FaceRenderer.shared?.image(of: .shared, layout: layout, points: geo.size, scale: 2) {
                    Image(decorative: frame, scale: 2)
                }
            }
        } else {
            FaceView(phase: phase, muted: muted, levels: levels, layout: layout, paused: paused, reduceMotion: reduceMotion)
                .pausesWhenIdle(phase: phase, wake: wake, paused: $paused)
                .onChange(of: paused) { _, now in onRest(now) }
        }
    }
}

// MARK: - Pausing

extension View {
    /// Stops an every-frame animation when nobody can see it move: once the face has dozed
    /// off with nothing going on, or while its window is hidden, minimised or fully covered
    /// (say, by a full-screen video).
    func pausesWhenIdle(phase: VoiceSession.Phase, wake: Int = 0, paused: Binding<Bool>) -> some View {
        modifier(IdlePause(phase: phase, wake: wake, paused: paused))
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
    let wake: Int
    @Binding var paused: Bool
    @State private var settled = false
    @State private var onScreen = true

    func body(content: Content) -> some View {
        content
            .onWindowVisibilityChange { onScreen = $0; update() }
            .task(id: "\(Mood.isIdle(phase))-\(wake)") {
                settled = false
                update()
                guard Mood.isIdle(phase) else { return }
                try? await Task.sleep(for: .seconds(FaceEngine.asleepAfter))
                guard !Task.isCancelled else { return }
                settled = true
                update()
            }
    }

    private func update() {
        let shouldPause = settled || (!onScreen && !UIDrive.isRunning)
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
