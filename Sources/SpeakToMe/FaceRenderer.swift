import AVFoundation
import AppKit
import MetalKit
import SwiftUI

/// Where the face sits. Stage is the main window, with the sky behind it; puck is the
/// floating face, just the head dissolving into a transparent window.
struct FaceLayout {
    enum Style { case stage, puck }

    var style: Style
    /// How much of the bottom the words take up. The face rises and shrinks to stay clear of them.
    var hush: CGFloat = 0
    /// The conversation is open, so the face shrinks to sit above it.
    var peek = false
}

/// A tiling cloud-like noise, made once. The shader reads it instead of computing noise for
/// every pixel, and the mist behind the controls is cut from the same pattern.
enum CloudNoise {
    static let size = 256

    static let pixels: [UInt8] = {
        var generator = SplitMix(state: 27)
        func lattice(_ cells: Int) -> [Double] { (0..<cells * cells).map { _ in Double.random(in: 0...1, using: &generator) } }
        let octaves = [(cells: 4, weight: 0.5), (cells: 8, weight: 0.26), (cells: 16, weight: 0.15), (cells: 32, weight: 0.09)]
            .map { (cells: $0.cells, weight: $0.weight, values: lattice($0.cells)) }
        var out = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                var sum = 0.0
                for octave in octaves {
                    let fx = Double(x) / Double(size) * Double(octave.cells), fy = Double(y) / Double(size) * Double(octave.cells)
                    let x0 = Int(fx), y0 = Int(fy)
                    let tx = smooth(fx - Double(x0)), ty = smooth(fy - Double(y0))
                    func at(_ i: Int, _ j: Int) -> Double { octave.values[(j % octave.cells) * octave.cells + i % octave.cells] }
                    let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * tx
                    let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * tx
                    sum += (top + (bottom - top) * ty) * octave.weight
                }
                out[y * size + x] = UInt8(min(255, max(0, (sum - 0.5) * 1.7 + 0.5) * 255))
            }
        }
        return out
    }()

    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// The persona: a looping film of the mask, played muted and handed to the shader a frame at a
/// time. Where its features sit was measured once on the film, in the shader's units around the
/// middle of the head.
final class PersonaFilm {
    /// The film's size in pixels, the middle of the head in it, and film pixels in one unit.
    private static let size = SIMD2<Float>(1280, 720)
    private static let middle = SIMD2<Float>(640, 392)
    private static let perUnit: Float = 1.3

    /// Where the voice leaves the mask, how far the jaw drops wide open, and how far down the chin is.
    static let mouth = SIMD4<Float>(0, 108, 26, 221)
    /// Each eye: x, y, half width, and how steeply it slants up towards the temple.
    static let eyeA = SIMD4<Float>(-61, 10, 38, 0.29)
    static let eyeB = SIMD4<Float>(61, 10, 38, -0.29)
    /// From head units to the film's texture coordinates: origin, then scale.
    static let map = SIMD4<Float>(middle.x / size.x, middle.y / size.y, perUnit / size.x, perUnit / size.y)

    /// A frame to show before the first decoded one, and in stills.
    let still: MTLTexture
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
    private let cache: CVMetalTextureCache
    private var current: (texture: MTLTexture, backing: CVMetalTexture)?
    private var watchers = Set<ObjectIdentifier>()
    private var pace: Float = 1

    init?(device: MTLDevice) {
        let bundled = Bundle.main.url(forResource: "persona", withExtension: "mp4")
        // Running from a checkout rather than the app bundle.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/persona.mp4")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil) else {
            print("Persona film unavailable")
            return nil
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // A calm moment, eyes lit, between the film's flares.
        var frame: CGImage?
        let done = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: CMTime(seconds: 1.9, preferredTimescale: 600)) { image, _, _ in
            frame = image
            done.signal()
        }
        done.wait()
        var made: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &made)
        guard let frame, let made,
              let still = try? MTKTextureLoader(device: device).newTexture(cgImage: frame, options: [
                  .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
              ])
        else {
            print("Persona film unreadable")
            return nil
        }
        self.still = still
        cache = made
        player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        // The looper plays copies of the item, and an output belongs to one item, so each copy gets its own.
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        for item in looper.loopingPlayerItems {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
            item.add(output)
            outputs[ObjectIdentifier(item)] = output
        }
        player.rate = 0
    }

    /// The newest frame, and what keeps it alive until the GPU is done with it.
    func frame() -> (texture: MTLTexture, backing: AnyObject?) {
        if let item = player.currentItem, let output = outputs[ObjectIdentifier(item)] {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                var made: CVMetalTexture?
                CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                                                          CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &made)
                if let made, let texture = CVMetalTextureGetTexture(made) { current = (texture, made) }
            }
        }
        return current.map { ($0.texture, $0.backing) } ?? (still, nil)
    }

    /// Plays while any view is drawing it, at the pace of the moment.
    func watch(_ on: Bool, by watcher: ObjectIdentifier) {
        if on { watchers.insert(watcher) } else { watchers.remove(watcher) }
        update()
    }

    func pace(_ rate: Float) {
        guard rate != pace else { return }
        pace = rate
        update()
    }

    private func update() {
        let rate = watchers.isEmpty ? 0 : pace
        if player.rate != rate { player.rate = rate }
    }
}

/// The apparition, the whole of it in one Metal fragment shader over the film, so it costs the
/// same however long the conversation runs, on the GPU the language model needs.
struct FaceView: NSViewRepresentable {
    let phase: VoiceSession.Phase
    let muted: Bool
    let levels: AudioLevels
    let layout: FaceLayout
    let paused: Bool
    let reduceMotion: Bool

    static var isAvailable: Bool { FaceRenderer.shared != nil }

    func makeNSView(context: Context) -> MTKView {
        let view = PassThroughMTKView(frame: .zero, device: FaceRenderer.shared?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.delegate = context.coordinator
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let drawer = context.coordinator
        drawer.phase = phase
        drawer.muted = muted
        drawer.levels = levels
        drawer.layout = layout
        FaceEngine.shared.reduceMotion = reduceMotion
        FaceRenderer.shared?.film.watch(!paused && !reduceMotion, by: ObjectIdentifier(drawer))
        view.preferredFramesPerSecond = Int((1 / Mood.frameInterval(for: phase)).rounded())
        if view.isPaused != paused { view.isPaused = paused }
        if paused { view.draw() } // something changed while it's holding still
    }

    static func dismantleNSView(_ view: MTKView, coordinator: FaceDrawer) {
        FaceRenderer.shared?.film.watch(false, by: ObjectIdentifier(coordinator))
    }

    func makeCoordinator() -> FaceDrawer { FaceDrawer(phase: phase, muted: muted, levels: levels, layout: layout) }

    /// Clicks go to the SwiftUI view around it (talk, drag the floating face).
    final class PassThroughMTKView: MTKView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Steps the engine every frame and hands it to the shader.
final class FaceDrawer: NSObject, MTKViewDelegate {
    var phase: VoiceSession.Phase
    var muted: Bool
    var levels: AudioLevels
    var layout: FaceLayout
    private var peekAmount: Double?
    private var hush: CGFloat?
    private var lastDraw: Double?

    init(phase: VoiceSession.Phase, muted: Bool, levels: AudioLevels, layout: FaceLayout) {
        self.phase = phase
        self.muted = muted
        self.levels = levels
        self.layout = layout
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = Date.timeIntervalSinceReferenceDate
        let engine = FaceEngine.shared
        let target = layout.peek ? 1.0 : 0.0
        let dt = min(0.1, now - (lastDraw ?? now))
        lastDraw = now
        peekAmount = peekAmount.map { $0 + (target - $0) * (1 - exp(-dt * 7)) } ?? target
        let scale = view.window?.backingScaleFactor ?? 2
        // The face makes room for the words without snapping.
        hush = hush.map { $0 + (layout.hush - $0) * CGFloat(1 - exp(-dt * 5)) } ?? layout.hush
        var eased = layout
        eased.hush = hush ?? layout.hush
        follow(pointerIn: view, layout: eased, peek: peekAmount ?? target, scale: scale)
        engine.step(phase: phase, muted: muted, levels: levels, now: now)
        FaceRenderer.shared?.film.pace(engine.mood.film)
        FaceRenderer.shared?.draw(engine, layout: eased, peek: peekAmount ?? target, scale: scale, in: view)
    }

    /// The eyes follow the pointer anywhere on screen.
    private func follow(pointerIn view: MTKView, layout: FaceLayout, peek: Double, scale: CGFloat) {
        guard let window = view.window else { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = view.convert(inWindow, from: nil)
        let frame = FaceRenderer.frame(in: view.drawableSize, layout: layout, peek: peek, scale: scale)
        let y = view.isFlipped ? local.y : view.bounds.height - local.y
        let dx = (local.x * scale - frame.center.x) / (frame.unit * 320)
        let dy = (y * scale - frame.center.y) / (frame.unit * 320)
        FaceEngine.shared.look(at: SIMD2(min(1, max(-1, dx)), min(1, max(-1, dy))))
    }
}

final class FaceRenderer {
    static let shared = FaceRenderer()

    let device: MTLDevice
    let film: PersonaFilm
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let rings: MTLTexture
    private let noise: MTLTexture
    private var ringBytes = [UInt8](repeating: 0, count: FaceEngine.ringSamples * 2)

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "faceVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "faceFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("Face shader unavailable: \(error)")
            return nil
        }
        let ring = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg8Unorm, width: FaceEngine.ringSamples, height: 1, mipmapped: false)
        let cloud = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: CloudNoise.size, height: CloudNoise.size, mipmapped: false)
        guard let rings = device.makeTexture(descriptor: ring), let noise = device.makeTexture(descriptor: cloud) else { return nil }
        CloudNoise.pixels.withUnsafeBytes {
            noise.replace(region: MTLRegionMake2D(0, 0, CloudNoise.size, CloudNoise.size), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: CloudNoise.size)
        }
        guard let film = PersonaFilm(device: device) else { return nil }
        self.device = device
        self.queue = queue
        self.rings = rings
        self.noise = noise
        self.film = film
    }

    /// Where the conversation's top edge sits when it's open, with the small face above it.
    static let sleeveTop = 170.0

    /// The head reaches this far above and below its centre, in the shader's units.
    private static let cloudAbove = 232.0, cloudBelow = 246.0

    /// The centre of the head and how many pixels one of its units takes. `size` is in pixels.
    static func frame(in size: CGSize, layout: FaceLayout, peek: Double, scale: CGFloat) -> (center: CGPoint, unit: Double) {
        let w = size.width, h = size.height, s = Double(scale)
        guard layout.style == .stage else {
            let unit = min(w, h) / 540
            return (CGPoint(x: w / 2, y: h / 2 + (cloudAbove - cloudBelow) / 2 * unit), unit)
        }
        let height = cloudAbove + cloudBelow
        let top = 44 * s
        let room = max(h - Double(layout.hush) * s - top - 12 * s, 200 * s)
        // Besides rising, it draws back as the words grow.
        let distance = 1 - 0.22 * min(1, max(0, (Double(layout.hush) - 130) / 170))
        let unit = min(w / 520, room / height, 1.45 * s) * distance
        let y = top + cloudAbove * unit + (room - height * unit) * 0.42
        let smallUnit = (sleeveTop - 36) * s / height
        let smallY = 36 * s + cloudAbove * smallUnit
        return (CGPoint(x: w / 2, y: y + (smallY - y) * peek), unit + (smallUnit - unit) * peek)
    }

    /// Matches `FaceUniforms` in the shader.
    private struct Uniforms {
        var size: SIMD2<Float>
        var center: SIMD2<Float>
        var gaze: SIMD2<Float>
        var film: SIMD4<Float>
        var scale: Float
        var unit: Float
        var time: Float
        var hushY: Float
        var tilt: Float
        var bob: Float
        var shudder: Float
        var jaw: Float
        var wide: Float
        var eye: Float
        var glow: Float
        var flare: Float
        var sparks: Float
        var thought: Float
        var light: Float
        var front: Float
        var frontStrength: Float
        var puck: Float
        var ringStrength: Float
        var sky: SIMD4<Float>
        var skyOld: SIMD4<Float>
        var said: SIMD4<Float>
        var heard: SIMD4<Float>
        var mouth: SIMD4<Float>
        var eyeA: SIMD4<Float>
        var eyeB: SIMD4<Float>
    }

    func draw(_ engine: FaceEngine, layout: FaceLayout, peek: Double, scale: CGFloat, in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        let frame = film.frame()
        encode(engine, layout: layout, peek: peek, size: view.drawableSize, scale: scale, film: frame.texture, into: encoder)
        let backing = frame.backing
        commands.addCompletedHandler { _ in withExtendedLifetime(backing) {} }
        commands.present(drawable)
        commands.commit()
    }

    /// One frame as an image, for `--snapshot` (ImageRenderer can't capture Metal).
    func image(of engine: FaceEngine, layout: FaceLayout, points: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(points.width * scale), height = Int(points.height * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(engine, layout: layout, peek: layout.peek ? 1 : 0,
               size: CGSize(width: width, height: height), scale: scale, film: film.still, into: encoder)
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)?.makeImage()
        }
    }

    private func encode(_ engine: FaceEngine, layout: FaceLayout, peek: Double, size: CGSize, scale: CGFloat,
                        film picture: MTLTexture, into encoder: MTLRenderCommandEncoder) {
        func vector(_ c: RGBA) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a)) }
        let s = Double(scale)
        let frame = Self.frame(in: size, layout: layout, peek: peek, scale: scale)

        ringBytes.withUnsafeMutableBytes { engine.fillRings($0) }
        ringBytes.withUnsafeBytes { raw in
            rings.replace(region: MTLRegionMake2D(0, 0, FaceEngine.ringSamples, 1), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: FaceEngine.ringSamples * 2)
        }

        var uniforms = Uniforms(
            size: SIMD2(Float(size.width), Float(size.height)),
            center: SIMD2(Float(frame.center.x), Float(frame.center.y)),
            gaze: SIMD2(Float(engine.gaze.x), Float(engine.gaze.y)),
            film: PersonaFilm.map,
            scale: Float(s),
            unit: Float(frame.unit),
            time: Float(engine.clock.truncatingRemainder(dividingBy: 3600)),
            hushY: layout.hush > 0 ? Float(size.height - Double(layout.hush) * s) : 0,
            tilt: Float(engine.tilt),
            bob: Float(engine.bob),
            shudder: Float(engine.startle),
            jaw: Float(engine.jaw),
            wide: Float(engine.wide),
            eye: Float(engine.eye),
            glow: Float(engine.glow),
            flare: engine.reduceMotion ? 0 : Float(engine.flare),
            sparks: engine.reduceMotion ? 0 : Float(max(engine.breath, engine.level * 0.6)),
            thought: Float(engine.recede),
            light: Float(engine.cloudLight),
            front: Float(engine.front * s),
            frontStrength: Float(engine.frontStrength),
            puck: layout.style == .puck ? 1 : 0,
            ringStrength: Float(max(0, 1 - peek * 2.5)), // too small and crowded above the conversation
            sky: vector(engine.mood.sky), skyOld: vector(engine.previousSky),
            said: vector(Mood.saidWave), heard: vector(Mood.heardWave),
            mouth: PersonaFilm.mouth, eyeA: PersonaFilm.eyeA, eyeB: PersonaFilm.eyeB)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(rings, index: 0)
        encoder.setFragmentTexture(noise, index: 1)
        encoder.setFragmentTexture(picture, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: Shader

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FaceUniforms {
        float2 size, center, gaze;
        float4 film;
        float scale, unit, time, hushY, tilt, bob, shudder, jaw, wide, eye, glow, flare, sparks,
              thought, light, front, frontStrength, puck, ringStrength;
        float4 sky, skyOld, said, heard, mouth, eyeA, eyeB;
    };

    vertex float4 faceVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    static float cover(float d, float aa) { return 1 - smoothstep(-aa, aa, d); }

    static float hash(float n) { return fract(sin(n * 12.9898) * 43758.5453); }
    static float hash2(float2 c) { return fract(sin(dot(c, float2(127.1, 311.7))) * 43758.5453); }

    /// The mask's lower plate, in head units: its top edge peaks at the bridge of the nose, dips
    /// to where the glow under each eye ends, and runs back up along that glow to the cheeks; its
    /// sides close in to the chin. Measured on the film.
    static float plateTop(float x) {
        float a = abs(x);
        return a < 56 ? 18 + 75 * pow(a / 56, 0.9) : 93 - (a - 56) * 0.46;
    }

    /// How much of the drop reaches this far out: at the cheeks the plate slides in under them.
    static float plateReach(float x) { return 1 - 0.85 * smoothstep(88.0, 128.0, abs(x)); }

    static float plateSide(float y) { return mix(122.0, 24.0, smoothstep(45.0, 220.0, y)); }

    static float plate(float2 q) {
        float inside = min(min(q.y - plateTop(q.x), plateSide(q.y) - abs(q.x)), 262 - q.y);
        return smoothstep(-1.2, 1.2, inside);
    }

    /// Sound in the sky: rings of the voice, spaced evenly, each as loud as the moment it left.
    static float ring(float distance, float theta, float loud, float travel, float time, float aa) {
        float bent = distance + loud * 11 * sin(theta * 7 + distance * 0.03 - time * 2.2);
        float gap = abs(fract(bent / 42 - travel) - 0.5) * 42;
        float width = 0.6 + loud * 2.4;
        return (1 - smoothstep(width * 0.2, width + 4.5, gap)) * smoothstep(0.03, 0.25, loud);
    }

    fragment float4 faceFragment(float4 position [[position]], constant FaceUniforms &u [[buffer(0)]],
                                 texture2d<float> rings [[texture(0)]], texture2d<float> noise [[texture(1)]],
                                 texture2d<float> film [[texture(2)]]) {
        constexpr sampler tile(filter::linear, address::repeat);
        constexpr sampler edge(filter::linear, address::clamp_to_edge);
        const float3 ice = float3(0.30, 0.78, 1.0);
        const float3 white = float3(0.86, 0.97, 1.0);
        float2 p = position.xy;
        float aa = 1.0 / u.unit;

        // Into the head's own space: it sways and bobs in front of the sky, and lurches at you
        // when you cut in, while the sky barely moves.
        float2 d = (p - u.center) / u.unit;
        float cs = cos(u.tilt), sn = sin(u.tilt);
        float2 f = float2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs);
        f.y -= u.bob;
        f /= 1 + 0.1 * u.shudder;
        float big = noise.sample(tile, d / 520 + float2(u.time * 0.009, u.time * 0.004)).r;
        float headR = length((d - float2(0, -6)) / float2(205, 246));
        float onHead = 1 - smoothstep(0.82, 1.08, headR);
        float2 g = mix(d / (1 + 0.035 * u.shudder), f, onHead);

        // The wave a phase change sends out of the mouth: the new light inside it, the old outside.
        float2 mouthAt = u.mouth.xy;
        float2 fromMouth = p - (u.center + float2(mouthAt.x * cs - mouthAt.y * sn, mouthAt.x * sn + mouthAt.y * cs) * u.unit);
        float wave = length(fromMouth);
        float passed = smoothstep(u.front - 26 * u.scale, u.front + 26 * u.scale, wave);
        float3 grade = mix(u.sky.rgb, u.skyOld.rgb, passed);

        // Under the words and behind the top bar the sky stays calm enough to read over.
        float hush = u.hushY > 0 ? mix(1.0, 0.25, smoothstep(u.hushY - 90 * u.scale, u.hushY, p.y)) : 1;
        hush *= mix(0.45, 1.0, smoothstep(56 * u.scale, 120 * u.scale, p.y));

        // The jaw: the whole lower plate of the mask, from the bridge of the nose to the chin, swings
        // down in one piece, a touch larger as it comes towards you and rocking a little as it talks.
        float opening = smoothstep(0.01, 0.06, u.jaw) * onHead;
        float drop = u.jaw * u.mouth.z * (1 + 0.3 * max(-u.wide, 0.0) - 0.15 * max(u.wide, 0.0));
        float rock = 0.02 * u.jaw * sin(u.time * 5.3);
        float2 pivot = float2(0, 120);
        float reachHere = plateReach(g.x);
        float2 q = g - float2(0, drop * reachHere) - pivot;
        q = float2(q.x * cos(rock) + q.y * sin(rock), -q.x * sin(rock) + q.y * cos(rock));
        q /= float2(1 + 0.04 * u.wide * u.jaw, 1 + 0.05 * u.jaw);
        float2 moved = q + pivot;
        float onPlate = plate(moved) * onHead;
        float leftBehind = plate(g) * (1 - onPlate) * step(g.y, plateTop(g.x) + drop * reachHere * 1.3 + 2) * opening;
        float2 s = mix(g, moved, onPlate);

        // The film, faded at its top and bottom into more of the same sky.
        float2 uv = u.film.xy + s * u.film.zw;
        float inFilm = smoothstep(0.0, 0.09, uv.y) * smoothstep(1.0, 0.955, uv.y) * smoothstep(0.0, 0.04, uv.x) * smoothstep(1.0, 0.96, uv.x);
        float3 picture = film.sample(edge, uv).rgb;
        float2 drift = float2(u.time * 0.004, u.time * 0.0015);
        float neb = noise.sample(tile, d / 640 + drift).r;
        float neb2 = noise.sample(tile, d / 250 - drift * 1.6).r;
        float band = exp(-pow((d.y - 10) / 210, 2.0));
        float3 space = float3(0.012, 0.026, 0.07)
            + float3(0.03, 0.10, 0.28) * smoothstep(0.3, 0.95, neb) * (0.3 + 0.7 * band)
            + float3(0.08, 0.24, 0.52) * smoothstep(0.55, 1.0, neb2) * band * 0.5;
        float2 cell = floor(p / (u.scale * 11));
        float2 at = float2(hash2(cell + 3.1), hash2(cell + 7.7));
        float star = (1 - smoothstep(0.0, 1.1 * u.scale, length(p - (cell + at) * u.scale * 11)))
            * step(0.93, hash2(cell)) * (0.45 + 0.55 * sin(u.time * (1.5 + 3 * at.x) + at.y * 30));
        space += white * star * 0.7;
        float3 color = mix(space, picture * 1.12, inFilm);

        // The mood colours the whole scene, and a thinking or sleeping head draws back into it.
        color *= grade * mix(1.0, u.light, onHead) * (1 - 0.35 * u.thought * onHead);

        // The eyes: blinking puts out the film's own light, and the glow rides on the voice.
        float glow = 0, core = 0;
        for (int i = 0; i < 2; i++) {
            float4 eye = i == 0 ? u.eyeA : u.eyeB;
            float c = cos(eye.w), n = sin(eye.w);
            float2 e = g - eye.xy;
            e = float2(e.x * c + e.y * n, -e.x * n + e.y * c);
            float tall = eye.z * 0.32;
            float almond = 1 - smoothstep(0.55, 1.0, length(e / float2(eye.z, tall * 1.4)));
            color *= mix(1.0, 0.2 + 0.8 * saturate(u.eye), almond);
            float2 hot = e - float2(u.gaze.x * eye.z * 0.25, u.gaze.y * tall * 0.5);
            float lid = max(saturate(u.eye), 0.04);
            core += exp(-dot(hot / float2(eye.z * 0.62, tall * 0.55 * lid), hot / float2(eye.z * 0.62, tall * 0.55 * lid)) * 1.6);
            glow += exp(-length(e / float2(eye.z * 1.5, eye.z * 0.95)) * 2.4);
        }
        float lit = u.glow * saturate(u.eye * 1.2) * (1 - u.thought * 0.5) * u.light;
        color += ice * glow * lit * 0.5 + (ice * 0.6 + white * 0.6) * core * lit;

        // The flare: a line of light through both eyes when the voice lands on something.
        float lineY = g.y - (u.eyeA.y + u.eyeB.y) / 2;
        float streak = exp(-abs(lineY) / (1.2 + 2.5 * u.flare)) * exp(-abs(g.x) / (80 + 520 * u.flare))
            + exp(-lineY * lineY / 400) * exp(-abs(g.x) / 240) * 0.25;
        color += mix(ice, white, 0.4) * streak * u.flare * 1.3 * hush;

        // The gap, as a real opening: the upper face's edge has a thickness, its underside showing
        // dark as the jaw drops; inside is a deep cavity lit softly from within; the plate's top
        // edge catches that light, and both edges darken into the crease.
        float shine = noise.sample(tile, float2(g.x / 40 - u.time * 0.8, g.y / 18)).r;
        float burn = (0.4 + 0.7 * saturate(u.glow)) * opening;
        float height = max(drop * reachHere, 0.5);
        float fromEdge = max(moved.y - plateTop(moved.x), 0.0);
        color *= 1 - 0.4 * exp(-fromEdge / 5) * onPlate * opening;
        color += ice * exp(-fromEdge / 1.6) * onPlate * burn * 0.28 * saturate(height / 4);
        if (leftBehind > 0) {
            float depth = g.y - plateTop(g.x);
            float t = saturate(depth / height);
            // The underside of the upper face: its own edge, seen from below, in shadow.
            float lip = min(height * 0.3, 3.5);
            float2 edgeAt = u.film.xy + float2(g.x, plateTop(g.x) - 1.5) * u.film.zw;
            float3 underside = film.sample(edge, edgeAt).rgb * 0.32 * (1 - 0.6 * saturate(depth / max(lip, 0.5)));
            float3 cavity = float3(0.004, 0.009, 0.022);
            cavity += ice * exp(-pow((t - 0.62) / 0.3, 2.0)) * (0.65 + 0.45 * shine) * burn * 0.55;
            cavity *= smoothstep(0.0, 0.35, t) * smoothstep(1.0, 0.82, t) * 0.8 + 0.2;
            float3 inside = mix(underside, cavity, smoothstep(lip * 0.6, lip * 1.4, depth));
            color = mix(color, inside, leftBehind);
        }
        // A little of the light spills out over the face above the gap.
        float above = plateTop(g.x) - g.y;
        color += ice * exp(-max(above, 0.0) / 9) * step(0.0, above) * smoothstep(0.0, 6.0, plateSide(g.y) - abs(g.x))
            * plateReach(g.x) * burn * saturate(height / 6) * 0.12;

        // Sparks blown off the head, as in the film, as hard as the reply speaks.
        float sparkle = 0;
        if (u.sparks > 0.02 && u.puck < 0.5) {
            for (int layer = 0; layer < 3; layer++) {
                float size = 9 + layer * 6;
                float2 q = float2(abs(g.x) - u.time * (34 + layer * 30) - layer * 31.0, g.y + layer * 17.0) / size;
                float2 c = floor(q);
                float2 at = float2(hash2(c + 1.7 + layer), hash2(c + 3.1 + layer)) - 0.5;
                float h = hash2(c + layer * 7.3);
                float spark = 1 - smoothstep(0.05, 0.16 + 0.08 * h, length(fract(q) - 0.5 - at * 0.6));
                float where = exp(-pow((g.y - 14) / (55 + 45 * layer), 2.0)) * smoothstep(80.0, 170.0, abs(g.x))
                    * exp(-abs(g.x) / (240 + 160 * u.sparks));
                sparkle += spark * step(1 - 0.5 * u.sparks, h) * where * (0.6 + 0.4 * sin(u.time * 7 + h * 40));
            }
        }
        color += mix(ice, white, 0.3) * sparkle * saturate(u.sparks * 1.6) * 1.1 * hush;

        // Voices ripple through the sky: the reply's out of the mouth, yours in towards it. Flattened,
        // like the light around the head.
        float2 flat = fromMouth * float2(1, 1.45);
        float reach = length(flat) / u.unit;
        float theta = atan2(flat.y, flat.x);
        float clear = 1 - smoothstep(0.0, 0.7, onHead);
        float along = saturate(reach / 720);
        float said = rings.sample(edge, float2(along, 0.5)).g;
        float heard = rings.sample(edge, float2(1 - along, 0.5)).r;
        if (u.puck < 0.5 && u.ringStrength > 0.01) {
            if (said > 0.02) color += u.said.rgb * ring(reach, theta, said, u.time * 3.8, u.time, aa) * hush * u.ringStrength * 0.55 * (1 - along * 0.85) * clear;
            if (heard > 0.02) color += u.heard.rgb * ring(reach, theta, heard, -u.time * 3.8, u.time, aa) * hush * u.ringStrength * 0.4 * (1 - along * 0.5) * clear;
        }
        color += ice * 0.3 * u.frontStrength * exp(-pow((wave - u.front) / (14 * u.scale), 2.0)) * hush;

        color *= mix(0.55, 1.0, hush);
        float visible = 1 - smoothstep(0.62, 1.0, headR + (big - 0.5) * 0.3);
        float alpha = u.puck > 0.5 ? smoothstep(0.0, 0.5, visible) : 1;
        return float4(color * alpha, alpha);
    }
    """
}
