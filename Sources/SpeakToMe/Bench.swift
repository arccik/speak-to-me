import AppKit
import Foundation

/// `SpeakToMe --uibench` opens the normal window, streams one long reply into a
/// 30-message conversation and prints what it cost: CPU time and how often the main
/// thread stalled. Point it at a fake server with `SPEAKTOME_OMLX_URL` so the language
/// model isn't on the GPU; `-chatOpen YES|NO` picks the layout, `-muteReplies YES` keeps it quiet.
@MainActor
enum UIBench {
    static func run() async {
        let session = VoiceSession.shared
        while session.phase != .ready {
            if case .failed(let message) = session.phase { print("BENCH failed: \(message)"); exit(1) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        NSApp.activate(ignoringOtherApps: true)
        let sample: [VoiceSession.Line] = [
            .init(role: "user", text: "What's the tallest mountain in Europe?"),
            .init(role: "assistant", text: "That's Mount Elbrus in the Caucasus, at about 5,642 metres. It's a dormant volcano with two summits."),
            .init(role: "user", text: "Have people skied down it?"),
            .init(role: "assistant", text: "Yes, plenty! There's a ski resort on its southern slopes, and the season runs from late autumn to spring.", note: "Searched the web: skiing Elbrus"),
            .init(role: "user", text: "What's the weather there right now?"),
            .init(role: "assistant", text: "It's about minus eight at the summit, with strong winds and clear skies."),
        ]
        session.beginTestConversation(lines: Array(repeating: sample, count: 5).flatMap { $0 }.map {
            VoiceSession.Line(role: $0.role, text: $0.text, note: $0.note)
        })
        try? await Task.sleep(for: .seconds(2))

        let monitor = StallMonitor()
        let cpuBefore = cpuMilliseconds()
        let start = Date()
        print("BENCH start"); fflush(stdout)
        session.send("Tell me a long story about the mountains.")
        while session.phase != .ready { try? await Task.sleep(for: .milliseconds(20)) }
        let seconds = Date().timeIntervalSince(start)
        let cpu = cpuMilliseconds() - cpuBefore
        let stalls = monitor.finish()
        print(String(format: "BENCH end seconds=%.2f cpu_ms=%d cpu_pct=%.1f stall_max_ms=%.1f stall_p99_ms=%.1f stalls_over_33ms=%d",
                     seconds, cpu, Double(cpu) / seconds / 10, stalls.max, stalls.p99, stalls.over33))
        fflush(stdout)
        session.deleteConversationForTest()
        exit(0)
    }

    /// User + system CPU time of this process (helper processes excluded).
    static func cpuMilliseconds() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func ms(_ t: timeval) -> Int { t.tv_sec * 1000 + Int(t.tv_usec) / 1000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }
}

/// Ticks on the main queue 120 times a second and records how late each tick fires,
/// which is how long the main thread was busy with something else.
final class StallMonitor: @unchecked Sendable {
    struct Result { var max: Double; var p99: Double; var over33: Int }

    private let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
    private let interval = 1.0 / 120
    private var last = CACurrentMediaTime()
    private var lateness: [Double] = []

    init() {
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(0))
        timer.setEventHandler { [self] in
            let now = CACurrentMediaTime()
            lateness.append(max(0, (now - last - interval) * 1000))
            last = now
        }
        timer.resume()
    }

    func finish() -> Result {
        timer.cancel()
        let sorted = lateness.sorted()
        guard !sorted.isEmpty else { return Result(max: 0, p99: 0, over33: 0) }
        return Result(max: sorted.last!, p99: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))],
                      over33: sorted.filter { $0 > 33 }.count)
    }
}
