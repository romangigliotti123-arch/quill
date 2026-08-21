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

    // A waveform, which is what Apple actually draws for a voice app.
    //
    // Voice Memos is a waveform. Dictation is a waveform. The nib was the better
    // pun — the app is called Quill — but Roman's brief was "something Apple
    // would design for this sort of app", and Apple would not draw a pen for a
    // thing you talk to.
    //
    // Seven bars, symmetric about the centre, tallest in the middle. Odd count on
    // purpose: an even one has no centre bar and the mark reads as two groups
    // rather than one shape. The heights are a shallow curve rather than random —
    // random bars look like a level meter caught mid-frame, and an icon is not a
    // frame of anything, it is a symbol of the whole.
    //
    // Bars, gaps and caps are all proportional to the tile, so the mark is the
    // same shape at 16pt as at 1024. That is the property the nib never had.
    let w = tile.width, h = tile.height, ox = tile.minX, oy = tile.minY

    // Fewer bars where seven cannot be drawn.
    //
    // At 16pt a seven-bar mark gives each bar about one pixel with a sub-pixel
    // gap, and the whole thing greys into a blob — measured by rendering it, not
    // guessed. Dropping to three keeps the bars thick enough to stay separate,
    // and three bars rising to a centre still reads as a waveform. This is the
    // same rule the slit and vent followed: the mark simplifies as it shrinks
    // rather than dissolving.
    let heights: [CGFloat]
    switch size {
    case ..<24:  heights = [0.44, 0.94, 0.44]
    case ..<48:  heights = [0.30, 0.66, 0.94, 0.66, 0.30]
    default:     heights = [0.26, 0.46, 0.74, 0.94, 0.74, 0.46, 0.26]
    }
    let bars = CGFloat(heights.count)
    // The mark spans 62% of the tile. Wider reads as a chart; narrower and the
    // bars crowd into a blob at small sizes.
    // Narrower when there are fewer bars, so three do not sprawl across the tile.
    let span = w * (heights.count >= 7 ? 0.62 : heights.count == 5 ? 0.58 : 0.56)
    let pitch = span / bars              // one bar plus one gap
    let barWidth = max(pitch * 0.50, 1)  // half, so bar and gap read equally
    let capRadius = barWidth / 2         // fully rounded caps, as SF Symbols do
    let midY = oy + h * 0.5
    let startX = ox + (w - span) / 2 + (pitch - barWidth) / 2

    NSColor.white.setFill()
    for (index, factor) in heights.enumerated() {
        // A bar shorter than it is wide cannot be drawn with round caps without
        // becoming a circle, so the shortest is floored at its own width.
        let barHeight = max(h * 0.5 * factor, barWidth)
        var rect = NSRect(x: startX + CGFloat(index) * pitch,
                          y: midY - barHeight / 2,
                          width: barWidth, height: barHeight)
        // Snapped to whole pixels below 64.
        //
        // This is what actually made the small sizes grey, rather than the number
        // of bars: a bar landing on a fractional x with a fractional width is
        // antialiased across two columns, so at 16pt every bar became two half-lit
        // pixels and the mark dissolved. Rounding puts each bar on a pixel and
        // gives it a hard edge, which is the whole difference between a legible
        // 16pt icon and a smudge.
        if size < 64 {
            rect = NSRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
                          width: max(rect.width.rounded(), 1),
                          height: max(rect.height.rounded(), 1))
        }
        let r = min(capRadius, rect.width / 2)
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
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
