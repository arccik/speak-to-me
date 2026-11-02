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
        let unit = min(w / 520, room / height, 1.45 * s)
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

    /// The shape of the head, as if it were pushing through a sheet of fog: how far each point
    /// stands out. The left and right of the face mirror each other.
    static float relief(float2 f, constant FaceUniforms &u, float2 mouth, float2 mouthSize) {
        float2 a = float2(sqrt(f.x * f.x + 90), f.y); // rounded through the middle, so no crease
        float lift = mix(u.browLeft, u.browRight, smoothstep(-40.0, 40.0, f.x));
        float h = bump(f, float2(0, -10), float2(138, 196), 1);
        h += bump(a, float2(50, -78 - lift * 9 + (a.x - 50) * u.browTilt * 0.25), float2(50, 15), 0.15);
        h -= bump(a, float2(58, -40), float2(33, 25), 0.42);
        h += bump(f, float2(0, -5), float2(12, 52), 0.15) + bump(f, float2(0, 40), float2(16, 13), 0.17);
        h += bump(a, float2(84, 22), float2(36, 20), 0.11) - bump(a, float2(84, 78), float2(28, 36), 0.13);
        h += bump(f, float2(0, 168), float2(40, 28), 0.14);
        h += bump(f, mouth, mouthSize + float2(13, 11), 0.1);
        h -= bump(f, mouth, mouthSize * 0.85 + float2(0, 1), 0.1 + 0.25 * u.jaw);
        return h;
    }

    /// Sound in the sky: rings of the voice, spaced evenly, each as loud as the moment it left.
    static float ring(float distance, float theta, float loud, float travel, float time, float aa) {
        float bent = distance + loud * 11 * sin(theta * 7 + distance * 0.03 - time * 2.2);
        float gap = abs(fract(bent / 42 - travel) - 0.5) * 42;
        float width = 0.7 + loud * 2.6;
        return (1 - smoothstep(width - aa, width + aa, gap)) * smoothstep(0.03, 0.2, loud);
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
        float mouthW = 40 + 17 * wideness + u.jaw * 4;
        float mouthH = 1.7 + u.jaw * (42 - 15 * max(wideness, 0.0) - 8 * max(-wideness, 0.0));
        // The upper lip barely moves; the jaw does the opening.
        float2 mouthCentre = mouthAt + float2(0, mouthH * 0.75);
        float2 mouthSize = float2(mouthW, mouthH);

        float visible = 0;
        if (abs(f.x) < 290 && abs(f.y) < 330) {
            float h = relief(f, u, mouthCentre, mouthSize);
            float2 slope = float2(relief(f + float2(3, 0), u, mouthCentre, mouthSize) - h,
                                  relief(f + float2(0, 3), u, mouthCentre, mouthSize) - h) / 3;
            float3 normal = normalize(float3(-slope * 74, 1));
            float diffuse = saturate(dot(normal, normalize(float3(-0.38, -0.72, 0.58))));
            float tone = 0.06 + 0.98 * pow(diffuse, 1.7);
            tone *= 0.86 + (noise.sample(tile, f / 300 + float2(u.time * 0.007, 0)).r - 0.5) * 0.3;
            // The sockets fall away into real dark.
            float2 mirrored = float2(abs(f.x), f.y);
            tone *= 1 - bump(mirrored, float2(58, -47), float2(31, 22), 0.92);
            // A little colder light from below, so the sockets never quite go flat.
            tone += 0.05 * saturate(dot(normal, float3(0.2, 0.8, 0.55)));
            float3 skin = float3(0.74, 0.77, 0.81) * tone * u.cloudLight;
            visible = smoothstep(0.08, 0.46, h + (big - 0.5) * 0.3) * (1 - u.thought * 0.62);
            color = mix(color, skin, visible);

            // The mouth: lips around a dark cavity, teeth that stay the same size however
            // far it opens, so the lips and jaw reveal them rather than stretch them.
            float2 m = f - mouthCentre;
            float corner = saturate(abs(m.x) / mouthW);
            float curve = u.smile * (0.45 - corner * corner) * 12 * (1 - saturate(u.jaw * 2.2));
            float y = m.y - curve;
            float mouthD = ellipse(float2(m.x, y), mouthSize);

            // Lips: the upper one faces down and stays in shadow, the fuller lower one catches the light.
            float lipSide = smoothstep(-3.0, 3.0, y);
            float lipWidth = mix(4.2, 7.5, lipSide) * (1 - corner * corner * 0.75);
            float lip = cover(mouthD - lipWidth, 1.8) * visible;
            float roll = saturate(1 - abs(mouthD - lipWidth * 0.45) / max(lipWidth * 0.6, 0.1));
            float3 lipTone = color * mix(0.62, 0.86, lipSide) + float3(0.05, 0.022, 0.026) * mix(0.5, 1.0, lipSide);
            lipTone += float3(0.05, 0.045, 0.045) * lipSide * roll;
            color = mix(color, lipTone, lip);

            float inside = cover(mouthD, 0.8 + min(mouthH * 0.05, 1.2)) * visible;
            if (inside > 0) {
                float open = saturate(y / max(mouthH, 1.0) * 0.5 + 0.5);
                float3 cavity = u.sky.rgb * 0.14 + float3(0.022, 0.012, 0.014) * (1 - open);

                // The tongue, lying low in the dark.
                float2 tongueAt = float2(m.x, y - mouthH * 0.62);
                float tongue = cover(ellipse(tongueAt, float2(min(mouthW * 0.62, 25.0), max(mouthH * 0.34, 0.5))), 2.0);
                float3 flesh = float3(0.2, 0.085, 0.095) * (0.55 + 0.6 * saturate(-tongueAt.y / max(mouthH * 0.34, 1.0)));
                cavity = mix(cavity, flesh, tongue * smoothstep(0.15, 0.4, u.jaw));

                // Teeth sit on an arch: narrower towards the corners, falling into shadow there.
                float dental = saturate(abs(m.x) / 54);
                float arc = asin(clamp(m.x / 54, -1.0, 1.0));
                float teethPhase = arc * 5.6;
                float within = abs(fract(teethPhase) - 0.5) * 2; // 0 mid-tooth, 1 at the gap
                float gapWidth = (0.3 + aa * 0.6) / 4.8; // half a unit or so, whatever the size on screen
                float gap = smoothstep(1 - gapWidth - 0.08, 1 - gapWidth + 0.08, within);
                float falloff = 1 - dental * dental * 0.78;
                float3 enamel = float3(0.86, 0.83, 0.72) * falloff * mix(0.82, 1.0, u.teeth) * u.cloudLight;

                // Uppers hang from a fixed line on the skull, each tooth's tip slightly rounded.
                float upperTip = mouthAt.y + 6 - mouthCentre.y - dental * dental * 6 - within * within * 1.6;
                float upper = (1 - smoothstep(upperTip - 0.7, upperTip + 0.7, m.y)) * (1 - smoothstep(0.9, 1.0, dental));
                float shade = mix(0.55, 1.0, smoothstep(upperTip - 13, upperTip - 6, m.y)); // the lip's shadow
                float3 uppers = enamel * shade * (1 - gap * 0.5);

                // Lowers ride on the jaw: smaller, tighter, half hidden by the lip.
                float lowPhase = arc * 7.0;
                float lowWithin = abs(fract(lowPhase) - 0.5) * 2;
                float lowGap = smoothstep(1 - gapWidth - 0.08, 1 - gapWidth + 0.08, lowWithin);
                float lowerTip = mouthH - 11 - dental * dental * 3 - lowWithin * lowWithin * 1.3;
                float lower = smoothstep(lowerTip - 0.7, lowerTip + 0.7, y) * (1 - smoothstep(0.72, 0.86, dental));
                float3 lowers = enamel * 0.8 * (1 - lowGap * 0.5) * mix(1.0, 0.6, saturate((y - lowerTip) / 11));

                float3 mouth = mix(cavity, lowers, lower * smoothstep(0.06, 0.14, u.jaw));
                mouth = mix(mouth, uppers, upper * smoothstep(0.03, 0.1, u.jaw));
                color = mix(color, mouth, inside);
            }

            // Fog drifting across the face, in front of it.
            float veil = noise.sample(tile, f / 340 + float2(-u.time * 0.012, u.time * 0.005)).r;
            color = mix(color, mist * 0.42, smoothstep(0.5, 0.86, veil) * 0.42 * saturate(visible * 1.5));
        }

        // Voices disturb the fog: the reply's ripples leave the mouth, yours close in on it.
        float clear = 1 - saturate(visible * 2.2); // never across the face
        float along = saturate(reach / 720);
        float said = rings.sample(edge, float2(along, 0.5)).g;
        float heard = rings.sample(edge, float2(1 - along, 0.5)).r;
        if (u.puck < 0.5 && u.ringStrength > 0.01) {
            if (said > 0.02) color = mix(color, u.reply.rgb, ring(reach, theta, said, u.time * 3.8, u.time, aa) * hush * u.ringStrength * 0.34 * (1 - along * 0.5) * clear);
            if (heard > 0.02) color = mix(color, u.you.rgb, ring(reach, theta, heard, -u.time * 3.8, u.time, aa) * hush * u.ringStrength * 0.34 * clear);
        }

        // Two points of light, deep in the sockets, that look through the fog at you.
        float side = f.x < 0 ? -1 : 1;
        float2 eyeAt = float2(abs(f.x) - 58, f.y + 49) - float2(u.gaze.x * side * 9, u.gaze.y * 7);
        float eyeDist = length(eyeAt);
        float eyeR = 2.4 + saturate(u.eye - 1) * 5;
        float light = (cover(eyeDist - eyeR, 0.9) + exp(-eyeDist / 8) * 0.3) * saturate(u.eye);
        color += float3(0.88, 0.93, 1.0) * light * (1 - u.thought * 0.45) * u.cloudLight;

        // Breath: cold mist falling from the mouth, only as strong as the voice.
        if (u.breath > 0.02 && u.puck < 0.5) {
            float2 b = f - mouthCentre - float2(0, mouthH);
            float spread = 26 + max(b.y, 0.0) * 0.5;
            float plume = 1 - smoothstep(spread * 0.15, spread, abs(b.x + sin(b.y * 0.018 + u.time) * 12));
            float falling = noise.sample(tile, float2(f.x / 190, f.y / 240 - u.time * 0.24)).r;
            float cloud = plume * smoothstep(0.36, 0.76, falling) * exp(-max(b.y, 0.0) / 120) * smoothstep(-6, 12, b.y);
            color = mix(color, mist, saturate(cloud * u.breath) * 0.55 * hush);
        }

        float alpha = u.puck > 0.5 ? saturate(visible * 1.8 + exp(-max(length(f / float2(170, 225)) - 1, 0.0) * 5) * 0.55) : 1;
        return float4(color * alpha, alpha);
    }
    """
}
