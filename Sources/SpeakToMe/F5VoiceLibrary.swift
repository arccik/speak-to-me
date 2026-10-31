import AVFoundation
import Foundation

/// A voice F5-TTS can imitate: a short clip and exactly what's said in it.
struct F5ClonedVoice: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var transcript: String

    var clip: URL { F5VoiceLibrary.folder.appendingPathComponent("\(id).wav") }
}

/// The voices you've added for F5-TTS, kept as clips next to a small list.
enum F5VoiceLibrary {
    enum ClipError: LocalizedError {
        case tooQuiet, tooShort

        var errorDescription: String? {
            switch self {
            case .tooQuiet: return "That recording is almost silent. Check the microphone and try again."
            case .tooShort: return "That clip has less than 2 seconds of speech."
            }
        }
    }

    static var folder: URL { SpeechModels.appRoot.appendingPathComponent("F5Voices", isDirectory: true) }
    private static var list: URL { folder.appendingPathComponent("voices.json") }

    /// Every extra second costs time on every sentence, and more than this doesn't sound better.
    private static let longestClip = 8.0
    private static let shortestClip = 2.0

    static func load() -> [F5ClonedVoice] {
        guard let data = try? Data(contentsOf: list) else { return [] }
        return (try? JSONDecoder().decode([F5ClonedVoice].self, from: data)) ?? []
    }

    static func save(_ voices: [F5ClonedVoice]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(voices).write(to: list, options: .atomic)
    }

    /// An audio file of any format as a clip: 24 kHz mono, without the silence around it,
    /// cut at a pause if it's long, and at a good level.
    static func clip(from file: URL) throws -> [Float] {
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.length)) else {
            throw ClipError.tooShort
        }
        try audio.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw ClipError.tooShort }
        var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
        for channel in 0..<Int(format.channelCount) {
            for i in mono.indices { mono[i] += channels[channel][i] / Float(format.channelCount) }
        }
        return try trimmed(Resampler.convert(mono, from: format.sampleRate, to: Double(F5TTS.sampleRate)))
    }

    private static func trimmed(_ samples: [Float]) throws -> [Float] {
        let peak = samples.reduce(0) { max($0, abs($1)) }
        guard peak > 0.005 else { throw ClipError.tooQuiet }

        // Loudness in 20 ms windows, to find the speech and the pauses in it.
        let rate = F5TTS.sampleRate, window = rate / 50
        let levels = stride(from: 0, to: samples.count - window, by: window).map { start in
            samples[start..<start + window].reduce(0) { max($0, abs($1)) }
        }
        guard let first = levels.firstIndex(where: { $0 > peak * 0.05 }),
              let last = levels.lastIndex(where: { $0 > peak * 0.05 })
        else { throw ClipError.tooQuiet }
        var end = min(samples.count, (last + 5) * window)
        let start = max(0, (first - 5) * window)
        if Double(end - start) / Double(rate) > longestClip {
            // The quietest moment in the last few seconds allowed, so no word is cut in half.
            let from = (start + 5 * rate) / window, to = (start + Int(longestClip) * rate) / window
            let pause = (from..<to).min { levels[$0] < levels[$1] } ?? to
            end = (pause + 1) * window
        }
        guard Double(end - start) / Double(rate) >= shortestClip else { throw ClipError.tooShort }
        return samples[start..<end].map { $0 * 0.9 / peak }
    }
}
