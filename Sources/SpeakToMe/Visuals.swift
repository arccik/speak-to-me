import SwiftUI

// MARK: - Mood

/// How the visuals should feel in each phase. Everything eases between moods, so
/// state changes melt into each other instead of snapping.
struct Mood {
    var core: RGBA
    var mid: RGBA
    var edge: RGBA
    /// Baseline wobble of the cloud's edge.
    var energy: Double
    /// How fast the edge churns.
    var speed: Double
    var scale: Double
    /// Slow rotation while thinking.
    var swirl: Double

    static func of(_ phase: VoiceSession.Phase) -> Mood {
        switch phase {
        case .loading, .ready:
            return Mood(core: .hex(0xCFE6FF), mid: .hex(0x4C7CF0), edge: .hex(0x34288A),
                        energy: 0.12, speed: 0.45, scale: 0.86, swirl: 0)
        case .listening:
            return Mood(core: .hex(0xE2FCFF), mid: .hex(0x2CC4E6), edge: .hex(0x2A55D6),
                        energy: 0.22, speed: 0.8, scale: 0.94, swirl: 0)
        case .hearing:
            return Mood(core: .hex(0xF0FEFF), mid: .hex(0x35D6EE), edge: .hex(0x2F62E8),
                        energy: 0.35, speed: 1.2, scale: 1.0, swirl: 0)
        case .transcribing, .thinking:
            return Mood(core: .hex(0xF3E9FF), mid: .hex(0x8E62F7), edge: .hex(0x3D2A9E),
                        energy: 0.42, speed: 1.6, scale: 0.92, swirl: 0.7)
        case .speaking:
            return Mood(core: .hex(0xE8F7FF), mid: .hex(0x3FA6FF), edge: .hex(0x5A3FD8),
                        energy: 0.28, speed: 1.1, scale: 1.0, swirl: 0.15)
        case .failed:
            return Mood(core: .hex(0xFFE4E4), mid: .hex(0xEF5A5A), edge: .hex(0x7A1F45),
                        energy: 0.1, speed: 0.4, scale: 0.84, swirl: 0)
        }
    }

    /// Which audio drives the cloud right now.
    static func level(for phase: VoiceSession.Phase, levels: AudioLevels, time: Double) -> Double {
        switch phase {
        case .listening, .hearing: return Double(levels.mic)
        case .speaking: return Double(levels.speaker)
        case .thinking, .transcribing: return 0.18 + 0.1 * sin(time * 3.1)
        default: return 0
        }
    }
}

struct RGBA {
    var r, g, b, a: Double

    static func hex(_ v: UInt32, _ a: Double = 1) -> RGBA {
        RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: a)
    }

    func mix(_ o: RGBA, _ t: Double) -> RGBA {
        RGBA(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t, a: a + (o.a - a) * t)
    }

    func color(_ opacity: Double = 1) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a * opacity)
    }
}

/// Per-frame eased state, kept in a reference so the TimelineView can update it while drawing.
final class MoodAnimator {
    private(set) var mood = Mood.of(.ready)
    private(set) var level = 0.0
    /// Time scaled by mood speed, so changing speed never makes the shape jump.
    private(set) var clock = 0.0
    private(set) var rotation = 0.0
    private var last: Double?

    func step(to target: Mood, level targetLevel: Double, now: Double) {
        guard let last else {
            // First frame: start in the right mood instead of fading in from "ready".
            self.last = now
            mood = target
            level = targetLevel
            return
        }
        let dt = min(0.1, now - last)
        self.last = now
        let k = 1 - exp(-dt * 4)
        mood.core = mood.core.mix(target.core, k)
        mood.mid = mood.mid.mix(target.mid, k)
        mood.edge = mood.edge.mix(target.edge, k)
        mood.energy += (target.energy - mood.energy) * k
        mood.speed += (target.speed - mood.speed) * k
        mood.scale += (target.scale - mood.scale) * k
        mood.swirl += (target.swirl - mood.swirl) * k
        // Fast attack, slow release, like a VU meter.
        let rate = targetLevel > level ? 18.0 : 5.0
        level += (targetLevel - level) * (1 - exp(-dt * rate))
        clock += dt * mood.speed
        rotation += dt * mood.swirl
    }
}

// MARK: - Mist orb

/// A soft, cloud-like orb: several blurred, gently deforming blobs stacked with
/// additive blending. Its edge churns with your voice or the assistant's.
struct MistOrb: View {
    let phase: VoiceSession.Phase
    let levels: AudioLevels
    @State private var animator = MoodAnimator()

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                animator.step(to: .of(phase), level: Mood.level(for: phase, levels: levels, time: now), now: now)
                draw(in: &context, size: size)
            }
        }
        .drawingGroup()
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let mood = animator.mood
        let level = animator.level
        let t = animator.clock
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.30 * mood.scale * (1 + 0.16 * level)
        let wobble = 0.035 + 0.11 * mood.energy + 0.16 * level

        // 1. Wide haze behind everything.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.45))
            let r = radius * 1.35
            layer.fill(
                blob(center: center, radius: r, wobble: wobble * 0.6, t: t * 0.6, seed: 11),
                with: .radialGradient(
                    Gradient(colors: [mood.mid.color(0.55), mood.edge.color(0.3), mood.edge.color(0)]),
                    center: center, startRadius: 0, endRadius: r * 1.1))
        }

        // 2. The cloud body: two offset blobs so the edge looks layered and misty.
        for (i, seed) in [1.0, 4.0].enumerated() {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: radius * (i == 0 ? 0.11 : 0.18)))
                layer.blendMode = i == 0 ? .normal : .plusLighter
                let r = radius * (i == 0 ? 1.0 : 0.94)
                let lightSource = CGPoint(x: center.x - r * 0.18, y: center.y - r * 0.22)
                layer.fill(
                    blob(center: center, radius: r, wobble: wobble, t: t, seed: seed),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: mood.core.color(i == 0 ? 0.95 : 0.35), location: 0),
                            .init(color: mood.mid.color(i == 0 ? 0.9 : 0.35), location: 0.45),
                            .init(color: mood.edge.color(i == 0 ? 0.85 : 0.0), location: 1),
                        ]),
                        center: lightSource, startRadius: 0, endRadius: r * 1.15))
            }
        }

        // 3. Glowing core.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.22))
            layer.blendMode = .plusLighter
            let r = radius * (0.5 + 0.12 * level)
            let c = CGPoint(x: center.x - radius * 0.08, y: center.y - radius * 0.1)
            layer.fill(
                blob(center: c, radius: r, wobble: wobble * 0.8, t: t * 1.3, seed: 7),
                with: .radialGradient(
                    Gradient(colors: [RGBA.hex(0xFFFFFF).color(0.85), mood.core.color(0.4), mood.core.color(0)]),
                    center: c, startRadius: 0, endRadius: r))
        }
    }

    /// A closed blob whose radius is modulated by a few slowly drifting sine harmonics.
    private func blob(center: CGPoint, radius: Double, wobble: Double, t: Double, seed: Double) -> Path {
        let points = 120
        let rotation = animator.rotation
        let harmonics: [(k: Double, speed: Double, weight: Double)] = [
            (2, 0.9, 0.55), (3, -1.3, 0.45), (5, 1.7, 0.3), (7, -2.3, 0.2), (11, 2.9, 0.1),
        ]
        var path = Path()
        for i in 0...points {
            let theta = Double(i) / Double(points) * 2 * .pi
            var offset = 0.0
            for h in harmonics {
                offset += sin(h.k * (theta + rotation) + t * h.speed + seed * h.k * 1.7) * h.weight
            }
            let r = radius * (1 + wobble * offset)
            let p = CGPoint(x: center.x + cos(theta) * r, y: center.y + sin(theta) * r)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Glow waves

/// Thin glowing sine strands that swell with the voice, tapering at both ends.
struct GlowWaves: View {
    let phase: VoiceSession.Phase
    let levels: AudioLevels
    @State private var animator = MoodAnimator()

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                animator.step(to: .of(phase), level: Mood.level(for: phase, levels: levels, time: now), now: now)
                let mood = animator.mood
                let amplitude = size.height * 0.42 * (0.08 + 0.92 * animator.level)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [mood.mid.color(0), mood.mid.color(0.9), mood.edge.mix(.hex(0xB794FF), 0.5).color(0.9), mood.edge.color(0)]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))

                for strand in 0..<3 {
                    let path = wave(size: size, amplitude: amplitude * [1, 0.7, 0.45][strand],
                                    frequency: [1.6, 2.1, 2.7][strand], phase: animator.clock * 3 + Double(strand) * 1.9)
                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: 4))
                        glow.stroke(path, with: shading, lineWidth: 3)
                    }
                    context.stroke(path, with: shading, lineWidth: strand == 0 ? 1.4 : 0.9)
                }
            }
        }
    }

    private func wave(size: CGSize, amplitude: Double, frequency: Double, phase: Double) -> Path {
        var path = Path()
        let steps = 90
        for i in 0...steps {
            let x = Double(i) / Double(steps)
            let taper = sin(x * .pi)
            let y = size.height / 2 + sin(x * frequency * 2 * .pi + phase) * amplitude * taper
            let p = CGPoint(x: x * size.width, y: y)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        return path
    }
}
