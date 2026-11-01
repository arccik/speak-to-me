import Foundation

/// The record's state: everything that was said, as a spiral of audio levels, and how the
/// disc is moving right now. Shared by the main window and the floating record, and stepped
/// once a frame from whichever is drawing.
final class LatheEngine {
    static var shared = LatheEngine()

    static let samplesPerTurn = 256
    static let windowSamples = 16_384 // the 64 turns the shader can see

    /// Two bytes a sample: how far the groove swings, and whose it is (0 you, 255 the reply).
    /// The swing leans a little on the turn before it, so neighbouring grooves nest instead of
    /// crossing, and waves ease out instead of ending in a stub. Mostly it's the voice right now.
    private var log: [UInt8] = []
    private var owner: UInt8 = 0
    private var position = 0.0 // in samples
    /// Your level and the reply's, waiting to be cut for words that had no audio (typed).
    private var pending: [UInt8] = []
    private var marks: [(turn: Double, id: UUID)] = []
    private var firstLineID: UUID?
    private var lineCount = 0
    private var lastInterruptedID: UUID?
    private var heardSinceMark = false

    private(set) var mood = Mood.of(.ready, muted: false)
    private(set) var previousVinyl = Mood.of(.ready, muted: false).vinyl
    private(set) var previousLabel = Mood.of(.ready, muted: false).label
    private(set) var level = 0.0
    private(set) var clock = 0.0
    private(set) var arm = 0.0
    private(set) var lift = 0.0
    private(set) var cutting = (you: 0.0, reply: 0.0)
    /// The wavefront crossing the disc, in points from the centre, and how hard it hits.
    private(set) var front = 10_000.0
    private(set) var frontStrength = 0.0
    private var speed = 0.0
    private var last: Double?

    /// Turns dragged back from the newest groove.
    private(set) var scrub = 0.0
    var isScrubbing = false
    var reduceMotion = false

    var turn: Double { position / Double(Self.samplesPerTurn) }
    var viewTurn: Double {
        let exact = turn - scrub
        // Reduce Motion: the disc holds still, and the grooves step out once a turn.
        return reduceMotion ? exact.rounded(.down) : exact
    }

    // MARK: Stepping

    func step(phase: VoiceSession.Phase, muted: Bool, levels: AudioLevels, now: Double) {
        let target = Mood.of(phase, muted: muted)
        guard let last else {
            self.last = now
            mood = target
            previousVinyl = target.vinyl
            previousLabel = target.label
            return
        }
        let dt = min(0.1, now - last)
        guard dt > 0 else { return }
        self.last = now

        if target.vinyl != mood.vinyl || target.label != mood.label { strike(1) }
        else if target.strikes, !mood.strikes { strike(0.6) }
        let oldVinyl = mood.vinyl, oldLabel = mood.label
        mood = target
        if frontStrength > 0, front == 0 {
            previousVinyl = oldVinyl
            previousLabel = oldLabel
        }
        front += dt * 1400
        if front > 2400 { frontStrength = 0 }

        let spin = pending.isEmpty ? mood.speed : max(mood.speed, 0.25)
        speed += (spin - speed) * (1 - exp(-dt * 2.2))
        arm += (mood.arm - arm) * (1 - exp(-dt * 6))
        lift += (mood.armLift - lift) * (1 - exp(-dt * 6))
        if !reduceMotion { clock += dt }

        var you = 0.0, reply = 0.0
        switch phase {
        case .listening, .hearing: you = muted ? 0 : Self.shaped(levels.mic)
        case .speaking: reply = Self.shaped(levels.speaker)
        default: break
        }
        if you > 0.05 { heardSinceMark = true }
        let peak = max(you, reply)
        // Fast attack, slow release, like a VU meter.
        level += (peak - level) * (1 - exp(-dt * (peak > level ? 18 : 5)))
        cutting.you += (you - cutting.you) * (1 - exp(-dt * 7))
        cutting.reply += (reply - cutting.reply) * (1 - exp(-dt * 7))

        let move = dt * speed * Double(Self.samplesPerTurn)
        write(upTo: position + move)

        if !isScrubbing, scrub != 0 {
            scrub *= exp(-dt * 5)
            if scrub < 0.002 { scrub = 0 }
        }
    }

    /// Below the room's noise floor is silence; above it, the voice takes the whole range.
    private static func shaped(_ value: Float) -> Double {
        min(1, max(0, (Double(value) - 0.18) / 0.72))
    }

    private func strike(_ strength: Double) {
        front = 0
        frontStrength = reduceMotion ? 0 : strength
        if reduceMotion { front = 10_000 }
    }

    private func write(upTo target: Double) {
        position = target
        while log.count / 2 < Int(position) {
            if pending.count >= 2 {
                cut(you: pending.removeFirst(), reply: pending.removeFirst())
            } else {
                cut(you: UInt8(cutting.you * 255), reply: UInt8(cutting.reply * 255))
            }
        }
    }

    private func cut(you: UInt8, reply: UInt8) {
        let previousTurn = log.count - Self.samplesPerTurn * 2
        let before = previousTurn >= 0 ? Int(log[previousTurn]) : Int(max(you, reply))
        log.append(UInt8((Int(max(you, reply)) * 7 + before * 3) / 10))
        if max(you, reply) > 8 { owner = reply > you ? 255 : 0 }
        log.append(owner)
    }

    // MARK: The conversation

    /// Keeps the record in step with the conversation: a different conversation gets
    /// pressed fresh, new lines get marked at the groove being cut.
    func sync(lines: [VoiceSession.Line]) {
        if lines.first?.id != firstLineID || lines.count < lineCount {
            press(lines)
        } else if lines.count > lineCount {
            for line in lines[lineCount...] {
                if line.role == "user", !heardSinceMark {
                    pending += Self.rhythm(of: line.text, you: true)
                }
                marks.append((turn, line.id))
                heardSinceMark = false
            }
            lineCount = lines.count
        }
        if let interrupted = lines.suffix(2).last(where: \.interrupted), interrupted.id != lastInterruptedID {
            if lastInterruptedID != nil || lineCount > 0, interrupted.id == lines.last?.id || lines.last?.role == "user" {
                strike(2.4)
                previousVinyl = mood.vinyl
                previousLabel = mood.label
            }
            lastInterruptedID = interrupted.id
        }
    }

    /// A saved conversation has no audio any more, so its grooves come from the rhythm of its words.
    private func press(_ lines: [VoiceSession.Line]) {
        log.removeAll()
        pending.removeAll()
        marks.removeAll()
        for line in lines where line.role != "error" {
            marks.append((Double(log.count / 2) / Double(Self.samplesPerTurn), line.id))
            let rhythm = Self.rhythm(of: line.text, you: line.role == "user")
            for i in stride(from: 0, to: rhythm.count, by: 2) { cut(you: rhythm[i], reply: rhythm[i + 1]) }
            for _ in 0..<(Self.samplesPerTurn / 4) { cut(you: 0, reply: 0) }
        }
        position = Double(log.count / 2)
        firstLineID = lines.first?.id
        lineCount = lines.count
        lastInterruptedID = lines.last(where: \.interrupted)?.id
        scrub = 0
    }

    private static func rhythm(of text: String, you: Bool) -> [UInt8] {
        var out: [UInt8] = []
        var seed: UInt32 = 2_166_136_261
        for word in text.split(whereSeparator: \.isWhitespace) {
            for scalar in word.unicodeScalars { seed = (seed ^ scalar.value) &* 16_777_619 }
            let peak = 0.3 + Double(seed % 70) / 100
            let length = max(6, word.count * 7)
            for i in 0..<length {
                let value = UInt8(peak * sin(Double(i) / Double(length) * .pi) * 255)
                out += you ? [value, 0] : [0, value]
            }
            out += [UInt8](repeating: 0, count: 10)
        }
        return out
    }

    // MARK: Scratching

    /// Dragging around the disc: backwards goes back through what was said.
    func scratch(byTurns delta: Double) {
        scrub = min(max(turn, 1.5), max(0, scrub + delta))
    }

    /// The line that was being cut at the groove now under the head.
    var lineAtHead: UUID? {
        guard scrub > 0.05 else { return nil }
        return marks.last(where: { $0.turn <= turn - scrub })?.id ?? marks.first?.id
    }

    /// The window of grooves the shader can see, newest last.
    func fill(_ buffer: UnsafeMutableRawBufferPointer) -> Double {
        let view = max(0, viewTurn) * Double(Self.samplesPerTurn)
        let end = Int(view)
        let count = Self.windowSamples * 2
        let start = (end - Self.windowSamples) * 2
        log.withUnsafeBytes { source in
            for i in stride(from: 0, to: count, by: 1) {
                let index = start + i
                buffer[i] = index >= 0 && index < source.count ? source[index] : 0
            }
        }
        return (view - Double(end)) / Double(Self.samplesPerTurn)
    }
}
