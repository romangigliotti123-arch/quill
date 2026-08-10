import AppKit

/// One of these per `OverlayState`. Each owns its own width so the pill can ask
/// what it should morph to, rather than a switch statement somewhere holding a
/// table of magic numbers that goes stale the moment the copy changes.
class OverlayContentView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    var contentWidth: CGFloat { OverlayMetrics.minPillWidth }
    func apply(_ palette: OverlayPalette) {}
    func advance(dt: CGFloat, elapsed: CGFloat, level: CGFloat) {}
}

final class OverlayListeningContent: OverlayContentView {

    private let dot = OverlayRecordDot(frame: .zero)
    private let waveform = OverlayWaveform(frame: .zero)
    private let keyCap = OverlayKeyCap(frame: .zero)

    private let leading: CGFloat = 12
    private let dotBox: CGFloat = 18
    private let dotToWave: CGFloat = 8
    private let waveToCap: CGFloat = 12
    private let trailing: CGFloat = 13

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Waveform only. The dot said "recording" next to a waveform that was
        // already moving, and the esc chip taught a shortcut every time you spoke
        // rather than the once you needed it. What is left is the smallest thing
        // that still answers "is it hearing me".
        addSubview(waveform)
    }

    required init?(coder: NSCoder) { nil }

    override var contentWidth: CGFloat {
        leading + waveform.intrinsicWidth + trailing
    }

    override func apply(_ palette: OverlayPalette) {
        waveform.apply(palette)
    }

    override func layout() {
        super.layout()
        waveform.frame = NSRect(x: leading, y: 0,
                                width: waveform.intrinsicWidth, height: bounds.height)
    }

    override func advance(dt: CGFloat, elapsed: CGFloat, level: CGFloat) {
        waveform.level = level
        waveform.advance(dt: dt)
    }
}

final class OverlayTranscribingContent: OverlayContentView {

    private let dots = OverlayThinkingDots(frame: .zero)
    private let label = OverlayType.label(13, .medium)

    private let leading: CGFloat = 16
    private let gap: CGFloat = 11
    private let trailing: CGFloat = 20

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.stringValue = "Transcribing"
        addSubview(dots)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override var contentWidth: CGFloat {
        leading + dots.intrinsicWidth + gap + labelWidth + trailing
    }

    private var labelWidth: CGFloat { OverlayType.width(of: label) }

    override func apply(_ palette: OverlayPalette) {
        dots.apply(palette)
        label.textColor = palette.primary
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        dots.frame = NSRect(x: leading, y: 0, width: dots.intrinsicWidth, height: h)
        let labelHeight = OverlayType.height(of: label)
        label.frame = NSRect(x: leading + dots.intrinsicWidth + gap,
                             y: (h - labelHeight) / 2,
                             width: labelWidth, height: labelHeight)
    }

    override func advance(dt: CGFloat, elapsed: CGFloat, level: CGFloat) {
        dots.advance(elapsed: elapsed)
        // The caption breathes on the dots' own period, so the two read as one
        // indicator rather than an animation sitting next to a label. Applied
        // to the label, not to self — the pill owns this view's alpha for the
        // state crossfade and would overwrite it on the next frame.
        let wave = 0.5 + 0.5 * sin(elapsed / 1.05 * 2 * .pi)
        label.alphaValue = Double(0.66 + 0.34 * wave)
    }
}

final class OverlayInsertedContent: OverlayContentView {

    private let check = OverlayCheckmark(frame: .zero)
    private let label = OverlayType.label(13, .medium, monospacedDigits: true)

    private let leading: CGFloat = 16
    private let glyph: CGFloat = 18
    private let gap: CGFloat = 10
    private let trailing: CGFloat = 20

    init(words: Int) {
        super.init(frame: .zero)
        label.stringValue = words == 1 ? "1 word" : "\(words) words"
        addSubview(check)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override var contentWidth: CGFloat {
        leading + glyph + gap + labelWidth + trailing
    }

    private var labelWidth: CGFloat { OverlayType.width(of: label) }

    override func apply(_ palette: OverlayPalette) {
        check.apply(palette)
        label.textColor = palette.primary
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        check.frame = NSRect(x: leading, y: (h - glyph) / 2, width: glyph, height: glyph)
        let labelHeight = OverlayType.height(of: label)
        label.frame = NSRect(x: leading + glyph + gap, y: (h - labelHeight) / 2,
                             width: labelWidth, height: labelHeight)
    }

    override func advance(dt: CGFloat, elapsed: CGFloat, level: CGFloat) {
        check.advance(elapsed: elapsed)
        label.alphaValue = Double(OverlayEasing.outCubic((elapsed - 0.10) / 0.22))
    }
}

final class OverlayErrorContent: OverlayContentView {

    private let icon = NSImageView()
    private let label = OverlayType.label(13, .medium)

    private let leading: CGFloat = 15
    private let glyph: CGFloat = 16
    private let gap: CGFloat = 10
    private let trailing: CGFloat = 18
    private let maxLabelWidth: CGFloat = 320

    init(message: String) {
        super.init(frame: .zero)
        label.stringValue = message
        let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: message)
        icon.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override var contentWidth: CGFloat {
        leading + glyph + gap + labelWidth + trailing
    }

    private var labelWidth: CGFloat { min(OverlayType.width(of: label), maxLabelWidth) }

    override func apply(_ palette: OverlayPalette) {
        icon.contentTintColor = palette.warn
        label.textColor = palette.primary
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: leading, y: (h - glyph) / 2, width: glyph, height: glyph)
        let labelHeight = OverlayType.height(of: label)
        label.frame = NSRect(x: leading + glyph + gap, y: (h - labelHeight) / 2,
                             width: labelWidth, height: labelHeight)
    }
}
