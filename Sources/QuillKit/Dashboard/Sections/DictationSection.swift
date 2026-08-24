import AppKit

// MARK: - Section

/// Dictation history: everything Quill has typed for you, and what it heard
/// first.
///
/// Shape: **one column**. The open record is a hero band across the top of the
/// page, sized to what is in it; under it, the whole history at full width,
/// dense, grouped by day. Click a row and the hero changes.
///
/// This replaced a split screen — a 452pt list on the left, an open record in a
/// card on the right — and the reason is the reason Roman gave for the whole
/// overhaul. The right-hand card was a fixed half of the window holding a
/// sentence and a two-line change summary, so two thirds of it was empty on
/// every record; the left-hand list was 452 points wide, so every dictation
/// longer than six words truncated. A screen managed to be simultaneously
/// starved and empty, in the same 1350 points.
///
/// The fix is not more tuning of the two columns. It is that a dictation history
/// has ONE axis — time — and a screen with one axis is a column. Music's library
/// is the reference and it is the right one: a hero that is as tall as its
/// content and no taller, then rows down the page at the full width of the
/// window, grouped by a date heading that is also the divider.
///
/// What that buys, concretely: the row text went from ~370 points to ~800, which
/// is the difference between reading a dictation and reading the first six words
/// of one; and the hero cannot leave a void, because nothing under it is pinned —
/// the list takes whatever height is left.
public final class DictationSectionView: NSView {

    /// One line of text with air around it. Music's track rows are in this band
    /// and they are the densest list Apple ships to consumers.
    private static let rowHeight: CGFloat = 44
    private static let groupHeight: CGFloat = 34
    /// The hero never grows past this. A very long dictation truncates in the
    /// hero and stays complete in the record itself — a page whose top third is
    /// a wall of text has stopped being a hero and become a document.
    private static let heroMaxHeight: CGFloat = 320
    private static let heroMinHeight: CGFloat = 116
    private static let searchWidth: CGFloat = 300
    private static let controlRowHeight: CGFloat = 34

    private let style: DashboardStyle
    private var records: [DictationRecord]

    private var filtered: [DictationRecord] = []
    private var selectedID: UUID?
    /// Which record the hero is currently showing, so a reload that changes
    /// nothing does not restart the cross-fade.
    private var renderedHeroID: UUID?
    private var query: String = ""

    private let header: DashboardSectionHeader
    private let action: DashboardButton
    private let secondary: DashboardButton

    // The open record.
    private var hero: DictationRecordView?

    // The list.
    private let search: DictationSearchField
    private let totals: NSTextField
    private let listRule: DashboardRule
    private let scroll: NSScrollView
    private let listBody: DictationFlippedView
    private var listItems: [ListItem] = []
    private var listMessage: DashboardMessageView?

    // First run.
    private var emptyState: DashboardMessageView?

    private enum ListItem {
        case group(DictationGroupHeader)
        case row(DictationRowView)
    }

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle, records: [DictationRecord], query: String = "") {
        self.style = style
        self.records = records
        self.query = query

        action = DashboardButton(title: DashboardSection.dictation.primaryAction.title,
                                 symbol: DashboardSection.dictation.primaryAction.symbol,
                                 kind: .primary, style: style)
        let second = DashboardSection.dictation.secondaryAction
        secondary = DashboardButton(title: second?.title ?? "Import", symbol: second?.symbol ?? "arrow.down.circle",
                                    kind: .secondary, style: style)
        // No meta line under the title. The totals belong on the control row
        // beside the search that filters them — a count under a heading is a
        // subtitle, a count next to a filter is a readout.
        header = DashboardSectionHeader(title: "Dictation",
                                        trailing: records.isEmpty ? [] : [secondary, action],
                                        style: style)
        totals = DashboardType.label("", font: DashboardType.callout,
                                     color: style.inkTertiary, alignment: .right)

        search = DictationSearchField(style: style, placeholder: "Search")
        listRule = DashboardRule(color: style.hairline)
        listBody = DictationFlippedView()
        scroll = NSScrollView()

        super.init(frame: .zero)

        // A correction rewrites a record under this view, and nothing else would
        // tell it. Without this the Correct button saves, the card keeps showing
        // the old text, and the only reasonable conclusion is that it did not
        // work.
        NotificationCenter.default.addObserver(
            forName: .quillHistoryChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.records = HistoryStore().all
                self.renderedHeroID = nil      // force the card to rebuild
                self.reload()
                self.needsLayout = true
            }
        }

        addSubview(header)

        // A real scroller, because a dictation history is a thousand rows long
        // by month three and a list that silently stops at eight is a list that
        // loses your work. Backgroundless and borderless: the page is already
        // drawn, and NSScrollView's own chrome is the default look this window
        // exists to avoid.
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .allowed
        scroll.contentView.drawsBackground = false
        scroll.documentView = listBody

        addSubview(search)
        addSubview(totals)
        addSubview(listRule)
        addSubview(scroll)

        search.onChange = { [weak self] text in self?.apply(query: text) }
        search.text = query
        selectedID = records.first?.id
        reload()
    }

    /// An empty history shows the empty state, NOT invented dictations.
    ///
    /// The old comment here argued that "a first launch that shows an empty
    /// rectangle is a first launch nobody trusts" — and then substituted eight
    /// fabricated dictations, unlabelled, styled exactly like real ones. Someone
    /// opening Quill for the first time would have read a week of their own
    /// history that never happened. An empty state is the honest answer; the
    /// fixtures stay, for the render harness only.
    public convenience init(style: DashboardStyle, store: HistoryStore = HistoryStore()) {
        self.init(style: style, records: store.all)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - State

    /// How many records survived the current query. Exposed so the filter can be
    /// tested without reading pixels.
    public var visibleRecordCount: Int { filtered.count }

    private static func totalsText(_ records: [DictationRecord]) -> String {
        guard !records.isEmpty else { return "" }
        let words = records.reduce(0) { $0 + $1.wordCount }
        return "\(DictationFormat.count(records.count)) dictation\(records.count == 1 ? "" : "s")"
            + "  \u{00B7}  \(DictationFormat.count(words)) words"
    }

    private func apply(query newValue: String) {
        query = newValue
        reload()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func select(_ record: DictationRecord) {
        guard selectedID != record.id else { return }
        selectedID = record.id
        for case .row(let row) in listItems { row.isSelected = row.recordID == record.id }
        rebuildHero()
        needsLayout = true
    }

    private func matches(_ record: DictationRecord) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return record.insertedText.localizedCaseInsensitiveContains(trimmed)
            || record.rawText.localizedCaseInsensitiveContains(trimmed)
    }

    private func reload() {
        for item in listItems {
            switch item {
            case .group(let view): view.removeFromSuperview()
            case .row(let view): view.removeFromSuperview()
            }
        }
        listItems = []
        listMessage?.removeFromSuperview()
        listMessage = nil
        emptyState?.removeFromSuperview()
        emptyState = nil

        guard !records.isEmpty else {
            search.isHidden = true
            totals.isHidden = true
            listRule.isHidden = true
            scroll.isHidden = true
            hero?.removeFromSuperview()
            hero = nil
            // First run is the one screen guaranteed to be seen, and it is a
            // teaching moment rather than an apology: the three steps are the
            // whole product, and a card sized to them beats a full-bleed well
            // with a paragraph floating in the middle of it.
            let view = DashboardMessageView(symbol: "waveform",
                                            title: "Nothing dictated yet",
                                            body: "Nothing is uploaded, and everything you say lands here.",
                                            steps: ["Hold \u{2325} anywhere \u{2014} any app, any text field.",
                                                    "Say it. The overlay shows what Quill is hearing.",
                                                    "Let go. It types where your cursor already is."],
                                            action: DashboardSection.dictation.primaryAction.title,
                                            actionSymbol: DashboardSection.dictation.primaryAction.symbol,
                                            style: style,
                                            elevation: .raised)
            addSubview(view)
            emptyState = view
            return
        }

        search.isHidden = false
        totals.isHidden = false
        listRule.isHidden = false

        filtered = records.filter(matches).sorted { $0.date > $1.date }
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        DashboardType.recolor(totals, style.inkTertiary)
        totals.attributedStringValue = NSAttributedString(
            string: searching
                ? "\(DictationFormat.count(filtered.count)) of \(DictationFormat.count(records.count))"
                : DictationSectionView.totalsText(records),
            attributes: [.font: DashboardType.callout, .foregroundColor: style.inkTertiary])

        if filtered.isEmpty {
            scroll.isHidden = true
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            let view = DashboardMessageView(symbol: "magnifyingglass",
                                            title: "No match for \u{201C}\(trimmed)\u{201D}",
                                            body: "Search reads the inserted text and the raw transcript. Neither contains that.",
                                            steps: [],
                                            action: "Clear search",
                                            actionSymbol: "xmark",
                                            style: style,
                                            elevation: .none)
            view.onAction = { [weak self] in
                self?.search.text = ""
                self?.apply(query: "")
            }
            addSubview(view)
            listMessage = view
        } else {
            scroll.isHidden = false
            var lastGroup: String?
            for record in filtered {
                let group = DictationFormat.dayTitle(record.date)
                if group != lastGroup {
                    let view = DictationGroupHeader(title: group, style: style)
                    listBody.addSubview(view)
                    listItems.append(.group(view))
                    lastGroup = group
                }
                let row = DictationRowView(record: record, highlight: query, style: style)
                row.isSelected = record.id == selectedID
                row.onClick = { [weak self] in self?.select(record) }
                listBody.addSubview(row)
                listItems.append(.row(row))
            }
        }

        // Selection follows the RECORDS, not the filter.
        //
        // This used to re-point `selectedID` at `filtered.first` whenever the open
        // record stopped matching — and `filtered.first` is nil on a query with no
        // results, so the hero was torn out and the whole page jumped up about 350
        // points under the pointer, mid-keystroke, while you were still typing in
        // the field. Clearing the query did not put it back either: it re-selected
        // the newest dictation instead of the one you had open.
        //
        // A record that merely falls out of a filter has not gone anywhere. Mail
        // does the same thing: the open message stays open and the list simply
        // shows no selection, which `row.isSelected == false` already gives us.
        if selectedID == nil || !records.contains(where: { $0.id == selectedID }) {
            selectedID = records.first?.id
        }
        for case .row(let row) in listItems { row.isSelected = row.recordID == selectedID }
        // Only when it actually changed. `reload()` runs on every keystroke, and
        // rebuilding an identical hero re-ran the cross-fade against itself once
        // per character.
        if renderedHeroID != selectedID { rebuildHero() }
    }

    private func rebuildHero(animated: Bool = true) {
        // Cross-fade rather than cut.
        //
        // Switching records used to tear the old view out and drop the new one
        // in with no animation at all, which is the "blink" Roman named: the pane
        // vanishes and the eye has to re-find where it was. The outgoing view is
        // kept alive just long enough to fade under the new one.
        //
        // Position is deliberately NOT animated. The two views occupy the same
        // frame, so sliding one over the other would be motion for its own sake —
        // and the HIG is blunt that a frequent interaction given too much movement
        // reads as lag rather than as feedback.
        let outgoing = hero
        hero = nil
        renderedHeroID = selectedID
        guard let selectedID, let record = records.first(where: { $0.id == selectedID }) else {
            outgoing?.removeFromSuperview()
            return
        }
        let view = DictationRecordView(record: record, style: style)
        addSubview(view)
        hero = view
        // Laid out before the fade starts, or the incoming view animates in at a
        // zero frame and arrives by resizing.
        needsLayout = true
        layoutSubtreeIfNeeded()

        guard animated, !DashboardMotion.isReduced, outgoing != nil else {
            outgoing?.removeFromSuperview()
            return
        }
        view.alphaValue = 0
        DashboardMotion.spring(DashboardMotion.selectSpring) { _ in
            view.animator().alphaValue = 1
            outgoing?.animator().alphaValue = 0
        } completion: {
            outgoing?.removeFromSuperview()
        }
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2
        guard width > 0 else { return }

        header.frame = NSRect(x: padX, y: padY, width: width, height: header.height)
        var y = DashboardSectionHeader.contentTop(for: header)

        if let emptyState {
            let cardWidth: CGFloat = 560
            let cardHeight = emptyState.fittingHeight(width: cardWidth)
            let room = max(200, bounds.height - y - padY)
            // Optical centre, not geometric: a block centred by arithmetic in a
            // tall column always reads as having sunk.
            emptyState.frame = NSRect(x: padX + ((width - cardWidth) / 2).rounded(),
                                      y: y + ((room - cardHeight) * 0.42).rounded(),
                                      width: cardWidth, height: cardHeight)
            return
        }

        // The hero is as tall as what is in it. This is the single decision that
        // removes the void: nothing below it is pinned to the bottom of the
        // window, so a short record makes a short hero and the list simply gets
        // longer. The old card was half the window whatever it held.
        if let hero {
            let natural = hero.fittingHeight(width: width)
            let height = min(DictationSectionView.heroMaxHeight,
                             max(DictationSectionView.heroMinHeight, natural))
            hero.frame = NSRect(x: padX, y: y, width: width, height: height)
            y += height + DashboardSpace.xl
        }

        // The control row: search on the left, nothing on the right. The totals
        // that used to sit in a footer under the list are in the header's meta
        // line now, beside the title they describe.
        search.frame = NSRect(x: padX, y: y,
                              width: min(DictationSectionView.searchWidth, width),
                              height: DictationSectionView.controlRowHeight)
        let totalsSize = totals.fittingSize
        totals.frame = NSRect(x: bounds.width - padX - min(totalsSize.width, width / 2),
                              y: y + ((DictationSectionView.controlRowHeight - totalsSize.height) / 2).rounded(),
                              width: min(totalsSize.width, width / 2), height: totalsSize.height)
        y += DictationSectionView.controlRowHeight + DashboardSpace.sm
        listRule.frame = NSRect(x: padX, y: y, width: width, height: 1)
        y += 1

        let listHeight = max(0, bounds.height - y - padY)

        if let listMessage {
            // Held near the search field rather than centred in six hundred
            // points of empty page: the answer to a query belongs next to the
            // query, not a screen below it.
            listMessage.frame = NSRect(x: padX, y: y, width: width,
                                       height: listHeight)
            return
        }

        // No fade over the bottom of the list, and its absence is deliberate.
        //
        // A gradient to a colour is a lie in a translucent window: the page is a
        // material, and the fade could only be painted in the material's FALLBACK
        // colour — which is the one thing on screen guaranteed not to match what
        // is actually behind it. Offscreen it showed as a pale band across the
        // last row; on a real desktop it would be worse, because the material has
        // the wallpaper in it and the band would not.
        //
        // A clipped row is what every Mac list does, and the overlay scroller says
        // "there is more" without inventing a colour.
        scroll.frame = NSRect(x: padX, y: y, width: width, height: listHeight)
        layoutList(width: width)
    }

    private func layoutList(width: CGFloat) {
        var y: CGFloat = 0
        for (index, item) in listItems.enumerated() {
            switch item {
            case .group(let view):
                // No rule above the first heading: the list's own top rule is
                // already there, and two lines one row apart is a table.
                view.showsTopRule = index > 0
                view.frame = NSRect(x: 0, y: y, width: width, height: DictationSectionView.groupHeight)
                y += DictationSectionView.groupHeight
            case .row(let row):
                row.frame = NSRect(x: 0, y: y, width: width, height: DictationSectionView.rowHeight)
                y += DictationSectionView.rowHeight
            }
        }
        listBody.frame = NSRect(x: 0, y: 0, width: width, height: y + DashboardSpace.lg)
    }
}

// MARK: - Group heading

/// A day, and the line that separates it from the day above.
///
/// The heading IS the divider — Music does exactly this, and it is why its
/// library reads as a set of days rather than as a table with a caption on every
/// tenth row. There are no rules between the rows themselves; Roman asked for
/// that twice, and it holds here for the same reason it held before: the rows
/// have their own internal hierarchy and the rhythm separates them.
final class DictationGroupHeader: NSView {

    var showsTopRule = true { didSet { needsDisplay = true } }

    private let label: NSTextField
    private let style: DashboardStyle

    override var isFlipped: Bool { true }

    init(title: String, style: DashboardStyle) {
        self.style = style
        label = DashboardType.label(title, font: DashboardType.headline, color: style.inkTertiary)
        super.init(frame: .zero)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Inset to the row's own gutter, so "Today" sits over the time column
        // rather than 12 points to its left. Only the label moves — the top rule
        // stays full width, where it lines up with the list rule above it.
        let size = label.fittingSize
        let inset = DashboardSpace.sm
        label.frame = NSRect(x: inset, y: (bounds.height - size.height).rounded() - 6,
                             width: min(size.width, bounds.width - inset), height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsTopRule else { return }
        style.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Row

/// One dictation, at the full width of the window.
///
/// Three columns and one line: when it was said, what was typed, and how much of
/// it. That is a Music track row, and it is the right shape for the same reason —
/// a list you scan by time wants a fixed row height and a stable gutter, and the
/// thing you are actually reading wants every point of width that is left.
///
/// It used to be two lines in a 452pt column, with the second line carrying
/// "13 words · 4.63 s · clean". The seconds are gone: that is release-to-inserted
/// latency, which is the same instrumentation Roman had already thrown off the
/// record card — *"I don't need to know the time it took... those little details
/// are just bloating up the screen."* It is still measured, and Insights is still
/// where a question about speed belongs. And "clean" is gone as a word, because
/// printing it on nine rows out of ten makes it furniture; a row now says
/// something about edits only when there were edits.
final class DictationRowView: NSView {

    let recordID: UUID
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            rebuild()
        }
    }

    private let style: DashboardStyle
    private let record: DictationRecord
    private let highlight: String
    private let isClean: Bool
    private let editCount: Int
    private var time: NSTextField
    private var snippet: NSTextField
    private var meta: NSTextField
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

    init(record: DictationRecord, highlight: String, style: DashboardStyle) {
        self.record = record
        self.style = style
        self.highlight = highlight.trimmingCharacters(in: .whitespaces)
        self.recordID = record.id
        let diff = TranscriptDiff.between(raw: record.rawText, inserted: record.insertedText)
        self.editCount = diff.editCount
        self.isClean = diff.isClean
        time = NSTextField(labelWithString: "")
        snippet = NSTextField(labelWithString: "")
        meta = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        addSubview(time)
        addSubview(snippet)
        addSubview(meta)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        time.removeFromSuperview()
        snippet.removeFromSuperview()
        meta.removeFromSuperview()

        time = DashboardType.label(DictationFormat.time(record.date), font: DashboardType.mono,
                                   color: isSelected ? style.inkSecondary : style.inkQuaternary)
        snippet = DashboardType.label(record.insertedText.isEmpty ? record.rawText : record.insertedText,
                                      font: isSelected ? DashboardType.bodyMedium : DashboardType.body,
                                      color: isSelected ? style.ink : style.inkSecondary)
        // Where the query actually hit. A filtered list that does not say why a
        // row survived makes the user re-read every row to find out.
        if !highlight.isEmpty {
            let string = NSMutableAttributedString(attributedString: snippet.attributedStringValue)
            let haystack = string.string as NSString
            var searchRange = NSRange(location: 0, length: haystack.length)
            while searchRange.length > 0 {
                let found = haystack.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive],
                                           range: searchRange)
                guard found.location != NSNotFound else { break }
                string.addAttribute(.backgroundColor, value: style.accentSoft, range: found)
                let next = found.location + found.length
                searchRange = NSRange(location: next, length: haystack.length - next)
            }
            snippet.attributedStringValue = string
        }
        var parts = ["\(DictationFormat.count(record.wordCount)) \(record.wordCount == 1 ? "word" : "words")"]
        if !isClean && editCount > 0 { parts.append("\(editCount) edit\(editCount == 1 ? "" : "s")") }
        meta = DashboardType.label(parts.joined(separator: "  \u{00B7}  "),
                                   font: DashboardType.caption, color: style.inkQuaternary,
                                   alignment: .right)

        addSubview(time)
        addSubview(snippet)
        addSubview(meta)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let inset = DashboardSpace.sm
        let gutter: CGFloat = 72
        let metaWidth: CGFloat = 150
        let textX = inset + gutter
        let textWidth = max(40, bounds.width - textX - metaWidth - inset - DashboardSpace.md)

        func centre(_ field: NSTextField) -> CGFloat {
            ((bounds.height - field.fittingSize.height) / 2).rounded()
        }

        snippet.frame = NSRect(x: textX, y: centre(snippet), width: textWidth,
                               height: snippet.fittingSize.height)
        time.frame = NSRect(x: inset, y: centre(time), width: gutter - 10, height: time.fittingSize.height)
        meta.frame = NSRect(x: bounds.width - inset - metaWidth, y: centre(meta),
                            width: metaWidth, height: meta.fittingSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0, dy: 1)
        if isSelected {
            DashboardDraw.fill(body, radius: DashboardRadius.row, color: style.rowSelected)
            // A stub of accent on the leading edge. The fill already says
            // "selected"; this says which of eight identical fills, at a glance,
            // from across the room.
            NSGraphicsContext.saveGraphicsState()
            DashboardDraw.path(body, DashboardRadius.row).addClip()
            style.accent.setFill()
            NSRect(x: body.minX, y: body.minY, width: 2.5, height: body.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else if hover.value > 0.001 {
            DashboardDraw.fill(body, radius: DashboardRadius.row,
                               color: style.hover.faded(hover.value))
        }
        // The press, on top of whichever of the two is showing. A scrim rather
        // than an alpha change: fading the row would take its text with it and
        // read as "disabled" for as long as the finger is down.
        if press.value > 0.001 {
            DashboardDraw.fill(body, radius: DashboardRadius.row,
                               color: NSColor(white: style.isDark ? 1 : 0, alpha: 0.07 * press.value))
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
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Search

/// A search field that is actually a field.
///
/// Flow hides theirs behind a magnifier icon in the corner, which costs a click
/// and hides the one control that makes a long history usable. An `NSSearchField`
/// would bring the system bezel and focus ring the rest of this window is drawn
/// from scratch to avoid, so the well is drawn here and only the text editing is
/// AppKit's.
final class DictationSearchField: NSView, NSTextFieldDelegate {

    var onChange: ((String) -> Void)?

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue; clear.isHidden = newValue.isEmpty }
    }

    private let style: DashboardStyle
    private let icon: DashboardIconView
    private let field: NSTextField
    private let clear: DictationClearButton
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hover.animate(to: isHovered ? 1 : 0)
        }
    }
    private lazy var hover = DashboardTween(view: self)

    override var isFlipped: Bool { true }

    init(style: DashboardStyle, placeholder: String) {
        self.style = style
        icon = DashboardIconView(image: DashboardIcon.image("magnifyingglass", pointSize: 12.5,
                                                            weight: .semibold, color: style.inkTertiary))
        field = NSTextField(string: "")
        clear = DictationClearButton(style: style)
        super.init(frame: .zero)

        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = DashboardType.body
        field.textColor = style.ink
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: DashboardType.body, .foregroundColor: style.inkQuaternary])
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        clear.isHidden = true
        clear.onClick = { [weak self] in
            guard let self else { return }
            self.text = ""
            self.onChange?("")
        }

        addSubview(icon)
        addSubview(field)
        addSubview(clear)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ obj: Notification) {
        clear.isHidden = field.stringValue.isEmpty
        onChange?(field.stringValue)
    }

    /// A pre-filled search field becomes first responder with everything
    /// selected, which arms the next keystroke to wipe the query the window just
    /// restored. Collapse to a caret at the end instead.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !field.stringValue.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.field.currentEditor() else { return }
            editor.selectedRange = NSRange(location: (self.field.stringValue as NSString).length, length: 0)
        }
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let size = field.fittingSize
        field.frame = NSRect(x: 32, y: ((bounds.height - size.height) / 2).rounded(),
                             width: bounds.width - 32 - 34, height: size.height)
        clear.frame = NSRect(x: bounds.width - 28, y: (bounds.height - 20) / 2, width: 20, height: 20)
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
        NSCursor.iBeam.set()
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.arrow.set()
    }

    /// The whole well is the target, not just the editable strip inside it.
    ///
    /// The `NSTextField` occupies x=32 to width-34, so clicking the magnifier, the
    /// padding, or anywhere in the 10 points before the text did nothing at all —
    /// a search box that ignores a third of its own surface. Every Mac search field
    /// focuses from anywhere inside its bezel.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
        // Put the caret where they clicked rather than selecting everything: a
        // click into a field with a query already in it is almost always an edit,
        // and select-all arms the next keystroke to wipe it.
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Nothing to commit — `mouseDown` already moved focus. Present so the
        // field counts as a control that answers the mouse, which is the thing
        // the dead-filter bug taught us to assert.
        _ = event
    }

    override func draw(_ dirtyRect: NSRect) {
        // A field on the page rather than inside a well, so it is drawn as a
        // tint of the page rather than as a hole in a card. The border warms
        // under the pointer — the one place in this window where the user is
        // about to type, and the only cue that it is a field at all.
        DashboardDraw.fill(bounds, radius: DashboardRadius.control, color: style.card)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.control,
                             color: style.hairline.mixed(with: style.hairlineStrong, hover.value))
    }
}

/// The clear affordance. `DashboardButton` pads for a label it does not have
/// here, so this is 20 points of icon and a hit area, and nothing else.
final class DictationClearButton: NSView {

    var onClick: (() -> Void)?

    private let icon: DashboardIconView
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hover.animate(to: isHovered ? 1 : 0)
        }
    }
    private lazy var hover = DashboardTween(view: self)
    private let style: DashboardStyle

    override var isFlipped: Bool { true }

    init(style: DashboardStyle) {
        self.style = style
        // The outline, not the filled variant: `xmark.circle.fill` knocks its
        // cross out of the disc using two palette colours, and a single-colour
        // palette configuration fills the knockout back in — a grey blob.
        icon = DashboardIconView(image: DashboardIcon.image("xmark.circle", pointSize: 13,
                                                            weight: .regular, color: style.inkTertiary))
        super.init(frame: .zero)
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hover.value > 0.001 else { return }
        // Grows into place as well as fading in. A circle that only fades reads
        // as a rendering artefact at this size.
        let inset = 3 * (1 - hover.value)
        let circle = bounds.insetBy(dx: inset, dy: inset)
        DashboardDraw.fill(circle, radius: circle.width / 2, color: style.hover.faded(hover.value))
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
        NSCursor.arrow.set()
    }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// A flipped container, so a list laid out top-down inside a scroll view stays
/// top-down. `NSScrollView`'s document view is bottom-up by default, which puts
/// row one at the bottom and the scroll position at the wrong end.
final class DictationFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Provider

/// Plugs the section into the dashboard shell. Deliberately answers for
/// `.dictation` and nothing else, so the shell keeps drawing its own
/// placeholder for the sections that are still being built.
public final class DictationSectionProvider: NSObject, DashboardSectionProvider {

    private let records: [DictationRecord]?
    private let query: String

    public init(records: [DictationRecord]? = nil, query: String = "") {
        self.records = records
        self.query = query
    }

    public func dashboardView(for section: DashboardSection, style: DashboardStyle) -> NSView? {
        guard section == .dictation else { return nil }
        if let records { return DictationSectionView(style: style, records: records, query: query) }
        return DictationSectionView(style: style)
    }
}

/// `QUILL_DICTATION_SHOTS=/dir` renders the section's states in both themes and
/// exits. Same argument as `DashboardPreviewRenderer.runIfRequested`: the states
/// that are hardest to get right are the ones nobody launches the app to look at.
///
/// This is wired into `main.swift`. It was not, for its whole existence — the
/// entry point was written, documented and never called, so `QUILL_DICTATION_SHOTS`
/// silently launched the app instead of rendering anything.
public enum DictationSectionShots {

    @discardableResult
    public static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["QUILL_DICTATION_SHOTS"] else { return false }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let states: [(String, DashboardSectionProvider)] = [
            ("history", DictationSectionProvider(records: DictationFixtures.records())),
            ("search", DictationSectionProvider(records: DictationFixtures.records(), query: "firestore")),
            ("nomatch", DictationSectionProvider(records: DictationFixtures.records(), query: "invoice")),
            ("empty", DictationSectionProvider(records: [])),
        ]
        do {
            for (name, provider) in states {
                for dark in [false, true] {
                    let url = directory.appendingPathComponent("dictation-\(name)-\(dark ? "dark" : "light").png")
                    try DashboardPreviewRenderer.write(section: .dictation, dark: dark,
                                                       provider: provider, to: url)
                    print(url.path)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("dictation render failed: \(error)\n".utf8))
            exit(1)
        }
        return true
    }
}
