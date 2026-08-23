import AppKit
import QuartzCore

/// The HUD itself: a glass capsule that morphs between states, plus the single
/// animation loop that drives everything inside it.
///
/// One display link runs width, entry/exit, content crossfade, the waveform and
/// every glyph. That is deliberate — the moment two of those are on different
/// clocks (a `Timer` for the waveform, `NSAnimationContext` for the width) the
/// morph stops looking like one object changing shape and starts looking like
/// parts sliding past each other.
final class OverlayHostView: NSView {

    /// Called once the exit animation has actually finished, so the panel is
    /// ordered out on the frame the pill disappears rather than before it.
    var onDismissed: (() -> Void)?

    /// `NSVisualEffectView` samples the window's backdrop, which does not exist
    /// in an offscreen bitmap — it contributes nothing to a headless render.
    /// Swapping it for a flat approximation is the only way the design can be
    /// reviewed without a screen recording permission.
    var usesSyntheticMaterial = false {
        didSet {
            effect.isHidden = usesSyntheticMaterial
            applyPalette()
        }
    }

    private let pill = NSView()
    private let effect = NSVisualEffectView()
    private let material = CALayer()
    private let tint = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let hairline = CAShapeLayer()
    /// Three overlapping arcs of shrinking extent. Their alphas accumulate
    /// toward the crown, which fakes a tapered specular — the honest way to do
    /// it is a gradient-masked stroke, and masks are dropped by
    /// `CALayer.render(in:)`, so the highlight would become unreviewable.
    private let topEdges = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private let topEdgeSpans: [CGFloat] = [0.94, 0.80, 0.66]
    private let topEdgeWeights: [CGFloat] = [0.34, 0.30, 0.36]
    private let shadowNear = CALayer()
    private let shadowFar = CALayer()

    private var palette = OverlayPalette.dark

    private var width = OverlaySpring(value: OverlayMetrics.minPillWidth,
                                      target: OverlayMetrics.minPillWidth,
                                      stiffness: 300, damping: 28)
    private var presence = OverlaySpring(value: 0, target: 0, stiffness: 340, damping: 24)

    private var current: OverlayContentView?
    private var outgoing: OverlayContentView?
    private var crossfade: CGFloat = 1
    private var stateElapsed: CGFloat = 0
    private var level: CGFloat = 0
    private var state: OverlayState = .hidden
    private var isPresenting = false

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    /// Called with the real, unclamped gap between display-link callbacks, in
    /// seconds — after the physics have used the clamped version. Set only by
    /// `OverlayFrameStressTest`, which is the only caller that needs to know
    /// what the link actually did rather than what the springs were told.
    var frameObserver: ((CFTimeInterval) -> Void)?

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        // Two shadows, not one: a tight contact shadow to seat the pill on the
        // desktop and a wide soft one for the float. A single radius can do one
        // or the other, never both.
        for shadow in [shadowFar, shadowNear] { layer?.addSublayer(shadow) }

        pill.wantsLayer = true
        pill.layer?.cornerRadius = OverlayMetrics.pillRadius
        pill.layer?.cornerCurve = .continuous
        pill.layer?.masksToBounds = true

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        pill.addSubview(effect)

        tint.startPoint = CGPoint(x: 0.5, y: 1)
        tint.endPoint = CGPoint(x: 0.5, y: 0)
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0)
        hairline.fillColor = nil
        hairline.lineWidth = 1
        for edge in topEdges {
            edge.fillColor = nil
            edge.lineWidth = 1
            edge.lineCap = .round
        }

        for sublayer in [material, tint, sheen, hairline] + topEdges {
            pill.layer?.addSublayer(sublayer)
        }
        addSubview(pill)

        applyPalette()
        layoutPill()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    private func applyPalette() {
        palette = OverlayPalette.resolve(effectiveAppearance)
        effect.appearance = NSAppearance(named: palette.isDark ? .vibrantDark : .vibrantLight)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        material.backgroundColor = usesSyntheticMaterial ? palette.material : palette.materialFloor
        material.cornerRadius = OverlayMetrics.pillRadius
        material.cornerCurve = .continuous
        // Three stops, not two: real glass is bright along the top edge, neutral
        // through the belly and slightly shaded at the bottom. A straight
        // top-to-bottom ramp reads as a flat plastic button.
        tint.colors = [palette.tintTop, palette.tintMid, palette.tintBottom]
        tint.locations = [0, 0.42, 1]
        sheen.colors = [palette.sheen, palette.sheen.copy(alpha: 0) ?? palette.sheen]
        hairline.strokeColor = palette.hairline
        let crown = palette.topEdge.alpha
        for (edge, weight) in zip(topEdges, topEdgeWeights) {
            edge.strokeColor = palette.topEdge.copy(alpha: crown * weight)
        }
        shadowFar.shadowColor = palette.shadow
        shadowNear.shadowColor = palette.shadow
        shadowFar.shadowOpacity = palette.shadowFarOpacity
        shadowNear.shadowOpacity = palette.shadowNearOpacity
        shadowFar.shadowRadius = 26
        shadowNear.shadowRadius = 6
        shadowFar.shadowOffset = CGSize(width: 0, height: -10)
        shadowNear.shadowOffset = CGSize(width: 0, height: -2)
        CATransaction.commit()

        current?.apply(palette)
        outgoing?.apply(palette)
    }

    // MARK: - State

    func present(_ newState: OverlayState) {
        if case .hidden = newState { dismiss(); return }

        if case .listening(let value) = newState { level = CGFloat(value) }

        let firstAppearance = !isPresenting
        isPresenting = true
        presence.target = 1
        presence.damping = 24

        if !Self.sameContent(state, newState) {
            swapContent(for: newState, animated: !firstAppearance)
        }
        state = newState

        if firstAppearance {
            width.snap(to: clampedWidth(current?.contentWidth ?? OverlayMetrics.minPillWidth))
        } else {
            width.target = clampedWidth(current?.contentWidth ?? OverlayMetrics.minPillWidth)
        }

        startLink()
        advance(dt: 0)
    }

    func dismiss() {
        guard isPresenting else { onDismissed?(); return }
        isPresenting = false
        presence.target = 0
        // Stiffer on the way out: an overshoot on exit reads as a bounce off
        // the bottom of the screen, which looks like a bug.
        presence.damping = 34
        startLink()
    }

    /// Deliberately ignores the level payload — a new amplitude every 20 ms is
    /// not a new state, and treating it as one would restart the crossfade
    /// thirty times a second.
    private static func sameContent(_ a: OverlayState, _ b: OverlayState) -> Bool {
        if case .listening = a, case .listening = b { return true }
        return a == b
    }

    private func swapContent(for newState: OverlayState, animated: Bool) {
        outgoing?.removeFromSuperview()
        outgoing = animated ? current : nil
        current?.removeFromSuperview()

        let content: OverlayContentView
        switch newState {
        case .hidden:                  content = OverlayContentView(frame: .zero)
        case .listening:               content = OverlayListeningContent(frame: .zero)
        case .transcribing:            content = OverlayTranscribingContent(frame: .zero)
        case .inserted(let words):     content = OverlayInsertedContent(words: words)
        case .error(let message):      content = OverlayErrorContent(message: message)
        }
        content.apply(palette)
        if let outgoing { pill.addSubview(outgoing) }
        pill.addSubview(content)
        current = content
        crossfade = animated ? 0 : 1
        stateElapsed = 0
    }

    private func clampedWidth(_ w: CGFloat) -> CGFloat {
        min(max(w, OverlayMetrics.minPillWidth), OverlayMetrics.maxPillWidth)
    }

    // MARK: - Animation loop

    /// Set by the offscreen renderer, which steps `advance(dt:)` by hand so the
    /// captured frame is deterministic instead of "whenever the link fired".
    var isDrivenExternally = false

    private func startLink() {
        guard link == nil, !isDrivenExternally else { return }
        guard window != nil else { return }
        lastTimestamp = CACurrentMediaTime()
        let created = displayLink(target: self, selector: #selector(step(_:)))
        created.add(to: .main, forMode: .common)
        link = created
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        let real = now - lastTimestamp
        // Clamped so a stall (space switch, app launch) replays as one slow
        // frame instead of teleporting every spring past its target.
        let dt = CGFloat(min(max(real, 0), 1.0 / 30.0))
        lastTimestamp = now
        advance(dt: dt)
        frameObserver?(real)
    }

    /// Split out from the display link so an offscreen render can step the very
    /// same animation deterministically.
    func advance(dt: CGFloat) {
        let calm = reduceMotion
        stateElapsed += dt
        crossfade = min(1, crossfade + (calm ? 1 : dt / 0.18))
        width.step(dt, reduceMotion: calm)
        presence.step(dt, reduceMotion: calm)

        current?.advance(dt: dt, elapsed: stateElapsed, level: level)
        outgoing?.advance(dt: dt, elapsed: stateElapsed, level: level)

        if crossfade >= 1, outgoing != nil {
            outgoing?.removeFromSuperview()
            outgoing = nil
        }

        applyDwell()
        layoutPill()

        if !isPresenting && presence.isSettled {
            stopLink()
            current?.removeFromSuperview()
            current = nil
            state = .hidden
            onDismissed?()
        }
    }

    /// Terminal states dismiss themselves. The coordinator is free to call
    /// `hide()` too — it is idempotent — but a confirmation that lingers until
    /// someone remembers to remove it is how a HUD ends up stuck on screen.
    private func applyDwell() {
        guard isPresenting, crossfade >= 1 else { return }
        switch state {
        case .inserted where stateElapsed > 1.15: dismiss()
        case .error where stateElapsed > 3.2:     dismiss()
        default: break
        }
    }

    // MARK: - Layout

    private func layoutPill() {
        let w = width.value
        let h = OverlayMetrics.pillHeight
        let frame = NSRect(x: ((bounds.width - w) / 2).rounded(),
                           y: ((bounds.height - h) / 2).rounded(),
                           width: w.rounded(), height: h)
        pill.frame = frame

        let p = presence.value
        alphaValue = Double(min(max(p * 1.7, 0), 1))
        // Applied as a *sublayer* transform: AppKit owns `frame` on a
        // view-backed layer and will stomp anything written there during
        // layout, but it never touches sublayerTransform.
        let scale = 0.90 + 0.10 * p
        let lift = -12 * (1 - p)
        var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY + lift, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayerTransform = transform

        let capsule = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size),
                             cornerWidth: OverlayMetrics.pillRadius,
                             cornerHeight: OverlayMetrics.pillRadius, transform: nil)
        for shadow in [shadowFar, shadowNear] {
            shadow.frame = frame
            shadow.shadowPath = capsule
        }

        let inner = CGRect(origin: .zero, size: frame.size)
        material.frame = inner
        tint.frame = inner
        sheen.frame = CGRect(x: 0, y: inner.height * 0.56, width: inner.width, height: inner.height * 0.44)
        hairline.frame = inner
        hairline.path = CGPath(roundedRect: inner.insetBy(dx: 0.5, dy: 0.5),
                               cornerWidth: OverlayMetrics.pillRadius - 0.5,
                               cornerHeight: OverlayMetrics.pillRadius - 0.5, transform: nil)
        for (edge, span) in zip(topEdges, topEdgeSpans) {
            edge.frame = inner
            edge.path = topEdgePath(in: inner, span: span)
        }
        CATransaction.commit()

        layoutContent(in: inner)
    }

    /// A specular highlight along the top of the capsule only. A gradient-masked
    /// stroke would be prettier, but `CALayer.render(in:)` drops masks and this
    /// HUD has to stay reviewable offscreen.
    private func topEdgePath(in rect: CGRect, span: CGFloat) -> CGPath {
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        let r = inset.height / 2
        let start = .pi * (0.5 + 0.5 * span)
        let end = .pi * (0.5 - 0.5 * span)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: inset.minX + r, y: inset.midY), radius: r,
                    startAngle: start, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: inset.maxX - r, y: inset.maxY))
        path.addArc(center: CGPoint(x: inset.maxX - r, y: inset.midY), radius: r,
                    startAngle: .pi / 2, endAngle: end, clockwise: true)
        return path
    }

    private func layoutContent(in rect: CGRect) {
        let eased = OverlayEasing.outCubic(crossfade)
        if let current {
            place(current, in: rect, alpha: eased, lift: 5 * (1 - eased), scale: 0.96 + 0.04 * eased)
        }
        if let outgoing {
            place(outgoing, in: rect, alpha: 1 - eased, lift: -5 * eased, scale: 1 - 0.04 * eased)
        }
    }

    private func place(_ content: OverlayContentView, in rect: CGRect,
                       alpha: CGFloat, lift: CGFloat, scale: CGFloat) {
        let w = clampedWidth(content.contentWidth)
        content.frame = NSRect(x: ((rect.width - w) / 2).rounded(), y: 0, width: w, height: rect.height)
        content.alphaValue = Double(alpha)
        content.layoutSubtreeIfNeeded()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var transform = CATransform3DMakeTranslation(w / 2, rect.height / 2 + lift, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -w / 2, -rect.height / 2, 0)
        content.layer?.sublayerTransform = transform
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutPill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLink() } else if isPresenting || !presence.isSettled { startLink() }
    }
}
