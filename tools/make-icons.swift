import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws Relay's logo — the trackpad dot grid, lit amber under a fingertip — and writes:
//   web/icon.png        iPhone Home Screen icon (180 px, square; iOS rounds the corners)
//   web/logo.svg        the same mark for the pairing screens
//   Support/Relay.icns  the Mac app icon (rounded, with the standard macOS margin)
// Usage: swift tools/make-icons.swift   (from the project root)

let surface = (r: 0.082, g: 0.075, b: 0.059)          // #15130f
let resting = (r: 0.914, g: 0.886, b: 0.839, a: 0.10) // warm grey dots
let amber = (r: 0.851, g: 0.647, b: 0.357, a: 1.0)    // #d9a55b
let grid = 9, step = 20.0, origin = 10.0               // in a 180-unit design space
let finger = (x: 104.0, y: 104.0)                      // y measured from the top
let litRadius = 62.0

/// Dots in design units (y from the top): center, radius, color.
func dots() -> [(x: Double, y: Double, r: Double, color: (Double, Double, Double, Double))] {
    var result: [(Double, Double, Double, (Double, Double, Double, Double))] = []
    for i in 0..<grid {
        for j in 0..<grid {
            let x = origin + Double(i) * step, y = origin + Double(j) * step
            let lit = max(0, 1 - hypot(x - finger.x, y - finger.y) / litRadius)
            let t = pow(lit, 0.8)
            let color = (resting.r + (amber.r - resting.r) * t, resting.g + (amber.g - resting.g) * t,
                         resting.b + (amber.b - resting.b) * t, resting.a + (amber.a - resting.a) * t)
            result.append((x, y, 2.1 + 2.4 * lit, color))
        }
    }
    return result.map { (x: $0.0, y: $0.1, r: $0.2, color: $0.3) }
}

/// Renders the mark into a `pixels`-sized PNG. `inset` and `corner` are fractions of the size.
func png(pixels: Int, inset: Double, corner: Double) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let size = Double(pixels), content = size * (1 - 2 * inset), offset = size * inset
    let rect = CGRect(x: offset, y: offset, width: content, height: content)
    let radius = size * corner
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()   // dots at the edges are cut by the rounded shape, as iOS does for the phone icon
    ctx.setFillColor(CGColor(srgbRed: surface.r, green: surface.g, blue: surface.b, alpha: 1))
    ctx.fill(rect)
    let scale = content / 180
    for d in dots() {
        ctx.setFillColor(CGColor(srgbRed: d.color.0, green: d.color.1, blue: d.color.2, alpha: d.color.3))
        let cx = offset + d.x * scale, cy = offset + (180 - d.y) * scale, r = d.r * scale
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    }
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

func svg() -> String {
    func hex(_ c: (Double, Double, Double, Double)) -> String {
        String(format: "rgba(%d,%d,%d,%.2f)", Int(c.0 * 255), Int(c.1 * 255), Int(c.2 * 255), c.3)
    }
    let circles = dots().map {
        String(format: "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"%.2f\" fill=\"%@\"/>", $0.x, $0.y, $0.r, hex($0.color))
    }.joined()
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 180 180" role="img" aria-label="Relay">\
    <rect width="180" height="180" rx="40" fill="#15130f"/>\(circles)</svg>

    """
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
try png(pixels: 180, inset: 0, corner: 0).write(to: root.appendingPathComponent("web/icon.png"))
try svg().write(to: root.appendingPathComponent("web/logo.svg"), atomically: true, encoding: .utf8)

// macOS icon: 824/1024 content with ~22% corner radius, per Apple's icon grid.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Relay.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png(pixels: points * scale, inset: 100.0 / 1024, corner: 185.0 / 1024)
            .write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Support/Relay.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote web/icon.png, web/logo.svg, Support/Relay.icns" : "iconutil failed")
