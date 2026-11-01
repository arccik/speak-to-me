import AppKit
import CoreText
import MetalKit
import SwiftUI

/// Where the disc sits. Stage is the main window, where it bleeds past every edge;
/// puck is the floating record, a whole small disc on a transparent window.
struct LatheLayout {
    enum Style { case stage, puck }

    var style: Style
    var labelText = ""
    /// How much of the bottom the words take up, where the grooves go quiet. Zero when nothing sits there.
    var hush: CGFloat = 0
    /// The conversation is open, so the disc rides up behind it.
    var peek = false
}

/// The record, the whole of it in one Metal fragment shader: each pixel works out which
/// turn of the spiral it's near and reads that moment's level from a 1-D texture. So a
/// long conversation costs the same as a short one, on the GPU the language model needs.
struct LatheView: NSViewRepresentable {
    let phase: VoiceSession.Phase
    let muted: Bool
    let levels: AudioLevels
    let layout: LatheLayout
    let paused: Bool
    let reduceMotion: Bool

    static var isAvailable: Bool { LatheRenderer.shared != nil }

    func makeNSView(context: Context) -> MTKView {
        let view = PassThroughMTKView(frame: .zero, device: LatheRenderer.shared?.device)
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
        LatheEngine.shared.reduceMotion = reduceMotion
        view.preferredFramesPerSecond = Int((1 / Mood.frameInterval(for: phase)).rounded())
        if view.isPaused != paused { view.isPaused = paused }
        if paused { view.draw() } // something changed while it's holding still
    }

    func makeCoordinator() -> LatheDrawer { LatheDrawer(phase: phase, muted: muted, levels: levels, layout: layout) }

    /// Clicks go to the SwiftUI view around it (talk, scratch, drag the floating record).
    final class PassThroughMTKView: MTKView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Steps the engine every frame and hands it to the shader.
final class LatheDrawer: NSObject, MTKViewDelegate {
    var phase: VoiceSession.Phase
    var muted: Bool
    var levels: AudioLevels
    var layout: LatheLayout
    private var peekAmount: Double?
    private var hush: CGFloat?
    private var lastDraw: Double?

    init(phase: VoiceSession.Phase, muted: Bool, levels: AudioLevels, layout: LatheLayout) {
        self.phase = phase
        self.muted = muted
        self.levels = levels
        self.layout = layout
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = Date.timeIntervalSinceReferenceDate
        let engine = LatheEngine.shared
        engine.step(phase: phase, muted: muted, levels: levels, now: now)
        let target = layout.peek ? 1.0 : 0.0
        let dt = min(0.1, now - (lastDraw ?? now))
        lastDraw = now
        peekAmount = peekAmount.map { $0 + (target - $0) * (1 - exp(-dt * 7)) } ?? target
        let scale = view.window?.backingScaleFactor ?? 2
        // The quiet area grows with the words, without snapping.
        hush = hush.map { $0 + (layout.hush - $0) * CGFloat(1 - exp(-dt * 7)) } ?? layout.hush
        var eased = layout
        eased.hush = hush ?? layout.hush
        LatheRenderer.shared?.draw(engine, layout: eased, peek: peekAmount ?? target, scale: scale, in: view)
    }
}

final class LatheRenderer {
    static let shared = LatheRenderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let grooves: MTLTexture
    private var scratch = [UInt8](repeating: 0, count: LatheEngine.windowSamples * 2)
    private var labelArt: (text: String, texture: MTLTexture)?
    private let blankArt: MTLTexture

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "latheVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "latheFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("Record shader unavailable: \(error)")
            return nil
        }
        let log = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg8Unorm, width: LatheEngine.windowSamples, height: 1, mipmapped: false)
        let blank = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        guard let grooves = device.makeTexture(descriptor: log), let blankArt = device.makeTexture(descriptor: blank) else { return nil }
        self.device = device
        self.queue = queue
        self.grooves = grooves
        self.blankArt = blankArt
    }

    /// Where the sleeve's top edge sits when the conversation is open: the record slides
    /// half into it, like one being put away.
    static let sleeveTop = 130.0

    /// In points. `peek` runs from 0, on the stage, to 1, half in the sleeve.
    static func center(in size: CGSize, style: LatheLayout.Style, peek: Double) -> CGPoint {
        guard style == .stage else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let y = size.height * 0.46
        return CGPoint(x: size.width / 2, y: y + (sleeveTop - y) * peek)
    }

    /// Matches `LatheUniforms` in the shader.
    private struct Uniforms {
        var size: SIMD2<Float>
        var center: SIMD2<Float>
        var pivot: SIMD2<Float>
        var head: SIMD2<Float>
        var scale: Float
        var labelR: Float
        var headR: Float
        var pitch: Float
        var discR: Float
        var turnFrac: Float
        var sampleFrac: Float
        var level: Float
        var clock: Float
        var hushY: Float
        var topHush: Float
        var front: Float
        var frontStrength: Float
        var armLift: Float
        var labelTextAlpha: Float
        var cuttingReply: Float
        var showArm: Float
        var vinyl: SIMD4<Float>
        var vinylOld: SIMD4<Float>
        var label: SIMD4<Float>
        var labelOld: SIMD4<Float>
        var you: SIMD4<Float>
        var reply: SIMD4<Float>
    }

    func draw(_ engine: LatheEngine, layout: LatheLayout, peek: Double, scale: CGFloat, in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        encode(engine, layout: layout, peek: peek, size: view.drawableSize, scale: scale, into: encoder)
        commands.present(drawable)
        commands.commit()
    }

    /// One frame as an image, for `--snapshot` (ImageRenderer can't capture Metal).
    func image(of engine: LatheEngine, layout: LatheLayout, points: CGSize, scale: CGFloat) -> CGImage? {
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

    private func encode(_ engine: LatheEngine, layout: LatheLayout, peek: Double, size: CGSize, scale: CGFloat,
                        into encoder: MTLRenderCommandEncoder) {
        func vector(_ c: RGBA) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a)) }
        let s = Double(scale)
        let w = size.width, h = size.height
        let stage = layout.style == .stage
        let points = Self.center(in: CGSize(width: w / s, height: h / s), style: layout.style, peek: peek)
        let center = CGPoint(x: points.x * s, y: points.y * s)
        let zoom = 1 - 0.5 * peek
        let labelR = (stage ? min(max(w, h) * 0.13, 150 * s) : min(w, h) * 0.16) * zoom
        let headR = labelR + (stage ? 14 : 4) * s * zoom
        let pitch = (stage ? 9 : 3.4) * s * zoom

        let sampleFrac = scratch.withUnsafeMutableBytes { engine.fill($0) }
        scratch.withUnsafeBytes { raw in
            grooves.replace(region: MTLRegionMake2D(0, 0, LatheEngine.windowSamples, 1), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: LatheEngine.windowSamples * 2)
        }

        // The arm hangs from the top right and swings in so its head lands on the newest groove.
        let onGroove = CGPoint(x: center.x + headR, y: center.y)
        let pivot = CGPoint(x: min(w - 26 * s, onGroove.x + 170 * s), y: center.y - min(h * 0.38, center.y + 240 * s))
        let dx = onGroove.x - pivot.x, dy = onGroove.y - pivot.y
        let length = hypot(dx, dy)
        let engaged = atan2(dy, dx), rest = Double.pi / 2 + 0.03
        let jitter = engine.reduceMotion ? 0 : engine.level * 0.006 * sin(engine.clock * 47)
        let swing = rest + (engaged - rest) * engine.arm + jitter
        let head = CGPoint(x: pivot.x + cos(swing) * length, y: pivot.y + sin(swing) * length)

        let view = engine.viewTurn
        var uniforms = Uniforms(
            size: SIMD2(Float(w), Float(h)),
            center: SIMD2(Float(center.x), Float(center.y)),
            pivot: SIMD2(Float(pivot.x), Float(pivot.y)),
            head: SIMD2(Float(head.x), Float(head.y)),
            scale: Float(s),
            labelR: Float(labelR), headR: Float(headR), pitch: Float(pitch),
            discR: stage ? 0 : Float(min(w, h) / 2 - s),
            turnFrac: Float(view - view.rounded(.down)),
            sampleFrac: Float(sampleFrac),
            level: engine.reduceMotion ? 0 : Float(engine.level),
            clock: Float(engine.clock.truncatingRemainder(dividingBy: 2 * .pi * 100)),
            hushY: layout.hush > 0 ? Float(h - Double(layout.hush) * s) : 0,
            topHush: Float(peek),
            front: Float(engine.front * s),
            frontStrength: Float(engine.frontStrength),
            armLift: Float(engine.lift),
            labelTextAlpha: layout.labelText.isEmpty ? 0 : 1,
            cuttingReply: engine.cutting.reply > engine.cutting.you ? 1 : 0,
            showArm: stage ? Float(max(0, 1 - peek * 2)) : 0,
            vinyl: vector(engine.mood.vinyl), vinylOld: vector(engine.previousVinyl),
            label: vector(engine.mood.label), labelOld: vector(engine.previousLabel),
            you: vector(Mood.youInk), reply: vector(Mood.replyInk))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(grooves, index: 0)
        encoder.setFragmentTexture(art(for: layout.labelText), index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: Label art

    /// The words printed around the label, drawn once and spun by the shader.
    private func art(for text: String) -> MTLTexture {
        guard !text.isEmpty else { return blankArt }
        if let labelArt, labelArt.text == text { return labelArt.texture }
        let pixels = 768
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixels, height: pixels, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: descriptor),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return blankArt }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let font = CTFontCreateWithName("AvenirNextCondensed-Heavy" as CFString, 62, nil)
        let center = CGFloat(pixels) / 2, radius = center - 76
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white, .kern: 3,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let total = CTLineGetTypographicBounds(line, nil, nil, nil)
        // Fits one lap of the label however long the model's name is.
        let fit = min(1, (2 * .pi * radius * 0.97) / total)
        var angle = CGFloat.pi / 2 + (total * fit / radius) / 2
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            let runFont = (CTRunGetAttributes(run) as Dictionary)[kCTFontAttributeName] as! CTFont
            for i in 0..<count {
                let step = advances[i].width * fit / radius
                angle -= step / 2
                context.saveGState()
                context.translateBy(x: center + cos(angle) * radius, y: center + sin(angle) * radius)
                context.rotate(by: angle - .pi / 2)
                context.scaleBy(x: fit, y: fit)
                var position = CGPoint(x: -advances[i].width / 2, y: 0)
                CTFontDrawGlyphs(runFont, &glyphs[i], &position, 1, context)
                context.restoreGState()
                angle -= step / 2
            }
        }
        if let data = context.data {
            texture.replace(region: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0, withBytes: data, bytesPerRow: pixels * 4)
        }
        labelArt = (text, texture)
        return texture
    }

    // MARK: Shader

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct LatheUniforms {
        float2 size, center, pivot, head;
        float scale, labelR, headR, pitch, discR, turnFrac, sampleFrac, level, clock, hushY, topHush,
              front, frontStrength, armLift, labelTextAlpha, cuttingReply, showArm;
        float4 vinyl, vinylOld, label, labelOld, you, reply;
    };

    vertex float4 latheVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    static float segment(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        return length(pa - ba * saturate(dot(pa, ba) / dot(ba, ba)));
    }

    fragment float4 latheFragment(float4 position [[position]], constant LatheUniforms &u [[buffer(0)]],
                                  texture2d<float> grooves [[texture(0)]], texture2d<float> art [[texture(1)]]) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        const float TAU = 6.2831853;
        float s = u.scale;
        float2 p = position.xy;
        float2 d = p - u.center;
        float r = length(d);
        float theta = atan2(d.y, d.x);

        // The wavefront: new colour inside it, old outside.
        float passed = smoothstep(u.front - 26 * s, u.front + 26 * s, r);
        float3 vinyl = mix(u.vinyl.rgb, u.vinylOld.rgb, passed);
        float3 color = vinyl;

        // Light caught in the grooves: the two wedges every record has. They stay put while it turns.
        float wedge = pow(abs(cos(theta + 0.85)), 26.0);
        float wide = pow(abs(cos(theta + 0.85)), 4.0);
        // Behind the words the grooves carry on, quietly enough to read over.
        float hush = u.hushY > 0 ? mix(1.0, 0.2, smoothstep(u.hushY - 70 * s, u.hushY, p.y)) : 1;
        hush *= 1 - u.topHush * (1 - smoothstep(26 * s, 62 * s, p.y));
        color += float3(1.0, 0.86, 0.82) * (0.13 * wedge + 0.035 * wide) * smoothstep(u.headR, u.headR + 60 * s, r) * hush;

        // Grooves.
        if (r > u.headR - 44 * u.pitch / 9) {
            float bump = u.frontStrength * exp(-pow((r - u.front) / (44 * s), 2.0)) * 11 * s;
            float rb = r - bump;
            float phi = fract(theta / TAU + 1);
            float along = (rb - u.headR) / u.pitch;
            int k0 = int(round(along - phi));
            int span = along < 24 ? 5 : 1; // only young grooves swing far enough to cross their neighbours
            for (int k = k0 + span; k >= k0 - span; k--) {
                if (k < 0) continue;
                float age = phi + float(k);
                float x = 1.0 - (age - u.sampleFrac) * 256.0 / 16384.0;
                if (x < 0) continue;
                float4 e = grooves.sample(linear, float2(x, 0.5));
                float env = e.r;
                float heat = exp(-age / 9.0);
                float at = u.turnFrac - age;
                // Long, smooth swells. Heat only sets how big they are: if it set their
                // speed too, the wave would bunch up tighter the longer you talked.
                float wave = sin(TAU * at * 9.0 + u.clock * 2.0) * 0.62
                           + sin(TAU * at * 14.0 - u.clock * 1.4 + 1.3) * 0.38;
                // Smaller discs have shorter waves, so they swing less or they'd curl into loops.
                float swing = u.pitch * (0.3 + heat * mix(0.8, 4.2, saturate(u.pitch / (9 * s)))) * env * wave;
                float shiver = u.level * u.pitch * 0.5 * sin(TAU * at * 7.0 + u.clock * 5.0);
                float dist = abs(rb - (u.headR + u.pitch * age + swing + shiver));
                float cut = smoothstep(0.02, mix(0.1, 0.3, saturate(u.pitch / (9 * s))), env);
                float w = s * mix(0.42, 0.65 + 1.3 * heat, cut) * (u.pitch / (9 * s) * 0.5 + 0.5);
                float cover = 1 - smoothstep(w - 0.7, w + 0.7, dist);
                float3 pure = mix(u.you.rgb, u.reply.rgb, e.g);
                // A groove keeps its full colour while it's hot, getting thinner, then
                // quickly sinks back into the vinyl: only what's being cut stands out.
                float3 ink = mix(vinyl * 0.58, pure, cut);
                float strength = mix(0.62, mix(0.22, 1.0, smoothstep(0.12, 0.5, heat)), cut);
                // A hot groove glows a little into the vinyl around it.
                color += pure * exp(-dist / (2.6 * u.pitch / 9)) * heat * cut * 0.09 * hush;
                color = mix(color, ink, cover * strength * hush);
            }
        }

        // The wavefront catches the light as it goes by.
        color += 0.14 * u.frontStrength * exp(-pow((r - u.front) / (12 * s), 2.0)) * hush;

        // Label, printed words, spindle.
        float labelEdge = 1 - smoothstep(u.labelR - 0.8, u.labelR + 0.8, r);
        if (labelEdge > 0) {
            float3 label = mix(u.label.rgb, u.labelOld.rgb, passed);
            float angle = TAU * u.turnFrac;
            float2 q = float2(d.x * cos(angle) + d.y * sin(angle), -d.x * sin(angle) + d.y * cos(angle));
            float ink = art.sample(linear, q / (2 * u.labelR) + 0.5).a * u.labelTextAlpha;
            label = mix(label, float3(1), ink);
            color = mix(color, label, labelEdge);
            color = mix(color, u.reply.rgb, 1 - smoothstep(u.labelR * 0.085 - 0.8, u.labelR * 0.085 + 0.8, r));
        }

        // The tonearm, flat and white with a soft shadow that lengthens as it lifts.
        if (u.showArm > 0) {
            float3 before = color;
            float2 along = normalize(u.head - u.pivot);
            float2 tail = u.head;
            float2 tip = u.head - along * 22 * s;
            float2 offset = float2(3, 5) * s * (1 + u.armLift * 2.2);
            float shade = 1 - smoothstep(0.0, (9 + 8 * u.armLift) * s, segment(p - offset, u.pivot, u.head) - 2 * s);
            color *= 1 - 0.34 * shade;
            float rod = 1 - smoothstep(-0.7, 0.7, segment(p, u.pivot, tip) - 1.6 * s);
            color = mix(color, float3(1), rod);
            float cartridge = 1 - smoothstep(-0.7, 0.7, segment(p, tip, tail) - 5 * s);
            color = mix(color, u.cuttingReply > 0.5 ? u.reply.rgb : float3(1), cartridge);
            float hub = length(p - u.pivot);
            color = mix(color, float3(1), 1 - smoothstep(13 * s - 0.7, 13 * s + 0.7, hub));
            color = mix(color, u.label.rgb, 1 - smoothstep(5 * s - 0.7, 5 * s + 0.7, hub));
            color = mix(before, color, u.showArm);
        }

        float alpha = u.discR > 0 ? 1 - smoothstep(u.discR - 0.8, u.discR + 0.8, r) : 1;
        return float4(color * alpha, alpha);
    }
    """
}
