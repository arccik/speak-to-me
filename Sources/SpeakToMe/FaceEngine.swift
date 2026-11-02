import Foundation

/// The face's state: what its lips, eyes and brows are doing right now, and the sound still
/// travelling through the sky. Shared by the main window and the floating face, and stepped
/// once a frame from whichever is drawing.
final class FaceEngine {
    static var shared = FaceEngine()

    /// How much sound the sky remembers: about four seconds, from the newest moment on.
    static let ringSamples = 256
    private static let ringRate = 60.0

    /// Fades away after this long with nothing going on, and drawing stops once its eyes are out.
    static let dozeAfter = 40.0
    static let asleepAfter = 45.0

    private(set) var mood = Mood.of(.ready, muted: false)
    private(set) var previousSky = Mood.of(.ready, muted: false).sky
    private(set) var clock = 0.0
    private(set) var level = 0.0

    // Lips.
    private(set) var jaw = 0.0
    /// -1 is pursed and round (oo), 1 is stretched wide (ee).
    private(set) var wide = 0.0
    private(set) var teeth = 0.0
    private(set) var breath = 0.0

    // The rest of the face.
    private(set) var eye = 1.0
    private(set) var gaze = SIMD2<Double>.zero
    private(set) var browLeft = 0.0
    private(set) var browRight = 0.0
    private(set) var browTilt = 0.0
    private(set) var smile = 0.5
    private(set) var thought = 0.0
    private var doze = 0.0
    /// How far it has sunk back into the fog.
    var recede: Double { max(thought, doze * 0.85) }
    private(set) var tilt = 0.0
    private(set) var bob = 0.0
    private(set) var cloudLight = 1.0
    /// Jumps to 1 when you cut in, and the head lurches forward before settling.
    private(set) var startle = 0.0

    /// The wave a phase change sends out of the mouth, in points, and how hard it hits.
    private(set) var front = 10_000.0
    private(set) var frontStrength = 0.0

    var reduceMotion = false
    /// Frames stepped so far, so a test can tell it's really drawing.
    private(set) var steps = 0

    private var last: Double?
    private var slowLevel = 0.0
    private var slowRoundness = 0.8
    private var emphasis = 0.0
    private var nextBlink = 3.0
    private var blinkLeft = 0.0
    private var nextGlance = 2.0
    private var glance = SIMD2<Double>.zero
    private var pointerAge = 100.0
    private var pointer = SIMD2<Double>.zero
    private var idle = 0.0
    private var lastPhase = VoiceSession.Phase.ready
    private var rings = [UInt8](repeating: 0, count: FaceEngine.ringSamples * 2)
    private var ringHead = 0
    private var ringDue = 0.0
    private var cutting = (you: 0.0, reply: 0.0)
    private var lastInterruptedID: UUID?
    private var firstLineID: UUID?

    // MARK: Stepping

    func step(phase: VoiceSession.Phase, muted: Bool, levels: AudioLevels, now: Double) {
        let target = Mood.of(phase, muted: muted)
        guard let last else {
            self.last = now
            mood = target
            previousSky = target.sky
            settle(on: target)
            return
        }
        let dt = min(0.1, now - last)
        guard dt > 0 else { return }
        self.last = now
        steps += 1

        if target.sky != mood.sky { strike(1) } else if target.strikes, !mood.strikes { strike(0.6) }
        let oldSky = mood.sky
        mood = target
        if frontStrength > 0, front == 0 { previousSky = oldSky }
        front += dt * 1400
        if front > 2400 { frontStrength = 0 }

        if phase != lastPhase {
            lastPhase = phase
            idle = 0
            if startle < 0.3 { blinkLeft = 0.16 } // a change of state gets a blink, unless it's jumped
        }
        idle = phase == .ready ? idle + dt : 0
        if !reduceMotion { clock += dt }
        startle *= exp(-dt * 3.2)
        if startle < 0.01 { startle = 0 }

        var you = 0.0, reply = 0.0
        switch phase {
        case .listening, .hearing: you = muted ? 0 : Self.shaped(levels.mic)
        case .speaking: reply = Self.shaped(levels.speaker)
        default: break
        }
        let peak = max(you, reply)
        level += (peak - level) * (1 - exp(-dt * (peak > level ? 18 : 5)))
        cutting.you += (you - cutting.you) * (1 - exp(-dt * 12))
        cutting.reply += (reply - cutting.reply) * (1 - exp(-dt * 12))
        writeRings(dt: dt)

        stepLips(reply: reply, bands: phase == .speaking ? levels.speakerBands : .zero, dt: dt)
        stepEyes(dt: dt)
        stepExpression(you: you, reply: reply, dt: dt)
    }

    /// Below the room's noise floor is silence; above it, the voice takes the whole range.
    private static func shaped(_ value: Float) -> Double {
        min(1, max(0, (Double(value) - 0.18) / 0.72))
    }

    private func settle(on mood: Mood) {
        jaw = mood.mouth
        wide = mood.mouthWide
        eye = mood.eye
        smile = mood.smile
        browLeft = mood.brow
        browRight = mood.brow
        browTilt = mood.browTilt
        thought = mood.thought
        cloudLight = mood.cloudLight
    }

    /// Lips come from the voice itself: loudness opens the jaw, the balance of low to middle
    /// frequencies rounds or stretches them, and a hiss brings the teeth together.
    private func stepLips(reply: Double, bands: SIMD3<Float>, dt: Double) {
        let low = Double(bands.x), mid = Double(bands.y), high = Double(bands.z)
        let total = low + mid + high
        var jawTarget = mood.mouth, wideTarget = mood.mouthWide, teethTarget = 0.0
        if reply > 0.02, total > 1e-5 {
            let hiss = high / total
            let closing = min(1, max(0, (hiss - 0.3) / 0.25))
            // Loudness is on a compressed scale, so spread it out or the mouth never shuts between sounds.
            jawTarget = max(mood.mouth, pow(reply, 2.2)) * (1 - 0.65 * closing)
            // Compared with this voice's own average, so any voice gets the full range of shapes.
            let roundness = low / max(low + mid, 1e-5)
            slowRoundness += (roundness - slowRoundness) * (1 - exp(-dt * 0.6))
            wideTarget = min(1, max(-1, (slowRoundness - roundness) * 7))
            teethTarget = closing
        }
        jawTarget *= 1 - startle
        jaw += (jawTarget - jaw) * (1 - exp(-dt * (jawTarget > jaw ? 34 : 20)))
        wide += (wideTarget - wide) * (1 - exp(-dt * 11))
        teeth += (teethTarget - teeth) * (1 - exp(-dt * 26))
        breath += (reply - breath) * (1 - exp(-dt * (reply > breath ? 10 : 2.5)))
    }

    private func stepEyes(dt: Double) {
        nextBlink -= dt
        if nextBlink <= 0 {
            blinkLeft = 0.16
            nextBlink = Double.random(in: 4...11)
        }
        blinkLeft = max(0, blinkLeft - dt)
        let blink = blinkLeft > 0 ? abs(blinkLeft / 0.08 - 1) : 1
        doze = min(1, max(0, (idle - Self.dozeAfter) / (Self.asleepAfter - 1 - Self.dozeAfter)))
        let open = (mood.eye + startle * 0.35) * blink * (1 - doze)
        eye += (open - eye) * (1 - exp(-dt * 30))

        nextGlance -= dt
        if nextGlance <= 0 {
            glance = SIMD2(Double.random(in: -0.55...0.55), Double.random(in: -0.3...0.3))
            nextGlance = Double.random(in: 1.2...3.6)
        }
        pointerAge += dt
        let following = max(0, min(1, 20 - pointerAge)) * mood.followsPointer
        let gazeTarget = mood.gaze ?? (glance * (1 - following) + pointer * following)
        gaze += (gazeTarget - gaze) * (1 - exp(-dt * 3.5)) // slowly, like it isn't in a hurry
    }

    private func stepExpression(you: Double, reply: Double, dt: Double) {
        // A jump in the voice is an emphasis: the brows go up with it.
        slowLevel += (reply - slowLevel) * (1 - exp(-dt * 3))
        if reply - slowLevel > 0.22 { emphasis = 1 }
        emphasis *= exp(-dt * 5)

        let settle = 1 - exp(-dt * 7)
        let lift = mood.brow + emphasis * 0.55 + you * 0.45 + startle
        browLeft += (lift - browLeft) * settle
        browRight += (lift + mood.browAsymmetry - browRight) * settle
        browTilt += (mood.browTilt - browTilt) * settle
        smile += (mood.smile * (1 - startle) - smile) * settle
        thought += (mood.thought - thought) * (1 - exp(-dt * 3))
        cloudLight += (mood.cloudLight - cloudLight) * settle

        if reduceMotion {
            tilt = 0
            bob = 0
        } else {
            tilt += (mood.tilt + sin(clock * 0.31) * 0.012 + sin(clock * 1.4) * 0.012 * reply - tilt) * settle
            bob = sin(clock * 0.5) * 3 - level * 3
        }
    }

    private func strike(_ strength: Double) {
        front = 0
        frontStrength = reduceMotion ? 0 : strength
        if reduceMotion { front = 10_000 }
    }

    // MARK: Sound in the sky

    private func writeRings(dt: Double) {
        ringDue += dt * Self.ringRate
        while ringDue >= 1 {
            ringDue -= 1
            ringHead = (ringHead + 1) % Self.ringSamples
            rings[ringHead * 2] = UInt8(cutting.you * 255)
            rings[ringHead * 2 + 1] = UInt8(cutting.reply * 255)
        }
    }

    /// Two bytes a moment, newest first: how loud you were and how loud the reply was.
    func fillRings(_ buffer: UnsafeMutableRawBufferPointer) {
        for i in 0..<Self.ringSamples {
            let index = (ringHead - i + Self.ringSamples) % Self.ringSamples
            buffer[i * 2] = reduceMotion ? 0 : rings[index * 2]
            buffer[i * 2 + 1] = reduceMotion ? 0 : rings[index * 2 + 1]
        }
    }

    // MARK: From outside

    /// The pointer relative to the face, about -1…1 on each axis. The eyes follow it.
    func look(at pointer: SIMD2<Double>) {
        if pointer != self.pointer { pointerAge = 0 }
        self.pointer = pointer
    }

    /// Someone's here: stay awake.
    func poke() { idle = 0 }

    /// Cutting into a reply makes it lurch.
    func sync(lines: [VoiceSession.Line]) {
        let interrupted = lines.suffix(2).last(where: \.interrupted)
        if lines.first?.id != firstLineID {
            firstLineID = lines.first?.id
            lastInterruptedID = lines.last(where: \.interrupted)?.id
            return
        }
        if let interrupted, interrupted.id != lastInterruptedID {
            lastInterruptedID = interrupted.id
            startle = reduceMotion ? 0 : 1
            strike(2.4)
            previousSky = mood.sky
        }
    }
}
