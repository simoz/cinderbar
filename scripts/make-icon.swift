// Draws the app icon: Cinder Bar's mirrored strip on a charcoal tile.
// Claude orange on the left, Codex teal on the right, white-hot against the
// "now" divider, a cinder glow underneath.
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let claude = rgb(0.851, 0.467, 0.341), codex = rgb(0.169, 0.710, 0.651)
let ember = rgb(0.24, 0.10, 0.06), amber = rgb(1.0, 0.71, 0.20), whiteHot = rgb(1.0, 0.97, 0.90)

func heat(_ t: Double, _ agent: NSColor) -> NSColor {
    let stops: [(Double, NSColor)] = [(0, ember), (0.45, agent), (0.78, amber), (1, whiteHot)]
    for i in 1..<stops.count where t <= stops[i].0 {
        let (a, ca) = stops[i - 1], (b, cb) = stops[i]
        return ca.blended(withFraction: (t - a) / (b - a), of: cb) ?? cb
    }
    return whiteHot
}

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // The macOS tile: 824pt square, 100pt margin, continuous-looking corners.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    rgb(0.09, 0.085, 0.10).setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    shape.addClip()
    NSGradient(colors: [rgb(0.17, 0.155, 0.18), rgb(0.07, 0.065, 0.08)])!.draw(in: tile, angle: -90)

    // Cinder glow rising from below the divider.
    let glowCenter = NSPoint(x: 512 * s, y: 330 * s)
    NSGradient(colors: [rgb(1.0, 0.55, 0.18, 0.55), rgb(0.85, 0.30, 0.10, 0.18), rgb(0.5, 0.15, 0.05, 0)])!
        .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 430 * s, options: [])

    // The strip: five cells a side, hottest against the divider.
    let cellW: CGFloat = 48 * s, gap: CGFloat = 14 * s, maxH: CGFloat = 320 * s
    let midY: CGFloat = 540 * s
    let left: [Double] = [0.18, 0.34, 0.55, 0.80, 1.0]     // oldest → newest
    let right: [Double] = [0.97, 0.47, 0.40, 0.28, 0.15]   // newest → oldest
    let dividerGap: CGFloat = 28 * s
    func cell(_ x: CGFloat, _ t: Double, _ agent: NSColor) {
        let h = maxH * CGFloat(0.62 + 0.38 * t)
        let r = NSRect(x: x, y: midY - h / 2, width: cellW, height: h)
        heat(t, agent).setFill()
        NSBezierPath(roundedRect: r, xRadius: 12 * s, yRadius: 12 * s).fill()
        if t > 0.97 {
            whiteHot.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: cellW * 0.38, dy: 26 * s), xRadius: 6 * s, yRadius: 6 * s).fill()
        }
    }
    var x = 512 * s - dividerGap - CGFloat(left.count) * (cellW + gap) + gap
    for t in left { cell(x, t, claude); x += cellW + gap }
    x = 512 * s + dividerGap
    for t in right { cell(x, t, codex); x += cellW + gap }

    // The divider: always "now".
    let divider = NSRect(x: 512 * s - 5 * s, y: midY - maxH / 2 - 40 * s, width: 10 * s, height: maxH + 80 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = rgb(1, 0.85, 0.6, 0.9)
    glow.shadowBlurRadius = 26 * s
    glow.set()
    whiteHot.setFill()
    NSBezierPath(roundedRect: divider, xRadius: 5 * s, yRadius: 5 * s).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Plan gauges under each lane.
    let gaugeY = midY - maxH / 2 - 78 * s
    let laneW = CGFloat(left.count) * (cellW + gap) - gap
    NSColor(white: 1, alpha: 0.14).setFill()
    NSBezierPath(roundedRect: NSRect(x: 512 * s - dividerGap - laneW, y: gaugeY, width: laneW, height: 12 * s), xRadius: 6 * s, yRadius: 6 * s).fill()
    NSBezierPath(roundedRect: NSRect(x: 512 * s + dividerGap, y: gaugeY, width: laneW, height: 12 * s), xRadius: 6 * s, yRadius: 6 * s).fill()
    claude.setFill()
    NSBezierPath(roundedRect: NSRect(x: 512 * s - dividerGap - laneW, y: gaugeY, width: laneW * 0.62, height: 12 * s), xRadius: 6 * s, yRadius: 6 * s).fill()
    codex.setFill()
    NSBezierPath(roundedRect: NSRect(x: 512 * s + dividerGap + laneW * 0.7, y: gaugeY, width: laneW * 0.3, height: 12 * s), xRadius: 6 * s, yRadius: 6 * s).fill()

    // A few sparks over the hottest cells.
    let sparks: [(CGFloat, CGFloat, CGFloat, Double)] = [(470, 760, 7, 0.9), (540, 800, 5, 0.75), (505, 840, 4, 0.55), (575, 745, 6, 0.8), (440, 820, 4, 0.5)]
    for (sx, sy, r, a) in sparks {
        rgb(1.0, 0.80, 0.45, a).setFill()
        NSBezierPath(ovalIn: NSRect(x: sx * s - r * s, y: sy * s - r * s, width: 2 * r * s, height: 2 * r * s)).fill()
    }

    // A faint top highlight, as on Apple's tiles.
    NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try draw(size: 1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
