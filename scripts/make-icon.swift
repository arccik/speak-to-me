// Draws the Speak to Me app icon — a pale head half lost in black fog, with two bloodshot eyes —
// and writes a 1024 px PNG. Usage: swift -O scripts/make-icon.swift <out.png> [small]
// Colours come from DESIGN.md. "small" is the master for the 16 and 32 pt slots: bigger, cleaner eyes,
// because the full drawing's sockets and veins average to mud at that size.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png")

let small = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "small"
let eyeScale = small ? 1.5 : 1.0

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()

struct RGB {
    var r, g, b: Double
    init(_ hex: UInt32) {
        // sRGB bytes, mixed as stored, the same way the stage's shader treats its colours.
        r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    static func * (c: RGB, k: Double) -> RGB { RGB(r: c.r * k, g: c.g * k, b: c.b * k) }
    func mixed(_ other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }
}

let void = RGB(0x07080C), fogGrey = RGB(0x8C96A8)
let fleshLit = RGB(0xA89E8C), fleshBruised = RGB(0x78696B), pale = RGB(0xE2DCC6)
let vein = RGB(0x751412), rawRim = RGB(0xB3241F), bloodWhite = RGB(0x54120F), eyeWhite = RGB(0xDDD3BC)
let milkIris = RGB(0xB3BDB8), irisEdge = RGB(0x2A2E30), pupil = RGB(0x040406), gum = RGB(0x330A0D)

func saturate(_ x: Double) -> Double { min(1, max(0, x)) }
func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = saturate((x - a) / (b - a))
    return t * t * (3 - 2 * t)
}
func hash(_ i: Int, _ j: Int) -> Double {
    let s = sin(Double(i) * 127.1 + Double(j) * 311.7) * 43758.5453
    return s - floor(s)
}
func noise(_ x: Double, _ y: Double) -> Double {
    let i = Int(floor(x)), j = Int(floor(y))
    let fx = x - floor(x), fy = y - floor(y)
    let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
    let top = hash(i, j) + (hash(i + 1, j) - hash(i, j)) * u
    let bottom = hash(i, j + 1) + (hash(i + 1, j + 1) - hash(i, j + 1)) * u
    return top + (bottom - top) * v
}
func fbm(_ x: Double, _ y: Double, octaves: Int = 5) -> Double {
    var total = 0.0, weight = 0.5, norm = 0.0, px = x, py = y
    for _ in 0..<octaves {
        total += noise(px, py) * weight
        norm += weight
        weight *= 0.5
        px = px * 2.03 + 17.3
        py = py * 2.03 + 9.1
    }
    return total / norm
}
func bump(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ sx: Double, _ sy: Double) -> Double {
    let dx = (x - cx) / sx, dy = (y - cy) / sy
    return exp(-(dx * dx + dy * dy))
}

// Face coordinates: 1 unit is half the tile, x runs right and y runs down, tipped a few degrees so it hangs askew.
let tilt = 0.075, eyeX = 0.31, eyeY = -0.12
func faceSpace(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
    let u = (px - 512) / 412, v = (py - 512) / 412
    return (u * cos(tilt) - v * sin(tilt), u * sin(tilt) + v * cos(tilt))
}
/// How far inside the skull's outline a point is: 1 at the centre, 0 at the edge.
func skull(_ x: Double, _ y: Double) -> Double {
    let width = 0.72 * (1 - 0.34 * smoothstep(0.05, 0.9, y))
    return 1 - (x / width) * (x / width) - (y / 1.0) * (y / 1.0)
}
func height(_ x: Double, _ y: Double) -> Double {
    var h = sqrt(max(0, skull(x, y))) * 0.62
    for side in [-1.0, 1.0] {
        h += bump(x, y, side * eyeX, -0.30, 0.25, 0.055) * 0.075              // brow ridge
        h -= bump(x, y, side * eyeX, eyeY, 0.23, 0.13) * 0.24                 // socket
        h += bump(x, y, side * 0.45, 0.14, 0.13, 0.075) * 0.07                // cheekbone
        h -= bump(x, y, side * 0.34, 0.38, 0.13, 0.15) * 0.21                 // wasted cheek
        h -= bump(x, y, side * 0.058, 0.275, 0.024, 0.016) * 0.07             // nostril
        h -= bump(x, y, side * 0.56, -0.42, 0.14, 0.2) * 0.05                 // temple
    }
    h += bump(x, y, 0, -0.02, 0.055, 0.25) * 0.2                              // nose bridge
    h += bump(x, y, 0, 0.215, 0.08, 0.055) * 0.09                             // nose tip
    h -= bump(x, y, 0, 0.52, 0.23, 0.014) * 0.09                              // mouth seam
    h += bump(x, y, 0, 0.74, 0.15, 0.08) * 0.06                               // chin
    h += (fbm(x * 5 + 40, y * 5 + 12, octaves: 3) - 0.5) * 0.014                          // skin
    return h
}

/// One eye, deep in its socket: wet, bloodshot, with a milky iris and a pinprick pupil. Nil outside the lids.
func eye(_ x: Double, _ y: Double, side: Double) -> (color: RGB, coverage: Double, rim: Double) {
    let ex = (x - side * eyeX) / eyeScale, ey = (y - eyeY) / eyeScale
    let a = 0.18, across = saturate(abs(ex) / a)
    let curve = 1 - across * across
    // Heavy upper lid: flat across the top and cutting into the iris. The outer corners droop.
    let droop = abs(ex) * abs(ex) * 0.5
    let top = -0.066 * sqrt(curve) + 0.008 + droop, bottom = 0.06 * curve + 0.008 + droop
    let inside = min(smoothstep(top - 0.004, top + 0.004, ey), 1 - smoothstep(bottom - 0.004, bottom + 0.004, ey))
    let lidDistance = min(abs(ey - top), abs(ey - bottom))
    // Raw along the lower lid only, fading out before the corners.
    let rim = (1 - smoothstep(0.002, 0.03, lidDistance)) * smoothstep(top, top + 0.05, ey) * (1 - smoothstep(0.72, 1, abs(ex) / a))

    // Whites turn to blood towards the corners, threaded with veins running in to the iris.
    let n = noise(ex * 13 + side * 31, ey * 62 + 5)
    let thread = 1 - smoothstep(0, 0.085, abs(n - 0.5))
    var color = eyeWhite.mixed(bloodWhite, saturate(across * across * (small ? 0.55 : 0.95) + 0.1))
    color = color.mixed(vein, thread * (0.45 + across * 0.55))

    let r = sqrt(ex * ex + ey * ey)
    let iris = 1 - smoothstep(0.058, 0.064, r)
    let limbal = smoothstep(0.046, 0.062, r)
    let streak = fbm(atan2(ey, ex) * 3 + side, r * 30, octaves: 2)
    color = color.mixed(milkIris.mixed(irisEdge, limbal * 0.6) * (0.82 + streak * 0.36), iris)
    color = color.mixed(pupil, 1 - smoothstep(0.015, 0.021, r))

    // Heavy lid shade across the top, then one wet catchlight on the side the light comes from.
    color = color * ((small ? 0.8 : 0.5) + (small ? 0.2 : 0.5) * smoothstep(top, top + 0.05, ey))
    let catchlight = bump(ex, ey, -0.024, -0.024, 0.011, 0.009)
    color = color.mixed(RGB(0xFFFFFF), catchlight * 0.9)
    return (color, inside, rim)
}

// MARK: Render (every pixel of the tile; height is cached so the normals can read neighbours)

let inset = 100, extent = 824
var heights = [Double](repeating: 0, count: (extent + 2) * (extent + 2))
for j in 0..<(extent + 2) {
    for i in 0..<(extent + 2) {
        let p = faceSpace(Double(inset + i) - 0.5, Double(inset + j) - 0.5)
        heights[j * (extent + 2) + i] = height(p.x, p.y)
    }
}

var pixels = [UInt8](repeating: 0, count: extent * extent * 4)
let step = 1.0 / 412
let lightLength = sqrt(0.78 * 0.78 + 0.34 * 0.34 + 0.52 * 0.52)
let light = (x: -0.78 / lightLength, y: -0.34 / lightLength, z: 0.52 / lightLength)

for j in 0..<extent {
    for i in 0..<extent {
        let px = Double(inset + i) + 0.5, py = Double(inset + j) + 0.5
        let (x, y) = faceSpace(px, py)
        let row = (j + 1) * (extent + 2) + i + 1
        let dx = (heights[row + 1] - heights[row - 1]) / (2 * step)
        let dy = (heights[row + extent + 2] - heights[row - extent - 2]) / (2 * step)
        let nl = sqrt(dx * dx + dy * dy + 1)

        // One hard side light: the nose throws the far half of the face into the dark, along a ragged edge.
        let diffuse = saturate((-dx * light.x - dy * light.y + light.z) / nl)
        let forehead = smoothstep(-0.26, -0.72, y), jaw = smoothstep(0.3, 0.8, y)
        let terminator = 0.012 + forehead * 0.13 + jaw * 0.08 + (fbm(y * 4 + 3, x * 3 + 8, octaves: 3) - 0.5) * (0.04 + (forehead + jaw) * 0.14)
        let softness = 0.018 + (forehead + jaw) * 0.05
        let lit = 1 - smoothstep(terminator - softness, terminator + softness, x)
        let sockets = bump(x, y, -eyeX, eyeY, 0.235, 0.135) + bump(x, y, eyeX, eyeY, 0.235, 0.135)
        let hollow = 1 - smoothstep(0.12, 0.72, sockets) * 0.95
        let blotch = fbm(x * 3.1 + 11, y * 3.1 + 2)
        var skin = fleshBruised.mixed(fleshLit, smoothstep(0.3, 0.62, blotch))
        skin = skin.mixed(pale, smoothstep(0.42, 0.98, diffuse) * 0.72)
        skin = skin * (0.72 + 0.42 * smoothstep(0.3, 0.68, fbm(x * 5.5 + 3, y * 5.5 + 29, octaves: 4)))
        let keyed = pow(diffuse, 1.35) * 1.3 * lit
        let amount = (keyed + 0.03 + 0.1 / nl * (1 - lit)) * hollow
        var color = skin * amount
        // The mouth is a seam of dark gum, all but swallowed by the veil.
        let seam = bump(x, y, 0, 0.52, 0.21, 0.016)
        color = color.mixed(gum * 0.5, saturate(seam * 1.15))

        // The head dissolves into the room at its edges, faster towards the jaw.
        let ragged = (fbm(x * 3 + 21, y * 3 + 40) - 0.5) * 0.85
        let edge = skull(x, y) + ragged - smoothstep(0.42, 1.0, y) * 0.42
        let solid = smoothstep(0.02, 0.42, edge)

        // The room: void, with a faint haze thickening towards the bottom.
        let haze = fbm(px / 210 + 5, py / 210 + 1)
        let room = void.mixed(fogGrey, smoothstep(0.38, 0.8, haze) * (0.05 + 0.13 * smoothstep(300, 924, py)))
        var pixel = room.mixed(color, solid)

        // A veil of fog drifting across the face, heaviest low down, kept clear of the eyes.
        let veilNoise = smoothstep(0.46, 0.76, fbm(x * 2.4 + 70, y * 3.2 + 33))
        let clearOfEyes = 1 - saturate(sockets * 1.3)
        let veil = veilNoise * (0.1 + 0.3 * smoothstep(0.1, 0.8, y)) * clearOfEyes
        pixel = pixel.mixed(fogGrey * 0.62, veil)

        // The eyes sit above the fog, so they are the first and last thing to read.
        for side in [-1.0, 1.0] where abs(x - side * eyeX) < 0.24 * eyeScale && abs(y - eyeY) < 0.16 * eyeScale {
            let e = eye(x, y, side: side)
            let strength = side < 0 || small ? 1.0 : 0.82
            pixel = pixel.mixed(rawRim * strength, e.rim * 0.8)
            pixel = pixel.mixed(e.color * strength, e.coverage)
        }

        let offset = (j * extent + i) * 4
        let grain = (hash(i, j) - 0.5) * 0.006
        pixels[offset] = UInt8(saturate(pixel.r + grain) * 255 + 0.5)
        pixels[offset + 1] = UInt8(saturate(pixel.g + grain) * 255 + 0.5)
        pixels[offset + 2] = UInt8(saturate(pixel.b + grain) * 255 + 0.5)
        pixels[offset + 3] = 255
    }
}

let face = CGImage(width: extent, height: extent, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: extent * 4, space: space,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!

// MARK: Tile (macOS icon grid: 824 units with a 186 unit corner, and a soft drop shadow)

func cg(_ hex: UInt32, _ a: CGFloat) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let tile = CGRect(x: inset, y: inset, width: extent, height: extent)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: cg(0x000000, 0.35))
canvas.addPath(tilePath)
canvas.setFillColor(cg(0x07080C, 1))
canvas.fillPath()
canvas.restoreGState()
canvas.saveGState()
canvas.addPath(tilePath)
canvas.clip()
canvas.draw(face, in: tile)
canvas.restoreGState()
// A faint cold rim, so the near-black tile keeps its shape on a dark Dock.
canvas.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
canvas.setStrokeColor(cg(0xE9ECF1, 0.13))
canvas.setLineWidth(4)
canvas.strokePath()

let rep = NSBitmapImageRep(cgImage: canvas.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("wrote \(output.path)")
