import AppKit

/// Renders any dashboard section to a PNG without launching Quill.
///
/// The same argument as `OverlayPreviewRenderer`, for a different reason: this
/// window *can* be screenshotted, but only by a human who has already launched
/// the app, looked at it and decided. That loop is too slow to iterate a design
/// in, and a design nobody iterates on ships looking like a template. Every
/// agent that builds a section can call this and read its own work back.
///
/// The output is 1350x850 at 2x — Wispr Flow's window size exactly, so the two
/// can be compared like for like rather than by impression.
///
/// One thing is synthetic and worth remembering: the traffic lights are drawn
/// by hand, because an offscreen borderless window has no titlebar buttons.
/// Their positions match the system's. Everything else — layout, type, colour,
/// shadow — is the shipping view hierarchy, drawn by the shipping code. That is
/// only true because nothing in the dashboard uses `NSVisualEffectView`; a
/// vibrant surface would render as a hole here and the preview would be a lie.
public enum DashboardPreviewRenderer {

    public static let size = DashboardMetrics.windowSize
    public static let scale: CGFloat = 2

    // MARK: - Public

    @discardableResult
    public static func write(section: DashboardSection,
                             dark: Bool,
                             provider: DashboardSectionProvider? = nil,
                             to url: URL) throws -> URL {
        let image = render(section: section, dark: dark, provider: provider)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try png(from: image).write(to: url)
        return url
    }

    /// Every section, both themes. What a build agent runs before claiming a
    /// screen is done.
    @discardableResult
    public static func renderAll(into directory: URL,
                                 sections: [DashboardSection] = DashboardSection.allCases,
                                 provider: DashboardSectionProvider? = nil) throws -> [URL] {
        var written: [URL] = []
        for dark in [false, true] {
            for section in sections {
                let url = directory.appendingPathComponent("dashboard-\(section.rawValue)-\(dark ? "dark" : "light").png")
                written.append(try write(section: section, dark: dark, provider: provider, to: url))
            }
        }
        return written
    }

    /// Entry point for `QUILL_DASHBOARD_SHOTS=/some/dir`, so the renderer is
    /// reachable from a shell without a test target.
    public static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["QUILL_DASHBOARD_SHOTS"] else { return false }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let only = ProcessInfo.processInfo.environment["QUILL_DASHBOARD_SECTIONS"]?
            .split(separator: ",")
            .compactMap { DashboardSection(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        do {
            let urls = try renderAll(into: directory,
                                     sections: (only?.isEmpty == false ? only! : DashboardSection.allCases),
                                     provider: DashboardSectionRegistry.shared)
            urls.forEach { print($0.path) }
        } catch {
            FileHandle.standardError.write(Data("dashboard render failed: \(error)\n".utf8))
            exit(1)
        }
        return true
    }

    // MARK: - Capture

    public static func render(section: DashboardSection,
                              dark: Bool,
                              provider: DashboardSectionProvider? = nil) -> CGImage {
        // AppKit will not lay out or fill layer contents without an application
        // object, even for a window nobody sees.
        _ = NSApplication.shared
        if NSApp.activationPolicy() != .prohibited && !NSApp.isRunning {
            NSApp.setActivationPolicy(.prohibited)
        }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let style: DashboardStyle = dark ? .dark : .light
        let root = DashboardRootView(style: style, selection: section, provider: provider)
        root.frame = NSRect(origin: .zero, size: size)
        window.contentView = root

        // Parked off the edge of the coordinate space. AppKit only lays out and
        // rasterises for a window it considers on screen; nothing requires that
        // screen to be one anybody is looking at.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()

        root.layoutSubtreeIfNeeded()
        setContentsScale(scale, on: root.layer)
        root.display()
        window.displayIfNeeded()
        // Non-negotiable, and the same trap the overlay renderer documents:
        // AppKit does not graft a subview's layer onto its superview's until a
        // display cycle actually runs, and no amount of `display()` triggers one
        // for a window with no on-screen area. Without this spin the render
        // comes back as an empty canvas with two stray layers on it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        root.layoutSubtreeIfNeeded()
        setContentsScale(scale, on: root.layer)
        setNeedsDisplay(root)
        root.displayIfNeeded()

        let context = CGContext(
            data: nil,
            width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)

        // macOS rounds the window's corners for us on screen; offscreen we have
        // to, or the PNG reads as a cropped web page rather than a window.
        let frame = NSRect(origin: .zero, size: size)
        context.saveGState()
        context.addPath(CGPath(roundedRect: frame,
                               cornerWidth: DashboardRadius.window,
                               cornerHeight: DashboardRadius.window,
                               transform: nil))
        context.clip()
        // The dashboard's views are flipped (top-left origin), so their layers
        // carry `isGeometryFlipped` — and a plain bitmap context is y-up. Render
        // the tree through a mirror or the entire window comes out upside down,
        // glyph by glyph.
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        root.layer?.render(in: context)
        context.restoreGState()
        drawTrafficLights(in: context, size: size, dark: dark)
        context.restoreGState()

        // The window edge. One hairline of contrast is what separates the
        // canvas from whatever the screenshot is pasted onto.
        context.saveGState()
        context.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                               cornerWidth: DashboardRadius.window - 0.5,
                               cornerHeight: DashboardRadius.window - 0.5,
                               transform: nil))
        context.setStrokeColor((dark ? DashboardStyle.dark : DashboardStyle.light).windowEdge.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        window.orderOut(nil)
        return context.makeImage()!
    }

    // MARK: - Chrome

    /// Synthetic. Standard macOS geometry: 12pt circles, 20pt apart, centred
    /// 20pt in from the leading edge and 20pt down from the top.
    private static func drawTrafficLights(in context: CGContext, size: NSSize, dark: Bool) {
        let colors: [(NSColor, NSColor)] = [
            (NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1), NSColor(srgbRed: 0.86, green: 0.26, blue: 0.24, alpha: 1)),
            (NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1), NSColor(srgbRed: 0.87, green: 0.60, blue: 0.10, alpha: 1)),
            (NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.11, green: 0.65, blue: 0.18, alpha: 1)),
        ]
        let y = size.height - 20
        for (index, pair) in colors.enumerated() {
            let centre = CGPoint(x: 20 + CGFloat(index) * 20, y: y)
            let rect = CGRect(x: centre.x - 6, y: centre.y - 6, width: 12, height: 12)
            context.setFillColor(pair.0.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(pair.1.withAlphaComponent(dark ? 0.35 : 0.5).cgColor)
            context.setLineWidth(0.5)
            context.strokeEllipse(in: rect.insetBy(dx: 0.25, dy: 0.25))
        }
    }

    // MARK: - Plumbing

    private static func setContentsScale(_ scale: CGFloat, on layer: CALayer?) {
        guard let layer else { return }
        layer.contentsScale = scale
        layer.sublayers?.forEach { setContentsScale(scale, on: $0) }
    }

    /// Raising `contentsScale` invalidates every view's backing store, and only
    /// a view that knows it is dirty will redraw at the new scale. Skip this and
    /// the whole render comes back as a 1x bitmap stretched to 2x.
    private static func setNeedsDisplay(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(setNeedsDisplay)
    }

    private static func png(from image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
