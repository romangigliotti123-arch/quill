import AppKit

// Small drawn pieces. Deliberately none of them use a `CALayer.mask`: masks are
// dropped by `CALayer.render(in:)`, which is the only way to inspect this HUD
// offscreen, so anything built on one is a thing that can never be reviewed.

/// Live-mic dot with a halo that swells and dies on a fixed cadence. Reads as
/// "recording" instantly and costs one circle.
final class OverlayRecordDot: NSView {

    private let core = CALayer()
    private let halo = CALayer()
    private let coreSize: CGFloat = 7
    private let period: CGFloat = 1.7

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        halo.anchorPoint = .zero
        core.anchorPoint = .zero
        layer?.addSublayer(halo)
        layer?.addSublayer(core)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ palette: OverlayPalette) {
        core.backgroundColor = palette.accent.cgColor
        halo.backgroundColor = palette.accent.cgColor
    }

    func advance(elapsed: CGFloat) {
        let phase = (elapsed.truncatingRemainder(dividingBy: period)) / period
        let spread = OverlayEasing.outCubic(phase)
        let haloSize = coreSize * (1 + 1.9 * spread)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        core.frame = CGRect(x: centre.x - coreSize / 2, y: centre.y - coreSize / 2,
                            width: coreSize, height: coreSize)
        core.cornerRadius = coreSize / 2
        halo.frame = CGRect(x: centre.x - haloSize / 2, y: centre.y - haloSize / 2,
                            width: haloSize, height: haloSize)
        halo.cornerRadius = haloSize / 2
        halo.opacity = Float(0.30 * (1 - spread))
        CATransaction.commit()
    }
}

/// Three dots on a travelling sine. Chosen over a spinner because it rhymes
/// with the waveform it replaces — the pill reads as one object changing mode
/// rather than two unrelated indicators swapping places.
final class OverlayThinkingDots: NSView {

    private let dots: [CALayer]
    private let dotSize: CGFloat = 5.5
    private let spacing: CGFloat = 5.5
    private let period: CGFloat = 1.05

    var intrinsicWidth: CGFloat { CGFloat(dots.count - 1) * (dotSize + spacing) + dotSize }

    override init(frame frameRect: NSRect) {
        dots = (0..<3).map { _ in
            let layer = CALayer()
            layer.anchorPoint = .zero
            return layer
        }
        super.init(frame: frameRect)
        wantsLayer = true
        dots.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ palette: OverlayPalette) {
        dots.forEach { $0.backgroundColor = palette.accent.cgColor }
    }

    func advance(elapsed: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            let phase = elapsed / period * 2 * .pi - CGFloat(index) * 0.62
            let wave = 0.5 + 0.5 * sin(phase)
            let size = dotSize * (0.74 + 0.36 * wave)
            let x = CGFloat(index) * (dotSize + spacing) + (dotSize - size) / 2
            dot.frame = CGRect(x: x, y: bounds.midY - size / 2, width: size, height: size)
            dot.cornerRadius = size / 2
            dot.opacity = Float(0.48 + 0.52 * wave)
        }
        CATransaction.commit()
    }
}

/// Checkmark that strokes itself on. The draw-in is the whole point: a static
/// tick tells you the state, a drawn one tells you the state *just changed*,
/// which is the only information a 900 ms confirmation has to carry.
final class OverlayCheckmark: NSView {

    private let stroke = CAShapeLayer()
    private let delay: CGFloat = 0.04
    private let duration: CGFloat = 0.30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        stroke.fillColor = nil
        stroke.lineWidth = 2.1
        stroke.lineCap = .round
        stroke.lineJoin = .round
        stroke.strokeEnd = 0
        layer?.addSublayer(stroke)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ palette: OverlayPalette) {
        stroke.strokeColor = palette.accent.cgColor
    }

    func advance(elapsed: CGFloat) {
        let path = CGMutablePath()
        let w = bounds.width, h = bounds.height
        path.move(to: CGPoint(x: w * 0.18, y: h * 0.52))
        path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.28))
        path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.74))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.frame = bounds
        stroke.path = path
        stroke.strokeEnd = OverlayEasing.outCubic((elapsed - delay) / duration)
        CATransaction.commit()
    }
}

/// The `esc` hint. `ignoresMouseEvents` rules out a real button, so the only
/// honest affordance the HUD can offer is naming the key.
final class OverlayKeyCap: NSView {

    private let plate = CAShapeLayer()
    private let label = OverlayType.label(9, .medium)

    var intrinsicWidth: CGFloat { 25 }
    var intrinsicHeight: CGFloat { 15 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        plate.lineWidth = 1
        layer?.addSublayer(plate)
        label.stringValue = "esc"
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ palette: OverlayPalette) {
        // Filled and barely-there rather than outlined. An outlined chip on a
        // HUD that cannot be clicked reads as a disabled button; a soft plate
        // reads as what it is — the name of a key.
        // Absolute alphas, not fractions of `secondary` — `withAlphaComponent`
        // replaces the alpha rather than scaling it, and reading it as a scale
        // is how this chip ended up brighter than the waveform it annotates.
        plate.fillColor = palette.secondary.withAlphaComponent(0.07).cgColor
        plate.strokeColor = palette.secondary.withAlphaComponent(0.10).cgColor
        label.textColor = palette.secondary.withAlphaComponent(0.30)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds
        plate.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                            cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
        CATransaction.commit()
        let height = OverlayType.height(of: label)
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2 - 0.5,
                             width: bounds.width, height: height)
    }
}
