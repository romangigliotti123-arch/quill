import AppKit

// MARK: - Section

/// Dictation history: everything Quill has typed for you, and what it heard
/// first.
///
/// Shape: a searchable list on the left, one open record on the right. Wispr
/// Flow uses the same screen for a single full-width column of finished
/// paragraphs, which scans well and answers nothing — you cannot copy a line
/// without selecting it by hand, cannot re-insert it at all, and cannot see
/// that "Netlify" was heard as "net lify". Splitting the screen costs list
/// width that a list of one-line utterances does not need, and buys a place to
/// put the record's actions, its timings and the raw-vs-inserted diff.
///
/// The list is deliberately two lines per row rather than Flow's wrapped
/// paragraph: a history you scan for *when* and *how long* wants a fixed row
/// height, and the full text is one click away in the pane that has room for it.
public final class DictationSectionView: NSView {

    private static let listWidth: CGFloat = 452
    private static let rowHeight: CGFloat = 56
    private static let groupHeight: CGFloat = 30

    private let style: DashboardStyle
    private let records: [DictationRecord]

    private var filtered: [DictationRecord] = []
    private var selectedID: UUID?
    private var query: String = ""

    // Header
    private let eyebrow: NSTextField
    private let heading: NSTextField
    private let blurb: NSTextField
    private let action: DashboardButton
    private let secondary: DashboardButton

    // List
    private let listWell: DashboardCardView
    private let search: DictationSearchField
    private let searchRule: DashboardRule
    private let footerRule: DashboardRule
    private let scroll: NSScrollView
    private let listBody: DictationFlippedView
    private let scrollFade: DictationFadeView
    private var footerLabel: NSTextField?
    private var listItems: [ListItem] = []
    private var listMessage: DictationMessageView?

    // Detail
    private var detail: DictationDetailView?
    private var detailPlaceholder: DictationMessageView?

    // First run
    private var emptyState: DictationMessageView?

    private enum ListItem {
        case group(NSTextField)
        case row(DictationRowView)
    }

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle, records: [DictationRecord], query: String = "") {
        self.style = style
        self.records = records
        self.query = query

        eyebrow = DashboardType.label("", font: DashboardType.eyebrow,
                                      color: style.inkTertiary)
        heading = DashboardType.label("Dictation", font: DashboardType.display, color: style.ink)
        blurb = DashboardType.label(records.isEmpty
                                    ? "Every dictation is kept on this Mac, with the raw transcript beside what was actually typed."
                                    : "",
                                    font: DashboardType.body, color: style.inkSecondary,
                                    lines: 2, lineHeight: 20)
        action = DashboardButton(title: DashboardSection.dictation.primaryAction.title,
                                 symbol: DashboardSection.dictation.primaryAction.symbol,
                                 kind: .primary, style: style)
        let second = DashboardSection.dictation.secondaryAction
        secondary = DashboardButton(title: second?.title ?? "Import", symbol: second?.symbol ?? "arrow.down.circle",
                                    kind: .secondary, style: style)

        listWell = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        search = DictationSearchField(style: style,
                                      placeholder: "Search \(records.count) dictation\(records.count == 1 ? "" : "s")")
        searchRule = DashboardRule(color: style.hairline)
        footerRule = DashboardRule(color: style.hairline)
        listBody = DictationFlippedView()
        scroll = NSScrollView()
        scrollFade = DictationFadeView(color: style.card)

        super.init(frame: .zero)

        addSubview(eyebrow)
        addSubview(heading)
        addSubview(blurb)
        addSubview(secondary)
        addSubview(action)

        // A real scroller, because a dictation history is a thousand rows long
        // by month three and a list that silently stops at eight is a list that
        // loses your work. Backgroundless and borderless: the well is already
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

        addSubview(listWell)
        listWell.addSubview(search)
        listWell.addSubview(searchRule)
        listWell.addSubview(scroll)
        listWell.addSubview(scrollFade)
        listWell.addSubview(footerRule)

        search.onChange = { [weak self] text in self?.apply(query: text) }
        search.text = query
        selectedID = records.first?.id
        reload()
    }

    /// The shipping path: real history, or the fixture set when there is none.
    /// A section that screenshots as an empty rectangle is a section nobody can
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - State

    /// How many records survived the current query. Exposed so the filter can be
    /// tested without reading pixels.
    public var visibleRecordCount: Int { filtered.count }

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
        rebuildDetail()
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
        footerLabel?.removeFromSuperview()
        footerLabel = nil
        listMessage?.removeFromSuperview()
        listMessage = nil
        emptyState?.removeFromSuperview()
        emptyState = nil

        guard !records.isEmpty else {
            listWell.isHidden = true
            scroll.isHidden = true
            detail?.removeFromSuperview()
            detail = nil
            detailPlaceholder?.removeFromSuperview()
            detailPlaceholder = nil
            // First run is the one screen guaranteed to be seen, and it is a
            // teaching moment rather than an apology: the three steps are the
            // whole product, and a card sized to them beats a full-bleed well
            // with a paragraph floating in the middle of it.
            let view = DictationMessageView(symbol: "waveform",
                                            title: "Nothing dictated yet",
                                            body: "Quill listens while you hold the key and types when you let go. Nothing is uploaded, and everything you say lands here.",
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

        listWell.isHidden = false
        search.isHidden = false
        searchRule.isHidden = false

        filtered = records.filter(matches).sorted { $0.date > $1.date }

        if filtered.isEmpty {
            footerRule.isHidden = true
            scroll.isHidden = true
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            let view = DictationMessageView(symbol: "magnifyingglass",
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
            listWell.addSubview(view)
            listMessage = view
        } else {
            footerRule.isHidden = false
            scroll.isHidden = false
            var lastGroup: String?
            for record in filtered {
                let group = DictationFormat.dayTitle(record.date)
                if group != lastGroup {
                    let label = DashboardType.label(group, font: DashboardType.micro,
                                                    color: style.inkQuaternary)
                    listBody.addSubview(label)
                    listItems.append(.group(label))
                    lastGroup = group
                }
                let row = DictationRowView(record: record, highlight: query, style: style)
                row.isSelected = record.id == selectedID
                row.onClick = { [weak self] in self?.select(record) }
                listBody.addSubview(row)
                listItems.append(.row(row))
            }
        }

        if selectedID == nil || !filtered.contains(where: { $0.id == selectedID }) {
            selectedID = filtered.first?.id
            for case .row(let row) in listItems { row.isSelected = row.recordID == selectedID }
        }
        rebuildDetail()
    }

    private func rebuildDetail() {
        detail?.removeFromSuperview()
        detail = nil
        detailPlaceholder?.removeFromSuperview()
        detailPlaceholder = nil

        guard let selectedID, let record = records.first(where: { $0.id == selectedID }) else {
            guard !records.isEmpty else { return }
            let view = DictationMessageView(symbol: "doc.text",
                                            title: "Nothing selected",
                                            body: "Pick a dictation on the left to see what the recogniser heard against what Quill typed.",
                                            steps: [], action: nil, actionSymbol: nil,
                                            style: style, elevation: .raised)
            addSubview(view)
            detailPlaceholder = view
            return
        }
        let view = DictationDetailView(record: record, style: style)
        addSubview(view)
        detail = view
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
        heading.frame = NSRect(x: padX, y: y, width: min(headingSize.width, width - 300), height: headingSize.height)
        y += headingSize.height + 6

        let blurbWidth = min(width - 300, 560)
        let blurbHeight = blurb.stringValue.isEmpty ? 0 : DashboardType.size(blurb, width: blurbWidth).height
        blurb.frame = NSRect(x: padX, y: y, width: blurbWidth, height: blurbHeight)
        y += blurbHeight

        // On first run the header's primary is hidden: the empty-state card owns
        // the call to action, and the same button twice on a screen with nothing
        // on it makes the screen look like it is begging.
        let buttonY = padY + eyebrowSize.height + 6
        action.isHidden = records.isEmpty
        let actionWidth = action.intrinsicWidth
        action.frame = NSRect(x: bounds.width - padX - actionWidth, y: buttonY, width: actionWidth, height: 36)
        let secondaryWidth = secondary.intrinsicWidth
        secondary.frame = NSRect(x: (records.isEmpty ? bounds.width - padX : action.frame.minX - 10) - secondaryWidth,
                                 y: buttonY, width: secondaryWidth, height: 36)

        y += DashboardSpace.lg + 2
        let columnsTop = y
        let columnsHeight = max(200, bounds.height - columnsTop - padY)

        if let emptyState {
            let cardWidth: CGFloat = 560
            let cardHeight = emptyState.fittingHeight(width: cardWidth)
            // Optical centre, not geometric: a block centred by arithmetic in a
            // tall column always reads as having sunk.
            emptyState.frame = NSRect(x: padX + ((width - cardWidth) / 2).rounded(),
                                      y: columnsTop + ((columnsHeight - cardHeight) * 0.42).rounded(),
                                      width: cardWidth, height: cardHeight)
            return
        }

        let listWidth = DictationSectionView.listWidth
        listWell.frame = NSRect(x: padX, y: columnsTop, width: listWidth, height: columnsHeight)
        layoutList()

        let detailX = padX + listWidth + DashboardSpace.lg
        let detailWidth = bounds.width - padX - detailX
        let detailFrame = NSRect(x: detailX, y: columnsTop, width: detailWidth, height: columnsHeight)
        detail?.frame = detailFrame
        detailPlaceholder?.frame = detailFrame
    }

    private func layoutList() {
        let pad = DashboardSpace.sm
        let width = listWell.bounds.width
        let height = listWell.bounds.height

        search.frame = NSRect(x: pad, y: pad, width: width - pad * 2, height: 34)
        let searchBottom = search.frame.maxY + pad
        searchRule.frame = NSRect(x: 0, y: searchBottom, width: width, height: 1)

        if let listMessage {
            scrollFade.isHidden = true
            // Held near the search field rather than centred in six hundred
            // points of empty well: the answer to a query belongs next to the
            // query, not a screen below it.
            listMessage.frame = NSRect(x: 0, y: searchBottom, width: width,
                                       height: min(height - searchBottom, 400))
            return
        }

        // The footer is where the totals live — Flow parks the same numbers in a
        // separate stats card on the far side of the window, which puts "how
        // much have I said" a screen away from the thing that said it.
        let footerHeight: CGFloat = 36
        let footerTop = height - footerHeight
        footerRule.frame = NSRect(x: 0, y: footerTop, width: width, height: 1)
        scroll.frame = NSRect(x: 0, y: searchBottom + 1, width: width, height: footerTop - searchBottom - 1)

        var y = DashboardSpace.xs
        var afterGroup = true
        for item in listItems {
            switch item {
            case .group(let label):
                let size = label.fittingSize
                label.frame = NSRect(x: DashboardSpace.md + 2, y: y + 11, width: size.width, height: size.height)
                y += DictationSectionView.groupHeight
                // The heading is the divider; a hairline under it as well is one
                // line too many.
                afterGroup = true
            case .row(let row):
                row.showsSeparator = !afterGroup
                afterGroup = false
                row.frame = NSRect(x: 0, y: y, width: width, height: DictationSectionView.rowHeight)
                y += DictationSectionView.rowHeight
            }
        }
        listBody.frame = NSRect(x: 0, y: 0, width: width, height: y + DashboardSpace.xs)

        // The list is clipped by the footer rule, and a hard clip through the
        // middle of a row's second line looks like a rendering fault rather than
        // a scroll position. Twenty-four points of fade turns the same cut into
        // the standard "there is more below".
        let overflows = listBody.frame.height > scroll.frame.height
        scrollFade.isHidden = !overflows
        scrollFade.frame = NSRect(x: 0, y: footerTop - 24, width: width, height: 24)

        footerLabel?.removeFromSuperview()
        let totalWords = filtered.reduce(0) { $0 + $1.wordCount }
        let text = "\(filtered.count) dictation\(filtered.count == 1 ? "" : "s")  \u{00B7}  \(DictationFormat.count(totalWords)) words"
        let label = DashboardType.label(text, font: DashboardType.caption, color: style.inkTertiary)
        listWell.addSubview(label)
        footerLabel = label
        let size = label.fittingSize
        label.frame = NSRect(x: DashboardSpace.md + 2,
                             y: footerTop + ((footerHeight - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
    }
}

// MARK: - Row

/// One dictation in the list: time gutter, the line as typed, and the numbers
/// that decide whether it is the one you were looking for.
final class DictationRowView: NSView {

    let recordID: UUID
    var onClick: (() -> Void)?
    var showsSeparator = true { didSet { needsDisplay = true } }
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            rebuild()
        }
    }

    private let style: DashboardStyle
    private let record: DictationRecord
    private let highlight: String
    private let editCount: Int
    private var time: NSTextField
    private var snippet: NSTextField
    private var meta: NSTextField
    private var isHovered = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(record: DictationRecord, highlight: String, style: DashboardStyle) {
        self.record = record
        self.style = style
        self.highlight = highlight.trimmingCharacters(in: .whitespaces)
        self.recordID = record.id
        let diff = TranscriptDiff.between(raw: record.rawText, inserted: record.insertedText)
        self.editCount = diff.editCount
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
                                   color: isSelected ? style.inkSecondary : style.inkTertiary)
        snippet = DashboardType.label(record.insertedText,
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
        var parts = ["\(record.wordCount) words"]
        parts.append("\(DictationFormat.seconds(record.timings.endToEndMs)) s")
        parts.append(editCount == 0 ? "clean" : "\(editCount) edit\(editCount == 1 ? "" : "s")")
        meta = DashboardType.label(parts.joined(separator: "  \u{00B7}  "),
                                   font: DashboardType.caption, color: style.inkQuaternary)

        addSubview(time)
        addSubview(snippet)
        addSubview(meta)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let leading = DashboardSpace.md + 2
        let gutter: CGFloat = 66
        let textX = leading + gutter
        let textWidth = bounds.width - textX - DashboardSpace.md

        let snippetSize = snippet.fittingSize
        snippet.frame = NSRect(x: textX, y: 11, width: textWidth, height: snippetSize.height)

        let timeSize = time.fittingSize
        time.frame = NSRect(x: leading,
                            y: 11 + ((snippetSize.height - timeSize.height) / 2).rounded(),
                            width: gutter - 8, height: timeSize.height)

        let metaSize = meta.fittingSize
        meta.frame = NSRect(x: textX, y: 11 + snippetSize.height + 3,
                            width: min(metaSize.width, textWidth), height: metaSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            DashboardDraw.raisedSurface(bounds.insetBy(dx: 6, dy: 2), radius: DashboardRadius.row,
                                        fillColor: style.raised, topColor: style.raisedTop,
                                        style: style, shadow: style.shadowRaised, flipped: true)
            // A two-point stub of accent on the leading edge. The pill already
            // says "selected"; this says which of eight identical pills, at a
            // glance, from across the room.
            NSGraphicsContext.saveGraphicsState()
            DashboardDraw.path(bounds.insetBy(dx: 6, dy: 2), DashboardRadius.row).addClip()
            style.accent.setFill()
            NSRect(x: 6, y: 2, width: 2.5, height: bounds.height - 4).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else if isHovered {
            DashboardDraw.fill(bounds.insetBy(dx: 6, dy: 2), radius: DashboardRadius.row, color: style.hover)
        } else if showsSeparator {
            style.hairline.setFill()
            NSRect(x: DashboardSpace.md + 2, y: 0, width: bounds.width - (DashboardSpace.md + 2) * 2, height: 1).fill()
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

    override func draw(_ dirtyRect: NSRect) {
        // Filled with the *panel* colour rather than a card colour: inside a
        // sunken well, an input has to read as one step further in, and in dark
        // mode that means darker, not lighter.
        DashboardDraw.fill(bounds, radius: DashboardRadius.control, color: style.panel)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.control, color: style.hairline)
    }
}

/// The clear affordance. `DashboardButton` pads for a label it does not have
/// here, so this is 20 points of icon and a hit area, and nothing else.
final class DictationClearButton: NSView {

    var onClick: (() -> Void)?

    private let icon: DashboardIconView
    private var isHovered = false { didSet { needsDisplay = true } }
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
        guard isHovered else { return }
        DashboardDraw.fill(bounds, radius: bounds.width / 2, color: style.hover)
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

// MARK: - Message states

/// Empty states, all three of them, from one view: first run, no search match,
/// and nothing selected. They differ by copy, by whether they offer an action,
/// and by whether they teach — which is not enough difference to justify three
/// layouts.
///
/// It measures itself. First run gets a card sized to its content and centred,
/// not a full-bleed well with a paragraph floating in the middle of it: a screen
/// whose only content is an apology should not also be the biggest empty
/// rectangle in the app.
final class DictationMessageView: NSView {

    enum Elevation { case none, sunken, raised }

    var onAction: (() -> Void)?

    private let style: DashboardStyle
    private let elevation: Elevation
    private let disc: DashboardIconView
    private let title: NSTextField
    private let body: NSTextField
    private var stepNumbers: [NSTextField] = []
    private var stepTexts: [NSTextField] = []
    private let button: DashboardButton?

    private static let discSize: CGFloat = 52
    private static let stepHeight: CGFloat = 30

    override var isFlipped: Bool { true }

    init(symbol: String,
         title: String,
         body: String,
         steps: [String],
         action: String?,
         actionSymbol: String?,
         style: DashboardStyle,
         elevation: Elevation) {
        self.style = style
        self.elevation = elevation
        disc = DashboardIconView(image: DashboardIcon.image(symbol, pointSize: 18, weight: .regular,
                                                            color: style.inkTertiary))
        self.title = DashboardType.label(title, font: DashboardType.title, color: style.ink, alignment: .center)
        self.body = DashboardType.label(body, font: DashboardType.body, color: style.inkTertiary,
                                        lines: 3, lineHeight: 21, alignment: .center)
        self.button = action.map {
            DashboardButton(title: $0, symbol: actionSymbol,
                            kind: steps.isEmpty ? .secondary : .primary, style: style)
        }
        super.init(frame: .zero)
        addSubview(disc)
        addSubview(self.title)
        addSubview(self.body)
        for (index, step) in steps.enumerated() {
            stepNumbers.append(DashboardType.label("\(index + 1)", font: DashboardType.micro,
                                                   color: style.inkTertiary, alignment: .center))
            stepTexts.append(DashboardType.label(step, font: DashboardType.callout, color: style.inkSecondary))
        }
        stepNumbers.forEach(addSubview)
        stepTexts.forEach(addSubview)
        self.button.map(addSubview)
        self.button?.onClick = { [weak self] in self?.onAction?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func bodyWidth(for width: CGFloat) -> CGFloat {
        min(width - DashboardSpace.xl * 2, 420)
    }

    /// Content height plus the card's own padding. Used by the section to size
    /// the card before it is laid out, so the same numbers drive both.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let inner = DictationMessageView.discSize + DashboardSpace.lg
            + title.fittingSize.height + DashboardSpace.xs
            + DashboardType.size(body, width: bodyWidth(for: width)).height
            + (stepTexts.isEmpty ? 0 : DashboardSpace.lg + CGFloat(stepTexts.count) * DictationMessageView.stepHeight)
            + (button == nil ? 0 : DashboardSpace.lg + 36)
        return inner + DashboardSpace.xxl * 2
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let bodyW = bodyWidth(for: width)
        let titleSize = title.fittingSize
        let bodyHeight = DashboardType.size(body, width: bodyW).height
        let total = fittingHeight(width: width) - DashboardSpace.xxl * 2

        var y = ((bounds.height - total) / 2).rounded()
        let disc = DictationMessageView.discSize
        discFrame = NSRect(x: ((width - disc) / 2).rounded(), y: y, width: disc, height: disc)
        self.disc.frame = NSRect(x: discFrame.minX + 16, y: y + 16, width: 20, height: 20)
        y += disc + DashboardSpace.lg

        title.frame = NSRect(x: ((width - titleSize.width) / 2).rounded(), y: y,
                             width: titleSize.width, height: titleSize.height)
        y += titleSize.height + DashboardSpace.xs

        body.frame = NSRect(x: ((width - bodyW) / 2).rounded(), y: y, width: bodyW, height: bodyHeight)
        y += bodyHeight

        if !stepTexts.isEmpty {
            y += DashboardSpace.lg
            // Steps are left-aligned as a block, centred as a group: three
            // centred sentences of different lengths read as a poem, not a list.
            let textWidth = stepTexts.map { $0.fittingSize.width }.max() ?? 0
            let blockWidth = 26 + DashboardSpace.sm + textWidth
            let x = ((width - blockWidth) / 2).rounded()
            numberFrames = []
            for (index, text) in stepTexts.enumerated() {
                let number = stepNumbers[index]
                let discRect = NSRect(x: x, y: y + 3, width: 22, height: 22)
                numberFrames.append(discRect)
                let numberSize = number.fittingSize
                number.frame = NSRect(x: discRect.minX, y: discRect.midY - numberSize.height / 2 + 0.5,
                                      width: discRect.width, height: numberSize.height)
                let size = text.fittingSize
                text.frame = NSRect(x: x + 26 + DashboardSpace.sm,
                                    y: discRect.midY - size.height / 2,
                                    width: min(size.width, width - x - 26 - DashboardSpace.sm - DashboardSpace.xl),
                                    height: size.height)
                y += DictationMessageView.stepHeight
            }
        }

        if let button {
            y += DashboardSpace.lg
            let buttonWidth = button.intrinsicWidth
            button.frame = NSRect(x: ((width - buttonWidth) / 2).rounded(), y: y, width: buttonWidth, height: 36)
        }
        needsDisplay = true
    }

    private var discFrame: NSRect = .zero
    private var numberFrames: [NSRect] = []

    override func draw(_ dirtyRect: NSRect) {
        switch elevation {
        case .none: break
        case .sunken: DashboardDraw.sunkenSurface(bounds, radius: DashboardRadius.card, style: style, flipped: true)
        case .raised:
            DashboardDraw.raisedSurface(bounds, radius: DashboardRadius.card,
                                        fillColor: style.raised, topColor: style.raisedTop,
                                        style: style, shadow: style.shadowCard, flipped: true)
        }
        guard discFrame != .zero else { return }
        DashboardDraw.fill(discFrame, radius: discFrame.width / 2,
                           color: elevation == .raised ? style.card : style.panel)
        DashboardDraw.stroke(discFrame, radius: discFrame.width / 2, color: style.hairline)
        for rect in numberFrames {
            DashboardDraw.fill(rect, radius: rect.width / 2, color: style.card)
            DashboardDraw.stroke(rect, radius: rect.width / 2, color: style.hairline)
        }
    }
}

/// A flipped container, so a list laid out top-down inside a scroll view stays
/// top-down. `NSScrollView`'s document view is bottom-up by default, which puts
/// row one at the bottom and the scroll position at the wrong end.
final class DictationFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The soft bottom edge of the scrolling list. Transparent to the mouse, so the
/// rows it covers still scroll and still click.
final class DictationFadeView: NSView {

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
        DashboardDraw.gradient(bounds, radius: 0,
                               top: color.withAlphaComponent(0), bottom: color, flipped: true)
    }
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

/// `QUILL_DICTATION_SHOTS=/dir` renders the section's three states in both
/// themes and exits. Same argument as `DashboardPreviewRenderer.runIfRequested`:
/// the states that are hardest to get right are the ones nobody launches the app
/// to look at.
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
