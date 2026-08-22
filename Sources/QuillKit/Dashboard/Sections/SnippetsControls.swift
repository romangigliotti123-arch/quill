import AppKit

// Controls the Snippets editor needs and the shell does not have yet.
//
// Deliberately prefixed rather than dropped into `DashboardStyle.swift`: eight
// sections are being built in parallel against that file, and a generic
// `DashboardToggle` written twice is a duplicate-symbol merge conflict instead
// of a component. Anything here that a second section also wants should be
// promoted into the shared file *once*, by whoever merges.
//
// Everything draws itself, for the reason the shell already states: an
// `NSButton`, `NSSwitch` or `NSSearchField` brings a system bezel and tint that
// no configuration fully removes, and none of them survive an offscreen render
// looking like what ships.

// MARK: - Well

/// The recessed container every input in this section sits in. Filled with the
/// *panel* colour rather than the card colour, which is brighter than its
/// surroundings in light mode and darker in dark — an input in both.
enum SnippetsWell {
    static func draw(_ rect: NSRect, radius: CGFloat, style: DashboardStyle, focused: Bool) {
        DashboardDraw.fill(rect, radius: radius, color: style.panel)
        DashboardDraw.stroke(rect, radius: radius,
                             color: focused ? style.accent.withAlphaComponent(0.55) : style.hairline)
        if focused {
            DashboardDraw.stroke(rect.insetBy(dx: -1.5, dy: -1.5), radius: radius + 1.5,
                                 color: style.accentSoft, width: 2)
        }
    }
}

// MARK: - Single-line field

/// An editable line in a well, with an optional leading badge.
///
/// `NSTextField` is kept but stripped to the text: no bezel, no background, no
/// focus ring. The well around it is drawn here so the focus state is a colour
/// the palette owns rather than the system's blue.
final class SnippetsField: NSView, NSTextFieldDelegate {

    var onChange: ((String) -> Void)?
    var onCommit: (() -> Void)?

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    private let field: NSTextField
    private let style: DashboardStyle
    private let badge: DashboardIconView?
    private var isFocused = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(style: DashboardStyle,
         placeholder: String,
         font: NSFont = DashboardType.bodyMedium,
         badgeSymbol: String? = nil,
         isSecure: Bool = false) {
        // The whole field, not just the cell.
        //
        // Giving an NSTextField an NSSecureTextFieldCell is the obvious version
        // and it terminates the process the moment the field takes focus:
        // "NSSecureTextFieldCell is not secure because the secure field editor's
        // delegate must be an NSSecureTextField". Which, on the API-key step of a
        // first-run window, is a crash on launch for every new user.
        field = isSecure ? NSSecureTextField() : NSTextField()
        self.style = style
        badge = badgeSymbol.map {
            DashboardIconView(image: DashboardIcon.image($0, pointSize: 12, weight: .semibold, color: style.accentInk))
        }
        super.init(frame: .zero)

        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = style.ink
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingTail
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: font, .foregroundColor: style.inkQuaternary])
        badge.map(addSubview)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        var x: CGFloat = 12
        if let badge {
            badge.frame = NSRect(x: 8, y: ((bounds.height - 24) / 2).rounded(), width: 24, height: 24)
            x = 40
        }
        let height = ceil(field.fittingSize.height)
        field.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(),
                             width: bounds.width - x - 12, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        SnippetsWell.draw(bounds, radius: DashboardRadius.control, style: style, focused: isFocused)
        guard badge != nil else { return }
        DashboardDraw.fill(NSRect(x: 8, y: ((bounds.height - 24) / 2).rounded(), width: 24, height: 24),
                           radius: 7, color: style.accentSoft)
    }

    func controlTextDidChange(_ notification: Notification) { onChange?(field.stringValue) }
    func controlTextDidBeginEditing(_ notification: Notification) { isFocused = true }
    func controlTextDidEndEditing(_ notification: Notification) {
        isFocused = false
        onCommit?()
    }

    func focus() {
        window?.makeFirstResponder(field)
        isFocused = true
    }
}

// MARK: - Multi-line field

/// The replacement editor. A real `NSTextView` in a scroller, because the thing
/// being edited is genuinely multi-paragraph and a one-line field would quietly
/// teach people that snippets are short.
final class SnippetsTextArea: NSView {

    var onChange: ((String) -> Void)?

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            applyTypography()
            needsDisplay = true
        }
    }

    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let style: DashboardStyle
    private let placeholder: String
    private var observer: NSObjectProtocol?

    override var isFlipped: Bool { true }

    init(style: DashboardStyle, placeholder: String) {
        self.style = style
        self.placeholder = placeholder
        super.init(frame: .zero)

        textView.isEditable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.font = DashboardType.body
        textView.textColor = style.ink
        textView.insertionPointColor = style.accent
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        addSubview(scroll)

        observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Redraw so the drawn placeholder clears on the first keystroke.
            self.needsDisplay = true
            self.onChange?(self.textView.string)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Line height has to be set on the storage, not the view — a text view
    /// given only a font packs paragraphs at the font's default leading, which
    /// is tighter than every other block of prose in the window.
    private func applyTypography() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.5
        paragraph.paragraphSpacing = 7
        textView.textStorage?.addAttributes(
            [.font: DashboardType.body, .foregroundColor: style.ink, .paragraphStyle: paragraph],
            range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: DashboardType.body, .foregroundColor: style.ink, .paragraphStyle: paragraph,
        ]
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        SnippetsWell.draw(bounds, radius: DashboardRadius.control, style: style, focused: false)
        // Drawn rather than set on the text view: `placeholderAttributedString`
        // is not public API on NSTextView, and reaching for it through KVC is a
        // runtime exception waiting for the OS release that renames it.
        guard textView.string.isEmpty else { return }
        NSAttributedString(string: placeholder,
                           attributes: [.font: DashboardType.body,
                                        .foregroundColor: style.inkQuaternary])
            .draw(at: NSPoint(x: 16, y: 18))
    }
}

// MARK: - Segmented control

/// Two mutually exclusive options, drawn as a raised thumb inside a sunken
/// track. Reads as a physical switch rather than two buttons that happen to be
/// adjacent.
final class SnippetsSegmented: NSView {

    var onSelect: ((Int) -> Void)?
    var selectedIndex: Int {
        didSet {
            rebuild()
            thumb.animate(to: CGFloat(selectedIndex), duration: DashboardMotion.standard)
        }
    }

    private let titles: [String]
    private let style: DashboardStyle
    private var labels: [NSTextField] = []
    /// Segment index as a continuous number, so the thumb can be between two.
    private lazy var thumb = DashboardTween(view: self, initial: CGFloat(selectedIndex))

    override var isFlipped: Bool { true }

    init(titles: [String], selectedIndex: Int, style: DashboardStyle) {
        self.titles = titles
        self.selectedIndex = selectedIndex
        self.style = style
        super.init(frame: .zero)
        for title in titles {
            let label = DashboardType.label(title, font: .systemFont(ofSize: 12.5, weight: .medium),
                                            color: style.inkSecondary, alignment: .center)
            addSubview(label)
            labels.append(label)
        }
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        for (index, label) in labels.enumerated() {
            DashboardType.recolor(label, index == selectedIndex ? style.ink : style.inkTertiary)
        }
        needsDisplay = true
        needsLayout = true
    }

    private var segmentWidth: CGFloat { bounds.width / CGFloat(max(1, titles.count)) }

    override func layout() {
        super.layout()
        for (index, label) in labels.enumerated() {
            let size = label.fittingSize
            label.frame = NSRect(x: segmentWidth * CGFloat(index),
                                 y: ((bounds.height - size.height) / 2).rounded(),
                                 width: segmentWidth, height: size.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.fill(bounds, radius: DashboardRadius.control, color: style.isDark ? style.cardAlt : style.card)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.control, color: style.hairline)
        // Interpolated position, not the selected index. The thumb travelling to
        // the segment you clicked is what makes a segmented control feel like one
        // object rather than three lights.
        let thumb = NSRect(x: segmentWidth * thumb.value + 3, y: 3,
                           width: segmentWidth - 6, height: bounds.height - 6)
        DashboardDraw.raisedSurface(thumb, radius: DashboardRadius.control - 3,
                                    fillColor: style.raised, topColor: style.raisedTop,
                                    style: style, shadow: style.shadowContact, flipped: true)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let index = min(titles.count - 1, max(0, Int(point.x / segmentWidth)))
        guard index != selectedIndex else { return }
        selectedIndex = index
        onSelect?(index)
    }
}

// MARK: - Toggle

/// On/off. `NSSwitch` exists and is the wrong shape here: it renders at the
/// system accent colour, which is whatever the user picked in System Settings,
/// and one uncontrolled blue capsule undoes a whole palette.
final class SnippetsToggle: NSView {

    var onToggle: ((Bool) -> Void)?
    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            knob.animate(to: isOn ? 1 : 0, duration: DashboardMotion.standard)
        }
    }

    private let style: DashboardStyle
    /// 0 = off, 1 = on. The knob's travel and the track's colour both read from
    /// it, so they arrive together instead of the fill snapping ahead.
    private lazy var knob = DashboardTween(view: self, initial: isOn ? 1 : 0)

    override var isFlipped: Bool { true }

    init(isOn: Bool, style: DashboardStyle) {
        self.isOn = isOn
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let t = knob.value

        // Ink, not accent. macOS tints its own switch with the system accent
        // colour, and copying that here would make "this row is on" the loudest
        // thing on a screen whose actual subject is the text below it. Colour is
        // spent on the snippet, not on its power switch.
        let off = style.isDark ? style.raised : style.card
        DashboardDraw.fill(bounds, radius: radius, color: off.mixed(with: style.fill, t))
        if t < 1 {
            DashboardDraw.stroke(bounds, radius: radius, color: style.hairlineStrong.faded(1 - t))
        }

        let inset: CGFloat = 3
        let diameter = bounds.height - inset * 2
        let x = inset + (bounds.width - inset * 2 - diameter) * t
        let dot = NSRect(x: x, y: inset, width: diameter, height: diameter)
        let restColor = style.isDark ? style.inkQuaternary : NSColor.white
        DashboardDraw.shadowed(style.shadowContact, flipped: true) {
            restColor.mixed(with: style.onFill, t).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        onToggle?(isOn)
    }
}

// MARK: - Highlighted line

/// One line of text with a soft marker behind a range of it.
///
/// Drawn rather than assembled with `.backgroundColor`, which paints a hard
/// rectangle the full height of the line — the difference between a highlight
/// and a selection artefact.
final class SnippetsHighlightLine: NSView {

    private var attributed = NSAttributedString()
    private var highlight: NSRange = NSRange(location: 0, length: 0)
    private let tint: NSColor
    private let font: NSFont

    override var isFlipped: Bool { true }

    init(font: NSFont, tint: NSColor) {
        self.font = font
        self.tint = tint
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, highlight range: NSRange, color: NSColor, highlightColor: NSColor) {
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .kern: 0,
        ])
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        if clamped.length > 0 {
            string.addAttribute(.foregroundColor, value: highlightColor, range: clamped)
        }
        attributed = string
        highlight = clamped
        needsDisplay = true
    }

    var intrinsicWidth: CGFloat { ceil(attributed.size().width) }

    override func draw(_ dirtyRect: NSRect) {
        let textHeight = ceil(attributed.size().height)
        let origin = NSPoint(x: 0, y: ((bounds.height - textHeight) / 2).rounded())
        if highlight.length > 0 {
            let prefix = attributed.attributedSubstring(from: NSRange(location: 0, length: highlight.location))
            let match = attributed.attributedSubstring(from: highlight)
            let x = ceil(prefix.size().width)
            let width = ceil(match.size().width)
            let rect = NSRect(x: x - 4, y: origin.y - 3, width: width + 8, height: textHeight + 6)
            DashboardDraw.fill(rect, radius: 5, color: tint)
        }
        attributed.draw(at: origin)
    }
}

// MARK: - Fade

/// A gradient that hides the cut edge of a scrolling list. Without it the last
/// visible row looks clipped by a bug; with it, the list obviously continues.
final class SnippetsFadeView: NSView {

    private let color: NSColor
    override var isFlipped: Bool { true }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let gradient = NSGradient(starting: color.withAlphaComponent(0), ending: color) else { return }
        gradient.draw(from: NSPoint(x: bounds.midX, y: bounds.minY),
                      to: NSPoint(x: bounds.midX, y: bounds.maxY),
                      options: [])
    }
}

/// Flipped container for the scroll view's document, so rows lay out top-down
/// like every other list in the dashboard.
final class SnippetsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
