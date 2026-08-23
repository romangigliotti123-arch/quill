import AppKit
import QuartzCore

/// Where the pill's fixed edge sits while its width springs — the edge
/// nearest the screen border it is docked to stays put, so growing never
/// pushes the pill off-screen or away from the corner it is anchored to.
enum PersistentOverlayAnchor {
    case left, center, right
}

/// The always-on button itself: a small glass pill, idle by default, that
/// widens on hover to show a label and switches to a live-mic dot while a
/// dictation it started is in progress.
///
/// Deliberately simpler than `OverlayHostView` — one gradient tint and one
/// shadow instead of three layered edges and a dual near/far shadow. That
/// view's complexity earns its keep because it is on screen for the whole
/// life of every dictation and was tuned frame by frame for it; this one is
/// idle almost all the time and two states, not five. Matching the material
/// (`NSVisualEffectView`, the same palette) gets the family resemblance
/// Roman asked for without importing tuning this view doesn't need.
final class PersistentOverlayHostView: NSView {

    var onClick: (() -> Void)?
    /// Fires from the second segment — only ever laid out or hit-testable
    /// when `showsNewNoteButton` is true.
    var onNewNote: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let tint = CAGradientLayer()
    private let hairline = CAShapeLayer()
    private let divider = CAShapeLayer()
    private let icon = NSImageView()
    private let label: NSTextField
    private let recordDot: OverlayRecordDot
    private let noteIcon = NSImageView()
    private let noteLabel: NSTextField

    private var palette = OverlayPalette.dark
    private var anchor: PersistentOverlayAnchor = .center
    private var isHovered = false
    private var isActive = false
    private var showsNewNoteButton = false

    private var width = OverlaySpring(value: PersistentOverlayMetrics.collapsedWidth,
                                      target: PersistentOverlayMetrics.collapsedWidth,
                                      stiffness: 340, damping: 30)
    private var labelAlpha: CGFloat = 0
    private var activeElapsed: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        label = OverlayType.label(12.5, .semibold)
        noteLabel = OverlayType.label(12.5, .semibold)
        recordDot = OverlayRecordDot(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        addSubview(effect)

        tint.locations = [0, 1]
        effect.layer?.addSublayer(tint)
        hairline.fillColor = nil
        hairline.lineWidth = 1
        effect.layer?.addSublayer(hairline)
        divider.fillColor = nil
        divider.lineWidth = 1
        effect.layer?.addSublayer(divider)

        icon.imageScaling = .scaleProportionallyDown
        icon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Dictate")
        addSubview(icon)

        label.alignment = .left
        addSubview(label)
        addSubview(recordDot)
        recordDot.isHidden = true

        noteIcon.imageScaling = .scaleProportionallyDown
        noteIcon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New note")
        addSubview(noteIcon)
        noteLabel.alignment = .left
        noteLabel.stringValue = "Note"
        addSubview(noteLabel)
        noteIcon.isHidden = true
        noteLabel.isHidden = true

        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - State

    func configure(anchor: PersistentOverlayAnchor, label text: String, showsNewNoteButton: Bool) {
        self.anchor = anchor
        label.stringValue = text
        self.showsNewNoteButton = showsNewNoteButton
        needsLayout = true
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        icon.isHidden = active
        recordDot.isHidden = !active
        activeElapsed = 0
        needsLayout = true
        ensureLink()
    }

    func applyStyle(_ appearance: NSAppearance?) {
        palette = OverlayPalette.resolve(appearance)
        applyPalette()
    }

    private func applyPalette() {
        tint.colors = [palette.tintTop, palette.tintBottom]
        hairline.strokeColor = palette.hairline
        divider.strokeColor = palette.hairline
        icon.contentTintColor = palette.primary
        label.textColor = palette.primary
        noteIcon.contentTintColor = palette.primary
        noteLabel.textColor = palette.primary
        recordDot.apply(palette)
        layer?.shadowColor = palette.shadow
        layer?.shadowOpacity = palette.shadowFarOpacity
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: 3)
    }

    // MARK: - Animation

    private func ensureLink() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = 0
    }

    private func stopLinkIfSettled() {
        guard !isActive, width.isSettled, abs(labelAlpha - targetLabelAlpha) < 0.01 else { return }
        link?.invalidate()
        link = nil
    }

    private var targetLabelAlpha: CGFloat { isHovered && !isActive ? 1 : 0 }

    @objc private func step(_ sender: CADisplayLink) {
        let now = sender.timestamp
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(now - lastTimestamp, 1.0 / 20)
        lastTimestamp = now

        let hoveredWidth = showsNewNoteButton
            ? PersistentOverlayMetrics.maxExpandedWidth : PersistentOverlayMetrics.expandedWidth
        width.target = isHovered ? hoveredWidth : PersistentOverlayMetrics.collapsedWidth
        width.step(CGFloat(dt), reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let target = targetLabelAlpha
        labelAlpha += (target - labelAlpha) * min(1, CGFloat(dt) * 10)

        if isActive {
            activeElapsed += CGFloat(dt)
            recordDot.advance(elapsed: activeElapsed)
        }

        layoutPill()
        stopLinkIfSettled()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        ensureLink()
        layoutPill()
    }

    /// The current pill frame and where the first segment ends within it —
    /// stashed here because `mouseUp` needs to know which segment was
    /// clicked, and layout is the only place that computes either.
    private var currentPillFrame: NSRect = .zero
    private var firstSegmentEnd: CGFloat = 0

    private func layoutPill() {
        let h = PersistentOverlayMetrics.height
        let w = max(PersistentOverlayMetrics.collapsedWidth, width.value)
        let margin = (bounds.width - PersistentOverlayMetrics.maxExpandedWidth) / 2
        let x: CGFloat
        switch anchor {
        case .left:   x = margin
        case .center: x = (bounds.width - w) / 2
        case .right:  x = bounds.width - margin - w
        }
        let y = (bounds.height - h) / 2
        let pillFrame = NSRect(x: x, y: y, width: w, height: h)
        currentPillFrame = pillFrame
        // Clamped to `w`: mid-spring, the pill can be narrower than a full
        // first segment, and the divider/second segment simply have nothing
        // to draw yet rather than overshooting the pill's own edge.
        firstSegmentEnd = min(pillFrame.minX + PersistentOverlayMetrics.expandedWidth, pillFrame.maxX)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effect.frame = pillFrame
        effect.layer?.cornerRadius = h / 2
        tint.frame = effect.bounds
        hairline.path = CGPath(roundedRect: effect.bounds.insetBy(dx: 0.5, dy: 0.5),
                               cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        layer?.shadowPath = CGPath(roundedRect: pillFrame, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)

        if showsNewNoteButton, w > PersistentOverlayMetrics.expandedWidth + 1 {
            let dividerX = firstSegmentEnd - pillFrame.minX
            let path = CGMutablePath()
            path.move(to: CGPoint(x: dividerX, y: 8))
            path.addLine(to: CGPoint(x: dividerX, y: h - 8))
            divider.path = path
            divider.opacity = Float(labelAlpha)
        } else {
            divider.path = nil
        }
        CATransaction.commit()

        let iconSize: CGFloat = 18
        icon.frame = NSRect(x: pillFrame.minX + (h - iconSize) / 2,
                            y: pillFrame.minY + (h - iconSize) / 2,
                            width: iconSize, height: iconSize)
        recordDot.frame = NSRect(x: pillFrame.minX + (h - 14) / 2, y: pillFrame.minY + (h - 14) / 2,
                                 width: 14, height: 14)

        let labelSize = label.fittingSize
        label.frame = NSRect(x: pillFrame.minX + h, y: pillFrame.minY + (h - labelSize.height) / 2,
                             width: max(0, firstSegmentEnd - (pillFrame.minX + h) - 8), height: labelSize.height)
        label.alphaValue = labelAlpha

        let showsSecondSegment = showsNewNoteButton && w > PersistentOverlayMetrics.expandedWidth + 1
        noteIcon.isHidden = !showsSecondSegment
        noteLabel.isHidden = !showsSecondSegment
        if showsSecondSegment {
            let segmentStart = firstSegmentEnd + 1
            let noteIconSize: CGFloat = 15
            noteIcon.frame = NSRect(x: segmentStart + 10, y: pillFrame.minY + (h - noteIconSize) / 2,
                                    width: noteIconSize, height: noteIconSize)
            let noteLabelSize = noteLabel.fittingSize
            noteLabel.frame = NSRect(x: segmentStart + 10 + noteIconSize + 4,
                                     y: pillFrame.minY + (h - noteLabelSize.height) / 2,
                                     width: max(0, pillFrame.maxX - (segmentStart + 10 + noteIconSize + 4) - 8),
                                     height: noteLabelSize.height)
            noteIcon.alphaValue = labelAlpha
            noteLabel.alphaValue = labelAlpha
        }
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways`, not `.activeInActiveApp` — the whole point of this
        // bar is to be hovered and clicked while some OTHER app is frontmost,
        // the one being dictated into. `.activeInActiveApp` is right for a
        // sidebar row inside Quill's own window, which is where this option
        // was copied from, and silently wrong here: it made hover only work
        // while Quill itself was the active app, so every real dictation
        // target — the app the pointer is actually hovering this bar from —
        // left the bar stuck collapsed. Clicking still worked, because
        // mouseDown/mouseUp delivery doesn't depend on tracking-area
        // activation; that is what made this easy to miss.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
        ensureLink()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.arrow.set()
        ensureLink()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard currentPillFrame.contains(point) else { return }
        if showsNewNoteButton, !noteIcon.isHidden, point.x >= firstSegmentEnd {
            onNewNote?()
        } else {
            onClick?()
        }
    }
}
