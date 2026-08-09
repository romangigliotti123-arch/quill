import AppKit

// The dashboard's entire visual vocabulary. Every colour, size, radius and
// shadow the window draws with is declared here and nowhere else — a section
// that reaches for a literal `NSColor` or a hand-picked padding is how eight
// screens built by eight different hands stop looking like one app.
//
// Two rules that are load-bearing rather than stylistic:
//
//  1. NOTHING USES NSVisualEffectView. Vibrancy samples a backdrop, and there
//     is no backdrop in an offscreen render — the effect view comes back as a
//     hole. Every surface here is drawn, so what `DashboardPreviewRenderer`
//     writes to disk is pixel-identical to what ships on screen. A design you
//     can only review by launching the app is a design nobody reviews.
//
//  2. COLOURS ARE RESOLVED EAGERLY, NOT DYNAMIC. Views draw with the palette
//     they were handed; they rebuild it in `viewDidChangeEffectiveAppearance`.
//     Dynamic `NSColor` would work for `draw(_:)` but not for the layer
//     properties elsewhere in Quill, and one resolution rule is cheaper to hold
//     in your head than two.

// MARK: - Scales

/// 4-point spacing scale. Nothing in the dashboard is spaced by a number that
/// is not on this list.
public enum DashboardSpace {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 40
    public static let huge: CGFloat = 56
}

/// Radii climb with the size of the thing. A 14-point radius on a 28-point chip
/// reads as a lozenge; a 7-point radius on a 700-point panel reads as a table.
public enum DashboardRadius {
    public static let chip: CGFloat = 7
    public static let row: CGFloat = 9
    public static let control: CGFloat = 10
    public static let card: CGFloat = 14
    public static let panel: CGFloat = 18
    /// macOS draws its own window corner; the offscreen renderer has to draw it
    /// by hand or the PNG looks like a cropped div rather than a window.
    public static let window: CGFloat = 12
}

public enum DashboardMetrics {
    /// Matches Wispr Flow's window exactly, so screenshots compare like for like.
    public static let windowSize = NSSize(width: 1350, height: 850)
    public static let minWindowSize = NSSize(width: 1_060, height: 700)

    public static let sidebarWidth: CGFloat = 234
    /// The strip the traffic lights live in. The content panel starts below it.
    public static let titlebarHeight: CGFloat = 52
    /// Gap between the floating panel and the window's right/bottom edge.
    public static let panelGap: CGFloat = 10

    public static let sidebarInset: CGFloat = 12
    public static let navRowHeight: CGFloat = 36
    public static let navRowGap: CGFloat = 4

    public static let contentPaddingX: CGFloat = 46
    public static let contentPaddingY: CGFloat = 40

    public static func panelFrame(in size: NSSize) -> NSRect {
        NSRect(x: sidebarWidth,
               y: titlebarHeight,
               width: size.width - sidebarWidth - panelGap,
               height: size.height - titlebarHeight - panelGap)
    }
}

// MARK: - Type

public enum DashboardType {

    // A macOS type scale, not a marketing one.
    //
    // The previous scale ran to a 27pt semibold display with an editorial title
    // under it, and set every secondary label in tracked mono caps. That reads as
    // a landing page wearing a window frame. Apple's own apps top out far lower —
    // System Settings sets a page title at 15-17pt — and reserve size for data,
    // not for headings. Everything below is a step on one 4pt-ish rhythm, and
    // there is exactly one monospaced face, used only where digits must align.
    public static var display: NSFont { .systemFont(ofSize: 20, weight: .semibold) }
    public static var title: NSFont { .systemFont(ofSize: 15, weight: .semibold) }
    public static var headline: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    public static var body: NSFont { .systemFont(ofSize: 13, weight: .regular) }
    public static var bodyMedium: NSFont { .systemFont(ofSize: 13, weight: .medium) }
    public static var callout: NSFont { .systemFont(ofSize: 12, weight: .regular) }
    public static var caption: NSFont { .systemFont(ofSize: 11.5, weight: .regular) }
    /// Kept for source compatibility. No longer monospaced or capitalised — the
    /// call sites that used it as a shouty label now read as quiet captions.
    public static var micro: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    public static var eyebrow: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    /// Metrics stay large. Size belongs to the number, not the heading above it.
    public static var metric: NSFont { .systemFont(ofSize: 28, weight: .regular) }
    public static var metricSmall: NSFont { .systemFont(ofSize: 19, weight: .regular) }
    /// The only monospaced face, and only where digits must line up in a column.
    public static var mono: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
    public static var control: NSFont { .systemFont(ofSize: 12.5, weight: .medium) }

    /// Swaps a label's colour without rebuilding its string. Labels here are set
    /// with `attributedStringValue`, which makes `textColor` a no-op — the trap
    /// that leaves half a window drawing dark text on a dark background one
    /// second after the system switches theme.
    public static func recolor(_ field: NSTextField, _ color: NSColor) {
        let string = NSMutableAttributedString(attributedString: field.attributedStringValue)
        string.addAttribute(.foregroundColor, value: color,
                            range: NSRange(location: 0, length: string.length))
        field.attributedStringValue = string
    }

    /// Optical tracking. SF sets large sizes too loose and small caps too tight;
    /// these are the corrections, expressed once.
    public static func tracking(for font: NSFont, uppercase: Bool = false) -> CGFloat {
        // Uppercase tracking is a correction for a treatment this design no
        // longer uses. Kept small for the few places caps still appear.
        if uppercase { return font.pointSize * 0.05 }
        switch font.pointSize {
        case 24...: return -0.55
        case 18..<24: return -0.35
        case 15..<18: return -0.2
        default: return 0
        }
    }

    /// One label factory. Bezels, background drawing and the focus ring are all
    /// off — an `NSTextField` that draws its own chrome is exactly the default
    /// AppKit look this window exists to avoid.
    public static func label(_ text: String,
                             font: NSFont,
                             color: NSColor,
                             tracking: CGFloat? = nil,
                             uppercase: Bool = false,
                             lines: Int = 1,
                             lineHeight: CGFloat? = nil,
                             alignment: NSTextAlignment = .left) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.maximumNumberOfLines = lines
        field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        field.cell?.usesSingleLineMode = lines == 1
        field.alignment = alignment

        let string = uppercase ? text.uppercased() : text
        let kern = tracking ?? self.tracking(for: font, uppercase: uppercase)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: kern,
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = field.lineBreakMode
        if let lineHeight {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        }
        attributes[.paragraphStyle] = paragraph
        field.attributedStringValue = NSAttributedString(string: string, attributes: attributes)
        return field
    }

    public static func size(_ field: NSTextField, width: CGFloat? = nil) -> NSSize {
        guard let width else { return field.fittingSize }
        return NSSize(width: width,
                      height: ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width,
                                                                         height: .greatestFiniteMagnitude)).height ?? field.fittingSize.height))
    }
}

// MARK: - Shadow

public struct DashboardShadow {
    public let color: NSColor
    public let radius: CGFloat
    /// Positive means *down the screen*, in both flipped and unflipped views.
    public let dy: CGFloat

    public init(color: NSColor, radius: CGFloat, dy: CGFloat) {
        self.color = color
        self.radius = radius
        self.dy = dy
    }
}

// MARK: - Palette

public struct DashboardStyle {

    public let isDark: Bool

    // Chrome
    public let canvasTop: NSColor
    public let canvasBottom: NSColor
    public let windowEdge: NSColor

    // Surfaces
    /// The big floating content panel.
    public let panel: NSColor
    /// A card *inside* the panel — quieter than the panel, never brighter.
    public let card: NSColor
    public let cardAlt: NSColor
    /// Anything that should read as lifted off the page: selected nav row,
    /// status pill, secondary button.
    public let raised: NSColor
    public let raisedTop: NSColor

    // Lines
    public let hairline: NSColor
    public let hairlineStrong: NSColor
    /// A one-pixel lighter line just inside a surface's top edge. This single
    /// detail is most of the difference between "card" and "rectangle".
    public let innerHighlight: NSColor

    // Ink
    public let ink: NSColor
    public let inkSecondary: NSColor
    public let inkTertiary: NSColor
    public let inkQuaternary: NSColor

    // Accent — used for live state, selection and one number per screen. If it
    // appears more than three times on a screen it has stopped being an accent.
    public let accent: NSColor
    public let accentSoft: NSColor
    public let accentInk: NSColor

    // Filled controls
    public let fill: NSColor
    public let fillHover: NSColor
    public let onFill: NSColor

    // Interaction
    public let hover: NSColor
    public let pressed: NSColor

    public let shadowCard: DashboardShadow
    public let shadowRaised: DashboardShadow
    public let shadowPanel: DashboardShadow
    public let shadowContact: DashboardShadow

    public static func resolve(_ appearance: NSAppearance?) -> DashboardStyle {
        let match = (appearance ?? NSApplication.shared.effectiveAppearance)
            .bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }

    private static func c(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    private static func w(_ value: CGFloat, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: value, green: value, blue: value, alpha: alpha)
    }

    /// Light: paper-white panel on a cool neutral canvas. Deliberately cooler
    /// and more neutral than Flow's warm cream — Quill is an instrument, not a
    /// notebook, and grey lets one warm accent do all the talking.
    public static let light = DashboardStyle(
        isDark: false,
        canvasTop: c(0xF0EEE9),
        canvasBottom: c(0xE6E3DC),
        windowEdge: w(0, 0.14),

        panel: c(0xFDFDFC),
        card: c(0xF7F6F3),
        cardAlt: c(0xFAF9F6),
        raised: c(0xFFFFFF),
        raisedTop: c(0xFFFFFF),

        hairline: c(0x1A1712, 0.075),
        hairlineStrong: c(0x1A1712, 0.13),
        innerHighlight: w(1, 0.9),

        ink: c(0x14120E),
        inkSecondary: c(0x57544D),
        inkTertiary: c(0x8A867E),
        inkQuaternary: c(0xB5B1A8),

        accent: c(0x3B6D6E),
        accentSoft: c(0x3B6D6E, 0.10),
        accentInk: c(0x2F5859),

        fill: c(0x1A1712),
        fillHover: c(0x2B2721),
        onFill: c(0xFDFDFC),

        hover: c(0x1A1712, 0.042),
        pressed: c(0x0B0D14, 0.085),

        shadowCard: DashboardShadow(color: c(0x0A0C14, 0.07), radius: 14, dy: 5),
        shadowRaised: DashboardShadow(color: c(0x0A0C14, 0.10), radius: 7, dy: 2),
        shadowPanel: DashboardShadow(color: c(0x0A0C14, 0.13), radius: 30, dy: 10),
        shadowContact: DashboardShadow(color: c(0x0A0C14, 0.07), radius: 1.5, dy: 1)
    )

    /// Dark: Flow does not ship one, so this is free ground. Not black — a
    /// graphite canvas with a lifted panel, because pure black gives shadow
    /// nothing to fall on and every surface collapses into one plane.
    public static let dark = DashboardStyle(
        isDark: true,
        canvasTop: c(0x0B0B0D),
        canvasBottom: c(0x121215),
        windowEdge: w(1, 0.13),

        panel: c(0x18191C),
        card: c(0x1E1F23),
        cardAlt: c(0x1B1C20),
        raised: c(0x2A2C31),
        raisedTop: c(0x303238),

        hairline: w(1, 0.075),
        hairlineStrong: w(1, 0.14),
        innerHighlight: w(1, 0.07),

        ink: c(0xF3F4F7),
        inkSecondary: c(0x9CA0A9),
        inkTertiary: c(0x71757E),
        inkQuaternary: c(0x53565E),

        accent: c(0x6FB3A8),
        accentSoft: c(0x6FB3A8, 0.16),
        accentInk: c(0x8ECFC3),

        fill: c(0xF2F3F6),
        fillHover: c(0xFFFFFF),
        onFill: c(0x0C0D10),

        hover: w(1, 0.055),
        pressed: w(1, 0.10),

        shadowCard: DashboardShadow(color: .black, radius: 14, dy: 5),
        shadowRaised: DashboardShadow(color: .black, radius: 8, dy: 3),
        shadowPanel: DashboardShadow(color: .black, radius: 34, dy: 12),
        shadowContact: DashboardShadow(color: .black, radius: 2, dy: 1)
    )
}

// MARK: - Drawing

public enum DashboardDraw {

    public static func path(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    public static func fill(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        path(rect, radius).fill()
    }

    public static func gradient(_ rect: NSRect,
                                radius: CGFloat,
                                top: NSColor,
                                bottom: NSColor,
                                flipped: Bool) {
        guard let gradient = NSGradient(starting: top, ending: bottom) else { return }
        NSGraphicsContext.saveGraphicsState()
        path(rect, radius).addClip()
        // Explicit endpoints rather than an angle: `draw(in:angle:)` measures
        // the angle in the *view's* coordinate system, so the same call points
        // the gradient in opposite directions in flipped and unflipped views.
        let high = NSPoint(x: rect.midX, y: flipped ? rect.minY : rect.maxY)
        let low = NSPoint(x: rect.midX, y: flipped ? rect.maxY : rect.minY)
        gradient.draw(from: high, to: low, options: [])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Strokes *inside* the rect. A stroke centred on the edge puts half a pixel
    /// outside the shape, which on a card sitting on a shadow reads as fringe.
    public static func stroke(_ rect: NSRect, radius: CGFloat, color: NSColor, width: CGFloat = 1) {
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        color.setStroke()
        let p = path(inset, max(0, radius - width / 2))
        p.lineWidth = width
        p.stroke()
    }

    /// The lit top edge. Clipped to the shape so it curves into the corners.
    public static func innerHighlight(_ rect: NSRect, radius: CGFloat, color: NSColor, flipped: Bool) {
        NSGraphicsContext.saveGraphicsState()
        path(rect.insetBy(dx: 0.5, dy: 0.5), radius - 0.5).addClip()
        color.setFill()
        let y = flipped ? rect.minY + 0.5 : rect.maxY - 1.5
        NSRect(x: rect.minX + radius * 0.5, y: y,
               width: rect.width - radius, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    public static func shadowed(_ shadow: DashboardShadow, flipped: Bool, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = shadow.color
        s.shadowBlurRadius = shadow.radius
        s.shadowOffset = NSSize(width: 0, height: flipped ? shadow.dy : -shadow.dy)
        s.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A surface with weight: contact shadow, ambient shadow, fill, hairline,
    /// lit top edge. Used for everything that should read as lifted.
    public static func raisedSurface(_ rect: NSRect,
                                     radius: CGFloat,
                                     fillColor: NSColor,
                                     topColor: NSColor? = nil,
                                     style: DashboardStyle,
                                     shadow: DashboardShadow,
                                     flipped: Bool) {
        shadowed(shadow, flipped: flipped) {
            fillColor.setFill()
            path(rect, radius).fill()
        }
        shadowed(style.shadowContact, flipped: flipped) {
            fillColor.setFill()
            path(rect, radius).fill()
        }
        if let topColor, topColor != fillColor {
            gradient(rect, radius: radius, top: topColor, bottom: fillColor, flipped: flipped)
        }
        stroke(rect, radius: radius, color: style.hairline)
        innerHighlight(rect, radius: radius, color: style.innerHighlight, flipped: flipped)
    }

    /// A surface with *less* weight than its container — the inverse move, for
    /// content wells. Flat fill, hairline, no shadow.
    public static func sunkenSurface(_ rect: NSRect,
                                     radius: CGFloat,
                                     style: DashboardStyle,
                                     flipped: Bool) {
        fill(rect, radius: radius, color: style.card)
        stroke(rect, radius: radius, color: style.hairline)
    }
}

// MARK: - Icons

public enum DashboardIcon {

    /// SF Symbols, pre-coloured through a palette configuration rather than
    /// template tinting. Template images tint through `contentTintColor`, which
    /// an `NSImageView` resolves against its window — and in an offscreen render
    /// there is no window to resolve against.
    public static func image(_ name: String,
                             pointSize: CGFloat,
                             weight: NSFont.Weight = .medium,
                             color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = base.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }
}

/// Draws an `NSImage` itself instead of handing it to `NSImageView`.
///
/// `NSImageView` sets its image as layer *contents*, which the offscreen
/// renderer then rescales from a 1x bitmap and blurs. Drawing in `draw(_:)`
/// happens at the layer's contents scale, so the symbol is sharp at 2x.
public final class DashboardIconView: NSView {

    public var image: NSImage? { didSet { needsDisplay = true } }

    public override var isFlipped: Bool { true }

    public init(image: NSImage?) {
        self.image = image
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let size = image.size
        let rect = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                          y: ((bounds.height - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }
}

// MARK: - Components

/// A card. Sunken (a well inside the panel) or raised (lifted off it).
public final class DashboardCardView: NSView {

    public enum Elevation { case sunken, raised, panel }

    public var style: DashboardStyle { didSet { needsDisplay = true } }
    public var elevation: Elevation { didSet { needsDisplay = true } }
    public var radius: CGFloat { didSet { needsDisplay = true } }

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle, elevation: Elevation = .sunken, radius: CGFloat = DashboardRadius.card) {
        self.style = style
        self.elevation = elevation
        self.radius = radius
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirtyRect: NSRect) {
        switch elevation {
        case .sunken:
            DashboardDraw.sunkenSurface(bounds, radius: radius, style: style, flipped: true)
        case .raised:
            DashboardDraw.raisedSurface(bounds, radius: radius,
                                        fillColor: style.raised, topColor: style.raisedTop,
                                        style: style, shadow: style.shadowCard, flipped: true)
        case .panel:
            DashboardDraw.fill(bounds, radius: radius, color: style.panel)
            DashboardDraw.stroke(bounds, radius: radius, color: style.hairline)
            DashboardDraw.innerHighlight(bounds, radius: radius, color: style.innerHighlight, flipped: true)
        }
    }
}

/// A button that draws itself. `NSButton` brings bezels, a focus ring and a
/// system tint that no amount of configuration fully removes.
public final class DashboardButton: NSView {

    public enum Kind { case primary, secondary, ghost }

    public var title: String { didSet { rebuild() } }
    public var symbol: String? { didSet { rebuild() } }
    public var kind: Kind { didSet { rebuild() } }
    public var style: DashboardStyle { didSet { rebuild() } }
    public var onClick: (() -> Void)?

    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private let label = NSTextField(labelWithString: "")
    private var icon: DashboardIconView?

    public override var isFlipped: Bool { true }

    public init(title: String, symbol: String? = nil, kind: Kind = .primary, style: DashboardStyle) {
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.style = style
        super.init(frame: .zero)
        addSubview(label)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var foreground: NSColor {
        switch kind {
        case .primary: return style.onFill
        case .secondary: return style.ink
        case .ghost: return style.inkSecondary
        }
    }

    private func rebuild() {
        let font = DashboardType.control
        label.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: foreground, .kern: -0.1]
        )
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false

        icon?.removeFromSuperview()
        if let symbol {
            let view = DashboardIconView(image: DashboardIcon.image(symbol, pointSize: 12.5, weight: .semibold, color: foreground))
            addSubview(view)
            icon = view
        } else {
            icon = nil
        }
        needsLayout = true
        needsDisplay = true
    }

    public var intrinsicWidth: CGFloat {
        ceil(label.fittingSize.width) + (icon == nil ? 0 : 22) + DashboardSpace.md * 2
    }

    public override func layout() {
        super.layout()
        var x = DashboardSpace.md
        if let icon {
            icon.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16)
            x += 22
        }
        let size = label.fittingSize
        label.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let radius = DashboardRadius.control
        switch kind {
        case .primary:
            let base = isPressed ? style.fillHover : (isHovered ? style.fillHover : style.fill)
            DashboardDraw.shadowed(style.shadowRaised, flipped: true) {
                base.setFill()
                DashboardDraw.path(bounds, radius).fill()
            }
            if !style.isDark {
                DashboardDraw.innerHighlight(bounds, radius: radius, color: NSColor(white: 1, alpha: 0.16), flipped: true)
            }
        case .secondary:
            DashboardDraw.raisedSurface(bounds, radius: radius,
                                        fillColor: isHovered ? style.raisedTop : style.raised,
                                        topColor: nil, style: style,
                                        shadow: style.shadowRaised, flipped: true)
        case .ghost:
            if isHovered {
                DashboardDraw.fill(bounds, radius: radius, color: style.hover)
            }
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }
    public override func mouseDown(with event: NSEvent) { isPressed = true }
    public override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// A small label in a hairline capsule. Used for counts, plan names and state.
public final class DashboardChip: NSView {

    public enum Tone { case neutral, accent, outline }

    private let label: NSTextField
    private let tone: Tone
    public var style: DashboardStyle {
        didSet {
            DashboardType.recolor(label, DashboardChip.color(for: tone, style: style))
            needsDisplay = true
        }
    }

    public override var isFlipped: Bool { true }

    private static func color(for tone: Tone, style: DashboardStyle) -> NSColor {
        switch tone {
        case .neutral: return style.inkTertiary
        case .accent: return style.accentInk
        case .outline: return style.inkSecondary
        }
    }

    public init(text: String, tone: Tone = .neutral, style: DashboardStyle, uppercase: Bool = true) {
        self.tone = tone
        self.style = style
        label = DashboardType.label(text, font: DashboardType.micro,
                                    color: DashboardChip.color(for: tone, style: style),
                                    uppercase: uppercase)
        super.init(frame: .zero)
        addSubview(label)
        let size = label.fittingSize
        frame = NSRect(x: 0, y: 0, width: ceil(size.width) + 15, height: 19)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        let size = label.fittingSize
        label.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                             y: ((bounds.height - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let radius = DashboardRadius.chip
        switch tone {
        case .neutral:
            DashboardDraw.fill(bounds, radius: radius, color: style.card)
            DashboardDraw.stroke(bounds, radius: radius, color: style.hairline)
        case .accent:
            DashboardDraw.fill(bounds, radius: radius, color: style.accentSoft)
        case .outline:
            DashboardDraw.stroke(bounds, radius: radius, color: style.hairlineStrong)
        }
    }
}

/// A physical-looking key. Quill is a hotkey-driven app; showing the binding as
/// a drawn key rather than the string "Right Option" is the difference between
/// documentation and an interface.
public final class DashboardKeycap: NSView {

    private let label: NSTextField
    private let style: DashboardStyle

    public override var isFlipped: Bool { true }

    public init(_ text: String, style: DashboardStyle) {
        self.style = style
        label = DashboardType.label(text,
                                    font: .systemFont(ofSize: 11.5, weight: .semibold),
                                    color: style.ink,
                                    tracking: 0,
                                    alignment: .center)
        super.init(frame: .zero)
        addSubview(label)
        let width = max(20, ceil(label.fittingSize.width) + 12)
        frame = NSRect(x: 0, y: 0, width: width, height: 20)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        let size = label.fittingSize
        label.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                             y: ((bounds.height - size.height) / 2).rounded() - 0.5,
                             width: size.width, height: size.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.raisedSurface(bounds, radius: 6,
                                    fillColor: style.raised, topColor: style.raisedTop,
                                    style: style, shadow: style.shadowContact, flipped: true)
    }
}

/// One-pixel rule that stays one pixel at 2x.
public final class DashboardRule: NSView {

    public var color: NSColor { didSet { needsDisplay = true } }
    public override var isFlipped: Bool { true }

    public init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

/// The live-state dot. Solid core, soft halo — the halo is what stops a 6-point
/// circle from reading as a bullet point.
public final class DashboardStatusDot: NSView {

    public var color: NSColor { didSet { needsDisplay = true } }
    public override var isFlipped: Bool { true }

    public init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirtyRect: NSRect) {
        let centre = NSPoint(x: bounds.midX, y: bounds.midY)
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - 6, y: centre.y - 6, width: 12, height: 12)).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - 3, y: centre.y - 3, width: 6, height: 6)).fill()
    }
}

/// The Quill mark: an ink-filled tile with a nib cut out of it. Drawn rather
/// than shipped as an asset so it inherits the palette and stays sharp at any
/// scale.
public final class DashboardMark: NSView {

    private var style: DashboardStyle
    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func apply(_ style: DashboardStyle) {
        self.style = style
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        DashboardDraw.shadowed(style.shadowRaised, flipped: true) {
            style.fill.setFill()
            DashboardDraw.path(rect, 8).fill()
        }
        DashboardDraw.gradient(rect, radius: 8,
                               top: style.isDark ? NSColor(white: 1, alpha: 1) : NSColor(srgbRed: 0.19, green: 0.20, blue: 0.24, alpha: 1),
                               bottom: style.fill,
                               flipped: true)

        // The nib: a lens shape with a slit and a vent hole, punched out of the
        // tile in the tile's own background colour.
        let w = rect.width, h = rect.height
        let nib = NSBezierPath()
        let top = NSPoint(x: w * 0.5, y: h * 0.18)
        let bottom = NSPoint(x: w * 0.5, y: h * 0.84)
        nib.move(to: top)
        nib.curve(to: bottom,
                  controlPoint1: NSPoint(x: w * 0.80, y: h * 0.38),
                  controlPoint2: NSPoint(x: w * 0.66, y: h * 0.70))
        nib.curve(to: top,
                  controlPoint1: NSPoint(x: w * 0.34, y: h * 0.70),
                  controlPoint2: NSPoint(x: w * 0.20, y: h * 0.38))
        style.onFill.setFill()
        nib.fill()

        // Slit + vent, cut back to the tile.
        style.fill.setFill()
        let slit = NSBezierPath()
        slit.move(to: NSPoint(x: w * 0.5 - 0.7, y: h * 0.30))
        slit.line(to: NSPoint(x: w * 0.5 + 0.7, y: h * 0.30))
        slit.line(to: NSPoint(x: w * 0.5 + 0.7, y: h * 0.72))
        slit.line(to: NSPoint(x: w * 0.5 - 0.7, y: h * 0.72))
        slit.close()
        slit.fill()
        NSBezierPath(ovalIn: NSRect(x: w * 0.5 - 2.1, y: h * 0.50, width: 4.2, height: 4.2)).fill()
    }
}
