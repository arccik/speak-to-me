import FluidAudio
import Foundation

/// The on-device speech models, all running through Core ML (mostly on the Neural
/// Engine) so the GPU stays free for the language model in oMLX.
///
/// - Silero VAD: detects when you start and stop talking.
/// - Parakeet TDT v3: speech-to-text, 25 languages.
/// - Kokoro 82M (ANE v3 pipeline): English text-to-speech, in a crash-isolated helper process.
/// - Supertonic-3: text-to-speech for 30 other languages, loaded only when needed.
/// - F5-TTS Russian: the exception, on the GPU through MLX, in a helper process of its own.
///
/// Which model speaks which language is the user's choice: see `SpeechEngine`.
final class SpeechModels {
    let vad: VadManager
    let asr: AsrManager
    let tts: TTSWorker
    let multilingual: MultilingualVoices
    let f5Russian: F5RussianVoice

    private init(vad: VadManager, asr: AsrManager, tts: TTSWorker) {
        self.vad = vad
        self.asr = asr
        self.tts = tts
        let multilingual = MultilingualVoices()
        self.multilingual = multilingual
        f5Russian = F5RussianVoice(multilingual: multilingual)
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

    /// Downloads and loads `engine`, so it's ready by the time a reply needs it.
    /// `progress` runs from 0 to 1 for a model that reports its download.
    func prepare(
        _ engine: SpeechEngine, using setup: SpeechSetup, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        switch engine {
        case .kokoro, .macOS: return
        case .f5Russian: try await f5Russian.prepare(voice: setup.languageVoice, progress: progress)
        case .myVoice: try await tts.prepareMyVoice()
        case .supertonic: try await multilingual.prepare(voice: setup.languageVoice)
        }
    }

    /// Speaks `text`, performing any SSML in it (see `SSML`).
    func speak(_ text: String, language: String = "en", using setup: SpeechSetup) async throws -> [Float] {
        guard SSML.hasMarkup(text) else { return try await speakWords(text, language: language, using: setup) }
        guard setup.expressive else { return try await speakWords(SSML.plain(text), language: language, using: setup) }
        var out: [Float] = []
        for segment in SSML.segments(of: text) {
            switch segment {
            case .pause(let seconds):
                out += [Float](repeating: 0, count: Int(seconds * 24_000))
            case .words(let words, let rate):
                var adjusted = setup
                adjusted.speed = setup.speed * rate
                out += try await speakWords(words, language: language, using: adjusted)
            }
        }
        return out
    }

    /// Speaks with the model chosen for `language`, or the next that can (see `SpeechSetup.route`).
    private func speakWords(_ text: String, language: String, using setup: SpeechSetup) async throws -> [Float] {
        var failure: Error?
        for engine in setup.route(for: language) {
            do {
                if let samples = try await synthesize(text, with: engine, language: language, setup: setup),
                   !samples.isEmpty {
                    return samples
                }
            } catch {
                failure = error
            }
        }
        throw failure ?? WorkerProcess.WorkerError.failed("No voice can speak this")
    }

    /// nil when `engine` can't speak `language` (or has no voice to speak with).
    func synthesize(_ text: String, with engine: SpeechEngine, language: String, setup: SpeechSetup) async throws -> [Float]? {
        switch engine {
        case .kokoro:
            return try await tts.speak(text, voice: setup.voice, speed: setup.speed)
        case .myVoice:
            guard let clonedVoice = setup.clonedVoice else { return nil }
            return try await tts.speak(text, voice: setup.voice, speed: setup.speed, clonedVoice: clonedVoice)
        case .supertonic:
            guard MultilingualVoices.languages.contains(language) else { return nil }
            return try await multilingual.speak(text, language: language, voice: setup.languageVoice, speed: setup.speed)
        case .f5Russian:
            // Mid-download, the next model says it rather than leaving the reply hanging.
            guard language == "ru", engine.isInstalled else { return nil }
            return try await f5Russian.speak(
                text, voice: setup.languageVoice, cloned: setup.f5Voice, speed: setup.speed, steps: setup.f5Steps,
                marksStress: setup.f5MarksStress, pronunciations: setup.f5Pronunciations)
        case .macOS:
            guard SystemVoice.hasVoice(for: language) else { return nil }
            return await SystemVoice.speak(text, language: language, speed: setup.speed)
        }
    }
}
