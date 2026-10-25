import AVFoundation
import NaturalLanguage

enum LanguageDetector {
    /// ISO code ("en", "pl", "ru", …) of `text`, or nil when it's too short to tell.
    static func detect(_ text: String) -> String? {
        guard text.split(separator: " ").count >= 3 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence > 0.6
        else { return nil }
        return language.rawValue
    }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

/// macOS's built-in voices, used for every language Kokoro can't speak. Offline and
/// instant; download "Premium" voices in System Settings → Accessibility → Spoken
/// Content for the best quality.
enum SystemVoice {
    static func hasVoice(for language: String) -> Bool {
        bestVoice(for: language) != nil
    }

    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    /// Renders `text` to 24 kHz mono samples (the app's playback format).
    static func speak(_ text: String, language: String, speed: Float) async -> [Float] {
        guard let voice = bestVoice(for: language) else { return [] }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * min(1.3, max(0.8, speed))
        let synthesizer = AVSpeechSynthesizer()
        let target = AVFormat.speaker

        return await withCheckedContinuation { continuation in
            var samples: [Float] = []
            var converter: AVAudioConverter?
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard !finished, let pcm = buffer as? AVAudioPCMBuffer else { return }
                // A zero-length buffer marks the end.
                guard pcm.frameLength > 0 else {
                    finished = true
                    _ = synthesizer // keep it alive until done
                    continuation.resume(returning: samples)
                    return
                }
                if converter == nil { converter = AVAudioConverter(from: pcm.format, to: target) }
                guard let converter,
                      let out = AVAudioPCMBuffer(
                        pcmFormat: target,
                        frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * target.sampleRate / pcm.format.sampleRate) + 64)
                else { return }
                var consumed = false
                converter.convert(to: out, error: nil) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    consumed = true
                    status.pointee = .haveData
                    return pcm
                }
                if let data = out.floatChannelData?[0] {
                    samples += UnsafeBufferPointer(start: data, count: Int(out.frameLength))
                }
            }
        }
    }
}

enum AVFormat {
    static let speaker = AVAudioFormat(standardFormatWithSampleRate: AudioIO.speakerSampleRate, channels: 1)!
}
