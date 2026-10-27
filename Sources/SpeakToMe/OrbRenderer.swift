import AppKit
import MetalKit
import SwiftUI

/// The mist orb drawn by one Metal fragment shader. The Canvas version blurs four layers
/// (the widest ~60 pt) every frame, on the GPU the language model needs; here each pixel
/// works out its own soft edge from the blob's shape, which looks the same and costs
/// next to nothing. The shader source is compiled when the app starts, so building
/// needs no Metal toolchain.
struct MetalMistOrb: NSViewRepresentable {
    let phase: VoiceSession.Phase
    let levels: AudioLevels
    let paused: Bool

    static var isAvailable: Bool { OrbRenderer.shared != nil }

    func makeNSView(context: Context) -> MTKView {
        let view = PassThroughMTKView(frame: .zero, device: OrbRenderer.shared?.device)
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
        context.coordinator.phase = phase
        context.coordinator.levels = levels
        view.preferredFramesPerSecond = Int((1 / Mood.frameInterval(for: phase)).rounded())
        if view.isPaused != paused { view.isPaused = paused }
    }

    func makeCoordinator() -> OrbDrawer { OrbDrawer(phase: phase, levels: levels) }

    /// Clicks go to the SwiftUI view around it (tap to talk, drag the floating orb).
    final class PassThroughMTKView: MTKView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Eases the mood every frame and hands it to the shader.
final class OrbDrawer: NSObject, MTKViewDelegate {
    var phase: VoiceSession.Phase
    var levels: AudioLevels
    private let animator = MoodAnimator()

    init(phase: VoiceSession.Phase, levels: AudioLevels) {
        self.phase = phase
        self.levels = levels
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = Date.timeIntervalSinceReferenceDate
        animator.step(to: .of(phase), level: Mood.level(for: phase, levels: levels, time: now), now: now)
        OrbRenderer.shared?.draw(animator, in: view)
    }
}

final class OrbRenderer {
    static let shared = OrbRenderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "orbVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "orbFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("Orb shader unavailable, falling back to Canvas: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    /// Matches `OrbUniforms` in the shader (float2, six floats, then three float4s).
    private struct Uniforms {
        var size: SIMD2<Float>
        var radius: Float
        var wobble: Float
        var clock: Float
        var rotation: Float
        var level: Float
        var pad: Float = 0
        var core: SIMD4<Float>
        var mid: SIMD4<Float>
        var edge: SIMD4<Float>
    }

    func draw(_ animator: MoodAnimator, in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        encode(animator, size: view.drawableSize, into: encoder)
        commands.present(drawable)
        commands.commit()
    }

    /// One frame as an image, for comparing with the Canvas version (`--snapshot`).
    func image(of animator: MoodAnimator, pixels: Int) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixels, height: pixels, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(animator, size: CGSize(width: pixels, height: pixels), into: encoder)
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        texture.getBytes(&bytes, bytesPerRow: pixels * 4, from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)?.makeImage()
        }
    }

    private func encode(_ animator: MoodAnimator, size: CGSize, into encoder: MTLRenderCommandEncoder) {
        let mood = animator.mood
        func vector(_ c: RGBA) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a)) }
        // Same geometry as `MistOrb.draw`, in pixels.
        var uniforms = Uniforms(
            size: SIMD2(Float(size.width), Float(size.height)),
            radius: Float(min(size.width, size.height) * 0.30 * mood.scale * (1 + 0.16 * animator.level)),
            wobble: Float(0.035 + 0.11 * mood.energy + 0.16 * animator.level),
            // Keep the sines precise: the clock only needs to be continuous, not small.
            clock: Float(animator.clock.truncatingRemainder(dividingBy: 2 * .pi * 1000)),
            rotation: Float(animator.rotation.truncatingRemainder(dividingBy: 2 * .pi)),
            level: Float(animator.level),
            core: vector(mood.core), mid: vector(mood.mid), edge: vector(mood.edge))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// The four layers of `MistOrb.draw`: each blurred blob becomes its gradient times a
    /// soft coverage (a Gaussian edge as wide as the blur), stacked front over back. (The
    /// Canvas sets `.plusLighter` inside each layer, where it has nothing to add to, so its
    /// layers composite normally too.)
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct OrbUniforms {
        float2 size;
        float radius, wobble, clock, rotation, level, pad;
        float4 core, mid, edge;
    };

    vertex float4 orbVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    // Edge of a blob: radius modulated by drifting sine harmonics.
    static float blobRadius(float theta, float radius, float wobble, float t, float seed, float rotation) {
        const float k[5] = {2, 3, 5, 7, 11};
        const float speed[5] = {0.9, -1.3, 1.7, -2.3, 2.9};
        const float weight[5] = {0.55, 0.45, 0.3, 0.2, 0.1};
        float offset = 0;
        for (int i = 0; i < 5; i++) {
            offset += sin(k[i] * (theta + rotation) + t * speed[i] + seed * k[i] * 1.7) * weight[i];
        }
        return radius * (1 + wobble * offset);
    }

    // How much of a blurred blob covers p: the normal CDF across its edge, dimmed
    // in the middle when the blur is wide compared with the blob (as a blurred disc is).
    static float coverage(float2 p, float2 center, float radius, float wobble, float t, float seed,
                          float rotation, float blur) {
        float2 d = p - center;
        float edge = blobRadius(length(d) > 0.001 ? atan2(d.y, d.x) : 0.0, radius, wobble, t, seed, rotation);
        float sigma = max(blur, 1.0); // SwiftUI's blur radius is the Gaussian's sigma
        // Clamped: past ±6 sigma it's 0 or 1 anyway, and fast-math tanh overflows to NaN.
        float x = clamp((edge - length(d)) / sigma, -6.0, 6.0);
        float cdf = 0.5 * (1 + tanh(0.7978845608 * (x + 0.044715 * x * x * x)));
        return cdf * (1 - exp(-0.5 * edge * edge / (sigma * sigma)));
    }

    // Colour stops (colour, opacity, location) along a radial gradient, premultiplied.
    static float4 stop(float4 c, float opacity) { float a = c.a * opacity; return float4(c.rgb * a, a); }
    static float4 gradient3(float r, float4 c0, float l0, float4 c1, float l1, float4 c2, float l2) {
        if (r <= l1) return mix(c0, c1, saturate((r - l0) / (l1 - l0)));
        return mix(c1, c2, saturate((r - l1) / (l2 - l1)));
    }

    fragment float4 orbFragment(float4 position [[position]], constant OrbUniforms &u [[buffer(0)]]) {
        float2 p = position.xy;
        float2 c = u.size * 0.5;
        float R = u.radius, w = u.wobble, t = u.clock, rot = u.rotation;
        float4 out = 0;

        // 1. Wide haze behind everything.
        {
            float r = R * 1.35;
            float cov = coverage(p, c, r, w * 0.6, t * 0.6, 11, rot, R * 0.45);
            float4 g = gradient3(length(p - c) / (r * 1.1), stop(u.mid, 0.55), 0, stop(u.edge, 0.3), 0.5, stop(u.edge, 0), 1);
            out = g * cov + out * (1 - g.a * cov);
        }
        // 2. The cloud body: two offset blobs.
        for (int i = 0; i < 2; i++) {
            float r = R * (i == 0 ? 1.0 : 0.94);
            float2 light = c + float2(-0.18, -0.22) * r;
            float cov = coverage(p, c, r, w, t, i == 0 ? 1 : 4, rot, R * (i == 0 ? 0.11 : 0.18));
            float4 g = gradient3(length(p - light) / (r * 1.15),
                                 stop(u.core, i == 0 ? 0.95 : 0.35), 0,
                                 stop(u.mid, i == 0 ? 0.9 : 0.35), 0.45,
                                 stop(u.edge, i == 0 ? 0.85 : 0.0), 1) * cov;
            out = g + out * (1 - g.a);
        }
        // 3. Glowing core.
        {
            float r = R * (0.5 + 0.12 * u.level);
            float2 cc = c + float2(-0.08, -0.1) * R;
            float cov = coverage(p, cc, r, w * 0.8, t * 1.3, 7, rot, R * 0.22);
            float4 g = gradient3(length(p - cc) / r, stop(float4(1), 0.85), 0, stop(u.core, 0.4), 0.5, stop(u.core, 0), 1);
            g *= cov;
            out = g + out * (1 - g.a);
        }
        return out;
    }
    """
}
