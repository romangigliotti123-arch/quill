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

    private var header: DashboardSectionHeader!
    private let heading: NSTextField
    private let blurb: NSTextField
    private let addButton: DashboardButton
    private let importButton: DashboardButton
    private var tiles: [DashboardMetricTile] = []

    private let list: DictionaryListView
    private var detail: DictionaryDetailView
    /// Shown when the rows are the preview fixture rather than this user's own
    /// history. Unlabelled sample data on a screen that exists to prove a number
    /// is worse than an empty screen: it is a claim, and it is false.
    private var sampleChip: DashboardChip?
    /// The add / import panel, present only while it is open.
    private var composer: DictionaryComposer?

    public override var isFlipped: Bool { true }

    public convenience init(style: DashboardStyle) {
        // Deliberately NOT filtered by `isMeasurement`, unlike Insights.
        //
        // The line is what the screen claims. Insights says "you dictated 14,145
        // words" and "you saved 3h 59m", which are claims about Roman, so a clip
        // played through a loopback must not count. This screen says "the word
        // 'graphify' was repaired six times, here is one of them" — and the eval
        // corpus is his own voice reading his own sentences, so those repairs
        // happened and those receipts are real. Dropping them would empty the
        // screen back to a fixture in order to be more honest, which is the wrong
        // direction.
        let records = HistoryStore().all
        self.init(style: style,
                  entries: DictionaryEntry.entries(vocabulary: .load(), records: records),
                  isSample: records.isEmpty)
    }

    public init(style: DashboardStyle, entries: [DictionaryEntry], isSample: Bool = false) {
        self.style = style
        // The list is the argument, so it is sorted by the number that carries
        // it: the terms Quill has had to fix most often float to the top, and
        // the ones it has never had to fix sink to the bottom where they read as
        // exactly what they are.
        let sorted = entries.sorted {
            $0.repairs == $1.repairs ? $0.term.lowercased() < $1.term.lowercased() : $0.repairs > $1.repairs
        }
        self.entries = sorted

        heading = DashboardType.label("", font: DashboardType.display, color: style.ink)
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

        header = DashboardSectionHeader(title: "Dictionary",
                                        trailing: [importButton, addButton],
                                        style: style)
        addSubview(header)
        addSubview(heading)
        addSubview(blurb)
        if isSample {
            let chip = DashboardChip(text: "Sample data", tone: .outline, style: style)
            addSubview(chip)
            sampleChip = chip
        }

        for tile in DictionarySectionView.metrics(for: sorted, style: style) {
            addSubview(tile)
            tiles.append(tile)
        }

        addSubview(list)
        addSubview(detail)

        list.onSelect = { [weak self] entry in self?.show(entry) }
        addButton.onClick = { [weak self] in self?.open(.add) }
        if let requested = ProcessInfo.processInfo.environment["QUILL_DICTIONARY_PANEL"] {
            // A review hook, same shape as QUILL_RESIZE_SWEEP: open the panel so a
            // render or a sweep can see it. Never set in normal use.
            // Synchronously, inside init. Deferring it to the next main-queue tick
            // put the panel into the tree after the renderer's display cycle had
            // already run, and AppKit does not graft a late subview's layer onto
            // its superview without another one — so the hook fired, the panel
            // existed, and the screenshot showed no panel.
            open(requested == "import"
                 ? .suggestions(VocabularyHarvest.suggestions())
                 : .add)
        }
        importButton.onClick = { [weak self] in
            self?.open(.suggestions(VocabularyHarvest.suggestions()))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Adding words

    /// Opens the panel, or closes it if the same button is pressed again.
    ///
    /// Not private: the offscreen renderer and the resize sweep need to be able
    /// to put the section into this state, and a panel that can only be reached
    /// by a mouse click is a panel that never gets reviewed at any window size.
    func open(_ mode: DictionaryComposer.Mode) {
        let alreadyOpen = composer != nil
        composer?.removeFromSuperview()
        composer = nil
        guard !alreadyOpen || isDifferent(mode) else {
            needsLayout = true
            return
        }

        let panel = DictionaryComposer(mode: mode, style: style)
        panel.onDismiss = { [weak self] in
            self?.composer?.removeFromSuperview()
            self?.composer = nil
            self?.needsLayout = true
        }
        // Rebuild the whole section: the term counts, the tiles and the list all
        // change together, and a screen where the header disagrees with the table
        // under it is the specific failure this section was written to avoid.
        panel.onAdded = { _ in
            NotificationCenter.default.post(name: .quillDashboardNeedsReload, object: nil)
        }
        addSubview(panel)
        composer = panel
        needsLayout = true
        DispatchQueue.main.async { panel.focus() }
    }

    /// Pressing "Add word" while the import panel is open should swap panels, not
    /// close it and leave the user wondering what happened.
    private func isDifferent(_ mode: DictionaryComposer.Mode) -> Bool {
        guard let composer else { return true }
        switch (composer.mode, mode) {
        case (.add, .add): return false
        case (.suggestions, .suggestions): return false
        default: return true
        }
    }

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
                                accent: false, style: style),
            DashboardMetricTile(value: "\(unused)", unit: "unused",
                                caption: "never fired since you added them",
                                accent: false, style: style),
        ]
    }

    // MARK: - Selection

    private func show(_ entry: DictionaryEntry?) {
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

        // The header places the title and both buttons. This screen used to do it
        // itself — an empty eyebrow, an empty blurb, and two buttons pinned to padY
        // at a hardcoded 36 points — which is four separate opinions about where a
        // heading goes, in one of the two screens that sets the bar for the rest.
        header.frame = NSRect(x: padX, y: padY, width: width, height: header.height)
        heading.frame = .zero
        blurb.frame = .zero
        if let sampleChip {
            let size = sampleChip.fittingSize
            sampleChip.frame = NSRect(x: importButton.frame.minX - 10 - size.width,
                                      y: (importButton.frame.midY - size.height / 2).rounded(),
                                      width: size.width, height: size.height)
        }

        var y = DashboardSectionHeader.contentTop(for: header) - DashboardSpace.xxs

        if let composer {
            let height = composer.height(forWidth: width)
            composer.frame = NSRect(x: padX, y: y, width: width, height: height)
            y += height + DashboardSpace.md
        }

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
        countW = 58
        countX = (18 + inner - countW).rounded()

        // The bar gives way before the words do.
        //
        // Every column but "Heard instead" took a share off the top and that one
        // took the remainder, so at the minimum window it collapsed to 34 points —
        // the heading and every value in it truncated to three characters. It is
        // the column carrying the evidence this whole screen is built on: what the
        // recogniser actually said instead.
        //
        // So the proportion bar is the flexible one now. It is a redundant
        // encoding — the number it visualises is printed immediately to its right
        // — and it can shrink to nothing without costing a fact.
        let wanted = (inner * 0.145).rounded()
        let floorForHeard: CGFloat = 96
        let roomForBar = max(0, countX - 14 - (heardX + floorForHeard) - 14)
        barW = min(wanted, roomForBar)
        barX = (countX - 14 - barW).rounded()
        heardW = max(0, barX - 14 - heardX)
    }
}

// MARK: - List

/// The well: filter strip, column headings, rows, footer.
final class DictionaryListView: NSView {

    var onSelect: ((DictionaryEntry?) -> Void)?

    /// Everything, unfiltered. `entries` is what the list is currently showing.
    private let allEntries: [DictionaryEntry]
    private var entries: [DictionaryEntry]
    private let style: DashboardStyle
    private let maxRepairs: Int

    /// Which of the three filter segments is live, and whether the footer's
    /// "review unused" is on top of it. Both used to be drawn and neither could
    /// be operated.
    private enum Filter: Int { case all, manual, learned }
    private var filter: Filter = .all
    private var unusedOnly = false
    private var sortByName = false

    static let rowHeight: CGFloat = 44

    private let segmented: DictionarySegmented
    private let sortControl: DictionarySortControl
    private let footButton: DictionaryFootButton
    private let scroll = NSScrollView()
    private let listDocument = DictionaryFlippedView()
    /// Shown when a filter empties the list. Lazily built, because the common
    /// case never needs it.
    private var emptyLabel: NSTextField?
    private let headTerm: NSTextField
    private let headHeard: NSTextField
    private let headCount: NSTextField
    private let headRule: DashboardRule
    private let footRule: DashboardRule
    private let footLabel: NSTextField
    private var rows: [DictionaryTermRow] = []
    private var selected: Int = 0

    override var isFlipped: Bool { true }

    init(entries: [DictionaryEntry], style: DashboardStyle) {
        self.allEntries = entries
        self.entries = entries
        self.style = style
        maxRepairs = max(1, entries.map(\.repairs).max() ?? 1)

        segmented = DictionarySegmented(titles: ["All", "Added by you", "Learned"], selected: 0, style: style)
        sortControl = DictionarySortControl(style: style)
        footButton = DictionaryFootButton(style: style)
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
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DashboardRadius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        // Backgroundless and borderless: the well is already drawn, and
        // NSScrollView's own chrome is the default look this window avoids.
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.documentView = listDocument
        addSubview(scroll)

        addSubview(segmented)
        addSubview(sortControl)
        addSubview(headTerm)
        addSubview(headHeard)
        addSubview(headCount)
        addSubview(headRule)

        addSubview(footRule)
        addSubview(footLabel)
        addSubview(footButton)
        buildRows()

        segmented.onChange = { [weak self] index in
            guard let self, let next = Filter(rawValue: index) else { return }
            self.filter = next
            self.unusedOnly = false
            self.applyFilter()
        }
        sortControl.onClick = { [weak self] in
            guard let self else { return }
            self.sortByName.toggle()
            self.sortControl.setTitle(self.sortByName ? "A \u{2013} Z" : "Most repaired", style: self.style)
            self.applyFilter()
        }
        footButton.onClick = { [weak self] in
            guard let self else { return }
            self.unusedOnly.toggle()
            self.applyFilter()
        }
    }

    /// The one place rows come from. Filtering used to be impossible because the
    /// rows were built once, in `init`, from a list that could never change.
    private func buildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        for (index, entry) in entries.enumerated() {
            let row = DictionaryTermRow(entry: entry, maxRepairs: maxRepairs, style: style)
            row.isSelected = index == selected
            row.onClick = { [weak self] in self?.select(index) }
            // Into the scrolling document, not straight onto the card. Parented
            // here they were laid out at document-relative coordinates on the
            // card itself, so row one printed through the filter strip.
            listDocument.addSubview(row)
            rows.append(row)
        }
        updateEmptyState()
        footButton.setTitle(unusedOnly ? "Show all" : unusedTitle, style: style)
        // Not offered beside an empty list. "Review 132 unused" next to a card
        // showing nothing is an invitation into a state the user is already in.
        footButton.isHidden = (!unusedOnly && unusedCount == 0) || (rows.isEmpty && !unusedOnly)
    }

    /// A filter that finds nothing has to say so.
    ///
    /// Tapping "Learned" on this Mac is one click from a blank card: the tile
    /// above it reads "142 added by you · 0 learned". It used to leave the list
    /// empty with only column headings, a footer reading "Showing 0 of 0", and an
    /// inspector still showing the term you had selected before — which is exactly
    /// the failure the comment above `applyFilter` says the filter exists to avoid.
    private func updateEmptyState() {
        emptyLabel?.removeFromSuperview()
        emptyLabel = nil
        guard rows.isEmpty else { return }
        let text: String
        if unusedOnly { text = "Nothing unused here." }
        else {
            switch filter {
            case .all: text = "No terms yet."
            case .manual: text = "You haven't added any terms yet."
            case .learned: text = "Quill hasn't learned any terms yet."
            }
        }
        let label = DashboardType.label(text, font: DashboardType.callout,
                                        color: style.inkTertiary, alignment: .center)
        addSubview(label)
        emptyLabel = label
    }

    private var unusedCount: Int { allEntries.filter { !$0.hasFired }.count }
    private var unusedTitle: String { "Review \(unusedCount) unused \u{203A}" }

    private func applyFilter() {
        var next = allEntries.filter { entry in
            switch filter {
            case .all: return true
            case .manual: return entry.origin == .manual
            case .learned: return entry.origin == .auto
            }
        }
        if unusedOnly { next = next.filter { !$0.hasFired } }
        next.sort {
            sortByName
                ? $0.term.lowercased() < $1.term.lowercased()
                : ($0.repairs == $1.repairs ? $0.term.lowercased() < $1.term.lowercased() : $0.repairs > $1.repairs)
        }
        entries = next
        selected = 0
        buildRows()
        needsLayout = true
        layoutSubtreeIfNeeded()
        // The inspector follows the list, INCLUDING to nothing. A filter that
        // leaves the right-hand card showing a term the list no longer contains is
        // worse than no filter at all, and an empty result is the case where that
        // bites hardest — the stale term is the only thing left on screen.
        onSelect?(entries.first)
    }

    /// How many rows survived the current filter. Pinned by a test, because
    /// "the buttons do something" is exactly the claim that went unchecked.
    var visibleEntryCount: Int { entries.count }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func select(_ index: Int) {
        guard index != selected, rows.indices.contains(index), entries.indices.contains(index) else { return }
        if rows.indices.contains(selected) { rows[selected].isSelected = false }
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
        // The sort control is secondary; the filter tabs are how you navigate. When
        // there is not room for both, the sort goes rather than printing through
        // "Learned".
        // The sort control loses its label rather than itself.
        //
        // It used to be hidden outright when the strip got tight, which at the
        // documented minimum window size meant the control that was just made real
        // could not be reached at all. The glyph alone is 30 points against a
        // ~54-point budget, so it always fits; `DictionaryTextControl` centres the
        // chevron when there is no label to sit beside.
        let full = sortControl.intrinsicWidth
        let roomy = inset + segmented.intrinsicWidth + 16 + full <= bounds.width - inset
        sortControl.showsLabel = roomy
        let sortWidth = sortControl.intrinsicWidth
        sortControl.frame = NSRect(x: bounds.width - inset - sortWidth, y: 15,
                                   width: sortWidth, height: 26)

        // Column headings.
        let headY: CGFloat = 51
        let headHeight = headTerm.fittingSize.height
        headTerm.frame = NSRect(x: columns.termX, y: headY, width: columns.termW, height: headHeight)
        headHeard.frame = NSRect(x: columns.heardX, y: headY, width: columns.heardW, height: headHeight)
        headCount.frame = NSRect(x: columns.countX, y: headY, width: columns.countW, height: headHeight)
        headRule.frame = NSRect(x: inset, y: headY + headHeight + 7, width: bounds.width - inset * 2, height: 1)

        // The list SCROLLS. It used to show as many whole rows as fitted and set
        // `isHidden = true` on the rest — so with 142 terms, 135 of them could not
        // be reached by any means. The screen announced a number it would not let
        // you look at, on the one tab whose whole argument is "here is the evidence".
        //
        // The stretch-to-the-footer-rule trick that used to live here has to go
        // with it: a scrolling document view needs a constant row height, and the
        // old `min(46, available / visible)` was deliberately elastic so the last
        // visible row would land exactly on the rule. Rows are a flat 44 now and
        // the overflow scrolls, which is the honest version of the same intent.
        let top = headRule.frame.maxY + 4
        let footerHeight: CGFloat = 36
        let listHeight = max(0, bounds.height - top - footerHeight)
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: listHeight)

        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            row.isHidden = false
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: DictionaryListView.rowHeight)
            y += DictionaryListView.rowHeight
            // Indexed off the row COUNT, not off what happens to be on screen.
            // Keyed off `visible` it would have dropped the hairline from row nine
            // onward and put a stray one under the last row of the document.
            row.showsRule = index < rows.count - 1 && index != selected && index + 1 != selected
        }
        listDocument.frame = NSRect(x: 0, y: 0, width: bounds.width, height: y)

        if let emptyLabel {
            emptyLabel.isHidden = !rows.isEmpty
            let size = emptyLabel.fittingSize
            emptyLabel.frame = NSRect(x: inset, y: top + ((listHeight - size.height) * 0.42).rounded(),
                                      width: bounds.width - inset * 2, height: size.height)
        }

        let footTop = bounds.height - footerHeight
        footRule.frame = NSRect(x: inset, y: footTop, width: bounds.width - inset * 2, height: 1)
        // "Showing 7 of 142" is stale by construction once the list scrolls, and
        // the sort clause was duplicated state — the sort control an inch away
        // already names the live order in its own label. What is left is the one
        // number that is still true, and it is short enough that it cannot clip.
        //
        // The paragraph style is the second half of that: the frame is clamped to
        // `roomForCount`, so without a break mode this field hard-cut mid-word with
        // no ellipsis ("sorted b"). A longer count or a wider footer button would
        // do it again.
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        footLabel.attributedStringValue = NSAttributedString(
            string: rows.count == allEntries.count
                ? DictationFormat.plural(rows.count, "term")
                : "\(DictationFormat.count(rows.count)) of \(DictationFormat.count(allEntries.count))",
            attributes: [.font: DashboardType.caption,
                         .foregroundColor: style.inkTertiary,
                         .paragraphStyle: truncating])
        let footSize = footLabel.fittingSize
        let actionSize = footButton.isHidden ? .zero : NSSize(width: footButton.intrinsicWidth, height: 24)
        // "Review 6 unused" is a control and keeps its width; the count beside it
        // is prose and gives way. They used to overlap and both became unreadable.
        let roomForCount = max(0, bounds.width - inset * 2 - actionSize.width - 16)
        footLabel.frame = NSRect(x: inset, y: (footTop + (footerHeight - footSize.height) / 2 + 0.5).rounded(),
                                 width: min(footSize.width, roomForCount), height: footSize.height)
        footButton.frame = NSRect(x: bounds.width - inset - actionSize.width,
                                  y: (footTop + (footerHeight - actionSize.height) / 2).rounded(),
                                  width: actionSize.width, height: actionSize.height)
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
///
/// It is also, now, a control. Roman: *"when you click All, Added by you or
/// Learned, none of those buttons actually work, or even just hovering over
/// them, nothing happens."* He was exactly right — this view had no tracking
/// area, no `mouseDown`, and no callback. It was a picture of a segmented
/// control, drawn well enough that the only way to find out was to click it.
///
/// A control that cannot be operated is worse than no control: it costs the user
/// a click and then makes them wonder what else on the screen is decoration.
final class DictionarySegmented: NSView {

    var onChange: ((Int) -> Void)?

    private let style: DashboardStyle
    private var labels: [NSTextField] = []
    private var titles: [String] = []
    private var selected: Int
    private var widths: [CGFloat] = []
    private var hovered: Int?
    private var pressed: Int?

    /// The pill travels between segments rather than appearing on the new one.
    /// Same argument as the sidebar's: selection that can only blink on and off
    /// reads as a redraw, and selection that moves reads as a control.
    private lazy var slide = DashboardTween(view: self)
    private var pillFrom: NSRect = .zero
    private var pillTo: NSRect = .zero

    override var isFlipped: Bool { true }

    init(titles: [String], selected: Int, style: DashboardStyle) {
        self.style = style
        self.selected = selected
        self.titles = titles
        super.init(frame: .zero)
        for (index, title) in titles.enumerated() {
            let field = DashboardType.label(title, font: DashboardType.caption,
                                            color: index == selected ? style.ink : style.inkTertiary,
                                            tracking: 0, alignment: .center)
            addSubview(field)
            labels.append(field)
            widths.append(ceil(field.fittingSize.width) + 24)
        }
        slide.set(1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var intrinsicWidth: CGFloat { widths.reduce(6) { $0 + $1 } }

    var selectedIndex: Int { selected }

    func select(_ index: Int, notify: Bool = true) {
        guard index != selected, labels.indices.contains(index) else { return }
        pillFrom = pillRect(selected)
        selected = index
        pillTo = pillRect(index)
        for (i, field) in labels.enumerated() {
            DashboardType.recolor(field, i == index ? style.ink : style.inkTertiary)
        }
        slide.set(0)
        slide.animate(to: 1, duration: DashboardMotion.standard)
        needsDisplay = true
        if notify { onChange?(index) }
    }

    private func pillRect(_ index: Int) -> NSRect {
        let x = widths.prefix(index).reduce(3) { $0 + $1 }
        return NSRect(x: x, y: 3, width: widths[index], height: max(0, bounds.height - 6))
    }

    private func segment(_ index: Int) -> NSRect { pillRect(index) }

    private func index(at point: NSPoint) -> Int? {
        labels.indices.first { segment($0).insetBy(dx: 0, dy: -3).contains(point) }
    }

    override func layout() {
        super.layout()
        for (index, field) in labels.enumerated() {
            let rect = segment(index)
            let size = field.fittingSize
            field.frame = NSRect(x: rect.minX, y: (rect.midY - size.height / 2).rounded(),
                                 width: rect.width, height: size.height)
        }
        // Bounds-dependent, so they cannot be cached from before the first layout.
        if pillTo == .zero { pillTo = pillRect(selected) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    private func update(hover point: NSPoint?) {
        let next = point.flatMap(index(at:))
        guard next != hovered else { return }
        hovered = next
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
        update(hover: convert(event.locationInWindow, from: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        update(hover: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        update(hover: nil)
        pressed = nil
    }
    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let hit = index(at: convert(event.locationInWindow, from: nil))
        pressed = nil
        needsDisplay = true
        if let hit, hit == index(at: convert(event.locationInWindow, from: nil)) { select(hit) }
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.fill(bounds, radius: DashboardRadius.row, color: style.isDark ? style.cardAlt : style.card)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.row, color: style.hairline)

        // An unselected segment lights under the pointer. This is the whole cue
        // that the strip is clickable at all, and it was the missing half of the
        // bug: with no hover, a control that does nothing and a control that is
        // merely slow look identical.
        if let hovered, hovered != selected {
            DashboardDraw.fill(segment(hovered).insetBy(dx: 1, dy: 0), radius: DashboardRadius.chip,
                               color: style.hover.faded(pressed == hovered ? 1 : 0.7))
        }
        let pill = pillFrom == .zero ? pillTo : pillFrom.lerp(to: pillTo, slide.value)
        DashboardDraw.raisedSurface(pill, radius: DashboardRadius.chip,
                                    fillColor: style.raised, topColor: style.raisedTop,
                                    style: style, shadow: style.shadowContact, flipped: true)
        if pressed == selected {
            DashboardDraw.fill(pill, radius: DashboardRadius.chip,
                               color: NSColor(white: style.isDark ? 1 : 0, alpha: 0.07))
        }
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
        // Sunken, like the list beside it and every card in Insights.
        //
        // It drew with `raisedSurface`, which in dark mode is 11% white — #5C5C5C
        // against a #252525 list — so the inspector was the single lightest panel
        // in the app and read as a different material from the card it sits next
        // to. `raisedSurface` is right for the things it was built for (the
        // sidebar pill, buttons, the slider thumb); it is not right for a panel.
        DashboardDraw.sunkenSurface(bounds, radius: DashboardRadius.card,
                                    style: style, flipped: true)
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

// MARK: - Small text controls

/// A quiet, drawn text control: a label, an optional trailing glyph, a hover
/// wash and a press scrim. `DashboardButton` pads for a pill it does not want
/// here, and an `NSTextField` cannot be clicked at all — which is what "Most
/// repaired" and "Review 6 unused ›" were before this: two pieces of text
/// styled as affordances, wired to nothing.
class DictionaryTextControl: NSView {

    var onClick: (() -> Void)?

    fileprivate var label: NSTextField
    fileprivate let glyph: DashboardIconView?
    fileprivate var style: DashboardStyle
    /// When false the control is its glyph and nothing else. Used where the strip
    /// is too tight for a word but hiding the control outright would take the
    /// only way to change the order off the screen.
    var showsLabel = true {
        didSet {
            guard showsLabel != oldValue else { return }
            label.isHidden = !showsLabel
            toolTip = showsLabel ? nil : label.attributedStringValue.string
            needsLayout = true
        }
    }

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hover.animate(to: isHovered ? 1 : 0)
        }
    }
    private var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            press.animate(to: isPressed ? 1 : 0,
                          duration: isPressed ? DashboardMotion.press : DashboardMotion.quick)
        }
    }
    private lazy var hover = DashboardTween(view: self)
    private lazy var press = DashboardTween(view: self)

    override var isFlipped: Bool { true }

    init(title: String, symbol: String?, style: DashboardStyle) {
        self.style = style
        label = DashboardType.label(title, font: DashboardType.caption, color: style.inkSecondary)
        glyph = symbol.map {
            DashboardIconView(image: DashboardIcon.image($0, pointSize: 9, weight: .semibold,
                                                         color: style.inkQuaternary))
        }
        super.init(frame: .zero)
        addSubview(label)
        glyph.map(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String, style: DashboardStyle) {
        label.removeFromSuperview()
        label = DashboardType.label(title, font: DashboardType.caption, color: style.inkSecondary)
        label.isHidden = !showsLabel
        addSubview(label)
        if !showsLabel { toolTip = title }
        needsLayout = true
        needsDisplay = true
    }

    var intrinsicWidth: CGFloat {
        guard showsLabel else { return glyph == nil ? 26 : 30 }
        return ceil(label.fittingSize.width) + (glyph == nil ? 0 : 14) + DashboardSpace.sm * 2
    }

    override func layout() {
        super.layout()
        guard showsLabel else {
            // Centred in its own box rather than anchored to a zero-width label,
            // which is where a hidden title would otherwise leave it.
            glyph?.frame = NSRect(x: ((bounds.width - 12) / 2).rounded(),
                                  y: (bounds.height - 12) / 2, width: 12, height: 12)
            return
        }
        let size = label.fittingSize
        label.frame = NSRect(x: DashboardSpace.sm, y: ((bounds.height - size.height) / 2).rounded(),
                             width: min(size.width, bounds.width), height: size.height)
        glyph?.frame = NSRect(x: label.frame.maxX + 3, y: (bounds.height - 12) / 2, width: 12, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        let lit = max(hover.value, press.value * 0.6)
        guard lit > 0.001 else { return }
        DashboardDraw.fill(bounds, radius: DashboardRadius.chip, color: style.hover.faded(lit))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        NSCursor.arrow.set()
    }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// "Most repaired" / "A – Z". Two orders is the whole control; a menu for two
/// choices is a menu nobody opens twice.
final class DictionarySortControl: DictionaryTextControl {
    init(style: DashboardStyle) {
        super.init(title: "Most repaired", symbol: "chevron.up.chevron.down", style: style)
    }
}

/// "Review N unused ›" / "Show all". The two labels this already carried imply
/// a toggle; now it is one.
final class DictionaryFootButton: DictionaryTextControl {
    init(style: DashboardStyle) {
        super.init(title: "", symbol: nil, style: style)
    }
}

/// Top-down inside a scroll view. `NSScrollView`'s document view is bottom-up by
/// default, which would put the most-repaired term at the bottom.
final class DictionaryFlippedView: NSView {
    override var isFlipped: Bool { true }
}
