import AVFoundation
import Foundation

/// `SpeakToMe --selftest [model]` runs the whole pipeline without a microphone:
/// Kokoro speaks a question → Parakeet transcribes it → oMLX answers → Kokoro speaks
/// the first sentence. Prints the time each stage takes, then exits.
enum SelfTest {
    static func run(model requested: String?) async {
        @Sendable func log(_ s: String) { print(s); fflush(stdout) }
        do {
            let client = OMLXClient.fromSettings()
            let models = try await client.chatModels()
            guard let model = requested ?? models.first(where: { $0.id.contains("gemma-4-26b-a4b") })?.id ?? models.first?.id
            else { log("No chat models in oMLX"); exit(1) }
            log("oMLX: \(client.baseURL.absoluteString), model: \(model)")

            var clock = Date()
            func lap() -> Int { defer { clock = Date() }; return Int(Date().timeIntervalSince(clock) * 1000) }

            let warm = Task { try await client.warmUp(model: model) }
            let speech = try await SpeechModels.load(voice: "af_heart") { log("  \($0)") }
            log("speech models ready: \(lap()) ms")
            try await warm.value
            log("LLM loaded: \(lap()) ms")

            let question = "What is the tallest mountain in Europe, and how high is it?"
            let spoken24k = try await speech.speak(question, voice: "am_adam", speed: 1)
            let spoken16k = resample(spoken24k, from: 24_000, to: 16_000)
            log("synthesized test question (\(spoken16k.count / 16) ms of audio): \(lap()) ms")

            // From here on is what you feel after you stop talking.
            let text = try await speech.transcribe(spoken16k)
            let stt = lap()
            log("STT  \(stt) ms  → \"\(text)\"")

            var chunker = SentenceChunker()
            var first: String?
            var reply = ""
            var ttft = 0
            for try await token in client.streamChat(
                model: model,
                messages: [.init(role: "system", content: await VoiceSession.defaultPrompt), .init(role: "user", content: text)])
            {
                if reply.isEmpty { ttft = lap() }
                reply += token
                if first == nil, let s = chunker.push(token).first { first = s; break }
            }
            let firstSentenceMs = ttft + lap()
            log("LLM  first token \(ttft) ms, first sentence \(firstSentenceMs) ms → \"\(first ?? reply)\"")

            let audio = try await speech.speak(first ?? reply, voice: "af_heart", speed: 1.05)
            let tts = lap()
            log("TTS  \(tts) ms → \(audio.count / 24) ms of audio")
            log("TOTAL end-of-speech → first audio ≈ \(stt + firstSentenceMs + tts) ms (+ \(UserDefaults.standard.integer(forKey: "endOfTurnMs") == 0 ? 600 : UserDefaults.standard.integer(forKey: "endOfTurnMs")) ms silence wait)")
            exit(0)
        } catch {
            log("SELFTEST FAILED: \(error)")
            exit(1)
        }
    }

    private static func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        let inFormat = AVAudioFormat(standardFormatWithSampleRate: from, channels: 1)!
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: to, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let output = AVAudioPCMBuffer(
            pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(samples.count) * to / from) + 64)!
        let converter = AVAudioConverter(from: inFormat, to: outFormat)!
        var done = false
        converter.convert(to: output, error: nil) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
