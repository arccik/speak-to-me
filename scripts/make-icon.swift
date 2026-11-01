// Draws the Speak to Me app icon — a live-cut record — and
// writes a 1024 px PNG. Usage: swift scripts/make-icon.swift <out.png> [record|orb|bubble|smile]
import AppKit
import CoreImage

let args = CommandLine.arguments
let output = URL(fileURLWithPath: args.count > 1 ? args[1] : "AppIcon-1024.png")
let variant = args.count > 2 ? args[2] : "record"

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let ci = CIContext()

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// The record: cherry vinyl with one hot groove of white and yellow waves, a cobalt label.
if variant == "record" {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let center = CGPoint(x: 512, y: 512)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.35))
    c.addPath(tilePath)
    c.setFillColor(rgb(0xE5102B))
    c.fillPath()
    c.restoreGState()
    c.addPath(tilePath)
    c.clip()
    c.setStrokeColor(rgb(0x8A0A1C, 0.75))
    c.setLineWidth(3)
    for r in stride(from: CGFloat(250), to: 620, by: 24) {
        c.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }
    func wave(radius: CGFloat, amplitude: CGFloat, cycles: CGFloat, shift: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for i in 0...720 {
            let t = CGFloat(i) / 720 * 2 * .pi
            let r = radius + amplitude * (sin(t * cycles + shift) * 0.7 + sin(t * (cycles + 5) + shift * 2) * 0.3)
            let p = CGPoint(x: center.x + cos(t) * r, y: center.y + sin(t) * r)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
    c.setLineWidth(11)
    c.setLineJoin(.round)
    c.setStrokeColor(rgb(0xF4FF3A))
    c.addPath(wave(radius: 345, amplitude: 34, cycles: 11, shift: 0.7))
    c.strokePath()
    c.setStrokeColor(rgb(0xFFFFFF))
    c.addPath(wave(radius: 262, amplitude: 28, cycles: 9, shift: 2.1))
    c.strokePath()
    c.setFillColor(rgb(0x1420FF))
    c.fillEllipse(in: CGRect(x: center.x - 190, y: center.y - 190, width: 380, height: 380))
    c.setFillColor(rgb(0xF4FF3A))
    c.fillEllipse(in: CGRect(x: center.x - 38, y: center.y - 38, width: 76, height: 76))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: output)
    print("wrote \(output.path)")
    exit(0)
}

/// Draws into a transparent full-size layer (origin top-left), optionally blurred.
func layer(blur: CGFloat = 0, _ draw: (CGContext) -> Void) -> CGImage {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(size))
    c.scaleBy(x: 1, y: -1)
    draw(c)
    let image = c.makeImage()!
    guard blur > 0 else { return image }
    let blurred = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: Double(blur))
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    return ci.createCGImage(blurred, from: CGRect(x: 0, y: 0, width: size, height: size))!
}

/// The orb's soft, organic edge: a circle modulated by a few fixed harmonics.
func blob(center: CGPoint, radius: CGFloat, wobble: CGFloat, seed: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for i in 0...180 {
        let t = CGFloat(i) / 180 * 2 * .pi
        let offset = sin(2 * t + seed) * 0.55 + sin(3 * t - seed * 1.7) * 0.4 + sin(5 * t + seed * 2.3) * 0.2
        let r = radius * (1 + wobble * offset)
        let point = CGPoint(x: center.x + cos(t) * r, y: center.y + sin(t) * r)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func fillRadial(_ c: CGContext, _ path: CGPath, colors: [CGColor], locations: [CGFloat], center: CGPoint, radius: CGFloat) {
    c.saveGState()
    c.addPath(path)
    c.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    c.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                         options: [.drawsAfterEndLocation])
    c.restoreGState()
}

// MARK: Tile (macOS icon grid: 824 pt rounded square with a soft drop shadow)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

let shadow = layer(blur: 18) { c in
    c.addPath(CGPath(roundedRect: tile.offsetBy(dx: 0, dy: 12), cornerWidth: 186, cornerHeight: 186, transform: nil))
    c.setFillColor(rgb(0x000000, 0.45))
    c.fillPath()
}
let background = layer { c in
    c.addPath(tilePath)
    c.clip()
    let night = CGGradient(colorsSpace: space, colors: [rgb(0x1B2050), rgb(0x0B0C1C)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(night, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // A faint inner rim of light along the top edge.
    c.addPath(tilePath)
    c.setStrokeColor(rgb(0xFFFFFF, 0.08))
    c.setLineWidth(4)
    c.strokePath()
}

// MARK: The orb

let center = CGPoint(x: 512, y: variant == "bubble" ? 478 : 492)
let radius: CGFloat = 238
let haze = layer(blur: 60) { c in
    fillRadial(c, blob(center: center, radius: radius * 1.35, wobble: 0.05, seed: 4),
               colors: [rgb(0x3C7BF0, 0.75), rgb(0x5A3FD8, 0.45), rgb(0x5A3FD8, 0)], locations: [0, 0.6, 1],
               center: center, radius: radius * 1.4)
}
let body = layer(blur: 16) { c in
    let light = CGPoint(x: center.x - 50, y: center.y - 62)
    let shape = CGMutablePath()
    shape.addPath(blob(center: center, radius: radius, wobble: 0.07, seed: 1))
    if variant == "bubble" {
        // A speech-bubble tail growing out of the lower left of the orb.
        shape.move(to: CGPoint(x: center.x - 150, y: center.y + 150))
        shape.addQuadCurve(to: CGPoint(x: center.x - 245, y: center.y + 300), control: CGPoint(x: center.x - 170, y: center.y + 260))
        shape.addQuadCurve(to: CGPoint(x: center.x - 30, y: center.y + 220), control: CGPoint(x: center.x - 120, y: center.y + 280))
        shape.closeSubpath()
    }
    fillRadial(c, shape,
               colors: [rgb(0xBFF4FF), rgb(0x34C2EA), rgb(0x3E7BEF), rgb(0x5B3FD8)], locations: [0, 0.3, 0.66, 1],
               center: light, radius: radius * 1.5)
}
let layered = layer(blur: 26) { c in
    c.setBlendMode(.plusLighter)
    fillRadial(c, blob(center: center, radius: radius * 0.92, wobble: 0.1, seed: 4),
               colors: [rgb(0xCFF6FF, 0.5), rgb(0x46C8F0, 0.35), rgb(0x46C8F0, 0)], locations: [0, 0.5, 1],
               center: CGPoint(x: center.x - 30, y: center.y - 40), radius: radius)
}
let core = layer(blur: 60) { c in
    c.setBlendMode(.plusLighter)
    let p = CGPoint(x: center.x - 34, y: center.y - 48)
    fillRadial(c, blob(center: p, radius: radius * 0.52, wobble: 0.06, seed: 7),
               colors: [rgb(0xFFFFFF, 0.55), rgb(0xBDF3FF, 0.3), rgb(0xBDF3FF, 0)], locations: [0, 0.45, 1],
               center: p, radius: radius * 0.58)
}

// MARK: Glow strands (the app's voice waves)

func strand(amplitude: CGFloat, frequency: CGFloat, phase: CGFloat, y: CGFloat, smile: Bool) -> CGPath {
    let path = CGMutablePath()
    let x0: CGFloat = 230, x1: CGFloat = 794
    for i in 0...160 {
        let u = CGFloat(i) / 160
        let x = x0 + (x1 - x0) * u
        let taper = sin(u * .pi)
        var dy = sin(u * frequency * 2 * .pi + phase) * amplitude * taper
        if smile { dy += -cos(u * .pi) * 0 + sin(u * .pi) * 70 } // bow downward into a smile
        let point = CGPoint(x: x, y: y + dy)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    return path
}

let strandsY: CGFloat = variant == "smile" ? 560 : 742
let strands = [
    strand(amplitude: variant == "smile" ? 18 : 46, frequency: 1.6, phase: 0.4, y: strandsY, smile: variant == "smile"),
    strand(amplitude: variant == "smile" ? 12 : 30, frequency: 2.1, phase: 2.2, y: strandsY, smile: variant == "smile"),
    strand(amplitude: variant == "smile" ? 8 : 20, frequency: 2.7, phase: 4.1, y: strandsY, smile: variant == "smile"),
]
func strokeStrands(_ c: CGContext, width: CGFloat, alpha: CGFloat) {
    for (i, path) in strands.enumerated() {
        c.saveGState()
        c.addPath(path.copy(strokingWithWidth: width * [1, 0.75, 0.6][i], lineCap: .round, lineJoin: .round, miterLimit: 4))
        c.clip()
        let g = CGGradient(colorsSpace: space,
                           colors: [rgb(0x46C8F0, 0), rgb(0x7FE3FF, alpha), rgb(0xB794FF, alpha), rgb(0x8E62F7, 0)] as CFArray,
                           locations: [0, 0.3, 0.7, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: 230, y: 0), end: CGPoint(x: 794, y: 0), options: [])
        c.restoreGState()
    }
}
let strandGlow = layer(blur: 10) { c in strokeStrands(c, width: 16, alpha: 0.8) }
let strandLines = layer { c in strokeStrands(c, width: 7, alpha: 1) }

// MARK: Composite

let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let full = CGRect(x: 0, y: 0, width: size, height: size)
canvas.draw(shadow, in: full)
canvas.draw(background, in: full)
canvas.saveGState()
canvas.addPath(CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil))
canvas.clip()
canvas.draw(haze, in: full)
canvas.draw(body, in: full)
canvas.setBlendMode(.plusLighter)
canvas.draw(layered, in: full)
canvas.draw(core, in: full)
if variant != "bubble" {
    canvas.draw(strandGlow, in: full)
    canvas.draw(strandLines, in: full)
}
canvas.restoreGState()

let rep = NSBitmapImageRep(cgImage: canvas.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("wrote \(output.path)")
