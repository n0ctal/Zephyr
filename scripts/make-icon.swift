// Generates AppIcon.icns: a speedometer gauge on a cool blue gradient (the
// "Zephyr" identity). Run: swift scripts/make-icon.swift <output-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetURL = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func renderIcon(px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = size * 0.06
    let bg = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = bg.width * 0.225
    let bgPath = NSBezierPath(roundedRect: bg, xRadius: radius, yRadius: radius)
    NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.80, blue: 0.94, alpha: 1),
        NSColor(srgbRed: 0.13, green: 0.46, blue: 0.86, alpha: 1),
    ])!.draw(in: bgPath, angle: -90)

    NSColor.white.setStroke()
    NSColor.white.setFill()

    let cx = size / 2, cy = size * 0.555, R = size * 0.255
    let a1 = 200.0, a2 = -20.0   // sweep over the top, gap at bottom

    func pt(_ deg: Double, _ rr: CGFloat) -> NSPoint {
        let r = deg * .pi / 180
        return NSPoint(x: cx + rr * CGFloat(cos(r)), y: cy + rr * CGFloat(sin(r)))
    }

    // Arc.
    let arc = NSBezierPath()
    var deg = a1
    var first = true
    while deg >= a2 {
        let p = pt(deg, R)
        if first { arc.move(to: p); first = false } else { arc.line(to: p) }
        deg -= 3
    }
    arc.lineWidth = size * 0.052
    arc.lineCapStyle = .round
    arc.lineJoinStyle = .round
    arc.stroke()

    // Ticks.
    for i in 0...6 {
        let t = a1 + (a2 - a1) * Double(i) / 6.0
        let tick = NSBezierPath()
        tick.move(to: pt(t, R * 0.78))
        tick.line(to: pt(t, R * 0.99))
        tick.lineWidth = size * 0.026
        tick.lineCapStyle = .round
        tick.stroke()
    }

    // Needle (points up-right ~70% of the dial).
    let needle = NSBezierPath()
    needle.move(to: NSPoint(x: cx, y: cy))
    needle.line(to: pt(52, R * 0.84))
    needle.lineWidth = size * 0.05
    needle.lineCapStyle = .round
    needle.stroke()

    // Hub.
    let hubR = size * 0.06
    NSBezierPath(ovalIn: NSRect(x: cx - hubR, y: cy - hubR, width: 2 * hubR, height: 2 * hubR)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    try! renderIcon(px: px).write(to: iconsetURL.appendingPathComponent("\(name).png"))
}
print("Wrote \(iconsetURL.path)")
