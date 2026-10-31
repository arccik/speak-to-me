import Foundation
import MLX
import MLXLinalg

/// F5-TTS v1 (a flow-matching mel generator) and its Vocos vocoder, on MLX. Ported from
/// lucasnewman's MIT-licensed f5-tts-mlx and vocos-mlx. It's inference only, so the layers
/// are plain structs over the checkpoint's arrays, addressed by the checkpoint's own names.
///
/// Runs in its own process (see `F5Worker`), on the GPU, so its gigabyte or two is gone
/// again as soon as another model is chosen.
final class F5TTS {
    enum F5Error: LocalizedError {
        case missingWeight(String)
        case tooLong

        var errorDescription: String? {
            switch self {
            case .missingWeight(let name): return "The F5-TTS download is incomplete (no \(name))"
            case .tooLong: return "Too long for F5-TTS to say in one go"
            }
        }
    }

    static let sampleRate = 24_000
    private static let hopLength = 256
    private static let melCount = 100
    /// The furthest its position embeddings reach, about 44 s including the reference.
    private static let maxFrames = 4096

    private let vocabulary: [Unicode.Scalar: Int32]
    private let transformer: DiT
    private let vocoder: Vocos

    init(checkpoint: URL, vocabulary vocabularyFile: URL, vocoder vocoderFile: URL) throws {
        // Scalars, not Characters: Swift would count the Kelvin sign and K as the same one.
        var vocabulary: [Unicode.Scalar: Int32] = [:]
        // The file has Windows line endings, which Swift won't split on "\n".
        for (index, entry) in try String(contentsOf: vocabularyFile, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n").enumerated() where entry.unicodeScalars.count == 1 {
            vocabulary[entry.unicodeScalars.first!] = Int32(index)
        }
        self.vocabulary = vocabulary
        transformer = try DiT(Weights(try loadArrays(url: checkpoint), prefix: "ema_model.transformer."))
        vocoder = try Vocos(Weights(try loadArrays(url: vocoderFile), prefix: ""))
    }

    /// A reference clip of the voice to speak in, already turned into mel frames.
    struct Reference {
        let mel: MLXArray
        let samples: Int
        let text: String
    }

    func reference(samples: [Float], text: String) -> Reference {
        var audio = MLXArray(samples)
        let rms = sqrt(mean(square(audio))).item(Float.self)
        if rms < 0.1, rms > 0 { audio = audio * (0.1 / rms) }
        let mel = LogMel.spectrogram(audio.asArray(Float.self))
        eval(mel)
        return Reference(mel: mel, samples: samples.count, text: text)
    }

    /// `steps` trades speed for quality: 16 is the fewest that stays clean.
    func speak(_ text: String, reference: Reference, speed: Float = 1, steps: Int = 16, seed: UInt64? = nil) throws -> [Float] {
        let characters = (reference.text + " " + text).precomposedStringWithCanonicalMapping.unicodeScalars
        let tokens = MLXArray(characters.map { vocabulary[$0] ?? 0 })
        let referenceFrames = reference.mel.dim(1)
        let textBytes = Float(text.utf8.count), referenceBytes = Float(reference.text.utf8.count)
        // The reference's speaking rate, carried over to the new text.
        let estimate = referenceFrames + Int(Float(referenceFrames) / referenceBytes * textBytes / speed)
        let conditioned = max(characters.count, referenceFrames)
        let frames = max(conditioned + 1, estimate)
        guard frames <= Self.maxFrames else { throw F5Error.tooLong }

        let cond = MLX.padded(reference.mel, widths: [0, .init((0, frames - referenceFrames)), 0])
        let keep = expandedDimensions(MLXArray(0..<frames) .< conditioned, axes: [0, 2])
        let stepCond = which(keep, cond, MLXArray.zeros(like: cond))

        // Guided and blank together, as a batch of two: quicker on the GPU than one by one.
        let spoken = transformer.conditioning(tokens: tokens, frames: frames, dropped: false)
        let blank = transformer.conditioning(tokens: tokens, frames: frames, dropped: true)
        let bothText = concatenated([spoken, blank], axis: 0)
        let bothCond = concatenated([stepCond, MLXArray.zeros(like: stepCond)], axis: 0)
        let rope = transformer.rotaryPositions(frames)

        if let seed { MLXRandom.seed(seed) }
        var y = MLXRandom.normal([Self.melCount, frames]).transposed()[.newAxis]

        // Sway sampling (coefficient -1) spends the steps early on, where they matter most.
        let t = linspace(Float(0), Float(1), count: steps)
        let times = 1 - cos(Float.pi / 2 * t)
        for i in 0..<(steps - 1) {
            let time = transformer.timeEmbedding(times[i][.newAxis])
            let both = transformer(
                concatenated([y, y], axis: 0), cond: bothCond, text: bothText,
                time: concatenated([time, time], axis: 0), rope: rope)
            let flows = both.split(parts: 2, axis: 0)
            // Classifier-free guidance, strength 2.
            y = y + (times[i + 1] - times[i]) * (flows[0] + (flows[0] - flows[1]) * 2)
            eval(y)
        }

        let mel = which(keep, cond, y)
        return Array(vocoder.decode(mel).dropFirst(reference.samples))
    }
}

/// A checkpoint's arrays, for looking up by name.
private struct Weights {
    let arrays: [String: MLXArray]
    let prefix: String

    init(_ arrays: [String: MLXArray], prefix: String) {
        self.arrays = arrays
        self.prefix = prefix
    }

    func callAsFunction(_ name: String) throws -> MLXArray {
        guard let array = arrays[prefix + name] else { throw F5TTS.F5Error.missingWeight(name) }
        return array
    }

    func scoped(_ name: String) -> Weights {
        Weights(arrays, prefix: prefix + name + ".")
    }
}

// MARK: - Layers

private struct Dense {
    let weight: MLXArray, bias: MLXArray

    init(_ weights: Weights) throws {
        weight = try weights("weight").T
        bias = try weights("bias")
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { matmul(x, weight) + bias }
}

private struct Conv {
    let weight: MLXArray, bias: MLXArray, padding: Int, groups: Int

    /// Checkpoints hold PyTorch's (out, in, width); MLX wants (out, width, in).
    init(_ weights: Weights, padding: Int, groups: Int) throws {
        weight = try weights("weight").swappedAxes(1, 2)
        bias = try weights("bias")
        self.padding = padding
        self.groups = groups
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        conv1d(x, weight, padding: padding, groups: groups) + bias
    }
}

private func layerNorm(_ x: MLXArray) -> MLXArray {
    MLXFast.layerNorm(x, weight: nil, bias: nil, eps: 1e-6)
}

private struct Norm {
    let weight: MLXArray, bias: MLXArray

    init(_ weights: Weights) throws {
        weight = try weights("weight")
        bias = try weights("bias")
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { MLXFast.layerNorm(x, weight: weight, bias: bias, eps: 1e-6) }
}

private func silu(_ x: MLXArray) -> MLXArray { x * sigmoid(x) }
private func mish(_ x: MLXArray) -> MLXArray { x * tanh(logAddExp(x, MLXArray(Float(0)))) }
private func gelu(_ x: MLXArray) -> MLXArray { x * (1 + erf(x / Float(2).squareRoot())) / 2 }
private func geluTanh(_ x: MLXArray) -> MLXArray {
    x * (1 + tanh(Float(2 / Double.pi).squareRoot() * (x + 0.044715 * x * x * x))) / 2
}

// MARK: - The transformer

private struct DiT {
    let timeIn: Dense, timeOut: Dense
    let textEmbedding: MLXArray
    let textBlocks: [TextBlock]
    let inputProjection: Dense, positionConv1: Conv, positionConv2: Conv
    let blocks: [Block]
    let finalLinear: Dense, output: Dense
    /// Sinusoidal text positions, (4096, 512).
    let textPositions: MLXArray

    private static let attentionHeadSize = 64

    init(_ weights: Weights) throws {
        let time = weights.scoped("time_embed.time_mlp")
        timeIn = try Dense(time.scoped("0"))
        timeOut = try Dense(time.scoped("2"))
        let text = weights.scoped("text_embed")
        textEmbedding = try text("text_embed.weight")
        textBlocks = try (0..<4).map { try TextBlock(text.scoped("text_blocks.\($0)")) }
        let input = weights.scoped("input_embed")
        inputProjection = try Dense(input.scoped("proj"))
        positionConv1 = try Conv(input.scoped("conv_pos_embed.conv1d.0"), padding: 15, groups: 16)
        positionConv2 = try Conv(input.scoped("conv_pos_embed.conv1d.2"), padding: 15, groups: 16)
        blocks = try (0..<22).map { try Block(weights.scoped("transformer_blocks.\($0)")) }
        finalLinear = try Dense(weights.scoped("norm_out.linear"))
        output = try Dense(weights.scoped("proj_out"))

        let dim = textEmbedding.dim(1)
        let frequencies = 1 / pow(Float(10_000), MLXArray(stride(from: 0, to: dim, by: 2).map(Float.init)) / Float(dim))
        let angles = outer(MLXArray(0..<4096).asType(.float32), frequencies)
        textPositions = concatenated([cos(angles), sin(angles)], axis: -1)
    }

    /// The text's embedding, or (`dropped`) the blank one of the same length that guidance
    /// compares it to. Stays the same through every step of a sentence, so it's worked out once.
    func conditioning(tokens: MLXArray, frames: Int, dropped: Bool) -> MLXArray {
        // Token 0 is padding. Text beyond the last frame is cut off.
        var ids = MLXArray.zeros([frames], type: Int32.self)
        let count = min(tokens.dim(0), frames)
        ids[0..<count] = tokens[0..<count] + 1
        let mask = ids .== 0
        if dropped { ids = MLXArray.zeros(like: ids) }
        let textMask = mask[.newAxis, 0..., .newAxis]
        var x = textEmbedding[ids][.newAxis] + textPositions[0..<frames][.newAxis]
        x = which(textMask, MLXArray.zeros(like: x), x)
        for block in textBlocks {
            x = block(x)
            x = which(textMask, MLXArray.zeros(like: x), x)
        }
        eval(x)
        return x
    }

    func timeEmbedding(_ time: MLXArray) -> MLXArray {
        let half = 128
        let rate = log(Float(10_000)) / Float(half - 1)
        let exponents = exp(MLXArray(0..<half).asType(.float32) * -rate)
        let angles = 1000 * expandedDimensions(time, axis: 1) * expandedDimensions(exponents, axis: 0)
        let hidden = concatenated([sin(angles), cos(angles)], axis: -1)
        return timeOut(silu(timeIn(hidden)))
    }

    /// Positions for attention, (frames, 64), each frequency twice.
    func rotaryPositions(_ frames: Int) -> MLXArray {
        let size = Self.attentionHeadSize
        let inverse = 1 / pow(Float(10_000), MLXArray(stride(from: 0, to: size, by: 2).map(Float.init)) / Float(size))
        let angles = outer(MLXArray(0..<frames).asType(.float32), inverse)
        return stacked([angles, angles], axis: -1).reshaped([frames, size])
    }

    func callAsFunction(_ noisy: MLXArray, cond: MLXArray, text: MLXArray, time: MLXArray, rope: MLXArray) -> MLXArray {
        var x = inputProjection(concatenated([noisy, cond, text], axis: -1))
        x = mish(positionConv2(mish(positionConv1(x)))) + x
        let cosines = cos(rope), sines = sin(rope)
        for block in blocks {
            x = block(x, time: time, cosines: cosines, sines: sines)
        }
        let modulation = finalLinear(silu(time)).split(parts: 2, axis: 1)
        x = layerNorm(x) * (1 + expandedDimensions(modulation[0], axis: 1)) + expandedDimensions(modulation[1], axis: 1)
        return output(x)
    }
}

/// ConvNeXt v2, which reads the text.
private struct TextBlock {
    let conv: Conv, norm: Norm, up: Dense, down: Dense
    let gamma: MLXArray, beta: MLXArray

    init(_ weights: Weights) throws {
        conv = try Conv(weights.scoped("dwconv"), padding: 3, groups: 512)
        norm = try Norm(weights.scoped("norm"))
        up = try Dense(weights.scoped("pwconv1"))
        down = try Dense(weights.scoped("pwconv2"))
        gamma = try weights("grn.gamma")
        beta = try weights("grn.beta")
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        var x = gelu(up(norm(conv(input))))
        // Global response normalization.
        let g = MLXLinalg.norm(x, ord: 2, axis: 1, keepDims: true)
        let n = g / (mean(g, axis: -1, keepDims: true) + 1e-6)
        x = gamma * (x * n) + beta + x
        return input + down(x)
    }
}

private struct Block {
    let modulation: Dense
    let toQ: Dense, toK: Dense, toV: Dense, toOut: Dense
    let feedIn: Dense, feedOut: Dense

    private static let heads = 16
    private static let scale = 1 / Float(64).squareRoot()

    init(_ weights: Weights) throws {
        modulation = try Dense(weights.scoped("attn_norm.linear"))
        let attention = weights.scoped("attn")
        toQ = try Dense(attention.scoped("to_q"))
        toK = try Dense(attention.scoped("to_k"))
        toV = try Dense(attention.scoped("to_v"))
        toOut = try Dense(attention.scoped("to_out.0"))
        feedIn = try Dense(weights.scoped("ff.ff.0.0"))
        feedOut = try Dense(weights.scoped("ff.ff.2"))
    }

    private func heads(_ x: MLXArray) -> MLXArray {
        x.reshaped([x.dim(0), x.dim(1), Self.heads, -1]).transposed(0, 2, 1, 3)
    }

    private func rotated(_ x: MLXArray, cosines: MLXArray, sines: MLXArray) -> MLXArray {
        // Swap each pair (a, b) for (-b, a).
        let pairs = x.reshaped(Array(x.shape.dropLast()) + [-1, 2])
        let half = stacked([-pairs[.ellipsis, 1], pairs[.ellipsis, 0]], axis: -1).reshaped(x.shape)
        return x * cosines + half * sines
    }

    func callAsFunction(_ input: MLXArray, time: MLXArray, cosines: MLXArray, sines: MLXArray) -> MLXArray {
        let m = modulation(silu(time)).split(parts: 6, axis: 1).map { expandedDimensions($0, axis: 1) }
        let (shiftAttention, scaleAttention, gateAttention) = (m[0], m[1], m[2])
        let (shiftFeed, scaleFeed, gateFeed) = (m[3], m[4], m[5])

        let normed = layerNorm(input) * (1 + scaleAttention) + shiftAttention
        let query = rotated(heads(toQ(normed)), cosines: cosines, sines: sines)
        let key = rotated(heads(toK(normed)), cosines: cosines, sines: sines)
        let attended = MLXFast.scaledDotProductAttention(
            queries: query, keys: key, values: heads(toV(normed)), scale: Self.scale, mask: nil)
        let merged = attended.transposed(0, 2, 1, 3).reshaped([input.dim(0), input.dim(1), -1])
        let x = input + gateAttention * toOut(merged)

        let feed = layerNorm(x) * (1 + scaleFeed) + shiftFeed
        return x + gateFeed * feedOut(geluTanh(feedIn(feed)))
    }
}

// MARK: - The vocoder

/// Turns mel frames into a waveform.
private struct Vocos {
    let embed: Conv, norm: Norm
    let blocks: [VocosBlock]
    let finalNorm: Norm, head: Dense

    private static let fftSize = 1024
    private static let hopLength = 256

    init(_ weights: Weights) throws {
        let backbone = weights.scoped("backbone")
        embed = try Conv(backbone.scoped("embed"), padding: 3, groups: 1)
        norm = try Norm(backbone.scoped("norm"))
        blocks = try (0..<8).map { try VocosBlock(backbone.scoped("convnext.\($0)")) }
        finalNorm = try Norm(backbone.scoped("final_layer_norm"))
        head = try Dense(weights.scoped("head.out"))
    }

    func decode(_ mel: MLXArray) -> [Float] {
        var x = norm(embed(mel))
        for block in blocks { x = block(x) }
        let parts = head(finalNorm(x)).split(parts: 2, axis: -1)
        let magnitude = minimum(exp(parts[0]), MLXArray(Float(100)))
        let spectrum = magnitude * cos(parts[1]) + magnitude * sin(parts[1]) * MLXArray(real: 0, imaginary: 1)
        // Vocos was trained with a symmetric window, unlike the spectrogram's periodic one.
        let window = (0..<Self.fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.fftSize - 1))) }
        let frames = (MLXFFT.irfft(spectrum[0], axis: -1) * MLXArray(window)).asArray(Float.self)

        // Overlap-add.
        let count = frames.count / Self.fftSize
        let length = (count - 1) * Self.hopLength + Self.fftSize
        var audio = [Float](repeating: 0, count: length), weights = audio
        for frame in 0..<count {
            let start = frame * Self.hopLength
            for i in 0..<Self.fftSize {
                audio[start + i] += frames[frame * Self.fftSize + i]
                weights[start + i] += window[i]
            }
        }
        for i in 0..<length where weights[i] != 0 { audio[i] /= weights[i] }
        return audio
    }
}

private struct VocosBlock {
    let conv: Conv, norm: Norm, up: Dense, down: Dense, gamma: MLXArray

    init(_ weights: Weights) throws {
        conv = try Conv(weights.scoped("dwconv"), padding: 3, groups: 512)
        norm = try Norm(weights.scoped("norm"))
        up = try Dense(weights.scoped("pwconv1"))
        down = try Dense(weights.scoped("pwconv2"))
        gamma = try weights("gamma")
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        input + gamma * down(gelu(up(norm(conv(input)))))
    }
}

// MARK: - Log-mel spectrogram

enum LogMel {
    private static let fftSize = 1024
    private static let hopLength = 256
    private static let melCount = 100

    /// Periodic Hann window.
    private static func window(_ size: Int) -> [Float] {
        (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
    }

    /// HTK triangular filters, (mels, bins).
    private static func filters() -> MLXArray {
        let bins = fftSize / 2 + 1
        func mel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func hz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }
        let top = mel(Double(F5TTS.sampleRate) / 2)
        let points = (0..<(melCount + 2)).map { hz(top * Double($0) / Double(melCount + 1)) }
        var bank = [Float](repeating: 0, count: melCount * bins)
        for m in 0..<melCount {
            for b in 0..<bins {
                let f = Double(F5TTS.sampleRate / 2) * Double(b) / Double(bins - 1)
                let down = (f - points[m]) / (points[m + 1] - points[m])
                let up = (points[m + 2] - f) / (points[m + 2] - points[m + 1])
                bank[m * bins + b] = Float(max(0, min(down, up)))
            }
        }
        return MLXArray(bank, [melCount, bins])
    }

    /// (1, frames, 100) for 24 kHz mono samples, padded by half a window at both ends.
    static func spectrogram(_ samples: [Float]) -> MLXArray {
        let padding = fftSize / 2
        let audio = [Float](repeating: 0, count: padding) + samples + [Float](repeating: 0, count: padding)
        let count = (audio.count - fftSize + hopLength) / hopLength
        let hann = window(fftSize)
        var frames = [Float](repeating: 0, count: count * fftSize)
        for frame in 0..<count {
            for i in 0..<fftSize { frames[frame * fftSize + i] = audio[frame * hopLength + i] * hann[i] }
        }
        let spectrum = MLXFFT.rfft(MLXArray(frames, [count, fftSize]), axis: -1)
        let magnitudes = abs(spectrum[0..<(count - 1)])
        let mel = matmul(magnitudes, filters().T)
        return log(maximum(mel, MLXArray(Float(1e-5))))[.newAxis]
    }
}
