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

/// `SpeakToMe --uidrive <dir> -chatOpen NO` plays through a voice turn in the normal window and
/// saves a picture of each moment: clicks it to start and stop, feeds made-up levels for your
/// voice and the reply, cuts in, and scratches the disc. Silent, and no real audio is involved, so
/// it can't reach another copy of the app. Events go straight to this app's window, never to
/// the rest of the screen.
@MainActor
enum UIDrive {
    private static var directory = ""

    static func run(to path: String) async {
        directory = path
        let session = VoiceSession.shared
        for _ in 0..<300 where session.phase != .ready { try? await Task.sleep(for: .milliseconds(200)) }
        report("booted")
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else {
            print("DRIVE no window"); exit(1)
        }
        window.orderFrontRegardless() // a covered window pauses itself; this doesn't take the keyboard
        session.beginTestConversation(lines: [
            .init(role: "user", text: "What's the tallest mountain in Europe?"),
            .init(role: "assistant", text: "That's Mount Elbrus in the Caucasus, at about 5,642 metres."),
            .init(role: "user", text: "Have people skied down it?"),
            .init(role: "assistant", text: "Yes, plenty! There's a ski resort on its southern slopes."),
        ])
        try? await Task.sleep(for: .seconds(1.5))
        capture(window, "1-stage")

        click(window)
        for _ in 0..<100 where !session.micOn { try? await Task.sleep(for: .milliseconds(100)) }
        report("clicked to start")
        click(window)
        for _ in 0..<100 where session.micOn { try? await Task.sleep(for: .milliseconds(100)) }
        report("clicked to stop")

        session.liveText = "And how long does it take to climb"
        await play(.hearing, seconds: 7) { session.levels.mic = $0 }
        capture(window, "2-hearing")
        report("fed your voice")
        session.liveText = nil
        session.levels.mic = 0

        session.lines.append(.init(role: "user", text: "And how long does it take to climb?"))
        session.phase = .thinking
        try? await Task.sleep(for: .seconds(1.2))
        capture(window, "3-thinking")

        session.lines.append(.init(role: "assistant", text: "Most people take about a week, to give the body time to adjust to the"))
        await play(.speaking, seconds: 7) { session.levels.speaker = $0 }
        capture(window, "4-speaking")
        report("fed the reply")

        session.lines[session.lines.count - 1].interrupted = true
        try? await Task.sleep(for: .milliseconds(180))
        capture(window, "5-cut-in")
        print("DRIVE cut in front=\(LatheEngine.shared.front) strength=\(LatheEngine.shared.frontStrength)")
        session.levels.speaker = 0
        session.phase = .ready
        try? await Task.sleep(for: .seconds(1.5))

        let center = NSPoint(x: window.contentLayoutRect.midX, y: window.contentLayoutRect.height * 0.54)
        drag(window, around: center, phase: .leftMouseDown, angle: 0)
        for step in 1...40 {
            drag(window, around: center, phase: .leftMouseDragged, angle: Double(step) * 0.12) // anti-clockwise goes back
            try? await Task.sleep(for: .milliseconds(20))
        }
        print("DRIVE scratched scrub=\(LatheEngine.shared.scrub) line=\(String(describing: LatheEngine.shared.lineAtHead))")
        try? await Task.sleep(for: .milliseconds(300))
        capture(window, "6-scratching")
        drag(window, around: center, phase: .leftMouseUp, angle: 40 * 0.12)
        try? await Task.sleep(for: .seconds(2))
        print("DRIVE released scrub=\(LatheEngine.shared.scrub)")

        try? await Task.sleep(for: .seconds(5))
        let before = UIBench.cpuMilliseconds()
        try? await Task.sleep(for: .seconds(5))
        print("DRIVE idle cpu_pct=\(Double(UIBench.cpuMilliseconds() - before) / 50)")

        session.deleteConversationForTest()
        exit(0)
    }

    /// Holds a phase with syllable-shaped levels coming in, like someone talking.
    private static func play(_ phase: VoiceSession.Phase, seconds: Double, feed: (Float) -> Void) async {
        VoiceSession.shared.phase = phase
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            let t = Date().timeIntervalSince(start)
            feed(Float(0.2 + 0.6 * max(0, sin(t * 12.6) * sin(t * 2.7 + 1))))
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private static func report(_ what: String) {
        let session = VoiceSession.shared
        print("DRIVE \(what): phase=\(session.phase) micOn=\(session.micOn) lines=\(session.lines.count) turn=\(LatheEngine.shared.turn) mic=\(session.levels.mic)")
        fflush(stdout)
    }

    private static func click(_ window: NSWindow) {
        let point = NSPoint(x: window.contentLayoutRect.midX - 120, y: window.contentLayoutRect.height * 0.4)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            send(window, type, at: point)
        }
    }

    private static func drag(_ window: NSWindow, around center: NSPoint, phase: NSEvent.EventType, angle: Double) {
        send(window, phase, at: NSPoint(x: center.x + cos(angle) * 180, y: center.y + sin(angle) * 180))
    }

    private static func send(_ window: NSWindow, _ type: NSEvent.EventType, at point: NSPoint) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        window.sendEvent(event)
    }

    private static func capture(_ window: NSWindow, _ name: String) {
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(directory)/\(name).png"]
        try? shot.run()
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
