import AVFoundation

/// Owns the single AVAudioEngine used for both the microphone and playback.
///
/// Voice processing is enabled on the input node, which turns on Apple's echo
/// canceller: the assistant's own voice (played through `player` on the same
/// engine) is subtracted from the mic signal, so you can interrupt it without
/// headphones.
final class AudioIO {
    static let micSampleRate: Double = 16_000
    static let speakerSampleRate: Double = 24_000

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let speakerFormat = AVAudioFormat(standardFormatWithSampleRate: speakerSampleRate, channels: 1)!
    private let micFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: micSampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    /// Bumped on every `stopPlayback()` so completions from flushed buffers are ignored.
    private var playbackGeneration = 0
    private let lock = NSLock()
    private var pendingBuffers = 0

    /// Called on the audio thread with 16 kHz mono samples.
    var onMicSamples: (([Float]) -> Void)?
    /// Called (on an arbitrary thread) when every scheduled buffer has finished playing.
    var onPlaybackDrained: (() -> Void)?

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingBuffers > 0
    }

    func start() throws {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        let input = engine.inputNode
        _ = engine.outputNode
        try input.setVoiceProcessingEnabled(true)

        // Voice processing changes the output unit's format; the mixer's implicit
        // link to it is stale, and the engine fails to start (-10875) unless we
        // reconnect it explicitly with the new format. Read the format before touching
        // `mainMixerNode`: creating the mixer rewires the output and changes it.
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: speakerFormat)

        let inputFormat = input.outputFormat(forBus: 0)
        guard let monoInput = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)
        else { throw AudioIOError.badFormat }
        converter = AVAudioConverter(from: monoInput, to: micFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer, monoFormat: monoInput)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        stopPlayback()
        engine.stop()
    }

    // MARK: - Mic

    private func handleMic(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) {
        guard let converter, let channel = buffer.floatChannelData?[0] else { return }
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
        onMicSamples?(Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength))))
    }

    // MARK: - Speaker

    func play(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: speakerFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

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
        if !player.isPlaying { player.play() }
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

enum AudioIOError: LocalizedError {
    case badFormat
    var errorDescription: String? { "Unsupported microphone format" }
}
