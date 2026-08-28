// Generates AppIcon.iconset: a marshmallow — Zephyr is зефир in Russian, and
// зефир is marshmallow in English, so the icon is the name.
//
// Drawn as geometry rather than traced from a picture, because the shape has
// to survive 16 points in the Finder sidebar as well as 1024 in the Dock, and
// a raster of a thin outline does not.
//
// Run: swift scripts/make-icon.swift <output-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetURL = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

// Three values in the whole icon, and no fourth.
let ground = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.051, alpha: 1)
let body = NSColor(srgbRed: 0.980, green: 0.816, blue: 0.863, alpha: 1)
let line = NSColor(srgbRed: 0.941, green: 0.443, blue: 0.565, alpha: 1)

/// A half ellipse, from the end of one semi-axis round to the other, bulging
/// by `reach` along `axis`. Two cubics per half is the standard circle
/// approximation, and at this size the error is well under a pixel.
let kappa: CGFloat = 0.5523

/// The marshmallow, built lying along the x axis and rotated into place.
///
/// Both ends are the same ellipse; the far one is hidden behind the body, so
/// only its outer half is drawn.
///
/// The sides are straight. Bowing them outward was the first attempt — a
/// cylinder can read as a medicine capsule, and a bulge is the usual cure —
/// but it puts a visible kink where the side meets the cap: the cap arc has
/// to leave horizontally, and a bowed side does not arrive that way. What
/// keeps this from looking pharmaceutical is being squat, with a cap wide
/// enough to see into.
func marshmallow(size: CGFloat) -> (silhouette: NSBezierPath, capEdge: NSBezierPath) {
    // The generous margin the large sizes want is a luxury at 16 points,
    // where every pixel spent on emptiness is one the shape does not get.
    let fill: CGFloat = size < 32 ? 1.14 : 1
    let halfLength = size * 0.145 * fill  // along the axis
    let radius = size * 0.195 * fill      // across it
    let cap = radius * 0.52               // how far a cap ellipse bulges

    let silhouette = NSBezierPath()
    // Upper side, near end to far end.
    silhouette.move(to: NSPoint(x: -halfLength, y: radius))
    silhouette.line(to: NSPoint(x: halfLength, y: radius))
    // Far cap, outer half.
    silhouette.curve(to: NSPoint(x: halfLength + cap, y: 0),
                     controlPoint1: NSPoint(x: halfLength + cap * kappa, y: radius),
                     controlPoint2: NSPoint(x: halfLength + cap, y: radius * kappa))
    silhouette.curve(to: NSPoint(x: halfLength, y: -radius),
                     controlPoint1: NSPoint(x: halfLength + cap, y: -radius * kappa),
                     controlPoint2: NSPoint(x: halfLength + cap * kappa, y: -radius))
    // Lower side, back again.
    silhouette.line(to: NSPoint(x: -halfLength, y: -radius))
    // Near cap, outer half.
    silhouette.curve(to: NSPoint(x: -halfLength - cap, y: 0),
                     controlPoint1: NSPoint(x: -halfLength - cap * kappa, y: -radius),
                     controlPoint2: NSPoint(x: -halfLength - cap, y: -radius * kappa))
    silhouette.curve(to: NSPoint(x: -halfLength, y: radius),
                     controlPoint1: NSPoint(x: -halfLength - cap, y: radius * kappa),
                     controlPoint2: NSPoint(x: -halfLength - cap * kappa, y: radius))
    silhouette.close()

    // The near cap's inner half. Drawn on top of the fill, it is the only
    // thing in the icon that says the shape has volume — there is no shading
    // anywhere else.
    let capEdge = NSBezierPath()
    capEdge.move(to: NSPoint(x: -halfLength, y: radius))
    capEdge.curve(to: NSPoint(x: -halfLength + cap, y: 0),
                  controlPoint1: NSPoint(x: -halfLength + cap * kappa, y: radius),
                  controlPoint2: NSPoint(x: -halfLength + cap, y: radius * kappa))
    capEdge.curve(to: NSPoint(x: -halfLength, y: -radius),
                  controlPoint1: NSPoint(x: -halfLength + cap, y: -radius * kappa),
                  controlPoint2: NSPoint(x: -halfLength + cap * kappa, y: -radius))

    // Lying diagonally, near end to the lower left.
    let place = NSAffineTransform()
    place.translateX(by: size / 2, yBy: size / 2)
    place.rotate(byDegrees: 38)
    silhouette.transform(using: place as AffineTransform)
    capEdge.transform(using: place as AffineTransform)
    return (silhouette, capEdge)
}

/// Stroke weight as a share of the icon.
///
/// Not a constant proportion. The drawing wants a fine line, and a fine line
/// at 16 points is a third of a pixel — it renders as a grey suggestion and
/// the outline breaks up. Small sizes get a disproportionately heavy line,
/// which is what every icon set that survives the Finder sidebar does.
func strokeWidth(_ size: CGFloat) -> CGFloat {
    switch size {
    case ..<24: return size * 0.075
    case ..<48: return size * 0.050
    case ..<96: return size * 0.030
    default: return size * 0.016
    }
}

func renderIcon(px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // The squircle every macOS icon sits in. Near-black rather than absolute:
    // a pure black tile has no edge at all against a dark Dock.
    let inset = size * 0.06
    let plate = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let plated = NSBezierPath(roundedRect: plate,
                              xRadius: plate.width * 0.225, yRadius: plate.width * 0.225)
    ground.setFill()
    plated.fill()

    let (silhouette, capEdge) = marshmallow(size: size)
    body.setFill()
    silhouette.fill()

    line.setStroke()
    // Below 32 points the near cap's edge lands within a pixel or two of the
    // outline and the two lines merge into a thick smudge. The shape reads
    // better as a clean silhouette there; detail that cannot be resolved is
    // not detail, it is noise.
    let strokes = size < 32 ? [silhouette] : [silhouette, capEdge]
    for path in strokes {
        path.lineWidth = strokeWidth(size)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

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
