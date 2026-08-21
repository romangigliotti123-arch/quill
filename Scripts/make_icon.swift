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

    // FLAT. No gradient, and that is the rule rather than a preference.
    //
    // Apple's current icon guidance for the Liquid Glass era is explicit: do not
    // bake shadows, highlights or gradients into the artwork, because the system
    // now lights the icon itself in real time and a pre-rendered gloss collides
    // with that lighting and reads as muddy. The previous version drew a vertical
    // gradient from #322D25 to #1A1712 — exactly the thing that is now wrong.
    //
    // A near-black tile rather than a colour: his Mac runs the Graphite accent
    // and the whole app is monochrome, so a vivid tile would be the one loud
    // object on the screen.
    let tileColour = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.094, alpha: 1)
    let clip = squircle(tile, radius: radius)
    clip.addClip()
    tileColour.setFill()
    clip.fill()

    // The nib, redrawn for legibility rather than for detail.
    //
    // The old mark carried a hairline slit and a vent hole sized at 1.2% and 7.5%
    // of the canvas. At 16pt — the Finder list, the ⌘-Tab switcher, the menu bar —
    // that slit is a single pixel and the vent is barely two, so both alias into
    // grey mush and the nib reads as a leaf. Apple's own marks survive 16pt
    // because they are a handful of bold shapes and nothing else.
    //
    // So: a wider nib, a slit that scales with the shape instead of with the
    // canvas, and the vent dropped entirely below the size where it can be seen.
    let w = tile.width, h = tile.height, ox = tile.minX, oy = tile.minY
    func p(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint { NSPoint(x: ox + w * fx, y: oy + h * fy) }

    // A nib is not a leaf, and the difference is asymmetry.
    //
    // The previous silhouette was pointed at BOTH ends and widest in the middle,
    // which is the shape of a leaf — and read as one at every size. A real nib
    // has a broad shoulder where it meets the barrel and tapers to a single point
    // at the writing end. Getting that one relationship right does more for
    // recognition than any amount of detail inside it.
    //
    // It is also much bigger than it was. The glyph filled about 55% of the tile,
    // which is why 16pt came out as a smudge; Apple's marks sit closer to 70% and
    // that headroom is most of what makes them survive the Finder list.
    let nib = NSBezierPath()
    let tip = p(0.5, 0.10)          // the writing point
    let shoulder = p(0.5, 0.92)     // the broad end
    nib.move(to: tip)
    // Right side: out to the widest point just above centre, then in to the
    // shoulder. Control points chosen so the widest part sits at ~0.62, which is
    // where a nib actually swells.
    nib.curve(to: shoulder,
              controlPoint1: p(0.30, 0.30), controlPoint2: p(0.14, 0.78))
    nib.curve(to: tip,
              controlPoint1: p(0.86, 0.78), controlPoint2: p(0.70, 0.30))
    NSColor.white.setFill()
    nib.fill()

    // The slit runs from the tip toward the vent, as it does on a real nib —
    // it is what stops the shape reading as a solid petal. Proportional to the
    // nib's width with a one-pixel floor, so it never disappears and never
    // becomes a gash.
    //
    // Below 48pt it is not drawn at all. A slit two pixels wide does not read as
    // a slit, it reads as the shape having gone slightly grey in the middle —
    // which is worse than a clean silhouette. Same rule as the vent below: detail
    // appears only at the sizes that can resolve it, and every size below that
    // gets the boldest honest version of the mark.
    if size >= 48 {
        tileColour.setFill()
        let slitWidth = max(w * 0.045, 1)
        NSBezierPath(rect: NSRect(x: ox + w * 0.5 - slitWidth / 2, y: oy + h * 0.16,
                                  width: slitWidth, height: h * 0.44)).fill()
    }

    // The vent only exists where it can be resolved. Below ~128pt it is fewer
    // than four pixels across and contributes nothing but a smudge.
    if size >= 128 {
        let vent = w * 0.11
        NSBezierPath(ovalIn: NSRect(x: ox + w * 0.5 - vent / 2, y: oy + h * 0.555,
                                    width: vent, height: vent)).fill()
    }

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
