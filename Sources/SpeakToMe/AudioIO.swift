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
/// Call everything except the mic/levels callbacks on the main thread.
final class AudioIO {
    static let micSampleRate: Double = 16_000
    static let speakerSampleRate: Double = 24_000

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let speakerFormat = AVAudioFormat(standardFormatWithSampleRate: speakerSampleRate, channels: 1)!
    private let micFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: micSampleRate, channels: 1, interleaved: false)!

    /// Bumped on every `stopPlayback()` so completions from flushed buffers are ignored.
    private var playbackGeneration = 0
    private let lock = NSLock()
    private var pendingBuffers = 0

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

    private(set) var isRunning = false
    private(set) var micEnabled = false
    /// You want to be able to talk over replies (the setting).
    private var echoCancellationWanted = false
    /// Voice processing is on right now. Without it the mic would hear the assistant
    /// through the speakers, so it delivers silence while a reply is playing.
    private var voiceProcessing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _voiceProcessing }
        set { lock.lock(); _voiceProcessing = newValue; lock.unlock() }
    }
    private var _voiceProcessing = false
    var echoCancellationActive: Bool { voiceProcessing }
    private var echoCancellationOff: DispatchWorkItem?
    private var pendingRebuild: DispatchWorkItem?
    private var configurationObserver: NSObjectProtocol?

    /// While muted the mic keeps running but delivers silence, so the listener just hears a pause.
    var micMuted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _micMuted }
        set { lock.lock(); _micMuted = newValue; lock.unlock() }
    }
    private var _micMuted = false

    /// `withMic: false` sets up playback only (for typed messages), with no mic or
    /// echo cancellation, so no microphone permission is needed.
    func start(withMic: Bool = true, echoCancellation: Bool = true) throws {
        micEnabled = withMic
        echoCancellationWanted = withMic && echoCancellation
        try build(voiceProcessing: false)
    }

    private func build(voiceProcessing enabled: Bool) throws {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        voiceProcessing = enabled
        guard micEnabled else {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: speakerFormat)
            try startEngine()
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
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer, monoFormat: monoInput, converter: converter)
        }
        try startEngine()
    }

    private func startEngine() throws {
        engine.prepare()
        try engine.start()
        isRunning = true
        // The engine stops itself when the audio hardware changes (headphones, a new
        // output device, voice processing settling). Bring it back rather than going silent.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.engineConfigurationChanged() }

        // Installed after start so it can't disturb the voice-processing format negotiation.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData?[0] else { return }
            self.levels.speaker = AudioLevels.rms(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
    }

    private func teardown() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if micEnabled { engine.inputNode.removeTap(onBus: 0) }
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        // Otherwise the device stays in voice-processing mode and the next plain engine's mic is silent.
        if micEnabled, voiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        echoCancellationOff?.cancel()
        pendingRebuild?.cancel()
        stopPlayback()
        teardown()
        levels.mic = 0
        levels.speaker = 0
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
    /// anything still queued on the player would be lost.
    private func setVoiceProcessing(_ enabled: Bool) {
        guard isRunning, micEnabled, voiceProcessing != enabled, !isPlaying else { return }
        pendingRebuild?.cancel()
        teardown()
        rebuild(voiceProcessing: enabled, attemptsLeft: 15)
    }

    /// Right after voice processing shuts down, the output device briefly reports an
    /// invalid format and the engine won't start (-10875), so a failed build is retried
    /// for a few seconds.
    private func rebuild(voiceProcessing enabled: Bool, attemptsLeft: Int) {
        pendingRebuild = nil
        do {
            try build(voiceProcessing: enabled)
            return
        } catch {
            teardown()
        }
        guard attemptsLeft > 0 else { isRunning = false; return }
        let work = DispatchWorkItem { [weak self] in
            self?.rebuild(voiceProcessing: enabled, attemptsLeft: attemptsLeft - 1)
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func engineConfigurationChanged() {
        guard isRunning, !engine.isRunning else { return }
        // Whatever was queued is gone; let the session know the reply stopped.
        let wasPlaying = isPlaying
        stopPlayback()
        if wasPlaying { onPlaybackDrained?() }
        pendingRebuild?.cancel()
        teardown()
        rebuild(voiceProcessing: voiceProcessing, attemptsLeft: 15)
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
        if !isPlaying { prepareEchoCancellation() }
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: speakerFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard startPlayer() else { return }

        lock.lock()
        pendingBuffers += 1
        let generation = playbackGeneration
        lock.unlock()

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            guard generation == self.playbackGeneration else { self.lock.unlock(); return }
            self.pendingBuffers -= 1
            let drained = self.pendingBuffers == 0
            self.lock.unlock()
            if drained { self.onPlaybackDrained?() }
        }
    }

    /// AVAudioPlayerNode raises an Objective-C exception, which would crash the app, if
    /// the engine stopped underneath it (say, while the output device reconfigures).
    /// If that happens, restart the engine once and try again.
    private func startPlayer() -> Bool {
        func tryStart() -> Bool {
            guard engine.isRunning else { return false }
            if player.isPlaying { return true }
            return STMCatchException { player.play() } == nil
        }
        if tryStart() { return true }
        guard isRunning else { return false }
        pendingRebuild?.cancel()
        teardown()
        rebuild(voiceProcessing: voiceProcessing, attemptsLeft: 15)
        return tryStart()
    }

    /// Immediately silences the assistant (used for barge-in).
    func stopPlayback() {
        lock.lock()
        playbackGeneration += 1
        pendingBuffers = 0
        lock.unlock()
        player.stop()
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
    var errorDescription: String? { "Unsupported microphone format" }
}
