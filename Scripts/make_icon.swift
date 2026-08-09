import AppKit

// Renders Quill's app icon from the same nib geometry the sidebar mark uses, so
// the icon and the in-app mark cannot drift apart.
//
// macOS icon conventions the naive version gets wrong: the artwork is NOT
// edge-to-edge — a 1024pt canvas carries roughly a 100pt margin so the tile
// matches the optical size of every other icon in the Dock; the corner is a
// continuous ("squircle") curve, not a plain rounded rect; and the whole thing
// needs a shadow-free, opaque tile because the Dock composites its own.

func squircle(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    // NSBezierPath's rounded rect is a circular arc. Apple's is a continuous
    // curve, which reads noticeably softer at large sizes.
    let path = NSBezierPath()
    let r = min(radius, min(rect.width, rect.height) / 2)
    let k = r * 0.2447  // continuous-curvature control offset
    let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
    path.move(to: NSPoint(x: x0 + r, y: y0))
    path.line(to: NSPoint(x: x1 - r, y: y0))
    path.curve(to: NSPoint(x: x1, y: y0 + r),
               controlPoint1: NSPoint(x: x1 - k, y: y0), controlPoint2: NSPoint(x: x1, y: y0 + k))
    path.line(to: NSPoint(x: x1, y: y1 - r))
    path.curve(to: NSPoint(x: x1 - r, y: y1),
               controlPoint1: NSPoint(x: x1, y: y1 - k), controlPoint2: NSPoint(x: x1 - k, y: y1))
    path.line(to: NSPoint(x: x0 + r, y: y1))
    path.curve(to: NSPoint(x: x0, y: y1 - r),
               controlPoint1: NSPoint(x: x0 + k, y: y1), controlPoint2: NSPoint(x: x0, y: y1 - k))
    path.line(to: NSPoint(x: x0, y: y0 + r))
    path.curve(to: NSPoint(x: x0 + r, y: y0),
               controlPoint1: NSPoint(x: x0, y: y0 + k), controlPoint2: NSPoint(x: x0 + k, y: y0))
    path.close()
    return path
}

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let margin = size * 0.098
    let tile = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = tile.width * 0.2237   // Apple's ratio for app tiles

    // Warm near-black, matching DashboardStyle.light.fill (#1A1712).
    let base = NSColor(srgbRed: 0.102, green: 0.090, blue: 0.071, alpha: 1)
    let lift = NSColor(srgbRed: 0.196, green: 0.176, blue: 0.145, alpha: 1)
    let clip = squircle(tile, radius: radius)
    clip.addClip()
    NSGradient(starting: lift, ending: base)?.draw(in: tile, angle: -90)

    // The nib, in the app's cream. Same control points as DashboardMark, scaled.
    let w = tile.width, h = tile.height, ox = tile.minX, oy = tile.minY
    func p(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint { NSPoint(x: ox + w * fx, y: oy + h * fy) }

    let nib = NSBezierPath()
    let top = p(0.5, 0.16), bottom = p(0.5, 0.86)
    nib.move(to: top)
    nib.curve(to: bottom, controlPoint1: p(0.82, 0.37), controlPoint2: p(0.67, 0.71))
    nib.curve(to: top, controlPoint1: p(0.33, 0.71), controlPoint2: p(0.18, 0.37))
    NSColor(srgbRed: 0.992, green: 0.988, blue: 0.976, alpha: 1).setFill()
    nib.fill()

    // Slit and vent, cut back to the tile so the nib reads as a nib and not a leaf.
    base.setFill()
    let slitWidth = max(size * 0.012, 1)
    NSBezierPath(rect: NSRect(x: ox + w * 0.5 - slitWidth / 2, y: oy + h * 0.29,
                              width: slitWidth, height: h * 0.42)).fill()
    let vent = size * 0.075
    NSBezierPath(ovalIn: NSRect(x: ox + w * 0.5 - vent / 2, y: oy + h * 0.485,
                                width: vent, height: vent)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
// The exact set iconutil expects. Missing sizes make macOS scale the nearest
// one, which is how an icon ends up soft in the Dock but crisp in Finder.
let plan: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in plan {
    let rep = render(size: CGFloat(px))
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: out.appendingPathComponent("\(name).png"))
}
print("wrote \(plan.count) sizes")
