import AppKit

/// The dashboard's information architecture.
///
/// The order matches Wispr Flow's deliberately. Not out of deference — this is
/// the order a dictation user actually moves through (what you said, what it
/// heard, how it writes, where it goes), and reordering it to look different
/// would cost every switcher their muscle memory for nothing.
public enum DashboardSection: String, CaseIterable, Sendable {
    case dictation
    case notetaker
    case insights
    case dictionary
    case snippets
    case style
    case transforms
    case scratchpad
    case settings
    case help

    public var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .notetaker: return "Notetaker"
        case .insights: return "Insights"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .transforms: return "Transforms"
        case .scratchpad: return "Scratchpad"
        case .settings: return "Settings"
        case .help: return "Help"
        }
    }

    public var symbolName: String {
        switch self {
        case .dictation: return "waveform"
        case .notetaker: return "record.circle"
        case .insights: return "chart.bar.xaxis"
        case .dictionary: return "character.book.closed"
        case .snippets: return "scissors"
        // A lettermark ("Aa") among eight stroke icons reads as a typo, not an
        // icon — Flow gets away with it because theirs is the only one.
        case .style: return "paintbrush.pointed"
        case .transforms: return "wand.and.sparkles"
        case .scratchpad: return "square.and.pencil"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }

    /// Everything above the rule.
    public static let primary: [DashboardSection] = [
        .dictation, .notetaker, .insights, .dictionary,
        .snippets, .style, .transforms, .scratchpad,
    ]

    /// Everything below it.
    public static let footer: [DashboardSection] = [.settings, .help]

    public var isFooter: Bool { DashboardSection.footer.contains(self) }

    /// The one thing this section is for. Sections override it; the shell needs
    /// a default so a placeholder page never offers "Start dictating" on the
    /// Settings screen, which is the kind of detail that makes a whole app look
    /// unfinished.
    public var primaryAction: (title: String, symbol: String) {
        switch self {
        case .dictation: return ("Start dictating", "waveform")
        case .notetaker: return ("New recording", "record.circle")
        case .insights: return ("Export report", "square.and.arrow.up")
        case .dictionary: return ("Add word", "plus")
        case .snippets: return ("New snippet", "plus")
        case .style: return ("New style", "plus")
        case .transforms: return ("New transform", "plus")
        case .scratchpad: return ("New note", "square.and.pencil")
        case .settings: return ("Run diagnostics", "stethoscope")
        case .help: return ("Run diagnostics", "stethoscope")
        }
    }

    /// Only where a second action genuinely exists. An always-present ghost
    /// button beside the primary is filler.
    public var secondaryAction: (title: String, symbol: String)? {
        switch self {
        case .dictation: return ("Import", "arrow.down.circle")
        case .dictionary: return ("Import", "arrow.down.circle")
        case .insights: return ("Last 30 days", "calendar")
        default: return nil
        }
    }

    /// Placeholder copy, so an unbuilt section still reads as a room with the
    /// lights off rather than a crash. Sections replace this wholesale.
    public var blurb: String {
        switch self {
        case .dictation: return "Everything you have dictated, newest first — the raw transcript kept beside what was inserted."
        case .notetaker: return "Capture a meeting end to end, on device, and keep the transcript with the notes it produced."
        case .insights: return "Speed, accuracy and the words Quill had to fix — measured, not estimated."
        case .dictionary: return "Names, jargon and spellings the recogniser has no reason to know. These bias what it hears, not what it prints."
        case .snippets: return "Say a trigger, insert a block of text. Signatures, addresses, boilerplate you retype daily."
        case .style: return "Teach Quill how you write in each app — punctuation, casing, how much it is allowed to tidy."
        case .transforms: return "Rewrite what you just said with one shortcut: shorten it, make it a list, drop the filler."
        case .scratchpad: return "Somewhere to dictate that is not a text field. Thoughts you want to come back to."
        case .settings: return "Hotkey, microphone, models and permissions."
        case .help: return "Diagnostics, shortcuts and how to get Quill unstuck."
        }
    }
}

// MARK: - Sidebar

public protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarView, didSelect section: DashboardSection)
}

/// The navigation rail.
///
/// Draws nothing of its own background — it sits directly on the window canvas
/// so the content panel reads as floating above it, which is where the window's
/// sense of depth comes from. Give the sidebar its own fill and the panel
/// flattens into a second column.
public final class SidebarView: NSView {

    public weak var delegate: SidebarDelegate?

    public private(set) var selection: DashboardSection
    public var style: DashboardStyle { didSet { applyStyle() } }

    private var rows: [DashboardSection: SidebarRowView] = [:]
    private let mark: DashboardMark
    private let wordmark: NSTextField
    private let rule: DashboardRule
    /// One pill for the whole rail, moved between rows, rather than a pill drawn
    /// by whichever row happens to be selected. Nine rows each drawing their own
    /// means selection can only ever appear and disappear; one that travels is
    /// the difference between a list that responds and a list that redraws.
    private let selectionPill: SidebarSelectionPill

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle, selection: DashboardSection = .dictation) {
        self.style = style
        self.selection = selection
        mark = DashboardMark(style: style)
        wordmark = DashboardType.label("Quill", font: .systemFont(ofSize: 17, weight: .semibold),
                                       color: style.ink, tracking: -0.3)
        rule = DashboardRule(color: style.hairline)
        selectionPill = SidebarSelectionPill(style: style)
        super.init(frame: .zero)

        addSubview(mark)
        addSubview(wordmark)
        // Below every row, so the pill is a surface the icon and label sit on
        // rather than a rectangle covering them.
        addSubview(selectionPill)
        for section in DashboardSection.allCases {
            let row = SidebarRowView(section: section, style: style)
            row.onClick = { [weak self] in self?.select(section) }
            addSubview(row)
            rows[section] = row
        }
        addSubview(rule)

        rows[selection]?.isSelected = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func select(_ section: DashboardSection) {
        guard section != selection else { return }
        rows[selection]?.isSelected = false
        selection = section
        rows[section]?.isSelected = true
        movePill(animated: true)
        delegate?.sidebar(self, didSelect: section)
    }

    /// The pill crosses the gap between the primary group and the footer when
    /// selection jumps from Scratchpad to Settings — which is a long way and,
    /// travelled at the same speed as a one-row hop, looks like a bug. Distance
    /// buys a little more time, capped so it never becomes something to wait for.
    private func movePill(animated: Bool) {
        guard let target = rows[selection]?.frame else { return }
        guard animated, !DashboardMotion.isReduced else {
            selectionPill.frame = target
            return
        }
        let distance = abs(target.midY - selectionPill.frame.midY)
        let duration = min(0.34, DashboardMotion.standard + Double(distance) / 3200)
        DashboardMotion.run(duration, timing: DashboardMotion.snap) { _ in
            self.selectionPill.animator().frame = target
        }
    }

    /// Every colour the rail drew with, re-resolved. Missing one here is not a
    /// cosmetic bug — it is white text on a white card the instant the system
    /// flips to light, which is what an eagerly-resolved palette costs.
    private func applyStyle() {
        mark.apply(style)
        DashboardType.recolor(wordmark, style.ink)
        rows.values.forEach { $0.style = style }
        selectionPill.style = style
        rule.color = style.hairline
        needsLayout = true
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        let inset = DashboardMetrics.sidebarInset
        let width = bounds.width

        // Header sits on the vertical centre of the titlebar strip's lower half,
        // clear of the traffic lights.
        let headerY = DashboardMetrics.titlebarHeight + 14
        mark.frame = NSRect(x: inset + 4, y: headerY, width: 26, height: 26)
        let wordSize = wordmark.fittingSize
        wordmark.frame = NSRect(x: inset + 4 + 26 + 9,
                                y: headerY + ((26 - wordSize.height) / 2).rounded(),
                                width: wordSize.width, height: wordSize.height)

        var y = headerY + 26 + 30
        for section in DashboardSection.primary {
            rows[section]?.frame = NSRect(x: inset, y: y,
                                          width: width - inset * 2,
                                          height: DashboardMetrics.navRowHeight)
            y += DashboardMetrics.navRowHeight + DashboardMetrics.navRowGap
        }
        let navBottom = y - DashboardMetrics.navRowGap

        // Footer builds upward from the bottom edge.
        var bottom = bounds.height - 16
        for section in DashboardSection.footer.reversed() {
            bottom -= DashboardMetrics.navRowHeight
            rows[section]?.frame = NSRect(x: inset, y: bottom,
                                          width: width - inset * 2,
                                          height: DashboardMetrics.navRowHeight)
            bottom -= DashboardMetrics.navRowGap
        }

        bottom -= 14
        rule.frame = NSRect(x: inset + 3, y: bottom, width: width - (inset + 3) * 2, height: 1)
        bottom -= 20

        // Follows the rows on a resize without animating — a window being dragged
        // has enough moving already.
        movePill(animated: false)

        // The card belongs with the nav, not floating above the footer. Anchored
    }
}

// MARK: - Row

/// One navigation row.
///
/// The selected state is a *raised* white pill rather than a flat grey fill.
/// Flat selection is the default everywhere, which is exactly why it disappears;
/// a pill with a contact shadow and a lit top edge reads as a physical position
/// in a list, and costs four lines of drawing.
public final class SidebarRowView: NSView {

    public let section: DashboardSection
    public var style: DashboardStyle { didSet { rebuild() } }
    public var isSelected: Bool = false { didSet { rebuild() } }
    public var onClick: (() -> Void)?

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hover.animate(to: isHovered ? 1 : 0)
        }
    }
    private var icon: DashboardIconView
    private var label: NSTextField
    private lazy var hover = DashboardTween(view: self)

    public override var isFlipped: Bool { true }

    public init(section: DashboardSection, style: DashboardStyle) {
        self.section = section
        self.style = style
        icon = DashboardIconView(image: nil)
        label = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        addSubview(icon)
        addSubview(label)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        let tint = isSelected ? style.accent : style.inkTertiary
        icon.image = DashboardIcon.image(section.symbolName,
                                         pointSize: 14.5,
                                         weight: isSelected ? .semibold : .medium,
                                         color: tint)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.attributedStringValue = NSAttributedString(
            string: section.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: isSelected ? .semibold : .medium),
                .foregroundColor: isSelected ? style.ink : style.inkSecondary,
                .kern: -0.1,
            ])
        needsLayout = true
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        icon.frame = NSRect(x: 11, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let size = label.fittingSize
        label.frame = NSRect(x: 39, y: ((bounds.height - size.height) / 2).rounded(),
                             width: min(size.width, bounds.width - 48), height: size.height)
    }

    /// Hover only. The selected pill is drawn once by the rail and moved between
    /// rows, so a row that drew its own would produce two of them mid-travel.
    public override func draw(_ dirtyRect: NSRect) {
        guard !isSelected, hover.value > 0.001 else { return }
        DashboardDraw.fill(bounds, radius: DashboardRadius.row,
                           color: style.hover.faded(hover.value))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
    }
    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.arrow.set()
    }
    public override func mouseDown(with event: NSEvent) {
        // Nudges in under the pointer. Without it the only feedback on press is
        // the section changing, which arrives a frame later and reads as lag.
        DashboardMotion.run(DashboardMotion.press) { _ in self.animator().alphaValue = 0.68 }
    }
    public override func mouseUp(with event: NSEvent) {
        DashboardMotion.run(DashboardMotion.quick) { _ in self.animator().alphaValue = 1 }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Selection pill

/// The raised surface under the selected row, owned by the rail so it can travel.
public final class SidebarSelectionPill: NSView {

    public var style: DashboardStyle { didSet { needsDisplay = true } }

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle) {
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Nothing in the pill responds to the pointer — the row above it does. A
    /// pill that swallowed clicks would make the currently-selected row the one
    /// item in the list you cannot click.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.raisedSurface(bounds, radius: DashboardRadius.row,
                                    fillColor: style.raised, topColor: style.raisedTop,
                                    style: style, shadow: style.shadowRaised, flipped: true)
    }
}
