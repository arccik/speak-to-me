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

/// The apparition, the whole of it in one Metal fragment shader, so it costs the same however
/// long the conversation runs, on the GPU the language model needs.
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
        view.preferredFramesPerSecond = Int((1 / Mood.frameInterval(for: phase)).rounded())
        if view.isPaused != paused { view.isPaused = paused }
        if paused { view.draw() } // something changed while it's holding still
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
        self.device = device
        self.queue = queue
        self.rings = rings
        self.noise = noise
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
        var scale: Float
        var unit: Float
        var time: Float
        var hushY: Float
        var tilt: Float
        var bob: Float
        var swell: Float
        var shudder: Float
        var jaw: Float
        var wide: Float
        var teeth: Float
        var smile: Float
        var eye: Float
        var browLeft: Float
        var browRight: Float
        var browTilt: Float
        var thought: Float
        var breath: Float
        var cloudLight: Float
        var front: Float
        var frontStrength: Float
        var puck: Float
        var ringStrength: Float
        var sky: SIMD4<Float>
        var skyOld: SIMD4<Float>
        var you: SIMD4<Float>
        var reply: SIMD4<Float>
    }

    func draw(_ engine: FaceEngine, layout: FaceLayout, peek: Double, scale: CGFloat, in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        encode(engine, layout: layout, peek: peek, size: view.drawableSize, scale: scale, into: encoder)
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
               size: CGSize(width: width, height: height), scale: scale, into: encoder)
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
                        into encoder: MTLRenderCommandEncoder) {
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
            scale: Float(s),
            unit: Float(frame.unit),
            time: Float(engine.clock.truncatingRemainder(dividingBy: 3600)),
            hushY: layout.hush > 0 ? Float(size.height - Double(layout.hush) * s) : 0,
            tilt: Float(engine.tilt),
            bob: Float(engine.bob),
            swell: engine.reduceMotion ? 0 : Float(engine.level),
            shudder: Float(engine.startle),
            jaw: Float(engine.jaw),
            wide: Float(engine.wide),
            teeth: Float(engine.teeth),
            smile: Float(engine.smile),
            eye: Float(engine.eye),
            browLeft: Float(engine.browLeft),
            browRight: Float(engine.browRight),
            browTilt: Float(engine.browTilt),
            thought: Float(engine.recede),
            breath: engine.reduceMotion ? 0 : Float(engine.breath),
            cloudLight: Float(engine.cloudLight),
            front: Float(engine.front * s),
            frontStrength: Float(engine.frontStrength),
            puck: layout.style == .puck ? 1 : 0,
            ringStrength: Float(max(0, 1 - peek * 2.5)), // too small and crowded above the conversation
            sky: vector(engine.mood.sky), skyOld: vector(engine.previousSky),
            you: vector(Mood.youInk), reply: vector(Mood.replyInk))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(rings, index: 0)
        encoder.setFragmentTexture(noise, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: Shader

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FaceUniforms {
        float2 size, center, gaze;
        float scale, unit, time, hushY, tilt, bob, swell, shudder, jaw, wide, teeth, smile, eye,
              browLeft, browRight, browTilt, thought, breath, cloudLight, front, frontStrength, puck, ringStrength;
        float4 sky, skyOld, you, reply;
    };

    vertex float4 faceVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    static float cover(float d, float aa) { return 1 - smoothstep(-aa, aa, d); }

    static float ellipse(float2 p, float2 r) {
        return (length(p / r) - 1) * min(r.x, r.y);
    }

    static float bump(float2 p, float2 c, float2 r, float a) {
        float2 d = (p - c) / r;
        return a * exp(-dot(d, d));
    }

    static float hash(float n) { return fract(sin(n * 12.9898) * 43758.5453); }

    /// The shape of the head: how far each point stands out, from skull to creases.
    /// The left and right of the face mirror each other, with a rounded seam down the middle.
    static float relief(float2 f, constant FaceUniforms &u, float2 mouth, float2 mouthSize) {
        float2 a = float2(sqrt(f.x * f.x + 40), f.y);
        float lift = mix(u.browLeft, u.browRight, smoothstep(-40.0, 40.0, f.x));
        float drop = u.jaw * 30;
        float h = bump(f, float2(0, -10), float2(132, 192 + drop * 0.5), 1);
        h -= bump(a, float2(122, -70), float2(26, 46), 0.16); // temples
        h += bump(a, float2(52, -84 - lift * 9 + (a.x - 50) * u.browTilt * 0.25), float2(46, 12), 0.2); // brow ridge
        h -= bump(a, float2(13, -70), float2(5, 16), 0.05); // the frown between the brows
        h -= bump(a, float2(58, -46), float2(31, 21), 0.5); // sockets
        h += bump(a, float2(58, -46), float2(19, 10), 0.13); // the eyeball under the lids
        h += bump(a, float2(60, -17), float2(27, 7), 0.05) - bump(a, float2(50, -26), float2(25, 5), 0.05); // bags and troughs
        h += bump(f, float2(0, -20), float2(10, 42), 0.14) + bump(f, float2(0, 34), float2(13, 11), 0.2); // bridge and tip
        float2 sides = float2(abs(f.x), f.y);
        h += bump(sides, float2(16, 40), float2(8, 7), 0.08) - bump(sides, float2(9.5, 47), float2(4.5, 3), 0.13); // wings and nostrils
        h -= bump(f, float2(0, 66), float2(3.5, 10), 0.03); // philtrum
        h += bump(a, float2(88, 12), float2(30, 15), 0.17) - bump(a, float2(84, 68 + drop * 0.3), float2(26, 38), 0.25); // cheekbones and hollows
        // The crease from the nose to the corner of the mouth.
        float2 fold = a - float2(22, 44), along = float2(mouthSize.x + 8, mouth.y - 44) - float2(22, 0);
        float crease = length(fold - along * saturate(dot(fold, along) / dot(along, along)));
        h -= 0.03 * exp(-crease * crease / 70);
        h += bump(f, float2(0, 172 + drop), float2(34, 20), 0.16) + bump(a, float2(96, 150 + drop * 0.6), float2(22, 40), 0.05); // chin and jaw
        h += bump(f, mouth, mouthSize + float2(9, 7), 0.06);
        h -= bump(f, mouth, mouthSize * 0.85 + float2(0, 1), 0.08 + 0.3 * u.jaw);
        return h;
    }

    /// Sound in the sky: rings of the voice, spaced evenly, each as loud as the moment it left.
    static float ring(float distance, float theta, float loud, float travel, float time, float aa) {
        float bent = distance + loud * 11 * sin(theta * 7 + distance * 0.03 - time * 2.2);
        float gap = abs(fract(bent / 42 - travel) - 0.5) * 42;
        float width = 0.8 + loud * 3.4;
        return (1 - smoothstep(width * 0.2, width + 3.5, gap)) * smoothstep(0.03, 0.25, loud);
    }

    fragment float4 faceFragment(float4 position [[position]], constant FaceUniforms &u [[buffer(0)]],
                                 texture2d<float> rings [[texture(0)]], texture2d<float> noise [[texture(1)]]) {
        constexpr sampler tile(filter::linear, address::repeat);
        constexpr sampler edge(filter::linear, address::clamp_to_edge);
        const float3 mist = float3(0.55, 0.59, 0.66);
        float2 p = position.xy;
        float aa = 1.0 / u.unit;

        // Into the head's own space: it hangs almost still, and lurches at you when you cut in.
        float2 d = (p - u.center) / u.unit;
        float cs = cos(u.tilt), sn = sin(u.tilt);
        float2 f = float2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs);
        f.y -= u.bob;
        f /= 1 + 0.1 * u.shudder;

        float2 mouthAt = float2(0, 102);
        float2 fromMouth = p - (u.center + float2(mouthAt.x * cs - mouthAt.y * sn, mouthAt.x * sn + mouthAt.y * cs) * u.unit);
        float reach = length(fromMouth) / u.unit;
        float theta = atan2(fromMouth.y, fromMouth.x);

        // The wave a phase change sends out of the mouth: new dark inside it, old outside.
        float wave = length(fromMouth);
        float passed = smoothstep(u.front - 26 * u.scale, u.front + 26 * u.scale, wave);
        float3 sky = mix(u.sky.rgb, u.skyOld.rgb, passed);

        // Under the words and behind the top bar the dark stays calm enough to read over.
        float hush = u.hushY > 0 ? mix(1.0, 0.2, smoothstep(u.hushY - 70 * u.scale, u.hushY, p.y)) : 1;
        hush *= mix(0.12, 1.0, smoothstep(64 * u.scale, 112 * u.scale, p.y));
        float3 color = sky;

        float big = noise.sample(tile, f / 520 + float2(u.time * 0.009, u.time * 0.004)).r;
        float fine = noise.sample(tile, f / 170 - float2(u.time * 0.014, 0)).r;

        // Fog on the ground, thickening towards the bottom.
        float2 hazeAt = p / (u.scale * 700);
        float haze = noise.sample(tile, hazeAt + float2(u.time * 0.006, 0)).r;
        haze = smoothstep(0.38, 0.9, haze) * (0.05 + 0.16 * smoothstep(u.size.y * 0.3, u.size.y, p.y));
        color = mix(color, mist, haze * mix(0.45, 1.0, hush));

        color += mist * 0.1 * u.frontStrength * exp(-pow((wave - u.front) / (16 * u.scale), 2.0)) * hush;

        // The head: lit from one side, dissolving at its edges, sinking back while it thinks or sleeps.
        float wideness = u.wide;
        float mouthW = 42 + 17 * wideness + u.jaw * 5;
        // It opens further than a jaw should.
        float mouthH = 1.7 + u.jaw * (58 - 22 * max(wideness, 0.0) - 12 * max(-wideness, 0.0));
        // The upper lip barely moves; the jaw does the opening.
        float2 mouthCentre = mouthAt + float2(0, mouthH * 0.65);
        float2 mouthSize = float2(mouthW, mouthH);

        float visible = 0;
        // No real face is symmetrical: this one is slightly askew, one eye lower than the other.
        float2 w = f + float2(sin(f.y * 0.017 + 1.3) * 5, sin(f.x * 0.021) * 3 + f.x * 0.035);
        if (abs(f.x) < 290 && abs(f.y) < 330) {
            float h = relief(w, u, mouthCentre, mouthSize);
            float2 slope = float2(relief(w + float2(3, 0), u, mouthCentre, mouthSize) - h,
                                  relief(w + float2(0, 3), u, mouthCentre, mouthSize) - h) / 3;
            // Skin: pores and blotches from the noise, and lines across the forehead.
            float pore = noise.sample(tile, f / 90).r;
            float lump = noise.sample(tile, f / 340).r;
            slope += float2(noise.sample(tile, (f + float2(14, 0)) / 340).r - lump,
                            noise.sample(tile, (f + float2(0, 14)) / 340).r - lump) * 0.012;
            float lines = smoothstep(-175.0, -130.0, f.y) * (1 - smoothstep(-112.0, -90.0, f.y)) * (1 - smoothstep(60.0, 110.0, abs(f.x)));
            slope.y += cos(f.y * 0.3 + big * 14 + f.x * f.x * 0.0006) * 0.0016 * lines;
            float3 normal = normalize(float3(-slope * 88, 1));
            float3 toLight = normalize(float3(-0.8, -0.42, 0.44)); // from one side, leaving the far half in shadow
            float diffuse = saturate(dot(normal, toLight));
            float tone = 0.045 + 1.02 * pow(diffuse, 1.6);
            // A little colder light from below, so the shadows never quite go flat.
            float under = saturate(dot(normal, float3(0.2, 0.8, 0.55)));
            // The sockets fall away into real dark.
            float2 wm = float2(abs(w.x), w.y);
            tone *= 1 - bump(wm, float2(58, -47), float2(32, 22), 0.62);
            tone *= 1 - bump(wm, float2(9.5, 47), float2(5, 3.4), 0.95); // the nostrils stay black
            tone *= 0.88 + (pore - 0.5) * 0.4;
            float blotch = noise.sample(tile, f / 620 + float2(3.1, 0.7)).r;
            float3 flesh = mix(float3(0.66, 0.62, 0.55), float3(0.47, 0.41, 0.42), smoothstep(0.32, 0.8, blotch));
            // Waxy sheen where the light glances off.
            float sheen = pow(saturate(dot(normal, normalize(toLight + float3(0, 0, 1)))), 34.0);
            float3 skin = (flesh * tone + float3(0.06, 0.08, 0.1) * under + float3(0.26, 0.26, 0.25) * sheen) * u.cloudLight;
            visible = smoothstep(0.1, 0.36, h + (big - 0.5) * 0.2) * (1 - u.thought * 0.5);
            color = mix(color, skin, visible);

            // The mouth: lips around a dark cavity, teeth that stay the same size however
            // far it opens, so the lips and jaw reveal them rather than stretch them.
            float2 m = f - mouthCentre;
            float corner = saturate(abs(m.x) / mouthW);
            // A sneer: one corner hitches higher than the other.
            float curve = u.smile * (0.45 - corner * corner) * 12 * (1 - saturate(u.jaw * 2.2)) - m.x * 0.05;
            float y = m.y - curve;
            // Lips, not an oval: corners taper to points, the top dips at the centre, the edge is uneven.
            float bow = y < 0 ? 1 - 0.14 * exp(-m.x * m.x / 90) : 1.0;
            float shapeX = pow(max(abs(m.x) / mouthW, 0.0001), 1.55);
            float shapeY = y / (mouthH * bow);
            float mouthD = (sqrt(shapeX * shapeX * 1 + shapeY * shapeY) - 1) * min(mouthW, mouthH + 8) * 0.7 + (fine - 0.5) * 2.2;
            // The skin bunches and darkens around it.
            color *= 1 - 0.5 * exp(-max(mouthD, 0.0) / 6) * visible;

            // Thin, cracked lips, pulled back from the teeth.
            float lipSide = smoothstep(-3.0, 3.0, y);
            float lipWidth = mix(2.8, 5.2, lipSide) * (1 - corner * corner * 0.75);
            float lip = cover(mouthD - lipWidth, 1.4) * visible;
            float crack = smoothstep(0.62, 0.8, noise.sample(tile, float2(f.x / 7, f.y / 46)).r);
            float3 lipTone = color * mix(0.5, 0.85, lipSide) * (1 - crack * 0.15) + float3(0.016, 0.006, 0.008); // the colour of dead skin, not lipstick
            color = mix(color, lipTone, lip);

            float inside = cover(mouthD, 1.3) * visible;
            if (inside > 0) {
                // Wet flesh near the edges, falling away to a black throat.
                float throat = saturate(-mouthD / max(min(mouthW, mouthH) * 0.62, 1.0));
                float3 mouth = mix(float3(0.085, 0.03, 0.035), float3(0.006, 0.002, 0.003), smoothstep(0.1, 0.8, throat));
                mouth *= 0.75 + 0.5 * fine;

                // The tongue, lying low in the dark.
                float2 tongueAt = float2(m.x, y - mouthH * 0.6);
                float tongue = cover(ellipse(tongueAt, float2(min(mouthW * 0.58, 26.0), max(mouthH * 0.32, 0.5))), 2.0);
                float3 tongueTone = float3(0.17, 0.06, 0.075) * (0.5 + 0.6 * saturate(-tongueAt.y / max(mouthH * 0.32, 1.0)));
                mouth = mix(mouth, tongueTone, tongue * smoothstep(0.2, 0.45, u.jaw));

                // Teeth on an arch: the same size however far it opens, so the lips reveal them.
                float dental = saturate(abs(m.x) / 56);
                float arc = asin(clamp(m.x / 56, -1.0, 1.0));
                float arch = 1 - dental * dental * 0.8;
                float upperRoot = mouthAt.y - 4 - mouthCentre.y - dental * dental * 7 + sin(arc * 9) * 1.6;

                // Dark gums, showing above the teeth when the lip pulls back.
                float gums = 1 - smoothstep(upperRoot + 2, upperRoot + 5, m.y);
                mouth = mix(mouth, float3(0.2, 0.04, 0.05) * arch * (0.6 + 0.8 * fine), gums);
                float lowerRoot = mouthH - 4 - dental * dental * 3 + sin(arc * 11 + 2) * 1.3;
                float lowerGums = smoothstep(lowerRoot - 2, lowerRoot + 1, y);
                mouth = mix(mouth, float3(0.14, 0.03, 0.035) * arch, lowerGums);

                // Each tooth its own: long or short, leaning, some rotten, a few gone. They come
                // to points, with black between them.
                float warp = arc * 6.6 + sin(arc * 13) * 0.35;
                for (int row = 0; row < 2; row++) {
                    if (row == 1 && mouthH < 7) continue; // nothing to see of them yet
                    float phase = row == 0 ? warp + (m.y - upperRoot) * 0.012 * sin(floor(warp) * 2.7)
                                           : warp * 1.14 + 0.4 - (lowerRoot - y) * 0.016 * sin(floor(warp * 1.14 + 0.4) * 1.9);
                    float id = floor(phase) + float(row) * 37;
                    float luck = hash(id + 3);
                    float side = (fract(phase) - 0.5) * 2;
                    float length = (row == 0 ? 19.0 : 12.5) * (0.62 + 0.62 * luck);
                    if (hash(id + 11) < 0.13) continue; // missing
                    // How far this column of the tooth reaches from its root, tapering to a point.
                    float point = mix(1.3, 3.4, hash(id + 41));
                    float taper = length * (1 - pow(abs(side), point)) * arch;
                    if (hash(id + 53) > 0.68) taper = min(taper, length * 0.52 + side * 2.5); // snapped off
                    float from = row == 0 ? m.y - upperRoot : lowerRoot - y;
                    float tooth = (1 - smoothstep(taper - 0.9, taper + 0.9, from)) * smoothstep(-0.5, 0.5, from);
                    tooth *= 1 - smoothstep(0.86, 1.0, abs(side));
                    if (tooth <= 0) continue;
                    float along = saturate(from / max(length, 1.0));
                    float rot = hash(id + 23);
                    float3 enamel = mix(float3(0.74, 0.67, 0.47), float3(0.4, 0.28, 0.13), smoothstep(0.35, 0.95, rot));
                    enamel = mix(float3(0.13, 0.08, 0.04), enamel, smoothstep(0.02, 0.4, along)); // stained at the gum
                    float grime = noise.sample(tile, float2(f.x / 48, f.y / 70)).r;
                    enamel *= 0.72 + 0.5 * grime;
                    enamel = mix(enamel, float3(0.05, 0.03, 0.02), smoothstep(0.62, 0.72, grime) * smoothstep(0.45, 0.8, rot)); // decay
                    enamel *= 1 - abs(side) * abs(side) * 0.6; // round across its face
                    enamel += float3(0.3) * pow(saturate(1 - abs(side + 0.3) * 3), 3.0) * (1 - along) * (row == 0 ? 1.0 : 0.5); // wet
                    float rowLight = row == 0 ? mix(0.5, 1.0, smoothstep(0.0, 0.5, along)) : 0.72;
                    mouth = mix(mouth, enamel * arch * rowLight * u.cloudLight, tooth);
                }
                mouth *= smoothstep(0.0, 0.05, u.jaw) * 0.85 + 0.15;
                // The far side of the mouth falls into the same shadow as the far side of the face.
                mouth *= mix(0.32, 1.0, 1 - smoothstep(-34.0, 30.0, w.x));
                color = mix(color, mouth, inside);
            }

            // Fog drifting across the face, in front of it.
            float veil = noise.sample(tile, f / 340 + float2(-u.time * 0.012, u.time * 0.005)).r;
            color = mix(color, mist * 0.42, smoothstep(0.52, 0.88, veil) * 0.26 * saturate(visible * 1.5));
        }

        // Voices disturb the fog: the reply's ripples leave the mouth, yours close in on it.
        float clear = 1 - smoothstep(0.0, 0.8, visible); // thinning out as they reach the face
        float along = saturate(reach / 720);
        float said = rings.sample(edge, float2(along, 0.5)).g;
        float heard = rings.sample(edge, float2(1 - along, 0.5)).r;
        if (u.puck < 0.5 && u.ringStrength > 0.01) {
            if (said > 0.02) color = mix(color, u.reply.rgb, ring(reach, theta, said, u.time * 3.8, u.time, aa) * hush * u.ringStrength * 0.3 * (1 - along * 0.85) * clear);
            if (heard > 0.02) color = mix(color, u.you.rgb, ring(reach, theta, heard, -u.time * 3.8, u.time, aa) * hush * u.ringStrength * 0.22 * (1 - along * 0.5) * clear);
        }

        // The eyes, deep in the sockets: wet, bloodshot, with a milky iris and a pinprick pupil.
        // They're drawn in front of the fog, so they look through it.
        float side = f.x < 0 ? -1 : 1;
        float2 e = float2(abs(w.x) - 58, w.y + 46);
        float across = saturate(abs(e.x) / 21);
        float lidUp = (7.6 * u.eye + 0.2) * (1 - across * across); // heavy lids, cutting off the top of the iris
        float lidDown = (6.5 * u.eye + 0.2) * (1 - across * across);
        float eyeOpen = cover(abs(e.y) - (e.y < 0 ? lidUp : lidDown), 1.2) * (1 - step(1.0, across)) * smoothstep(0.03, 0.14, u.eye);
        // The lid's thickness: a dark line above, a raw wet rim below.
        float lidEdge = abs(e.y) - (e.y < 0 ? lidUp : lidDown);
        if (across < 1) {
            float near = exp(-max(lidEdge, 0.0) / 2.2) * saturate(visible * 1.8);
            color = e.y < 0 ? color * (1 - near * 0.8) : mix(color, float3(0.2, 0.12, 0.11) * u.cloudLight, near * 0.4);
        }
        if (eyeOpen > 0) {
            float3 white = float3(0.56, 0.52, 0.43) * (1 - across * across * 0.6);
            float vein = smoothstep(0.5, 0.68, noise.sample(tile, float2(e.y / 22 + side, e.x / 110)).r);
            white = mix(white, float3(0.33, 0.13, 0.11), saturate(across * across * 0.7 + vein * (0.25 + across * 0.75)));
            float2 irisAt = float2(e.x * side, e.y) - float2(u.gaze.x * 9, u.gaze.y * 7);
            float irisD = length(irisAt);
            float cloudy = noise.sample(tile, irisAt / 42 + side).r;
            float3 eyeball = mix(white, float3(0.17, 0.17, 0.16), cover(irisD - 7.2, 2.0) * 0.8); // a blurred ring, not a line
            eyeball = mix(eyeball, mix(float3(0.72, 0.71, 0.66), float3(0.43, 0.43, 0.41), saturate(irisD / 6.5 + (cloudy - 0.5))), cover(irisD - 6.1, 1.6));
            eyeball = mix(eyeball, float3(0.02), cover(irisD - 1.5 - saturate(u.eye - 1) * 0.4, 0.9) * mix(0.55, 1.0, cloudy)); // milk across the pupil
            eyeball *= mix(0.2, 1.0, smoothstep(-lidUp, -lidUp + 8, e.y)); // the lid's shadow
            float2 glint = (irisAt - float2(-3.2, -1.2)) * float2(0.7, 1.5);
            eyeball += float3(0.55) * cover(length(glint) - 1.1 - (fine - 0.5) * 1.2, 0.8); // wet, and not quite round
            color = mix(color, eyeball * (1 - u.thought * 0.3) * u.cloudLight, eyeOpen * saturate(visible * 1.8));
        }

        // Breath: cold mist falling from the mouth, only as strong as the voice.
        if (u.breath > 0.02 && u.puck < 0.5) {
            float2 b = f - mouthCentre - float2(0, mouthH);
            float spread = 26 + max(b.y, 0.0) * 0.5;
            float plume = 1 - smoothstep(spread * 0.15, spread, abs(b.x + sin(b.y * 0.018 + u.time) * 12));
            float falling = noise.sample(tile, float2(f.x / 190, f.y / 240 - u.time * 0.24)).r;
            float cloud = plume * smoothstep(0.36, 0.76, falling) * exp(-max(b.y, 0.0) / 120) * smoothstep(-6, 12, b.y);
            color = mix(color, mist * 1.15, saturate(cloud * u.breath * 1.5) * 0.85 * hush);
        }

        float alpha = u.puck > 0.5 ? smoothstep(0.0, 0.55, visible) : 1;
        return float4(color * alpha, alpha);
    }
    """
}
