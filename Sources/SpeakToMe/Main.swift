import Foundation

/// Picks between the app and its helper process before any UI starts.
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--tts-worker") {
            TTSWorker.runWorker(voice: args.indices.contains(flag + 1) ? args[flag + 1] : "af_heart")
        }
        if args.contains("--f5-worker") {
            F5Worker.run()
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
        if let flag = args.firstIndex(of: "--langtest") {
            let dir = args.indices.contains(flag + 1) ? args[flag + 1] : nil
            Task.detached { await SelfTest.languages(writingTo: dir) }
            dispatchMain()
        }
        if args.contains("--f5switchtest") {
            Task { @MainActor in await SelfTest.f5Switching() }
            dispatchMain()
        }
        if let flag = args.firstIndex(of: "--f5test"), args.count > flag + 4 {
            SelfTest.f5(modelDir: args[flag + 1], reference: args[flag + 2], referenceText: args[flag + 3], out: args[flag + 4])
        }
        if let flag = args.firstIndex(of: "--speechtest") {
            let dir = args.indices.contains(flag + 1) ? args[flag + 1] : nil
            Task.detached { await SelfTest.speechModels(writingTo: dir) }
            dispatchMain()
        }
        SpeakToMeApp.main()
    }
}
