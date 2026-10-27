import AVFoundation
import ObjCSupport

/// Owns the single AVAudioEngine used for both the microphone and playback.
///
/// With echo cancellation on, voice processing is enabled on the input node while the
/// assistant has something to say: Apple's echo canceller subtracts its voice (played
/// through `player` on the same engine) from the mic signal, so you can interrupt it
/// without headphones. Voice processing also makes macOS turn down every other app's
/// audio, so between replies the engine runs a plain mic and YouTube or music play
/// at full volume.
///
/// Call the public methods on the main thread. They return at once: building, tearing
/// down and switching the engine (up to a second or two with voice processing) happens
/// in order on `queue`, its own thread, so the UI never waits for the audio hardware. Audio
/// handed to `play` while the engine is being rebuilt simply plays once it's back.
final class AudioIO: @unchecked Sendable {
    static let micSampleRate: Double = 16_000
    static let speakerSampleRate: Double = 24_000

    private let queue = EngineThread()

    // Only touched on `queue`.
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var engineHasMic = false
    /// What the engine is being built with; `voiceProcessing` only follows once it's running.
    private var engineVoiceProcessing = false
    private var configurationObserver: NSObjectProtocol?

    private let speakerFormat = AVAudioFormat(standardFormatWithSampleRate: speakerSampleRate, channels: 1)!
    private let micFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: micSampleRate, channels: 1, interleaved: false)!

    // Shared between threads, behind `lock`.
    private let lock = NSLock()
    /// Bumped on every `stopPlayback()` so completions from flushed buffers are ignored.
    private var playbackGeneration = 0
    /// Buffers handed to `play` that haven't finished (some may still wait on `queue`).
    private var pendingBuffers = 0
    /// Of those, the ones already scheduled on the player; the engine can't be rebuilt under them.
    private var scheduledBuffers = 0
    /// Bumped by every start and stop, so work queued for an earlier run gives up.
    private var run = 0
    private var _isRunning = false
    private var _voiceProcessing = false
    private var _micMuted = false

    /// Live mic and speaker loudness for the visualizer.
    let levels = AudioLevels()

    /// Called on the audio thread with 16 kHz mono samples.
    var onMicSamples: (([Float]) -> Void)?
    /// Called (on an arbitrary thread) when every scheduled buffer has finished playing.
    var onPlaybackDrained: (() -> Void)?

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingBuffers > 0
    }

    private(set) var isRunning: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isRunning }
        set { lock.lock(); _isRunning = newValue; lock.unlock() }
    }

    // Main thread only.
    private(set) var micEnabled = false
    /// You want to be able to talk over replies (the setting).
    private var echoCancellationWanted = false
    private var echoCancellationOff: DispatchWorkItem?

    /// Voice processing is on right now. Without it the mic would hear the assistant
    /// through the speakers, so it delivers silence while a reply is playing.
    private var voiceProcessing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _voiceProcessing }
        set { lock.lock(); _voiceProcessing = newValue; lock.unlock() }
    }
    var echoCancellationActive: Bool { voiceProcessing }

    /// While muted the mic keeps running but delivers silence, so the listener just hears a pause.
    var micMuted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _micMuted }
        set { lock.lock(); _micMuted = newValue; lock.unlock() }
    }

    private var currentRun: Int {
        lock.lock(); defer { lock.unlock() }
        return run
    }

    private func isCurrent(_ run: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.run == run && _isRunning
    }

    /// `withMic: false` sets up playback only (for typed messages), with no mic or
    /// echo cancellation, so no microphone permission is needed. `completion` runs on
    /// the main thread once the engine is up (nil) or has failed for good.
    func start(withMic: Bool = true, echoCancellation: Bool = true,
               completion: (@MainActor (Error?) -> Void)? = nil) {
        micEnabled = withMic
        echoCancellationWanted = withMic && echoCancellation
        lock.lock()
        run += 1
        let run = run
        _isRunning = true
        lock.unlock()
        queue.async { [self] in
            // Just after another engine or app let go of the audio device, starting it can
            // fail with a generic hardware error ('what', 2003329396) that clears up within
            // a moment, so give it a few tries before reporting a problem.
            var failure: Error?
            for attempt in 1... {
                guard isCurrent(run) else { return }
                do {
                    try build(voiceProcessing: false, mic: withMic)
                    failure = nil
                    break
                } catch {
                    teardown()
                    failure = error
                    guard attempt < 6 else { break }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            if failure != nil { isRunning = false }
            DispatchQueue.main.async {
                guard self.currentRun == run else { return }
                MainActor.assumeIsolated { completion?(failure) }
            }
        }
    }

    /// On `queue`.
    private func build(voiceProcessing enabled: Bool, mic: Bool) throws {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        engineHasMic = mic
        engineVoiceProcessing = enabled
        guard mic else {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: speakerFormat)
            try startEngine()
            voiceProcessing = false
            return
        }
        let input = engine.inputNode
        if enabled {
            _ = engine.outputNode
            try input.setVoiceProcessingEnabled(true)
            // Ask for as little ducking of other apps as macOS allows.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)

            // Voice processing changes the output unit's format; the mixer's implicit
            // link to it is stale, and the engine fails to start (-10875) unless we
            // reconnect it explicitly with the new format. Read the format before touching
            // `mainMixerNode`: creating the mixer rewires the output and changes it.
            let outputFormat = engine.outputNode.inputFormat(forBus: 0)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: speakerFormat)

        let inputFormat = input.outputFormat(forBus: 0)
        guard let monoInput = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: monoInput, to: micFormat)
        else { throw AudioIOError.badFormat }

        // The converter belongs to this engine, so a rebuild can't swap it under a running tap.
        let firstInput = DispatchSemaphore(value: 0)
        var heard = false
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            if !heard { heard = true; firstInput.signal() }
            self?.handleMic(buffer, monoFormat: monoInput, converter: converter)
        }
        try startEngine()
        // Now and then a voice-processing engine starts without its audio ever running;
        // the first `player.play()` then hangs for ~7 s. Audio normally flows within
        // ~0.1 s, so if it hasn't in half a second, fail and let the caller build it again.
        guard firstInput.wait(timeout: .now() + 0.5) == .success else { throw AudioIOError.noInput }
        voiceProcessing = enabled
    }

    /// On `queue`.
    private func startEngine() throws {
        engine.prepare()
        try engine.start()
        // The engine stops itself when the audio hardware changes (headphones, a new
        // output device, voice processing settling). Bring it back rather than going silent.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.engineConfigurationChanged() }
        }

        // Installed after start so it can't disturb the voice-processing format negotiation.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData?[0] else { return }
            self.levels.speaker = AudioLevels.rms(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
    }

    /// On `queue`.
    private func teardown() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if engineHasMic { engine.inputNode.removeTap(onBus: 0) }
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        // Otherwise the device stays in voice-processing mode and the next plain engine's mic is silent.
        if engineHasMic, engineVoiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
    }

    func stop() {
        guard isRunning else { return }
        lock.lock()
        run += 1
        _isRunning = false
        lock.unlock()
        echoCancellationOff?.cancel()
        stopPlayback()
        queue.async { [self] in
            teardown()
            levels.mic = 0
            levels.speaker = 0
        }
    }

    // MARK: - Echo cancellation on demand

    /// Turns echo cancellation on ahead of a reply, so it's settled by the time audio plays.
    func prepareEchoCancellation() {
        echoCancellationOff?.cancel()
        guard echoCancellationWanted, !voiceProcessing else { return }
        setVoiceProcessing(true)
    }

    /// You've started talking: don't switch the engine under you mid-sentence.
    func holdEchoCancellation() {
        echoCancellationOff?.cancel()
    }

    /// Turns echo cancellation off once things have been quiet for a moment, giving
    /// other apps their full volume back. Call when the conversation is idle again.
    func relaxEchoCancellation(after delay: TimeInterval = 1.5) {
        echoCancellationOff?.cancel()
        guard voiceProcessing else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.setVoiceProcessing(false)
        }
        echoCancellationOff = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Rebuilds the engine with voice processing on or off. Only between replies:
    /// anything already scheduled on the player would be lost.
    private func setVoiceProcessing(_ enabled: Bool) {
        guard isRunning, micEnabled else { return }
        let run = currentRun
        queue.async { [self] in
            lock.lock()
            let busy = scheduledBuffers > 0
            lock.unlock()
            guard isCurrent(run), engineVoiceProcessing != enabled, !busy else { return }
            teardown()
            rebuild(voiceProcessing: enabled, run: run)
        }
    }

    /// On `queue`. Right after voice processing shuts down, the output device briefly
    /// reports an invalid format and the engine won't start (-10875), so a failed build
    /// is retried for a few seconds. Anything queued behind it waits, which is the point:
    /// audio for the reply plays on the rebuilt engine.
    private func rebuild(voiceProcessing enabled: Bool, run: Int) {
        for attempt in 0...15 {
            guard isCurrent(run) else { return }
            do {
                try build(voiceProcessing: enabled, mic: engineHasMic)
                return
            } catch {
                teardown()
            }
            if attempt < 15 { Thread.sleep(forTimeInterval: 0.2) }
        }
        lock.lock()
        if self.run == run { _isRunning = false }
        lock.unlock()
    }

    /// On `queue`.
    private func engineConfigurationChanged() {
        guard isRunning, !engine.isRunning else { return }
        // Whatever was queued is gone; let the session know the reply stopped.
        let wasPlaying = isPlaying
        flushPlayback()
        player.stop()
        if wasPlaying { onPlaybackDrained?() }
        teardown()
        rebuild(voiceProcessing: engineVoiceProcessing, run: currentRun)
    }

    // MARK: - Mic

    private func handleMic(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat, converter: AVAudioConverter) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = buffer.frameLength
        // Voice processing can hand us several channels; channel 0 is the processed mic.
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames) else { return }
        mono.frameLength = frames
        mono.floatChannelData![0].update(from: channel, count: Int(frames))

        let ratio = micFormat.sampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        if micMuted || (!voiceProcessing && isPlaying) {
            levels.mic = 0
            onMicSamples?([Float](repeating: 0, count: samples.count))
            return
        }
        levels.mic = AudioLevels.rms(samples)
        onMicSamples?(Array(samples))
    }

    // MARK: - Speaker

    func play(_ samples: [Float]) {
        guard isRunning, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: speakerFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        if !isPlaying { prepareEchoCancellation() }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        lock.lock()
        pendingBuffers += 1
        let generation = playbackGeneration
        lock.unlock()

        queue.async { [self] in
            lock.lock()
            let stale = generation != playbackGeneration
            lock.unlock()
            guard !stale else { return }
            guard startPlayer() else { return finishBuffer(generation, scheduled: false) }
            lock.lock()
            scheduledBuffers += 1
            lock.unlock()
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.finishBuffer(generation, scheduled: true)
            }
        }
    }

    private func finishBuffer(_ generation: Int, scheduled: Bool) {
        lock.lock()
        guard generation == playbackGeneration else { lock.unlock(); return }
        pendingBuffers -= 1
        if scheduled { scheduledBuffers -= 1 }
        let drained = pendingBuffers == 0
        lock.unlock()
        if drained { onPlaybackDrained?() }
    }

    /// On `queue`. AVAudioPlayerNode raises an Objective-C exception, which would crash
    /// the app, if the engine stopped underneath it (say, while the output device
    /// reconfigures). If that happens, restart the engine once and try again.
    private func startPlayer() -> Bool {
        func tryStart() -> Bool {
            guard engine.isRunning else { return false }
            if player.isPlaying { return true }
            return STMCatchException { player.play() } == nil
        }
        if tryStart() { return true }
        guard isRunning else { return false }
        teardown()
        rebuild(voiceProcessing: engineVoiceProcessing, run: currentRun)
        return tryStart()
    }

    /// Forgets every buffer handed to `play`, so their completions are ignored.
    private func flushPlayback() {
        lock.lock()
        playbackGeneration += 1
        pendingBuffers = 0
        scheduledBuffers = 0
        lock.unlock()
    }

    /// Immediately silences the assistant (used for barge-in). Audio still waiting on
    /// `queue` is dropped, and the player stops as soon as the queue gets to it.
    func stopPlayback() {
        flushPlayback()
        queue.async { [self] in player.stop() }
    }
}

/// Thread-safe loudness values (0…1), written by audio threads and read by the UI every frame.
final class AudioLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var _mic: Float = 0
    private var _speaker: Float = 0

    var mic: Float {
        get { lock.lock(); defer { lock.unlock() }; return _mic }
        set { lock.lock(); _mic = newValue; lock.unlock() }
    }

    var speaker: Float {
        get { lock.lock(); defer { lock.unlock() }; return _speaker }
        set { lock.lock(); _speaker = newValue; lock.unlock() }
    }

    /// RMS mapped to a perceptual 0…1 range (≈ -50 dB → 0, ≈ -10 dB → 1).
    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let db = 20 * log10(max(sqrt(sum / Float(samples.count)), 1e-6))
        return min(1, max(0, (db + 50) / 40))
    }
}

enum AudioIOError: LocalizedError {
    case badFormat
    case noInput

    var errorDescription: String? {
        switch self {
        case .badFormat: return "Unsupported microphone format"
        case .noInput: return "The microphone didn't start"
        }
    }
}

/// A serial worker for the engine: blocks run one after another, in order, on one thread
/// that runs a run loop. Voice processing (AUVoiceIO) started from a plain dispatch queue
/// reports that it's running but never delivers audio; it needs a run loop like the main thread's.
private final class EngineThread: Thread, @unchecked Sendable {
    private var runLoop: CFRunLoop!
    private let started = DispatchSemaphore(value: 0)

    override init() {
        super.init()
        name = "AudioIO"
        qualityOfService = .userInteractive
        start()
        started.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A run loop with nothing to watch returns at once; this port keeps it alive.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        started.signal()
        while true { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
    }

    func async(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}
