import AVFoundation
import FluidAudio
import Foundation
import SwiftUI

/// The conversation loop:
/// mic → VAD → (you stop talking) → Parakeet → oMLX stream → sentence chunks → Kokoro → speaker.
/// If you start talking while the assistant is thinking or speaking, it stops (barge-in).
@MainActor
final class VoiceSession: ObservableObject {
    enum Phase: Equatable {
        case loading(String)
        case ready
        case listening
        case hearing
        case transcribing
        case thinking
        case speaking
        case failed(String)
    }

    struct Line: Identifiable {
        let id = UUID()
        let role: String
        var text: String
        var interrupted = false
    }

    @Published var phase: Phase = .loading("Starting…")
    @Published var lines: [Line] = []
    @Published var models: [OMLXClient.Model] = []
    @Published var micLevel: Float = 0
    @Published var lastLatencyMs: Int?
    /// Mic problems are shown here instead of `.failed`, so Start stays usable for a retry.
    @Published var micNotice: String?

    @AppStorage("model") var modelID = ""
    @AppStorage("voice") var voice = "af_heart"
    @AppStorage("speed") var speed = 1.05
    @AppStorage("endOfTurnMs") var endOfTurnMs = 600
    @AppStorage("systemPrompt") var systemPrompt = VoiceSession.defaultPrompt

    static let defaultPrompt = """
        You are a friendly, quick-witted voice assistant having a spoken conversation. \
        Answer in one to three short, natural sentences unless asked for more detail. \
        Never use markdown, lists, headings, code blocks or emoji: everything you write is read aloud.
        """

    static let voices = [
        "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky", "af_nova",
        "am_adam", "am_michael", "am_eric", "am_liam", "am_onyx",
        "bf_emma", "bf_isabella", "bm_george", "bm_lewis", "bm_daniel",
    ]

    var isActive: Bool {
        switch phase {
        case .listening, .hearing, .transcribing, .thinking, .speaking: return true
        default: return false
        }
    }

    private let client = OMLXClient.fromSettings()
    private let audio = AudioIO()
    private var speech: SpeechModels?
    private var listenerTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var micStream: AsyncStream<[Float]>.Continuation?
    private var history: [OMLXClient.Message] = []

    // MARK: - Setup

    func boot() async {
        do {
            phase = .loading("Connecting to oMLX…")
            models = try await client.chatModels()
            if !models.contains(where: { $0.id == modelID }) {
                modelID = Self.pickDefault(models)?.id ?? ""
            }
        } catch {
            phase = .failed("Can't reach oMLX at \(client.baseURL.absoluteString). Is the oMLX app running?\n\(error.localizedDescription)")
            return
        }
        do {
            let warm = Task { [client, modelID] in try? await client.warmUp(model: modelID) }
            speech = try await SpeechModels.load(voice: voice) { message in
                Task { @MainActor in self.phase = .loading(message) }
            }
            phase = .loading("Loading \(modelID) in oMLX…")
            await warm.value
            phase = .ready
        } catch {
            phase = .failed("Couldn't load the speech models: \(error.localizedDescription)")
        }
    }

    /// Prefer a fast mixture-of-experts or small model; big dense models make replies laggy.
    private static func pickDefault(_ models: [OMLXClient.Model]) -> OMLXClient.Model? {
        let preferred = ["gemma-4-26b-a4b", "a3b", "a4b", "9b", "8b", "4b", "12b"]
        for hint in preferred {
            if let match = models.first(where: { $0.id.lowercased().contains(hint) }) { return match }
        }
        return models.min { $0.sizeBytes < $1.sizeBytes }
    }

    func modelChanged() {
        let client = client, modelID = modelID
        Task { try? await client.warmUp(model: modelID) }
    }

    // MARK: - Conversation on/off

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard speech != nil else { return }
        micNotice = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startListening()
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .audio) {
                    startListening()
                } else {
                    micNotice = Self.deniedNotice
                }
            }
        default:
            micNotice = Self.deniedNotice
        }
    }

    static let deniedNotice =
        "Microphone access is off. Turn on Speak to Me in System Settings → Privacy & Security → Microphone, then press Start."

    private func startListening() {
        guard let speech else { return }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(200))
        micStream = continuation
        audio.onMicSamples = { continuation.yield($0) }
        audio.onPlaybackDrained = { [weak self] in
            Task { @MainActor in self?.playbackDrained() }
        }
        do {
            try audio.start()
        } catch {
            micStream?.finish()
            micNotice = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        phase = .listening
        listenerTask = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.listen(stream: stream, vad: speech.vad, session: self)
        }
    }

    func stop() {
        turnTask?.cancel()
        listenerTask?.cancel()
        micStream?.finish()
        audio.stop()
        phase = .ready
        micLevel = 0
    }

    func clearConversation() {
        turnTask?.cancel()
        audio.stopPlayback()
        lines.removeAll()
        history.removeAll()
        if isActive { phase = .listening }
    }

    // MARK: - Listening (runs off the main thread)

    /// Silero works on 256 ms chunks. We keep a little audio from before speech
    /// starts so the first syllable isn't clipped.
    private nonisolated static func listen(stream: AsyncStream<[Float]>, vad: VadManager, session: VoiceSession?) async {
        let chunkSize = VadManager.chunkSize
        let chunkMs = 256
        var pending: [Float] = []
        var preRoll: [[Float]] = []
        var utterance: [Float] = []
        var inSpeech = false
        var speechChunks = 0
        var silenceMs = 0
        var vadState = VadStreamState.initial()

        for await samples in stream {
            pending += samples
            while pending.count >= chunkSize {
                if Task.isCancelled { return }
                let chunk = Array(pending.prefix(chunkSize))
                pending.removeFirst(chunkSize)

                // We only use the speech probability; our own turn-taking logic sits below.
                guard let result = try? await vad.processStreamingChunk(chunk, state: vadState) else { continue }
                vadState = result.state
                let probability = result.probability
                let level = min(1, sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)) * 8)
                let (assistantBusy, endMs) = await MainActor.run { () -> (Bool, Int) in
                    session?.micLevel = level
                    return (session?.assistantBusy ?? false, session?.endOfTurnMs ?? 600)
                }

                if !inSpeech {
                    preRoll.append(chunk)
                    if preRoll.count > 2 { preRoll.removeFirst() }
                    // While the assistant talks, require more evidence so echo residue can't interrupt it.
                    let needed = assistantBusy ? 2 : 1
                    speechChunks = probability > (assistantBusy ? 0.7 : 0.5) ? speechChunks + 1 : 0
                    if speechChunks >= needed {
                        inSpeech = true
                        silenceMs = 0
                        utterance = preRoll.flatMap { $0 }
                        preRoll.removeAll()
                        await session?.userStartedSpeaking()
                    }
                } else {
                    utterance += chunk
                    silenceMs = probability < 0.35 ? silenceMs + chunkMs : 0
                    if silenceMs >= endMs {
                        inSpeech = false
                        speechChunks = 0
                        let audio = utterance
                        utterance = []
                        await session?.userFinished(audio, endedAt: Date())
                    }
                }
            }
        }
    }

    private var assistantBusy: Bool {
        phase == .thinking || phase == .speaking || phase == .transcribing
    }

    private func userStartedSpeaking() {
        if assistantBusy || audio.isPlaying { interrupt() }
        phase = .hearing
    }

    private func interrupt() {
        turnTask?.cancel()
        turnTask = nil
        audio.stopPlayback()
        if let last = lines.indices.last, lines[last].role == "assistant" {
            lines[last].interrupted = true
        }
    }

    // MARK: - A turn

    private func userFinished(_ samples: [Float], endedAt: Date) {
        guard let speech else { return }
        // Ignore coughs and clicks shorter than ~0.4 s.
        guard samples.count > 6_400 else { phase = .listening; return }
        phase = .transcribing
        turnTask = Task {
            do {
                let text = try await speech.transcribe(samples)
                try Task.checkCancellation()
                guard text.count > 1 else { phase = .listening; return }
                lines.append(Line(role: "user", text: text))
                history.append(.init(role: "user", content: text))
                try await respond(speech: speech, startedAt: endedAt)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    lines.append(Line(role: "error", text: error.localizedDescription))
                    phase = .listening
                }
            }
        }
    }

    private func respond(speech: SpeechModels, startedAt: Date) async throws {
        phase = .thinking
        let messages = [OMLXClient.Message(role: "system", content: systemPrompt)] + history.suffix(20)
        lines.append(Line(role: "assistant", text: ""))
        let lineIndex = lines.count - 1

        // Sentences flow from the LLM stream into the TTS loop, which runs concurrently.
        let (sentences, sentenceSink) = AsyncStream<String>.makeStream()
        speakingTurn = true
        defer { speakingTurn = false }
        let voice = voice, speed = Float(speed)
        let ttsTask = Task {
            var first = true
            for await sentence in sentences {
                if Task.isCancelled { return }
                guard let samples = try? await speech.speak(sentence, voice: voice, speed: speed),
                      !Task.isCancelled
                else { continue }
                if first {
                    first = false
                    lastLatencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                }
                phase = .speaking
                audio.play(samples)
            }
        }

        var reply = ""
        var chunker = SentenceChunker()
        do {
            for try await token in client.streamChat(model: modelID, messages: messages) {
                try Task.checkCancellation()
                reply += token
                if lines.indices.contains(lineIndex) { lines[lineIndex].text = SentenceChunker.visible(reply) }
                for sentence in chunker.push(token) { sentenceSink.yield(sentence) }
            }
            for sentence in chunker.finish() { sentenceSink.yield(sentence) }
            sentenceSink.finish()
            await withTaskCancellationHandler {
                await ttsTask.value
            } onCancel: {
                ttsTask.cancel()
            }
        } catch {
            sentenceSink.finish()
            ttsTask.cancel()
            history.append(.init(role: "assistant", content: SentenceChunker.visible(reply)))
            throw error
        }
        history.append(.init(role: "assistant", content: SentenceChunker.visible(reply)))
        if !audio.isPlaying, phase == .thinking || phase == .speaking { phase = .listening }
    }

    /// True while a reply is still being generated or synthesized, so a short gap
    /// between two sentences doesn't count as "done speaking".
    private var speakingTurn = false

    private func playbackDrained() {
        if phase == .speaking, !speakingTurn { phase = .listening }
    }
}

extension SentenceChunker {
    /// The reply as shown on screen: thinking removed, otherwise untouched.
    static func visible(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"<think>[\s\S]*?(</think>|$)"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }
}
