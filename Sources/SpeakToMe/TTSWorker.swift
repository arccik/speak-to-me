import AVFoundation
import FluidAudio
import Foundation

/// Kokoro text-to-speech (and PocketTTS cloned voices), run in child processes
/// (this same executable, started with `--tts-worker`).
///
/// Core ML's CPU backend (libBNNS) on macOS 27 crashes inside Kokoro with an
/// uncatchable trap for some inputs. Isolated in its own process, a crash can't take
/// the app down. A second, already-loaded process waits on standby, so recovering
/// costs one sentence's synthesis time rather than a reload.
actor TTSWorker {
    private let voice: String
    private var active: WorkerProcess?
    private var standby: Task<WorkerProcess, Error>?
    private(set) var restarts = 0

    init(voice: String) {
        self.voice = voice
    }

    func start(progress: (@Sendable (String) -> Void)? = nil) async throws {
        let first = WorkerProcess(voice: voice)
        try await first.start(progress: progress)
        active = first
        refillStandby()
    }

    func stop() async {
        await active?.stop()
        standby?.cancel()
        if let spare = try? await standby?.value { await spare.stop() }
    }

    /// Synthesizes `text`. The crash depends on the exact number of phoneme tokens
    /// (it hits at a bucket boundary), so after a crash we retry with one token fewer
    /// (no final punctuation), then one more (an extra period). Both sound the same.
    func speak(_ text: String, voice: String, speed: Float, clonedVoice: String? = nil) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let withoutFinal = trimmed.last.map { ".!?;:,".contains($0) } == true ? String(trimmed.dropLast()) : trimmed + "."
        for variant in [trimmed, withoutFinal, trimmed + "."] {
            try Task.checkCancellation()
            let worker = try await liveWorker()
            try Task.checkCancellation()
            do {
                return try await worker.request(variant, voice: voice, speed: speed, clonedVoice: clonedVoice)
            } catch WorkerProcess.WorkerError.crashed {
                restarts += 1
                if active === worker { active = nil }
            }
        }
        throw WorkerProcess.WorkerError.crashed
    }

    /// Turns a recording of someone's voice into a reusable PocketTTS voice file.
    /// The first call downloads PocketTTS (a few hundred MB).
    func clone(sample: URL, to output: URL) async throws {
        let worker = try await liveWorker()
        _ = try await worker.send(["clone": sample.path, "out": output.path])
    }

    /// Downloads and loads PocketTTS ahead of the first sentence.
    func prepareMyVoice() async throws {
        let worker = try await liveWorker()
        _ = try await worker.send(["prepareClone": true])
    }

    private func liveWorker() async throws -> WorkerProcess {
        if let active { return active }
        let next: WorkerProcess
        if let standby {
            self.standby = nil
            next = try await standby.value
        } else {
            next = WorkerProcess(voice: voice)
            try await next.start()
        }
        active = next
        refillStandby()
        return next
    }

    private func refillStandby() {
        guard standby == nil else { return }
        let voice = voice
        standby = Task {
            let spare = WorkerProcess(voice: voice)
            try await spare.start()
            return spare
        }
    }
}

/// One Kokoro child process.
///
/// Protocol: one JSON object per line on stdin/stdout.
///   → {"id": 1, "text": "...", "voice": "af_heart", "speed": 1.05}
///   ← {"id": 1, "pcm": "<base64 Int16 24 kHz mono>"}  or  {"id": 1, "error": "..."}
///   ← {"ready": true} once loaded, {"progress": "..."} while loading
actor WorkerProcess {
    enum WorkerError: LocalizedError {
        case crashed
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .crashed: return "The voice engine stopped unexpectedly"
            case .failed(let message): return message
            }
        }
    }

    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[Float], Error>] = [:]
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var progress: (@Sendable (String) -> Void)?

    init(voice: String) {
        arguments = ["--tts-worker", voice]
    }

    /// A helper speaking this same protocol, started with other `arguments`.
    init(arguments: [String]) {
        self.arguments = arguments
    }

    func start(progress: (@Sendable (String) -> Void)? = nil) async throws {
        self.progress = progress
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        // One ordered stream into the actor: a Task per chunk could reorder them.
        let (chunks, sink) = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; sink.finish() } else { sink.yield(data) }
        }
        Task { [weak self] in
            for await data in chunks { await self?.received(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.terminated() }
        }
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        try await withCheckedThrowingContinuation { readyWaiter = $0 }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        // Nothing waiting on an answer should wait forever.
        terminated()
    }

    func request(_ text: String, options: [String: Any]) async throws -> [Float] {
        var line = options
        line["text"] = text
        return try await send(line)
    }

    func request(_ text: String, voice: String, speed: Float, clonedVoice: String? = nil) async throws -> [Float] {
        var line: [String: Any] = ["text": text, "voice": voice, "speed": speed]
        if let clonedVoice { line["clonedVoice"] = clonedVoice }
        return try await send(line)
    }

    /// Sends one request; resolves with the samples (empty for commands like "clone").
    func send(_ request: [String: Any]) async throws -> [Float] {
        try Task.checkCancellation()
        if process?.isRunning != true { try await start(progress: progress) }
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        var line = request
        line["id"] = id
        var data = try JSONSerialization.data(withJSONObject: line)
        data.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input?.write(contentsOf: data)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: WorkerError.crashed)
            }
        }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if json["ready"] != nil {
                readyWaiter?.resume()
                readyWaiter = nil
            } else if let message = json["progress"] as? String {
                // Only startup progress belongs on the loading screen; later messages are ignored.
                if readyWaiter != nil { progress?(message) }
            } else if let id = json["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                if let base64 = json["pcm"] as? String, let pcm = Data(base64Encoded: base64) {
                    continuation.resume(returning: Self.floats(fromInt16: pcm))
                } else if json["ok"] != nil {
                    continuation.resume(returning: [])
                } else {
                    continuation.resume(throwing: WorkerError.failed(json["error"] as? String ?? "Speech failed"))
                }
            } else if let error = json["fatal"] as? String {
                readyWaiter?.resume(throwing: WorkerError.failed(error))
                readyWaiter = nil
            }
        }
    }

    private func terminated() {
        process = nil
        buffer.removeAll()
        readyWaiter?.resume(throwing: WorkerError.crashed)
        readyWaiter = nil
        for continuation in pending.values { continuation.resume(throwing: WorkerError.crashed) }
        pending.removeAll()
    }

    private static func floats(fromInt16 data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32_767 }
        }
    }

    /// How a helper hands back its samples.
    static func pcmBase64(_ samples: [Float]) -> String {
        var pcm = Data(count: samples.count * 2)
        pcm.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() { out[i] = Int16(max(-1, min(1, s)) * 32_767) }
        }
        return pcm.base64EncodedString()
    }
}

extension TTSWorker {
    // MARK: - Worker side

    /// `SPEAKTOME_KOKORO` = v3 (default) | v3gpu | legacy, for comparing Core ML routes.
    private static func makeKokoro(voice: String) -> KokoroAneManager {
        switch ProcessInfo.processInfo.environment["SPEAKTOME_KOKORO"] {
        case "legacy":
            return KokoroAneManager(defaultVoice: voice, directory: SpeechModels.modelsRoot, version: .legacy)
        case "v3gpu":
            return KokoroAneManager(
                defaultVoice: voice, directory: SpeechModels.modelsRoot, computeUnits: .aneTailGpu, version: .v3)
        default:
            return KokoroAneManager(defaultVoice: voice, directory: SpeechModels.modelsRoot, version: .v3)
        }
    }

    /// Entry point of the child process. Never returns.
    static func runWorker(voice: String) -> Never {
        Task.detached {
            func send(_ object: [String: Any]) {
                guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
            }
            do {
                send(["progress": "Loading voice (first run downloads and compiles it, ~1 min)…"])
                let tts = makeKokoro(voice: voice)
                try await tts.initialize(preloadVoices: [voice])
                _ = try? await tts.synthesizeDetailed(text: "Hello there.", voice: voice)
                send(["ready": true])

                let cloned = ClonedVoices()
                while let line = readLine() {
                    guard let data = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let id = json["id"] as? Int
                    else { continue }
                    do {
                        if let sample = json["clone"] as? String, let out = json["out"] as? String {
                            try await cloned.clone(sample: URL(fileURLWithPath: sample), to: URL(fileURLWithPath: out))
                            send(["id": id, "ok": true])
                            continue
                        }
                        if json["prepareClone"] != nil {
                            try await cloned.prepare()
                            send(["id": id, "ok": true])
                            continue
                        }
                        guard let text = json["text"] as? String else { continue }
                        let speed = (json["speed"] as? NSNumber)?.floatValue ?? 1
                        let samples: [Float]
                        if let voiceFile = json["clonedVoice"] as? String {
                            samples = try await cloned.speak(text, voiceFile: voiceFile)
                        } else {
                            samples = try await tts.synthesizeDetailed(
                                text: text, voice: json["voice"] as? String ?? voice, speed: speed
                            ).samples
                        }
                        send(["id": id, "pcm": WorkerProcess.pcmBase64(samples)])
                    } catch {
                        send(["id": id, "error": error.localizedDescription])
                    }
                }
                exit(0)
            } catch {
                send(["fatal": error.localizedDescription])
                exit(1)
            }
        }
        dispatchMain()
    }
}

/// PocketTTS with cloned voices, inside the worker process. Loaded on first use.
private actor ClonedVoices {
    private var manager: PocketTtsManager?
    private var voices: [String: PocketTtsVoiceData] = [:]

    private func ready() async throws -> PocketTtsManager {
        if let manager { return manager }
        let manager = PocketTtsManager(directory: SpeechModels.modelsRoot)
        try await manager.initialize()
        self.manager = manager
        return manager
    }

    func prepare() async throws {
        _ = try await ready()
    }

    func clone(sample: URL, to output: URL) async throws {
        let manager = try await ready()
        try await manager.cloneVoiceToFile(from: sample, to: output)
        voices[output.path] = nil
    }

    func speak(_ text: String, voiceFile: String) async throws -> [Float] {
        let manager = try await ready()
        let voice: PocketTtsVoiceData
        if let cached = voices[voiceFile] {
            voice = cached
        } else {
            voice = try manager.loadClonedVoice(from: URL(fileURLWithPath: voiceFile))
            voices[voiceFile] = voice
        }
        let wav = try await manager.synthesize(text: text, voiceData: voice)
        return WAV.samples(wav)
    }
}

/// Supertonic-3 (31 languages). Runs in the app itself, not the Kokoro workers, so
/// there's one copy rather than one per worker. Loaded only once a conversation
/// turns to another language; the first ever load downloads it (~170 MB).
actor MultilingualVoices {
    static let languages = Set(Supertonic3Constants.availableLanguages).subtracting(["en", "na"])
    static let voices = Supertonic3Voice.allCases.map(\.rawValue)
    static let defaultVoice = Supertonic3Voice.f1.rawValue

    private var manager: Task<Supertonic3Manager, Error>?
    private var styles: [Supertonic3Voice: Supertonic3VoiceStyle] = [:]

    func prepare(voice: String) async throws {
        _ = try await ready()
        _ = try await style(voice)
    }

    private func ready() async throws -> Supertonic3Manager {
        if let manager { return try await manager.value }
        let task = Task {
            let manager = Supertonic3Manager(directory: SpeechModels.modelsRoot)
            try await manager.initialize()
            return manager
        }
        manager = task
        do { return try await task.value } catch { manager = nil; throw error }
    }

    /// 24 kHz samples, like Kokoro's.
    func speak(_ text: String, language: String, voice name: String, speed: Float) async throws -> [Float] {
        let manager = try await ready()
        let style = try await style(name)
        let samples = try await manager.synthesize(text: text, language: language, style: style, speed: speed).samples
        return Resampler.convert(samples, from: Double(Supertonic3Constants.sampleRate), to: AudioIO.speakerSampleRate)
    }

    private func style(_ name: String) async throws -> Supertonic3VoiceStyle {
        let voice = Supertonic3Voice(name: name) ?? .f1
        if let cached = styles[voice] { return cached }
        let style = try await Supertonic3ResourceDownloader.loadVoiceStyle(voice, directory: SpeechModels.modelsRoot)
        styles[voice] = style
        return style
    }
}

enum Resampler {
    static func convert(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard !samples.isEmpty, from != to else { return samples }
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

/// Minimal WAV reader for 16-bit PCM or 32-bit float mono/stereo (first channel).
enum WAV {
    /// 16-bit mono WAV.
    static func data(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32_767) }
        data.append(contentsOf: "RIFF".utf8); append(UInt32(36 + pcm.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8); append(UInt32(pcm.count * 2))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func samples(_ data: Data) -> [Float] {
        var offset = 12
        var bits = 16, channels = 1, isFloat = false
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let body = offset + 8
            if id == "fmt " {
                let format = data[body..<body + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
                channels = Int(data[body + 2..<body + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
                bits = Int(data[body + 14..<body + 16].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
                isFloat = format == 3
            } else if id == "data" {
                let end = min(data.count, body + size)
                let bytesPerFrame = bits / 8 * channels
                let frames = (end - body) / bytesPerFrame
                return data[body..<end].withUnsafeBytes { raw in
                    (0..<frames).map { i in
                        let at = i * bytesPerFrame
                        return isFloat
                            ? raw.loadUnaligned(fromByteOffset: at, as: Float.self)
                            : Float(raw.loadUnaligned(fromByteOffset: at, as: Int16.self)) / 32_767
                    }
                }
            }
            offset = body + size + (size & 1)
        }
        return []
    }
}
