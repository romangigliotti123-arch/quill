import AppKit

/// Renders the real HUD views to PNG without a screen.
///
/// A floating panel cannot be screenshotted by a build agent — `CGWindowList`
/// needs Screen Recording, and the HUD deliberately never activates so there is
/// nothing to focus and capture. Without this, the only way to review the design
/// is to ship it and look, which is how default-looking UI survives.
///
/// Two things are approximated and neither is a lie worth forgetting: the
/// `NSVisualEffectView` is swapped for a flat fill because it samples a window
/// backdrop that does not exist offscreen, and the desktop behind the pill is
/// synthetic. Everything else — geometry, type, colour, the waveform's actual
/// sample history — is the shipping code.
public enum OverlayPreviewRenderer {

    public struct Shot: Sendable {
        public let name: String
        public let states: [(OverlayState, CGFloat)]
    }

    public static let shots: [Shot] = [
        Shot(name: "listening", states: [(.listening(level: 0), 1.9)]),
        Shot(name: "transcribing", states: [(.listening(level: 0), 1.2), (.transcribing, 0.9)]),
        Shot(name: "morph", states: [(.listening(level: 0), 1.2), (.transcribing, 0.09)]),
        Shot(name: "inserted", states: [(.transcribing, 0.6), (.inserted(words: 42), 0.5)]),
        Shot(name: "error", states: [(.error("Secure Input is on — quit Ghostty's secure entry"), 0.8)]),
        Shot(name: "entry", states: [(.listening(level: 0), 0.09)]),
    ]

    @discardableResult
    public static func renderAll(into directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for dark in [true, false] {
            for shot in shots {
                let url = directory.appendingPathComponent("\(shot.name)-\(dark ? "dark" : "light").png")
                let image = render(shot, dark: dark)
                try png(from: image).write(to: url)
                written.append(url)
            }
        }
        return written
    }

    // MARK: - Capture

    private static func render(_ shot: Shot, dark: Bool) -> CGImage {
        let size = OverlayMetrics.panelSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let host = OverlayHostView(frame: NSRect(origin: .zero, size: size))
        host.isDrivenExternally = true
        host.usesSyntheticMaterial = true
        window.contentView = host
        // Off in the corner of the coordinate space: AppKit only lays out and
        // fills layer contents for a window it considers on screen, but nothing
        // says that screen has to be one anybody is looking at.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()

        let dt: CGFloat = 1.0 / 60.0
        var clock: CGFloat = 0
        for (state, seconds) in shot.states {
            var remaining = seconds
            while remaining > 0 {
                host.present(level(state, at: clock))
                host.advance(dt: dt)
                remaining -= dt
                clock += dt
            }
        }

        host.layoutSubtreeIfNeeded()
        host.display()
        window.displayIfNeeded()
        // Non-negotiable. AppKit does not graft a subview's layer onto its
        // superview's layer until a display cycle runs, and neither `display()`
        // nor `displayIfNeeded()` triggers one for a window with no on-screen
        // area. Without this spin `host.layer` has two sublayers instead of the
        // whole tree, and every render comes back as an empty desktop.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        setContentsScale(2, on: host.layer)

        let scale = 2
        let context = CGContext(
            data: nil,
            width: Int(size.width) * scale, height: Int(size.height) * scale,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        drawDesktop(in: context, size: size, dark: dark)
        host.layer?.render(in: context)

        window.orderOut(nil)
        return context.makeImage()!
    }

    /// Speech-shaped level, including a real pause. A still of a waveform that
    /// never goes quiet proves nothing — the flat stretch is what shows the
    /// bars are history rather than an animation.
    private static func level(_ state: OverlayState, at t: CGFloat) -> OverlayState {
        guard case .listening = state else { return state }
        let syllable = pow(max(0, sin(t * 8.1)), 1.4)
        let stress = 0.40 + 0.60 * pow(max(0, sin(t * 2.3 + 0.9)), 0.6)
        // Hard gate: 1.15 s of speech, 0.55 s of nothing. Anything softer and
        // the envelope's release smooths the gap away before it reaches a bar.
        let cycle = t.truncatingRemainder(dividingBy: 1.70)
        let speaking: CGFloat = cycle < 1.15 ? 1 : 0
        let grain = 0.10 * (0.5 + 0.5 * sin(t * 37.7))
        return .listening(level: Float(min(1, (syllable * stress + grain) * speaking)))
    }

    private static func setContentsScale(_ scale: CGFloat, on layer: CALayer?) {
        guard let layer else { return }
        layer.contentsScale = scale
        layer.sublayers?.forEach { setContentsScale(scale, on: $0) }
    }

    // MARK: - Synthetic backdrop

    private static func drawDesktop(in context: CGContext, size: NSSize, dark: Bool) {
        let colors: [CGColor] = dark
            // Not pitch black: a dark HUD over a black rectangle always looks
            // like glass, because there is nothing behind it to fail to show.
            ? [NSColor(srgbRed: 0.17, green: 0.19, blue: 0.29, alpha: 1).cgColor,
               NSColor(srgbRed: 0.06, green: 0.07, blue: 0.11, alpha: 1).cgColor]
            : [NSColor(srgbRed: 0.90, green: 0.91, blue: 0.94, alpha: 1).cgColor,
               NSColor(srgbRed: 0.78, green: 0.80, blue: 0.85, alpha: 1).cgColor]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: size.height),
                                   end: CGPoint(x: size.width, y: 0),
                                   options: [])

        // A couple of soft blobs so the glass has something with structure to
        // sit over — a perfectly flat backdrop flatters translucency unfairly.
        let blob = dark
            ? NSColor(srgbRed: 0.30, green: 0.42, blue: 0.72, alpha: 0.30).cgColor
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.55).cgColor
        let clear = blob.copy(alpha: 0)!
        let radial = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                colors: [blob, clear] as CFArray, locations: [0, 1])!
        for centre in [CGPoint(x: size.width * 0.24, y: size.height * 0.78),
                       CGPoint(x: size.width * 0.82, y: size.height * 0.18)] {
            context.drawRadialGradient(radial, startCenter: centre, startRadius: 0,
                                       endCenter: centre, endRadius: size.height * 0.9,
                                       options: [])
        }
    }

    private static func png(from image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
