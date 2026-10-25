import FluidAudio
import Foundation

/// The on-device speech models, all running through Core ML (mostly on the Neural
/// Engine) so the GPU stays free for the language model in oMLX.
///
/// - Silero VAD: detects when you start and stop talking.
/// - Parakeet TDT v3: speech-to-text, 25 languages.
/// - Kokoro 82M (ANE v3 pipeline): text-to-speech, in a crash-isolated helper process.
final class SpeechModels {
    let vad: VadManager
    let asr: AsrManager
    let tts: TTSWorker

    private init(vad: VadManager, asr: AsrManager, tts: TTSWorker) {
        self.vad = vad
        self.asr = asr
        self.tts = tts
    }

    /// Our own model folder. FluidVoice's Core ML copies are an older build that
    /// current FluidAudio rejects, so we keep a separate set and never touch theirs.
    static let appRoot: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SpeakToMe", isDirectory: true)
    static var modelsRoot: URL { appRoot.appendingPathComponent("Models", isDirectory: true) }

    static func load(voice: String, progress: @escaping @Sendable (String) -> Void) async throws -> SpeechModels {
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        // The voice loads in its own process, in parallel with everything below.
        let tts = TTSWorker(voice: voice)
        let ttsReady = Task { try await tts.start(progress: progress) }

        progress("Loading voice detection…")
        let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5), modelDirectory: appRoot)

        progress("Loading speech recognition…")
        let asrModels = try await AsrModels.downloadAndLoad(
            to: modelsRoot.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true),
            version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(asrModels)

        progress("Warming up…")
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        _ = try? await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)

        try await ttsReady.value
        return SpeechModels(vad: vad, asr: asr, tts: tts)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// English goes to Kokoro; other languages to a macOS system voice when one exists.
    /// A cloned voice (PocketTTS, English only) replaces Kokoro when given.
    func speak(_ text: String, voice: String, speed: Float, language: String = "en", clonedVoice: String? = nil) async throws -> [Float] {
        if language != "en", SystemVoice.hasVoice(for: language) {
            return await SystemVoice.speak(text, language: language, speed: speed)
        }
        return try await tts.speak(text, voice: voice, speed: speed, clonedVoice: clonedVoice)
    }
}
