import AppKit
import MetalKit
import SwiftUI
import Vision

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

/// Where the features are in the portrait, in the shader's units around the middle of the head,
/// found once with Vision, so the mouth and eyes open where the photo's really are.
struct PortraitMap {
    var uvEye: SIMD2<Float>
    var uvX: SIMD2<Float>
    var uvY: SIMD2<Float>
    /// x, y, half width, and how far down the chin is.
    var mouth: SIMD4<Float>
    /// x, y, half width. The first eye's w holds the y the map's origin sits at.
    var eyeA: SIMD4<Float>
    var eyeB: SIMD4<Float>

    private static let eyeLineY: Float = -46
    private static let eyesToMouth: Float = 122

    static func load(device: MTLDevice) -> (texture: MTLTexture, map: PortraitMap)? {
        let bundled = Bundle.main.url(forResource: "persona", withExtension: "jpg")
        // Running from a checkout rather than the app bundle.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/persona.jpg")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil),
              let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let texture = try? MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
                  .SRGB: false, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft,
              ])
        else {
            print("Portrait unavailable")
            return nil
        }
        let size = SIMD2(Float(image.width), Float(image.height))
        // Positions measured on the shipped portrait, as a fraction of its size, in case Vision finds nothing.
        var left = SIMD2<Float>(0.463, 0.510), right = SIMD2<Float>(0.553, 0.510)
        var eyeWidths = SIMD2<Float>(0.0394, 0.0387)
        var lipsL = SIMD2<Float>(0.470, 0.709), lipsR = SIMD2<Float>(0.545, 0.702)
        var chin: Float = 0.847
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        // The portrait has a crowd behind the persona; the biggest face is the one that speaks.
        if let marks = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.landmarks,
           let eyeL = marks.leftEye, let eyeR = marks.rightEye, let lips = marks.outerLips, let contour = marks.faceContour {
            let extent = CGSize(width: image.width, height: image.height)
            func points(_ region: VNFaceLandmarkRegion2D) -> [SIMD2<Float>] {
                region.pointsInImage(imageSize: extent).map { SIMD2(Float($0.x) / size.x, 1 - Float($0.y) / size.y) }
            }
            func middle(_ list: [SIMD2<Float>]) -> SIMD2<Float> { list.reduce(.zero, +) / Float(list.count) }
            func span(_ list: [SIMD2<Float>]) -> Float { (list.map(\.x).max() ?? 0) - (list.map(\.x).min() ?? 0) }
            let a = points(eyeL), b = points(eyeR), m = points(lips)
            left = middle(a); right = middle(b)
            eyeWidths = SIMD2(span(a), span(b))
            lipsL = m.min { $0.x < $1.x } ?? lipsL
            lipsR = m.max { $0.x < $1.x } ?? lipsR
            chin = points(contour).map(\.y).max() ?? chin
        }
        // In pixels from here, so that a unit is square on the photo.
        let eyeMiddle = (left + right) / 2 * size
        let along = simd_normalize((right - left) * size)
        let down = SIMD2(-along.y, along.x)
        let lipMiddle = (lipsL + lipsR) / 2 * size
        let perUnit = simd_length(lipMiddle - eyeMiddle) / eyesToMouth // photo pixels in one unit
        func unit(_ fraction: SIMD2<Float>) -> SIMD2<Float> {
            let offset = fraction * size - eyeMiddle
            return SIMD2(simd_dot(offset, along), simd_dot(offset, down) + eyeLineY * perUnit) / perUnit
        }
        let mouth = unit((lipsL + lipsR) / 2)
        let a = unit(left), b = unit(right)
        let map = PortraitMap(
            uvEye: eyeMiddle / size,
            uvX: along * perUnit / size, uvY: down * perUnit / size,
            mouth: SIMD4(mouth.x, mouth.y, simd_length((lipsR - lipsL) * size) / 2 / perUnit, unit(SIMD2((lipsL.x + lipsR.x) / 2, chin)).y),
            eyeA: SIMD4(a.x, a.y, eyeWidths.x * size.x / 2 / perUnit, eyeLineY),
            eyeB: SIMD4(b.x, b.y, eyeWidths.y * size.x / 2 / perUnit, 0))
        return (texture, map)
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
    private let portrait: MTLTexture
    private let map: PortraitMap
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
        guard let persona = PortraitMap.load(device: device) else { return nil }
        self.device = device
        self.queue = queue
        self.rings = rings
        self.noise = noise
        portrait = persona.texture
        map = persona.map
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
        var uvEye: SIMD2<Float>
        var uvX: SIMD2<Float>
        var uvY: SIMD2<Float>
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
        var mouth: SIMD4<Float>
        var eyeA: SIMD4<Float>
        var eyeB: SIMD4<Float>
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
            uvEye: map.uvEye, uvX: map.uvX, uvY: map.uvY,
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
            you: vector(Mood.youInk), reply: vector(Mood.replyInk),
            mouth: map.mouth, eyeA: map.eyeA, eyeB: map.eyeB)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(rings, index: 0)
        encoder.setFragmentTexture(noise, index: 1)
        encoder.setFragmentTexture(portrait, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: Shader

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FaceUniforms {
        float2 size, center, gaze, uvEye, uvX, uvY;
        float scale, unit, time, hushY, tilt, bob, swell, shudder, jaw, wide, teeth, smile, eye,
              browLeft, browRight, browTilt, thought, breath, cloudLight, front, frontStrength, puck, ringStrength;
        float4 sky, skyOld, you, reply, mouth, eyeA, eyeB;
    };

    vertex float4 faceVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    static float cover(float d, float aa) { return 1 - smoothstep(-aa, aa, d); }

    static float ellipse(float2 p, float2 r) {
        return (length(p / r) - 1) * min(r.x, r.y);
    }

    static float hash(float n) { return fract(sin(n * 12.9898) * 43758.5453); }

    /// Sound in the sky: rings of the voice, spaced evenly, each as loud as the moment it left.
    static float ring(float distance, float theta, float loud, float travel, float time, float aa) {
        float bent = distance + loud * 11 * sin(theta * 7 + distance * 0.03 - time * 2.2);
        float gap = abs(fract(bent / 42 - travel) - 0.5) * 42;
        float width = 0.8 + loud * 3.4;
        return (1 - smoothstep(width * 0.2, width + 3.5, gap)) * smoothstep(0.03, 0.25, loud);
    }

    fragment float4 faceFragment(float4 position [[position]], constant FaceUniforms &u [[buffer(0)]],
                                 texture2d<float> rings [[texture(0)]], texture2d<float> noise [[texture(1)]],
                                 texture2d<float> portrait [[texture(2)]]) {
        constexpr sampler tile(filter::linear, address::repeat);
        constexpr sampler edge(filter::linear, address::clamp_to_edge);
        constexpr sampler photo(filter::linear, mip_filter::linear, address::clamp_to_edge);
        const float3 mist = float3(0.55, 0.59, 0.66);
        float2 p = position.xy;
        float aa = 1.0 / u.unit;

        // Into the head's own space: it hangs almost still, and lurches at you when you cut in.
        float2 d = (p - u.center) / u.unit;
        float cs = cos(u.tilt), sn = sin(u.tilt);
        float2 f = float2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs);
        f.y -= u.bob;
        f /= 1 + 0.1 * u.shudder;

        float2 mouthAt = u.mouth.xy;
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

        // The head dissolves into the fog at its edges.
        float reachOut = length((f - float2(0, -8)) / float2(222, 262)) + (big - 0.5) * 0.34;
        float visible = (1 - smoothstep(0.58, 1.02, reachOut)) * (1 - u.thought * 0.5);

        // The mouth opens as the real thing would: the upper lip barely rises, the jaw drops and
        // pulls the skin below it, the corners draw in or out with the sound.
        float W = u.mouth.z * (1 + 0.2 * u.wide + 0.06 * u.jaw);
        float2 dm = f - mouthAt;
        float lens = saturate(1 - (dm.x / W) * (dm.x / W));
        float open = u.jaw * W * (1.45 - 0.55 * max(u.wide, 0.0) - 0.35 * max(-u.wide, 0.0));
        float rise = open * 0.2, drop = open * 0.8;
        float jawReach = 1 - smoothstep(W * 0.5, W * 3.2, abs(dm.x));
        float fade = 1 - smoothstep(u.mouth.w + 10, u.mouth.w + 150, f.y);

        float2 s = f;
        if (dm.y > 0) {
            // Spread over far more distance than it moves, so the skin stretches instead of smearing.
            float past = smoothstep(0.0, 34.0 + drop * 2.6, dm.y - drop * lens);
            s.y -= drop * mix(lens, jawReach, past) * fade;
        } else {
            s.y += rise * lens * (1 - smoothstep(0.0, 24.0, -dm.y - rise * lens));
        }
        float near = 1 - smoothstep(0.0, W * 1.9, length(dm * float2(1, 0.8)));
        s.x = mix(s.x, mouthAt.x + dm.x * u.mouth.z / W, near);

        // The eyes: the photo's own irises shift to look at you, and its own lid closes over them.
        float eyeMask = 0;
        float2 glintAt = float2(1000);
        for (int i = 0; i < 2; i++) {
            float4 eye = i == 0 ? u.eyeA : u.eyeB;
            float2 e = f - eye.xy;
            float tall = eye.z * 0.46;
            float inAlmond = 1 - smoothstep(0.62, 1.0, length(e / float2(eye.z, tall)));
            if (inAlmond > 0) {
                s -= float2(u.gaze.x * eye.z * 0.34, u.gaze.y * tall * 0.55) * inAlmond;
                float shut = saturate(1 - u.eye);
                if (e.y < tall * (2 * shut - 1)) { s.y = eye.y - tall * 1.9 + (e.y + tall) * 0.3; inAlmond *= 1 - smoothstep(0.0, 0.2, shut); }
                eyeMask = max(eyeMask, inAlmond * smoothstep(0.03, 0.2, u.eye));
            }
            float2 toGlint = e - float2(u.gaze.x * eye.z * 0.34, u.gaze.y * tall * 0.55);
            if (length(toGlint) < length(glintAt)) glintAt = toGlint;
        }
        // The forehead rides up with the brows.
        float lift = mix(u.browLeft, u.browRight, smoothstep(-40.0, 40.0, f.x));
        s.y += lift * 7 * (1 - smoothstep(-40.0, -8.0, f.y - u.eyeA.y)) * smoothstep(-190.0, -90.0, f.y - u.eyeA.y);

        // Photo to the dark world: cold in shadow, bone in the light, deeper contrast, and the far
        // side of the head falling away.
        float2 uv = u.uvEye + (s.x - 0) * u.uvX + (s.y - u.eyeA.w) * u.uvY;
        float3 source = portrait.sample(photo, uv).rgb;
        float grey = dot(source, float3(0.3, 0.59, 0.11));
        grey = pow(saturate((grey - 0.05) * 1.3), 1.35);
        float3 skin = mix(float3(0.5, 0.58, 0.72), float3(0.98, 0.93, 0.8), smoothstep(0.1, 0.8, grey)) * grey;
        skin *= mix(0.42, 1.08, 1 - smoothstep(-70.0, 130.0, f.x));
        skin *= 0.94 + (fine - 0.5) * 0.14;
        skin *= u.cloudLight;
        if (eyeMask > 0) {
            // Milky over the iris, raw at the corners.
            float3 clouded = mix(skin, float3(0.72, 0.72, 0.66) * (0.38 + grey * 1.15), 0.62);
            float vein = smoothstep(0.5, 0.7, noise.sample(tile, f / 26).r);
            skin = mix(skin, mix(clouded, float3(0.42, 0.12, 0.1), vein * 0.28), eyeMask);
        }
        color = mix(color, skin, visible);

        // The opening itself, in place of the lips' parting line.
        float inTop = dm.y + rise * lens, inBottom = drop * lens - dm.y;
        float edgeD = -min(inTop, inBottom);
        color *= 1 - 0.42 * exp(-max(edgeD, 0.0) / 5) * smoothstep(0.0, 0.03, u.jaw) * lens * visible;
        float inside = cover(edgeD, 0.8) * step(0.01, lens) * visible * smoothstep(0.015, 0.05, u.jaw);
        if (inside > 0) {
            float scale = 42 / W;
            float2 t = dm * scale;
            float tH = (drop + rise) * scale;
            float depth = saturate(min(inTop, inBottom) * scale / max(tH * 0.42, 1.0));
            float3 mouth = mix(float3(0.085, 0.03, 0.035), float3(0.006, 0.002, 0.003), smoothstep(0.1, 0.8, depth));
            mouth *= 0.75 + 0.5 * fine;

            // The tongue, lying low in the dark.
            float2 tongueAt = float2(t.x, t.y - drop * scale * 0.72);
            float tongueSize = max(tH * 0.27, 0.5);
            float tongue = cover(ellipse(tongueAt, float2(26, tongueSize)), 2.0);
            mouth = mix(mouth, float3(0.17, 0.06, 0.075) * (0.5 + 0.6 * saturate(-tongueAt.y / tongueSize)), tongue * smoothstep(0.2, 0.45, u.jaw));

            // Teeth on an arch: the same size however far it opens, so the lips reveal them.
            float dental = saturate(abs(t.x) / 56);
            float arc = asin(clamp(t.x / 56, -1.0, 1.0));
            float arch = 1 - dental * dental * 0.8;
            float upperRoot = -rise * scale - 3 - dental * dental * 4 + sin(arc * 9) * 1.4;
            float lowerRoot = drop * scale * lens + 3 - dental * dental * 3 + sin(arc * 11 + 2) * 1.2;

            // Dark gums, showing above the teeth as the lip pulls back.
            mouth = mix(mouth, float3(0.2, 0.04, 0.05) * arch * (0.6 + 0.8 * fine), 1 - smoothstep(upperRoot + 3, upperRoot + 6, t.y));
            mouth = mix(mouth, float3(0.14, 0.03, 0.035) * arch, smoothstep(lowerRoot - 4, lowerRoot - 1, t.y));

            // Each tooth its own: long or short, leaning, some rotten, some snapped, a few gone.
            float warp = arc * 6.6 + sin(arc * 13) * 0.35;
            for (int row = 0; row < 2; row++) {
                if (row == 1 && tH < 7) continue; // nothing to see of them yet
                float phase = row == 0 ? warp + (t.y - upperRoot) * 0.012 * sin(floor(warp) * 2.7)
                                       : warp * 1.14 + 0.4 - (lowerRoot - t.y) * 0.016 * sin(floor(warp * 1.14 + 0.4) * 1.9);
                float id = floor(phase) + float(row) * 37;
                float luck = hash(id + 3);
                float across = (fract(phase) - 0.5) * 2;
                float length = (row == 0 ? 21.0 : 13.5) * (0.62 + 0.62 * luck);
                if (hash(id + 11) < 0.13) continue; // missing
                float point = mix(1.3, 3.4, hash(id + 41));
                float taper = length * (1 - pow(abs(across), point)) * arch;
                if (hash(id + 53) > 0.68) taper = min(taper, length * 0.52 + across * 2.5); // snapped off
                float from = row == 0 ? t.y - upperRoot : lowerRoot - t.y;
                float tooth = (1 - smoothstep(taper - 0.9, taper + 0.9, from)) * smoothstep(-0.5, 0.5, from);
                tooth *= 1 - smoothstep(0.86, 1.0, abs(across));
                if (tooth <= 0) continue;
                float along = saturate(from / max(length, 1.0));
                float rot = hash(id + 23);
                float3 enamel = mix(float3(0.74, 0.67, 0.47), float3(0.4, 0.28, 0.13), smoothstep(0.35, 0.95, rot));
                enamel = mix(float3(0.13, 0.08, 0.04), enamel, smoothstep(0.02, 0.4, along)); // stained at the gum
                float grime = noise.sample(tile, float2(t.x / 48, t.y / 70)).r;
                enamel *= 0.72 + 0.5 * grime;
                enamel = mix(enamel, float3(0.05, 0.03, 0.02), smoothstep(0.62, 0.72, grime) * smoothstep(0.45, 0.8, rot)); // decay
                enamel *= 1 - across * across * 0.6; // round across its face
                enamel += float3(0.3) * pow(saturate(1 - abs(across + 0.3) * 3), 3.0) * (1 - along) * (row == 0 ? 1.0 : 0.5); // wet
                float rowLight = row == 0 ? mix(0.5, 1.0, smoothstep(0.0, 0.5, along)) : 0.72;
                mouth = mix(mouth, enamel * arch * rowLight * u.cloudLight, tooth);
            }
            // In the same light as the photo: dim, cold in shadow, darker the less it opens,
            // and the far side falling away with the far side of the face.
            float tone = dot(mouth, float3(0.3, 0.59, 0.11));
            mouth = mix(mix(float3(0.5, 0.56, 0.68) * tone, mouth, 0.72), mouth, smoothstep(0.1, 0.5, tone));
            mouth *= 0.62 * mix(0.42, 1.0, 1 - smoothstep(-34.0, 60.0, f.x)) * (0.35 + 0.65 * smoothstep(0.0, 14.0, tH));
            mouth *= 1 - 0.55 * saturate(1 - min(inTop, inBottom) * scale / 7); // shadow under the lips
            color = mix(color, mouth, inside);
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

        // Fog drifting across the face, in front of it.
        float veil = noise.sample(tile, f / 340 + float2(-u.time * 0.012, u.time * 0.005)).r;
        color = mix(color, mist * 0.42, smoothstep(0.52, 0.88, veil) * 0.24 * saturate(visible * 1.5));

        // A cold point in each pupil, so they look through the fog.
        float glow = exp(-glintAt.x * glintAt.x / 7 - glintAt.y * glintAt.y / 7) * saturate(u.eye) * (0.28 + saturate(u.eye - 1) * 1.8);
        color += float3(0.88, 0.93, 1.0) * glow * (1 - u.thought * 0.45) * u.cloudLight * saturate(visible * 1.8);

        // Breath: cold mist falling from the mouth, only as strong as the voice.
        if (u.breath > 0.02 && u.puck < 0.5) {
            float2 b = dm - float2(0, drop);
            float spread = 26 + max(b.y, 0.0) * 0.5;
            float plume = 1 - smoothstep(spread * 0.15, spread, abs(b.x + sin(b.y * 0.018 + u.time) * 12));
            float falling = noise.sample(tile, float2(f.x / 190, f.y / 240 - u.time * 0.24)).r;
            float cloud = plume * smoothstep(0.36, 0.76, falling) * exp(-max(b.y, 0.0) / 120) * smoothstep(-6, 12, b.y);
            color = mix(color, mist * 1.15, saturate(cloud * u.breath * 1.5) * 0.85 * hush);
        }

        float alpha = u.puck > 0.5 ? smoothstep(0.0, 0.5, visible) : 1;
        return float4(color * alpha, alpha);
    }
    """
}
