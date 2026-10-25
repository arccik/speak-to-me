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
            try audio.start()
            out.append("AudioIO start: OK")
            audio.play([Float](repeating: 0, count: 2_400))
            try? await Task.sleep(for: .milliseconds(300))
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
