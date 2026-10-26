import AVFoundation
import Foundation

/// `open build/SpeakToMe.app --args --micdiag` checks mic permission and whether the
/// app's audio engine starts, writing the result to ~/Library/Application Support/SpeakToMe/micdiag.txt.
enum MicDiagnostics {
    static func run() async {
        var out: [String] = []
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        out.append("permission before: \(status.rawValue) (0 notDetermined, 1 restricted, 2 denied, 3 authorized)")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        out.append("permission granted: \(granted)")

        let audio = AudioIO()
        do {
            let samples = SampleCounter()
            audio.onMicSamples = { samples.add($0.count) }
            try audio.start()
            out.append("AudioIO start: OK, echo cancellation \(audio.echoCancellationActive ? "on" : "off")")
            try? await Task.sleep(for: .milliseconds(500))
            out.append("mic samples in 0.5 s at start: \(samples.take())")
            // A reply turns echo cancellation on; once it's over, it turns off again.
            audio.play([Float](repeating: 0, count: 2_400))
            out.append("while replying: echo cancellation \(audio.echoCancellationActive ? "on" : "off")")
            try? await Task.sleep(for: .milliseconds(500))
            let before = samples.take()
            audio.relaxEchoCancellation(after: 0.2)
            try? await Task.sleep(for: .milliseconds(800))
            out.append("mic samples while switching: \(samples.take())")
            try? await Task.sleep(for: .milliseconds(3000))
            _ = samples.take()
            try? await Task.sleep(for: .milliseconds(500))
            out.append("after reply: echo cancellation \(audio.echoCancellationActive ? "on" : "off")")
            out.append("mic samples in 0.5 s, with / without echo cancellation: \(before) / \(samples.take())")
            audio.stop()
        } catch {
            out.append("AudioIO start FAILED: \(error)")
        }
        let url = SpeechModels.appRoot.appendingPathComponent("micdiag.txt")
        try? FileManager.default.createDirectory(at: SpeechModels.appRoot, withIntermediateDirectories: true)
        try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        exit(0)
    }
}

private final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
    func take() -> Int { lock.lock(); defer { count = 0; lock.unlock() }; return count }
}
