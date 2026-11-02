import AppKit
import SwiftUI

/// Wisps of dark mist for the controls, baked once per shape from the same noise as the cloud, so
/// a dozen of them cost no more than a dozen small images.
@MainActor
enum Mist {
    private static var baked: [String: CGImage] = [:]

    /// `firm` is the condensed puff under the pointer, with a tighter edge.
    static func puff(width: CGFloat, height: CGFloat, firm: Bool, seed: Int) -> CGImage? {
        let aspect = min(12, max(1, (width / max(height, 1)).rounded()))
        let key = "\(aspect)-\(firm)-\(seed % 3)"
        if let image = baked[key] { return image }
        let h = 96, w = Int(CGFloat(h) * aspect)
        let noise = CloudNoise.pixels, size = CloudNoise.size
        let soft = firm ? 0.3 : 0.5
        let offset = seed % 3 * 83
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                // Distance from a stadium running the length of the puff, so long ones stay even.
                let radius = Double(h) * 0.5
                let cx = max(radius, min(Double(w) - radius, Double(x)))
                let dx = (Double(x) - cx) / radius, dy = (Double(y) - radius) / radius
                let dist = (dx * dx + dy * dy).squareRoot()
                // Read gently, so edges billow and thin out rather than tear.
                let n = Double(noise[(y + offset) % size * size + (x + offset) % size]) / 255
                let field = dist + (n - 0.5) * (firm ? 0.22 : 0.5)
                let core = min(1, max(0, (0.92 - field) / soft))
                // A thin haze reaches further out than the body of the puff.
                let haze = min(1, max(0, (1.0 - dist) / 0.45)) * (firm ? 0.25 : 0.45) * min(1, n * 1.5)
                // Always gone before the edge of the image, however the noise falls.
                let rim = min(1, max(0, (1 - dist) / 0.14))
                let a = UInt8(max(core * core * (3 - 2 * core), haze) * rim * 255)
                let i = (y * w + x) * 4
                pixels[i] = a; pixels[i + 1] = a; pixels[i + 2] = a; pixels[i + 3] = a
            }
        }
        let image = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        baked[key] = image
        return image
    }
}

extension EnvironmentValues {
    /// Puffs drift while the face is awake and hold still once it's asleep, so nothing draws.
    @Entry var mistDrifts = true
}

/// The mist behind a control. It drifts slowly at rest and condenses under the pointer, and
/// `burst` going up throws off vapour.
struct MistBackground: View {
    var firm = false
    var opacity = 1.0
    var burst = 0
    var seed = 0
    /// How far the mist reaches past the control's edges.
    var spill = CGSize(width: 18, height: 12)
    @Environment(\.mistDrifts) private var drifts
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width + spill.width * 2, height = geo.size.height + spill.height * 2
            let still = reduceMotion || !drifts || Snapshots.isRendering
            TimelineView(.animation(minimumInterval: 1.0 / 10, paused: still)) { _ in
                let t = still ? 0 : Date.timeIntervalSinceReferenceDate + Double(seed) * 2.3
                ZStack {
                    puff(width: width, height: height, firm: false).opacity(firm ? 0 : 0.17)
                    puff(width: width, height: height, firm: true).opacity(firm ? 0.3 : 0)
                }
                .scaleEffect(firm ? 1.04 : 1 + sin(t * 0.7) * 0.018)
                .offset(x: firm ? 0 : sin(t * 0.45) * 2.4, y: firm ? 0 : cos(t * 0.6) * 1.6)
            }
            .frame(width: width, height: height)
            .offset(x: -spill.width, y: -spill.height)
            .overlay(alignment: .topLeading) {
                Vapour(burst: burst, width: width, height: height, seed: seed, reduceMotion: reduceMotion)
                    .offset(x: -spill.width, y: -spill.height)
            }
        }
        .opacity(opacity)
        .animation(.easeOut(duration: 0.22), value: firm)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func puff(width: CGFloat, height: CGFloat, firm: Bool) -> some View {
        if let image = Mist.puff(width: width, height: height, firm: firm, seed: seed) {
            Image(decorative: image, scale: 1).resizable().frame(width: width, height: height).colorMultiply(Theme.mist)
        }
    }
}

/// A click scatters the wisp: wisps fly out and thin away.
private struct Vapour: View {
    let burst: Int
    let width: CGFloat
    let height: CGFloat
    let seed: Int
    let reduceMotion: Bool
    @State private var spread = 1.0

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                if let image = Mist.puff(width: width, height: height, firm: false, seed: seed + index + 1) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: width, height: height)
                        .colorMultiply(Theme.mist)
                        .scaleEffect(1 + spread * (0.5 + Double(index) * 0.22))
                        .offset(x: spread * CGFloat(index - 1) * 26, y: spread * (CGFloat(index) * 7 - 14))
                }
            }
        }
        .opacity((1 - spread) * 0.4)
        .onChange(of: burst) {
            guard !reduceMotion else { return }
            spread = 0
            withAnimation(.easeOut(duration: 0.55)) { spread = 1 }
        }
        .allowsHitTesting(false)
    }
}
