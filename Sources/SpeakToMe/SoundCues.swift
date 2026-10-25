import AVFoundation

/// Short, soft tones generated on the fly (no sound files): a rising chime when the
/// mic opens, a falling one when it closes, and a low blip on errors.
@MainActor
enum SoundCues {
    enum Cue {
        case start, stop, error

        /// (frequency Hz, start s, duration s) partials.
        var notes: [(Double, Double, Double)] {
            switch self {
            case .start: return [(660, 0, 0.12), (990, 0.08, 0.16)]
            case .stop: return [(880, 0, 0.12), (587, 0.08, 0.16)]
            case .error: return [(330, 0, 0.18), (311, 0.1, 0.2)]
            }
        }
    }

    private static var players: [AVAudioPlayer] = []

    static func play(_ cue: Cue) {
        guard UserDefaults.standard.object(forKey: "soundCues") as? Bool ?? true else { return }
        guard let player = try? AVAudioPlayer(data: wav(for: cue)) else { return }
        player.volume = 0.35
        player.play()
        // Keep a reference until it finishes; drop finished ones.
        players.removeAll { !$0.isPlaying }
        players.append(player)
    }

    private static func wav(for cue: Cue) -> Data {
        let rate = 44_100.0
        let length = cue.notes.map { $0.1 + $0.2 }.max() ?? 0.3
        var samples = [Float](repeating: 0, count: Int(length * rate))
        for (frequency, start, duration) in cue.notes {
            let first = Int(start * rate), count = Int(duration * rate)
            for i in 0..<count where first + i < samples.count {
                let t = Double(i) / rate
                // Soft attack, exponential decay: a gentle "ding" rather than a beep.
                let envelope = min(1, t / 0.008) * exp(-t * 18)
                samples[first + i] += Float(sin(2 * .pi * frequency * t) * envelope * 0.5)
            }
        }
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32_767) }
        data.append(contentsOf: "RIFF".utf8); append(UInt32(36 + pcm.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8); append(UInt32(pcm.count * 2))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
