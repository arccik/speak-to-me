import Foundation

/// Picks between the app and its helper process before any UI starts.
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--tts-worker") {
            TTSWorker.runWorker(voice: args.indices.contains(flag + 1) ? args[flag + 1] : "af_heart")
        }
        if let flag = args.firstIndex(of: "--ttsstress") {
            let count = args.indices.contains(flag + 1) ? Int(args[flag + 1]) ?? 60 : 60
            Task.detached { await SelfTest.stressTTS(count: count) }
            dispatchMain()
        }
        if let flag = args.firstIndex(of: "--clonetest"), args.indices.contains(flag + 1) {
            let dir = args[flag + 1]
            Task.detached { await SelfTest.cloneVoice(to: dir) }
            dispatchMain()
        }
        if args.contains("--chattest") {
            Task { @MainActor in await SelfTest.chat() }
            dispatchMain()
        }
        if args.contains("--langtest") {
            Task.detached { await SelfTest.languages() }
            dispatchMain()
        }
        SpeakToMeApp.main()
    }
}
