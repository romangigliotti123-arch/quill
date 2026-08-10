import AppKit

/// The Dictionary section.
///
/// Flow's version of this screen is a promo banner and five naked rows: the word
/// and nothing else. You cannot tell from it whether a single entry has ever
/// done anything, which is fine for Flow — its biasing runs server side and it
/// has no reason to doubt itself. Quill does. Contextual biasing was measured
/// inert here, so the dictionary is a *repair* list, and the only question worth
/// answering on this screen is "is it working".
///
/// So the screen is built around evidence rather than storage. Every row carries
/// what the recogniser actually said instead and how often the entry fired; the
/// terms that have never fired are marked as such and counted in the header,
/// because dead entries are the failure mode; and the inspector on the right
/// shows one real dictation, raw and repaired, with the word Quill put back
/// highlighted in place.
///
/// Layout: header, three numbers, then a list and an inspector. The two-column
/// body is the shape every Mac app with a table already has, and it is the only
/// way to show per-row evidence without a 1,000-point-wide row.
public final class DictionarySectionView: NSView {

    private let style: DashboardStyle
    private let entries: [DictionaryEntry]

    private let eyebrow: NSTextField
    private let heading: NSTextField
    private let blurb: NSTextField
    private let addButton: DashboardButton
    private let importButton: DashboardButton
    private var tiles: [DashboardMetricTile] = []

    private let list: DictionaryListView
    private var detail: DictionaryDetailView

    public override var isFlipped: Bool { true }

    public convenience init(style: DashboardStyle) {
        self.init(style: style,
                  entries: DictionaryEntry.entries(vocabulary: .load(), records: HistoryStore().all))
    }

    public init(style: DashboardStyle, entries: [DictionaryEntry]) {
        self.style = style
        // The list is the argument, so it is sorted by the number that carries
        // it: the terms Quill has had to fix most often float to the top, and
        // the ones it has never had to fix sink to the bottom where they read as
        // exactly what they are.
        let sorted = entries.sorted {
            $0.repairs == $1.repairs ? $0.term.lowercased() < $1.term.lowercased() : $0.repairs > $1.repairs
        }
        self.entries = sorted

        eyebrow = DashboardType.label("", font: DashboardType.eyebrow,
                                      color: style.inkTertiary)
        heading = DashboardType.label("Dictionary", font: DashboardType.display, color: style.ink)
        blurb = DashboardType.label(
            "",
            font: DashboardType.body, color: style.inkSecondary, lines: 2, lineHeight: 20)

        let primary = DashboardSection.dictionary.primaryAction
        addButton = DashboardButton(title: primary.title, symbol: primary.symbol, kind: .primary, style: style)
        let secondary = DashboardSection.dictionary.secondaryAction ?? ("Import", "arrow.down.circle")
        importButton = DashboardButton(title: secondary.title, symbol: secondary.symbol, kind: .secondary, style: style)

        list = DictionaryListView(entries: sorted, style: style)
        detail = DictionaryDetailView(entry: sorted.first, style: style)

        super.init(frame: .zero)

        addSubview(eyebrow)
        addSubview(heading)
        addSubview(blurb)
        addSubview(importButton)
        addSubview(addButton)

        for tile in DictionarySectionView.metrics(for: sorted, style: style) {
            addSubview(tile)
            tiles.append(tile)
        }

        addSubview(list)
        addSubview(detail)

        list.onSelect = { [weak self] entry in self?.show(entry) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Numbers

    /// Three counts, all derived from the rows below them. Nothing here is a
    /// number someone typed: a header that disagrees with its own table is the
    /// fastest way to lose a reader.
    private static func metrics(for entries: [DictionaryEntry], style: DashboardStyle) -> [DashboardMetricTile] {
        let auto = entries.filter { $0.origin == .auto }.count
        let manual = entries.count - auto
        let repairs = entries.reduce(0) { $0 + $1.repairs }
        let unused = entries.filter { !$0.hasFired }.count
        return [
            DashboardMetricTile(value: "\(entries.count)", unit: "terms",
                                caption: "\(manual) added by you · \(auto) learned",
                                accent: false, style: style),
            DashboardMetricTile(value: "\(repairs)", unit: "repairs",
                                caption: "words put back into your text",
                                accent: true, style: style),
            DashboardMetricTile(value: "\(unused)", unit: "unused",
                                caption: "never fired since you added them",
                                accent: false, style: style),
        ]
    }

    // MARK: - Selection

    private func show(_ entry: DictionaryEntry) {
        let replacement = DictionaryDetailView(entry: entry, style: style)
        replacement.frame = detail.frame
        replaceSubview(detail, with: replacement)
        detail = replacement
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2

        var y = padY
        let eyebrowSize = eyebrow.fittingSize
        eyebrow.frame = NSRect(x: padX, y: y, width: eyebrowSize.width, height: eyebrowSize.height)
        y += eyebrowSize.height + 10

        let headingSize = heading.fittingSize
        heading.frame = NSRect(x: padX, y: y, width: min(headingSize.width, width - 260), height: headingSize.height)
        y += headingSize.height + 8

        let blurbWidth = min(width - 300, 660)
        let blurbHeight = blurb.stringValue.isEmpty ? 0 : DashboardType.size(blurb, width: blurbWidth).height
        blurb.frame = NSRect(x: padX, y: y, width: blurbWidth, height: blurbHeight)
        y += blurbHeight

        let addWidth = addButton.intrinsicWidth
        addButton.frame = NSRect(x: bounds.width - padX - addWidth,
                                 y: padY + eyebrowSize.height + 6, width: addWidth, height: 36)
        let importWidth = importButton.intrinsicWidth
        importButton.frame = NSRect(x: addButton.frame.minX - 10 - importWidth,
                                    y: addButton.frame.minY, width: importWidth, height: 36)

        y += DashboardSpace.lg + DashboardSpace.xxs

        let tileGap = DashboardSpace.md
        let tileWidth = ((width - tileGap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)).rounded(.down)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: padX + (tileWidth + tileGap) * CGFloat(index), y: y,
                                width: tileWidth, height: 92)
        }
        y += 92 + DashboardSpace.lg

        let bodyHeight = max(200, bounds.height - y - padY)
        let detailWidth: CGFloat = 366
        let gap = DashboardSpace.lg
        list.frame = NSRect(x: padX, y: y, width: width - detailWidth - gap, height: bodyHeight)
        detail.frame = NSRect(x: padX + width - detailWidth, y: y, width: detailWidth, height: bodyHeight)
    }
}

// MARK: - Columns

/// Shared column geometry. The header labels and every row read the same struct,
/// because a table whose headings drift two points off its cells is a table
/// nobody trusts to be aligned anywhere else either.
struct DictionaryColumns {
    let inset: CGFloat = 18
    let termX: CGFloat
    let termW: CGFloat
    let heardX: CGFloat
    let heardW: CGFloat
    let barX: CGFloat
    let barW: CGFloat
    let countX: CGFloat
    let countW: CGFloat

    init(width: CGFloat) {
        let inner = width - 18 * 2
        termX = 18
        termW = (inner * 0.34).rounded()
        heardX = (termX + termW + 12).rounded()
        barW = (inner * 0.145).rounded()
        countW = 58
        countX = (18 + inner - countW).rounded()
        barX = (countX - 14 - barW).rounded()
        heardW = barX - 14 - heardX
    }
}

// MARK: - List

/// The well: filter strip, column headings, rows, footer.
final class DictionaryListView: NSView {

    var onSelect: ((DictionaryEntry) -> Void)?

    private let entries: [DictionaryEntry]
    private let style: DashboardStyle
    private let maxRepairs: Int

    private let segmented: DictionarySegmented
    private let sortLabel: NSTextField
    private let sortIcon: DashboardIconView
    private let headTerm: NSTextField
    private let headHeard: NSTextField
    private let headCount: NSTextField
    private let headRule: DashboardRule
    private let footRule: DashboardRule
    private let footLabel: NSTextField
    private let footAction: NSTextField
    private var rows: [DictionaryTermRow] = []
    private var selected: Int = 0

    override var isFlipped: Bool { true }

    init(entries: [DictionaryEntry], style: DashboardStyle) {
        self.entries = entries
        self.style = style
        maxRepairs = max(1, entries.map(\.repairs).max() ?? 1)

        segmented = DictionarySegmented(titles: ["All", "Added by you", "Learned"], selected: 0, style: style)
        sortLabel = DashboardType.label("Most repaired", font: DashboardType.caption, color: style.inkTertiary)
        sortIcon = DashboardIconView(image: DashboardIcon.image("chevron.up.chevron.down", pointSize: 9,
                                                                weight: .semibold, color: style.inkQuaternary))
        headTerm = DashboardType.label("Term", font: DashboardType.micro, color: style.inkQuaternary)
        headHeard = DashboardType.label("Heard instead", font: DashboardType.micro, color: style.inkQuaternary)
        headCount = DashboardType.label("Repairs", font: DashboardType.micro, color: style.inkQuaternary,
                                        alignment: .right)
        headRule = DashboardRule(color: style.hairline)
        footRule = DashboardRule(color: style.hairline)
        footLabel = DashboardType.label("", font: DashboardType.caption, color: style.inkTertiary)
        // The terms that have never fired sort to the bottom, which means they
        // are the rows nobody scrolls to. Naming them in the footer is what
        // turns "sorted by repairs" from a convenience into an audit.
        let unused = entries.filter { !$0.hasFired }.count
        footAction = DashboardType.label(unused > 0 ? "Review \(unused) unused ›" : "Show all",
                                         font: DashboardType.caption, color: style.inkSecondary,
                                         alignment: .right)

        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DashboardRadius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        addSubview(segmented)
        addSubview(sortLabel)
        addSubview(sortIcon)
        addSubview(headTerm)
        addSubview(headHeard)
        addSubview(headCount)
        addSubview(headRule)

        for (index, entry) in entries.enumerated() {
            let row = DictionaryTermRow(entry: entry, maxRepairs: maxRepairs, style: style)
            row.isSelected = index == 0
            row.onClick = { [weak self] in self?.select(index) }
            addSubview(row)
            rows.append(row)
        }

        addSubview(footRule)
        addSubview(footLabel)
        addSubview(footAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func select(_ index: Int) {
        guard index != selected, rows.indices.contains(index) else { return }
        rows[selected].isSelected = false
        selected = index
        rows[index].isSelected = true
        needsLayout = true
        onSelect?(entries[index])
    }

    override func layout() {
        super.layout()
        let columns = DictionaryColumns(width: bounds.width)
        let inset = columns.inset

        // Filter strip.
        segmented.frame = NSRect(x: inset, y: 15, width: segmented.intrinsicWidth, height: 26)
        let sortSize = sortLabel.fittingSize
        // The sort control is secondary; the filter tabs are how you navigate. When
        // there is not room for both, the sort goes rather than printing through
        // "Learned".
        let sortNeeds = sortSize.width + 12 + 5
        let sortFits = inset + segmented.intrinsicWidth + 16 + sortNeeds <= bounds.width - inset
        sortIcon.isHidden = !sortFits
        sortLabel.isHidden = !sortFits
        sortIcon.frame = NSRect(x: bounds.width - inset - 12, y: 22, width: 12, height: 12)
        sortLabel.frame = NSRect(x: sortIcon.frame.minX - 5 - sortSize.width,
                                 y: (28 - sortSize.height / 2).rounded(),
                                 width: sortSize.width, height: sortSize.height)

        // Column headings.
        let headY: CGFloat = 51
        let headHeight = headTerm.fittingSize.height
        headTerm.frame = NSRect(x: columns.termX, y: headY, width: columns.termW, height: headHeight)
        headHeard.frame = NSRect(x: columns.heardX, y: headY, width: columns.heardW, height: headHeight)
        headCount.frame = NSRect(x: columns.countX, y: headY, width: columns.countW, height: headHeight)
        headRule.frame = NSRect(x: inset, y: headY + headHeight + 7, width: bounds.width - inset * 2, height: 1)

        // Rows fill what is left above a footer that always keeps its 38 points.
        // The height is fitted rather than fixed: as many whole rows as will
        // clear 40 points, then stretched to land exactly on the footer rule.
        // A list that stops 30 points short of its own container reads as
        // clipped; one that ends on the rule reads as a list.
        let top = headRule.frame.maxY + 4
        let footerHeight: CGFloat = 36
        let available = bounds.height - top - footerHeight
        let visible = max(0, min(rows.count, Int((available / 40).rounded(.down))))
        let rowHeight = visible == 0 ? 42 : min(46, available / CGFloat(visible))

        for (index, row) in rows.enumerated() {
            guard index < visible else {
                row.isHidden = true
                continue
            }
            row.isHidden = false
            row.frame = NSRect(x: 0, y: top + rowHeight * CGFloat(index), width: bounds.width, height: rowHeight)
            // No rule under the last visible row, and none touching the edge of
            // the selection pill — a hairline meeting a raised corner reads as a
            // seam rather than a divider.
            row.showsRule = index < visible - 1 && index != selected && index + 1 != selected
        }

        let footTop = bounds.height - footerHeight
        footRule.frame = NSRect(x: inset, y: footTop, width: bounds.width - inset * 2, height: 1)
        let shown = min(visible, rows.count)
        footLabel.attributedStringValue = NSAttributedString(
            string: "Showing \(shown) of \(rows.count) · sorted by repairs",
            attributes: [.font: DashboardType.caption, .foregroundColor: style.inkTertiary])
        let footSize = footLabel.fittingSize
        let actionSize = footAction.fittingSize
        // "Review 6 unused" is a control and keeps its width; the count beside it
        // is prose and gives way. They used to overlap and both became unreadable.
        let roomForCount = max(0, bounds.width - inset * 2 - actionSize.width - 16)
        footLabel.frame = NSRect(x: inset, y: (footTop + (footerHeight - footSize.height) / 2 + 0.5).rounded(),
                                 width: min(footSize.width, roomForCount), height: footSize.height)
        footAction.frame = NSRect(x: bounds.width - inset - actionSize.width,
                                  y: footLabel.frame.minY, width: actionSize.width, height: actionSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.sunkenSurface(bounds, radius: DashboardRadius.card, style: style, flipped: true)
    }
}

// MARK: - Row

/// One term. Term, what the recogniser said instead, how much of the section's
/// total repair volume it accounts for, and the count.
final class DictionaryTermRow: NSView {

    var onClick: (() -> Void)?
    var isSelected = false { didSet { rebuild() } }
    var showsRule = true { didSet { needsDisplay = true } }

    private let entry: DictionaryEntry
    private let maxRepairs: Int
    private let style: DashboardStyle

    private let term: NSTextField
    private var star: DashboardIconView?
    private var autoChip: DashboardChip?
    private let heard: NSTextField
    private var extra: NSTextField?
    private let count: NSTextField

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hover.animate(to: isHovered ? 1 : 0)
        }
    }
    private lazy var hover = DashboardTween(view: self)

    override var isFlipped: Bool { true }

    init(entry: DictionaryEntry, maxRepairs: Int, style: DashboardStyle) {
        self.entry = entry
        self.maxRepairs = maxRepairs
        self.style = style

        // An unused term is drawn back, not hidden. It is still a real entry —
        // it just has not earned its place yet, and saying so in ink weight is
        // quieter and more useful than a warning badge.
        let ink = entry.hasFired ? style.ink : style.inkTertiary
        term = DashboardType.label(entry.display, font: DashboardType.bodyMedium, color: ink)

        // An expansion never gets misheard — it fires on the trigger. Saying
        // "expansion" is the honest thing to put in this column; a mishearing
        // that does not exist is not an em dash, it is a different kind of entry.
        let isExpansion = entry.mishearings.isEmpty && entry.replacement != nil
        heard = DashboardType.label(
            entry.mishearings.first.map(\.heard) ?? (isExpansion ? "expansion" : "—"),
            font: isExpansion ? DashboardType.micro
                : (entry.mishearings.isEmpty ? DashboardType.callout : DashboardType.mono),
            color: entry.hasFired ? (isExpansion ? style.inkTertiary : style.inkSecondary) : style.inkQuaternary,
            tracking: isExpansion ? nil : 0,
            uppercase: isExpansion)

        count = DashboardType.label(entry.hasFired ? "\(entry.repairs)" : "never",
                                    font: entry.hasFired ? DashboardType.mono : DashboardType.caption,
                                    color: entry.hasFired ? style.ink : style.inkQuaternary,
                                    tracking: 0, alignment: .right)

        super.init(frame: .zero)

        if entry.isStarred {
            let view = DashboardIconView(image: DashboardIcon.image("star.fill", pointSize: 9,
                                                                    weight: .semibold, color: style.inkQuaternary))
            addSubview(view)
            star = view
        }
        if entry.origin == .auto {
            let chip = DashboardChip(text: "learned", tone: .outline, style: style)
            addSubview(chip)
            autoChip = chip
        }
        // Only the top form is worth a column; the rest are one number, and the
        // inspector lists them in full.
        if entry.mishearings.count > 1 {
            let field = DashboardType.label("+\(entry.mishearings.count - 1)", font: DashboardType.micro,
                                            color: style.inkQuaternary, tracking: 0)
            addSubview(field)
            extra = field
        }

        addSubview(term)
        addSubview(heard)
        addSubview(count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        DashboardType.recolor(term, isSelected ? style.ink : (entry.hasFired ? style.ink : style.inkTertiary))
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let columns = DictionaryColumns(width: bounds.width)

        let termSize = term.fittingSize
        let termWidth = min(termSize.width, columns.termW)
        term.frame = NSRect(x: columns.termX, y: ((bounds.height - termSize.height) / 2).rounded(),
                            width: termWidth, height: termSize.height)
        var trailing = columns.termX + termWidth + 6
        if let star {
            star.frame = NSRect(x: trailing, y: (bounds.height / 2 - 5).rounded(), width: 10, height: 10)
            trailing += 14
        }
        if let autoChip {
            autoChip.frame = NSRect(x: trailing, y: ((bounds.height - autoChip.frame.height) / 2).rounded(),
                                    width: autoChip.frame.width, height: autoChip.frame.height)
        }

        let heardSize = heard.fittingSize
        let heardWidth = min(heardSize.width, columns.heardW - 26)
        heard.frame = NSRect(x: columns.heardX, y: ((bounds.height - heardSize.height) / 2).rounded(),
                             width: heardWidth, height: heardSize.height)
        if let extra {
            let size = extra.fittingSize
            extra.frame = NSRect(x: columns.heardX + heardWidth + 7,
                                 y: ((bounds.height - size.height) / 2).rounded() + 1,
                                 width: size.width, height: size.height)
        }

        let countSize = count.fittingSize
        count.frame = NSRect(x: columns.countX, y: ((bounds.height - countSize.height) / 2).rounded(),
                             width: columns.countW, height: countSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let columns = DictionaryColumns(width: bounds.width)

        if isSelected {
            // The same raised pill the sidebar uses for its selected row. One
            // selection idiom for the whole window.
            let pill = NSRect(x: 8, y: 1, width: bounds.width - 16, height: bounds.height - 2)
            DashboardDraw.raisedSurface(pill, radius: DashboardRadius.row,
                                        fillColor: style.raised, topColor: style.raisedTop,
                                        style: style, shadow: style.shadowRaised, flipped: true)
        } else if hover.value > 0.001 {
            DashboardDraw.fill(NSRect(x: 8, y: 1, width: bounds.width - 16, height: bounds.height - 2),
                               radius: DashboardRadius.row, color: style.hover.faded(hover.value))
        }

        // Volume bar. Proportional to the busiest term, so the column reads as
        // one distribution rather than eleven unrelated widths.
        if entry.hasFired {
            let fraction = CGFloat(entry.repairs) / CGFloat(maxRepairs)
            let track = NSRect(x: columns.barX, y: (bounds.height / 2 - 2).rounded(), width: columns.barW, height: 4)
            DashboardDraw.fill(track, radius: 2, color: style.hairline)
            let filled = NSRect(x: track.minX, y: track.minY,
                                width: max(4, (track.width * fraction).rounded()), height: track.height)
            DashboardDraw.fill(filled, radius: 2, color: isSelected ? style.inkSecondary : style.inkQuaternary)
        }

        if showsRule {
            style.hairline.setFill()
            NSRect(x: columns.inset, y: bounds.height - 1, width: bounds.width - columns.inset * 2, height: 1).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Segmented filter

/// Three-way filter. Hairline capsule, raised pill on the selected segment —
/// `NSSegmentedControl` brings the system tint and a bezel that belongs to a
/// different app.
final class DictionarySegmented: NSView {

    private let style: DashboardStyle
    private var labels: [NSTextField] = []
    private var selected: Int
    private var widths: [CGFloat] = []

    override var isFlipped: Bool { true }

    init(titles: [String], selected: Int, style: DashboardStyle) {
        self.style = style
        self.selected = selected
        super.init(frame: .zero)
        for (index, title) in titles.enumerated() {
            let field = DashboardType.label(title, font: DashboardType.caption,
                                            color: index == selected ? style.ink : style.inkTertiary,
                                            tracking: 0, alignment: .center)
            addSubview(field)
            labels.append(field)
            widths.append(ceil(field.fittingSize.width) + 24)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var intrinsicWidth: CGFloat { widths.reduce(6) { $0 + $1 } }

    private func segment(_ index: Int) -> NSRect {
        let x = widths.prefix(index).reduce(3) { $0 + $1 }
        return NSRect(x: x, y: 3, width: widths[index], height: bounds.height - 6)
    }

    override func layout() {
        super.layout()
        for (index, field) in labels.enumerated() {
            let rect = segment(index)
            let size = field.fittingSize
            field.frame = NSRect(x: rect.minX, y: (rect.midY - size.height / 2).rounded(),
                                 width: rect.width, height: size.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.fill(bounds, radius: DashboardRadius.row, color: style.isDark ? style.cardAlt : style.card)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.row, color: style.hairline)
        DashboardDraw.raisedSurface(segment(selected), radius: DashboardRadius.chip,
                                    fillColor: style.raised, topColor: style.raisedTop,
                                    style: style, shadow: style.shadowContact, flipped: true)
    }
}

// MARK: - Inspector

/// The right-hand card: everything known about one entry, ending in the actual
/// dictation it fired on.
final class DictionaryDetailView: NSView {

    private let entry: DictionaryEntry?
    private let style: DashboardStyle

    private let title: NSTextField
    private var star: DashboardIconView?
    private let originChip: DashboardChip
    private let meta: NSTextField

    private let heardHead: NSTextField
    private var heardRows: [(NSTextField, NSTextField)] = []
    private var emptyNote: NSTextField?

    private var sparkHead: NSTextField?
    private var spark: DictionarySparkView?

    private var caughtHead: NSTextField?
    private var caughtWell: DashboardCardView?
    private var caughtRaw: NSTextField?
    private var caughtArrow: DashboardIconView?
    private var caughtClean: DictionaryHighlightText?

    private var rules: [DashboardRule] = []
    private let footRule: DashboardRule
    private let foot: NSTextField

    override var isFlipped: Bool { true }

    init(entry: DictionaryEntry?, style: DashboardStyle) {
        self.entry = entry
        self.style = style

        let term = entry?.replacement.map { "\(entry?.term ?? "")  →  \($0)" } ?? entry?.term ?? "No entry"
        title = DashboardType.label(term, font: DashboardType.title, color: style.ink)
        originChip = DashboardChip(text: entry?.origin.label ?? "—", tone: .neutral, style: style)

        var metaParts: [String] = []
        if let entry {
            if entry.added.isEmpty {
                metaParts.append(entry.lastFired.map { "Last repair \($0)" } ?? "No repair yet")
            } else {
                metaParts.append("Added \(entry.added)")
                metaParts.append(entry.lastFired.map { "last repair \($0)" } ?? "no repair yet")
            }
        }
        meta = DashboardType.label(metaParts.joined(separator: " · "), font: DashboardType.callout,
                                   color: style.inkTertiary)

        let forms = entry?.mishearings.count ?? 0
        heardHead = DashboardType.label(forms > 0 ? "Heard instead · \(forms) form\(forms == 1 ? "" : "s")"
                                            : (entry?.replacement != nil ? "Expands to" : "Nothing caught yet"),
                                        font: DashboardType.caption, color: style.inkTertiary)
        footRule = DashboardRule(color: style.hairline)
        foot = DashboardType.label(
            "Matched on 1–3 word spans by edit distance, after the transcript — biasing never fires on this Mac.",
            font: .systemFont(ofSize: 11, weight: .regular), color: style.inkQuaternary,
            tracking: 0, lines: 3, lineHeight: 15)

        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DashboardRadius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        addSubview(title)
        addSubview(originChip)
        addSubview(meta)
        if entry?.isStarred == true {
            let view = DashboardIconView(image: DashboardIcon.image("star.fill", pointSize: 10,
                                                                    weight: .semibold, color: style.inkQuaternary))
            addSubview(view)
            star = view
        }
        addSubview(rule())
        addSubview(heardHead)

        if let entry {
            if !entry.mishearings.isEmpty {
                for mishearing in entry.mishearings.prefix(4) {
                    let left = DashboardType.label(mishearing.heard, font: DashboardType.mono,
                                                   color: style.inkSecondary, tracking: 0)
                    let right = DashboardType.label("\(mishearing.count)", font: DashboardType.mono,
                                                    color: style.inkTertiary, tracking: 0, alignment: .right)
                    addSubview(left)
                    addSubview(right)
                    heardRows.append((left, right))
                }
            } else if let replacement = entry.replacement {
                let left = DashboardType.label(replacement, font: DashboardType.mono,
                                               color: style.inkSecondary, tracking: 0)
                let right = DashboardType.label("\(entry.substitutions)", font: DashboardType.mono,
                                                color: style.inkTertiary, tracking: 0, alignment: .right)
                addSubview(left)
                addSubview(right)
                heardRows.append((left, right))
            } else {
                // The honest empty state, and the reason this screen exists.
                let note = DashboardType.label(
                    "This term has not appeared in a dictation since you added it, so nothing here has been proven. It costs nothing to keep.",
                    font: DashboardType.callout, color: style.inkTertiary, lines: 4, lineHeight: 17)
                addSubview(note)
                emptyNote = note
            }

            if entry.hasFired {
                addSubview(rule())
                let head = DashboardType.label("Repairs, last 8 weeks", font: DashboardType.caption,
                                               color: style.inkTertiary)
                addSubview(head)
                sparkHead = head
                // Beside its own label rather than beneath it. Eight numbers do
                // not need a chart the width of the card — given one, the bars
                // come out square and read as blocks instead of as a trend.
                let view = DictionarySparkView(values: entry.weekly, style: style)
                addSubview(view)
                spark = view
            }

            if let raw = entry.caughtRaw, let clean = entry.caughtClean {
                addSubview(rule())
                let head = DashboardType.label("Last caught · \(entry.lastFired ?? "a dictation")",
                                               font: DashboardType.caption, color: style.inkTertiary)
                addSubview(head)
                caughtHead = head

                // The evidence sits in a well: it is quoted material, not the
                // inspector's own copy, and a sunken surface says so without a
                // quotation mark or an italic.
                let well = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.row)
                addSubview(well)
                caughtWell = well

                let rawField = DashboardType.label(raw, font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                                   color: style.inkQuaternary, tracking: 0, lines: 3, lineHeight: 16)
                addSubview(rawField)
                caughtRaw = rawField

                let arrow = DashboardIconView(image: DashboardIcon.image("arrow.turn.down.right", pointSize: 10,
                                                                          weight: .semibold, color: style.inkQuaternary))
                addSubview(arrow)
                caughtArrow = arrow

                // The one place on this screen the accent is spent on prose: the
                // exact word Quill put back, in the sentence it put it back into.
                let word = entry.replacement ?? entry.term
                let attributed = NSMutableAttributedString(string: clean, attributes: [
                    .font: DashboardType.body,
                    .foregroundColor: style.ink,
                    .kern: -0.05,
                ])
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = 19
                paragraph.maximumLineHeight = 19
                attributed.addAttribute(.paragraphStyle, value: paragraph,
                                        range: NSRange(location: 0, length: attributed.length))
                var range = (clean as NSString).range(of: word, options: [.caseInsensitive])
                if range.location == NSNotFound { range = NSRange(location: 0, length: 0) }
                if range.length > 0 {
                    attributed.addAttribute(.foregroundColor, value: style.accentInk, range: range)
                }
                let view = DictionaryHighlightText(attributed: attributed, highlight: range,
                                                   color: style.accentSoft)
                addSubview(view)
                caughtClean = view
            }
        }

        addSubview(footRule)
        addSubview(foot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func rule() -> DashboardRule {
        let view = DashboardRule(color: style.hairline)
        rules.append(view)
        return view
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 20
        let width = bounds.width - pad * 2
        var y = pad
        var ruleIndex = 0
        rules.forEach { $0.isHidden = true }

        func place(_ rule: DashboardRule) {
            rule.isHidden = false
            rule.frame = NSRect(x: pad, y: y, width: width, height: 1)
            y += 1 + 17
        }

        // The footnote is pinned to the bottom edge: it is a property of the
        // mechanism, not of whichever entry happens to be selected, and it
        // should not jump around as the selection changes. Everything above it
        // is laid out against this ceiling, and a block that would cross it is
        // dropped rather than drawn through it — the window is resizable, and
        // a short window must lose the least important block, not overlap.
        let footHeight = DashboardType.size(foot, width: width).height
        let footY = bounds.height - pad - footHeight
        foot.frame = NSRect(x: pad, y: footY, width: width, height: footHeight)
        footRule.frame = NSRect(x: pad, y: footY - 16, width: width, height: 1)
        let ceiling = footY - 16 - 16

        let titleSize = title.fittingSize
        let titleWidth = min(titleSize.width, width - originChip.frame.width - 30)
        title.frame = NSRect(x: pad, y: y, width: titleWidth, height: titleSize.height)
        if let star {
            star.frame = NSRect(x: pad + titleWidth + 6, y: y + (titleSize.height / 2 - 5).rounded(),
                                width: 11, height: 11)
        }
        originChip.frame = NSRect(x: bounds.width - pad - originChip.frame.width,
                                  y: y + ((titleSize.height - originChip.frame.height) / 2).rounded(),
                                  width: originChip.frame.width, height: originChip.frame.height)
        y += titleSize.height + 5

        let metaSize = meta.fittingSize
        meta.frame = NSRect(x: pad, y: y, width: min(metaSize.width, width), height: metaSize.height)
        y += metaSize.height + 17

        // Below here everything is optional. The identity of the entry — its
        // name, where it came from, when it last fired — is the one thing this
        // card must always be able to show; every block under it is dropped
        // rather than drawn over the footnote when the window is short.
        let headHeight = heardHead.fittingSize.height
        let canShowHeard = y + 1 + 17 + headHeight + 18 <= ceiling
        heardHead.isHidden = !canShowHeard
        emptyNote?.isHidden = true
        for (left, right) in heardRows {
            left.isHidden = true
            right.isHidden = true
        }

        if canShowHeard {
            place(rules[ruleIndex])
            heardHead.frame = NSRect(x: pad, y: y, width: width, height: headHeight)
            y += headHeight + 11

            for (left, right) in heardRows {
                let size = left.fittingSize
                guard y + size.height <= ceiling else { break }
                left.isHidden = false
                right.isHidden = false
                left.frame = NSRect(x: pad, y: y, width: min(size.width, width - 40), height: size.height)
                right.frame = NSRect(x: bounds.width - pad - 34, y: y, width: 34, height: size.height)
                y += size.height + 7
            }
            if !heardRows.isEmpty { y -= 7 }
            if let emptyNote {
                let height = DashboardType.size(emptyNote, width: width).height
                if y + height <= ceiling {
                    emptyNote.isHidden = false
                    emptyNote.frame = NSRect(x: pad, y: y, width: width, height: height)
                    y += height
                }
            }
            y += 17
        }
        ruleIndex += 1

        // Sized before either block is placed, so the decision to keep or drop
        // the chart is made knowing what the evidence below it costs.
        let sparkRow: CGFloat = 36
        let sparkBlock = sparkHead == nil ? 0 : 1 + 17 + sparkRow
        let wellPad: CGFloat = 12
        let rawHeight = caughtRaw.map { DashboardType.size($0, width: width - wellPad * 2).height } ?? 0
        let cleanWidth = width - wellPad * 2 - 18
        let cleanHeight = caughtClean?.height(for: cleanWidth) ?? 0
        let caughtBlock = caughtHead == nil ? 0
            : 1 + 17 + caughtHead!.fittingSize.height + 10 + wellPad + rawHeight + 6 + cleanHeight + wellPad

        let keepSpark = canShowHeard && sparkHead != nil && y + sparkBlock + caughtBlock <= ceiling
        let keepCaught = canShowHeard && caughtHead != nil
            && y + (keepSpark ? sparkBlock : 0) + caughtBlock <= ceiling

        if let sparkHead, let spark {
            sparkHead.isHidden = !keepSpark
            spark.isHidden = !keepSpark
            if keepSpark {
                place(rules[ruleIndex])
                // Sitting on the chart's baseline rather than centred against
                // its box: the bars grow from the bottom, so a label centred on
                // the row reads as floating above its own data.
                let height = sparkHead.fittingSize.height
                sparkHead.frame = NSRect(x: pad, y: (y + sparkRow - height - 2).rounded(),
                                         width: width - 180, height: height)
                spark.frame = NSRect(x: bounds.width - pad - 168, y: y, width: 168, height: sparkRow)
                y += sparkRow + 17
            }
            ruleIndex += 1
        }

        if let caughtHead, let caughtWell, let caughtRaw, let caughtArrow, let caughtClean {
            for view in [caughtHead, caughtWell, caughtRaw, caughtArrow, caughtClean] as [NSView] {
                view.isHidden = !keepCaught
            }
            if keepCaught {
                place(rules[ruleIndex])
                let height = caughtHead.fittingSize.height
                caughtHead.frame = NSRect(x: pad, y: y, width: width, height: height)
                y += height + 10

                let wellHeight = wellPad + rawHeight + 6 + cleanHeight + wellPad
                caughtWell.frame = NSRect(x: pad, y: y, width: width, height: wellHeight)
                caughtRaw.frame = NSRect(x: pad + wellPad, y: y + wellPad, width: width - wellPad * 2, height: rawHeight)
                let cleanY = y + wellPad + rawHeight + 6
                caughtArrow.frame = NSRect(x: pad + wellPad, y: cleanY + 3, width: 12, height: 12)
                caughtClean.frame = NSRect(x: pad + wellPad + 18, y: cleanY, width: cleanWidth, height: cleanHeight)
                y += wellHeight
            }
            ruleIndex += 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.raisedSurface(bounds, radius: DashboardRadius.card,
                                    fillColor: style.raised, topColor: style.raisedTop,
                                    style: style, shadow: style.shadowCard, flipped: true)
    }
}

// MARK: - Spark

/// Eight weeks of repairs. Bars rather than a line: eight integers, most of them
/// small, and a line through them invents a continuity the data does not have.
final class DictionarySparkView: NSView {

    private let values: [Int]
    private let style: DashboardStyle

    override var isFlipped: Bool { true }

    init(values: [Int], style: DashboardStyle) {
        self.values = values
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let peak = CGFloat(max(1, values.max() ?? 1))
        let gap: CGFloat = 5
        let step = (bounds.width + gap) / CGFloat(values.count)
        let barWidth = (step - gap).rounded(.down)
        let baseline = bounds.height - 1

        style.hairline.setFill()
        NSRect(x: 0, y: baseline, width: bounds.width, height: 1).fill()

        for (index, value) in values.enumerated() {
            let x = (step * CGFloat(index)).rounded()
            // Empty weeks still get a stub, so the axis reads as eight weeks
            // rather than as however many weeks happened to be busy.
            let height = value == 0 ? 3 : max(5, (baseline * CGFloat(value) / peak).rounded())
            let rect = NSRect(x: x, y: baseline - height, width: barWidth, height: height)
            let colour: NSColor
            if index == values.count - 1 {
                colour = style.accent
            } else if value == 0 {
                colour = style.hairlineStrong
            } else {
                colour = style.inkQuaternary
            }
            DashboardDraw.fill(rect, radius: 2, color: colour)
        }
    }
}

// MARK: - Highlighted text

/// Body text with a rounded highlight behind one range.
///
/// `NSTextField` can colour a range's background, but only as a hard rectangle
/// that clips the descenders and butts against the next word. Laying the string
/// out by hand costs twenty lines and buys the one detail this screen is really
/// selling: the repaired word, marked in place, inside a real sentence.
final class DictionaryHighlightText: NSView {

    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private let range: NSRange
    private let color: NSColor

    override var isFlipped: Bool { true }

    init(attributed: NSAttributedString, highlight range: NSRange, color: NSColor) {
        storage = NSTextStorage(attributedString: attributed)
        self.range = range
        self.color = color
        super.init(frame: .zero)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat {
        size(width)
        return ceil(manager.usedRect(for: container).height)
    }

    @discardableResult
    private func size(_ width: CGFloat) -> NSSize {
        container.size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).size
    }

    override func layout() {
        super.layout()
        size(bounds.width)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        size(bounds.width)
        if range.length > 0 {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            color.setFill()
            manager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in
                let padded = NSRect(x: rect.minX - 4, y: rect.minY + 1,
                                    width: rect.width + 8, height: rect.height - 2)
                NSBezierPath(roundedRect: padded, xRadius: 5, yRadius: 5).fill()
            }
        }
        manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero)
    }
}
