import Foundation
import MLX

/// F5-TTS Russian (Misha24-10/F5-TTS_RUSSIAN, CC-BY-NC-4.0), as seen from the app: downloads
/// the model, makes the short clip of a voice it imitates, and talks to its helper process.
actor F5RussianVoice {
    private struct RemoteFile {
        let name: String
        let url: String
        let bytes: Int64
    }

    /// Pinned to the revisions this was tested with. The largest comes last, and only
    /// finished files get their final name, so its presence means the download is complete.
    private static let files = [
        RemoteFile(
            name: "vocab.txt",
            url: "https://huggingface.co/Misha24-10/F5-TTS_RUSSIAN/resolve/ea166adeae4c80ec5ee423a671e2bdb83906cf84/F5TTS_v1_Base/vocab.txt",
            bytes: 13_800),
        RemoteFile(
            name: "vocos.safetensors",
            url: "https://huggingface.co/lucasnewman/vocos-mel-24khz/resolve/ee89d00fac94b61e1235e0869f3e8d49711b7484/model.safetensors",
            bytes: 54_348_264),
        RemoteFile(
            name: "model_v1.safetensors",
            url: "https://huggingface.co/Misha24-10/F5-TTS_RUSSIAN/resolve/ea166adeae4c80ec5ee423a671e2bdb83906cf84/F5TTS_v1_Base_v2/model_last_inference.safetensors",
            bytes: 1_348_435_761),
    ]

    static let folderName = "f5-tts-russian"
    static var folder: URL { SpeechModels.modelsRoot.appendingPathComponent(folderName, isDirectory: true) }
    static let installedMarker = "\(folderName)/model_v1.safetensors"

    /// What the reference clip says. Generating time grows with its length, so it's short.
    static let referenceText = "Сегодня хорошая погода, можно прогуляться."

    private let multilingual: MultilingualVoices
    private var worker: Task<WorkerProcess, Error>?

    init(multilingual: MultilingualVoices) {
        self.multilingual = multilingual
    }

    /// Downloads whatever's missing (`progress` from 0 to 1), then loads and warms up the
    /// model. Everything after the first load is quick.
    func prepare(voice: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(progress: progress)
        _ = try await speak("Да.", voice: voice, speed: 1)
    }

    /// 24 kHz samples.
    func speak(_ text: String, voice: String, speed: Float) async throws -> [Float] {
        let reference = try await referenceClip(voice: voice)
        return try await liveWorker().request(
            Self.spellingOutNumbers(text),
            options: ["reference": reference.path, "referenceText": Self.referenceText, "speed": speed])
    }

    /// Frees its memory; the next `speak` loads it again.
    func stop() async {
        let running = worker
        worker = nil
        if let process = try? await running?.value { await process.stop() }
    }

    private func liveWorker() async throws -> WorkerProcess {
        if let worker { return try await worker.value }
        let task = Task {
            let process = WorkerProcess(arguments: ["--f5-worker"])
            try await process.start()
            return process
        }
        worker = task
        do { return try await task.value } catch { worker = nil; throw error }
    }

    /// The model learns how to sound from a clip, so one is made with the matching Supertonic-3 voice.
    private func referenceClip(voice: String) async throws -> URL {
        let clip = Self.folder.appendingPathComponent("reference-\(voice).wav")
        if FileManager.default.fileExists(atPath: clip.path) { return clip }
        let samples = try await multilingual.speak(Self.referenceText, language: "ru", voice: voice, speed: 1)
        try WAV.data(samples, sampleRate: F5TTS.sampleRate).write(to: clip, options: .atomic)
        return clip
    }

    private func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let total = Self.files.reduce(0) { $0 + $1.bytes }
        var finished: Int64 = 0
        for file in Self.files {
            let destination = Self.folder.appendingPathComponent(file.name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                let done = finished
                try await FileDownload.fetch(file.url, to: destination, expectedBytes: file.bytes) { bytes in
                    progress(Double(done + bytes) / Double(total))
                }
            }
            finished += file.bytes
            progress(Double(finished) / Double(total))
        }
    }

    /// The model reads digits badly, so "42" becomes "сорок два". Always the nominative: a
    /// listener forgives the wrong case more easily than a garbled number.
    static func spellingOutNumbers(_ text: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru")
        formatter.numberStyle = .spellOut
        var result = ""
        var rest = Substring(text)
        while let match = rest.firstMatch(of: #/\d+/#) {
            result += rest[..<match.range.lowerBound]
            if let number = Int(match.output), let words = formatter.string(from: NSNumber(value: number)) {
                result += words
            } else {
                result += match.output
            }
            rest = rest[match.range.upperBound...]
        }
        return result + rest
    }
}

/// One file over HTTPS, with progress. It's only given its final name once complete.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private enum DownloadError: LocalizedError {
        case incomplete(String)

        var errorDescription: String? {
            switch self {
            case .incomplete(let reason): return "The download didn't finish: \(reason)"
            }
        }
    }

    private let destination: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    static func fetch(
        _ url: String, to destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let delegate = FileDownload(destination: destination, expectedBytes: expectedBytes, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: URL(string: url)!).resume()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this returns.
        do {
            let size = try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64 ?? 0
            guard size == expectedBytes else {
                throw DownloadError.incomplete("got \(size) of \(expectedBytes) bytes")
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? failure {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

// MARK: - Worker side

enum F5Worker {
    /// Entry point of the child process. Never returns. Same line protocol as `WorkerProcess`
    /// describes; a request also names the reference clip and what it says.
    static func run() -> Never {
        func send(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        }
        // Between sentences it needs no scratch memory held back from the language model.
        Memory.cacheLimit = 256 * 1024 * 1024
        let model: F5TTS
        do {
            let folder = F5RussianVoice.folder
            model = try F5TTS(
                checkpoint: folder.appendingPathComponent("model_v1.safetensors"),
                vocabulary: folder.appendingPathComponent("vocab.txt"),
                vocoder: folder.appendingPathComponent("vocos.safetensors"))
        } catch {
            send(["fatal": error.localizedDescription])
            exit(1)
        }
        send(["ready": true])

        var references: [String: F5TTS.Reference] = [:]
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? Int
            else { continue }
            guard let text = json["text"] as? String,
                  let path = json["reference"] as? String,
                  let referenceText = json["referenceText"] as? String,
                  let clip = try? Data(contentsOf: URL(fileURLWithPath: path))
            else {
                send(["id": id, "error": "F5-TTS got an incomplete request"])
                continue
            }
            let reference = references[path] ?? model.reference(samples: WAV.samples(clip), text: referenceText)
            references[path] = reference
            do {
                let speed = (json["speed"] as? NSNumber)?.floatValue ?? 1
                let samples = try model.speak(text, reference: reference, speed: speed)
                send(["id": id, "pcm": WorkerProcess.pcmBase64(samples)])
            } catch {
                send(["id": id, "error": error.localizedDescription])
            }
        }
        exit(0)
    }
}
