import AppKit

// The Snippets screen.
//
// Wispr Flow's version of this page is, on the day it was captured, a promo
// banner and one row. The banner is 60% of the window, it is an advertisement
// for the feature you are already looking at, and it teaches you nothing the
// second time you open the page. Underneath it, a snippet is a line of grey
// text — you cannot see what it expands to without opening a modal, cannot see
// whether it has ever fired, and cannot tell a two-word replacement from a
// three-paragraph one.
//
// So this page is built around the two questions that page cannot answer:
// *what does it actually type*, and *does it actually fire*. The library is on
// the left with a real preview and a real usage count; the editor is on the
// right, always open, never a modal; and underneath the editor is the same
// phrase run through the shipping `SnippetExpander`, showing the substitution
// that will happen. Nothing on this screen is a mock-up of the behaviour — the
// preview line is the engine's own output.
//
// Type is the system font throughout. Flow reaches for a serif display face,
// which looks good and is the one thing here we are not copying: a serif
// headline in a Mac utility window is a magazine cover on an instrument panel.

// MARK: - Section

public final class SnippetsSectionView: NSView {

    private enum Metrics {
        static let listWidth: CGFloat = 404
        static let columnGap: CGFloat = 22
        static let rowHeight: CGFloat = 68
        static let listHeaderHeight: CGFloat = 52
    }

    private let store: SnippetStore
    private let style: DashboardStyle

    /// The working list. Reloaded from the store after every mutation rather
    /// than patched in place — a list view that maintains its own parallel copy
    /// of the truth is where "it saved but the row still says the old thing"
    /// comes from.
    private var snippets: [Snippet] = []
    private var visible: [Snippet] = []
    private var selectedID: UUID?
    private var filter: String = ""

    // Header
    private var header: DashboardSectionHeader!
    private let newButton: DashboardButton

    // Library
    private let listCard: DashboardCardView
    private let filterField: SnippetsField
    private let countLabel: NSTextField
    private let listRule: DashboardRule
    private let scroll = NSScrollView()
    private let listDocument = SnippetsFlippedView()
    private let fade: SnippetsFadeView
    private let emptyFilterLabel: NSTextField
    private var rows: [SnippetRowView] = []

    // Editor
    private let editor: SnippetEditorView

    // Empty state
    private let emptyState: SnippetsEmptyStateView

    public override var isFlipped: Bool { true }

    public init(store: SnippetStore, style: DashboardStyle) {
        self.store = store
        self.style = style

        newButton = DashboardButton(title: "New snippet", symbol: "plus", kind: .primary, style: style)

        listCard = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        filterField = SnippetsField(style: style, placeholder: "Filter phrases",
                                    font: DashboardType.callout, badgeSymbol: nil)
        countLabel = DashboardType.label("", font: DashboardType.micro,
                                         color: style.inkQuaternary,
                                         alignment: .right)
        listRule = DashboardRule(color: style.hairline)
        fade = SnippetsFadeView(color: style.card)
        emptyFilterLabel = DashboardType.label("No phrase matches that.", font: DashboardType.callout,
                                               color: style.inkTertiary, alignment: .center)
        editor = SnippetEditorView(style: style)
        emptyState = SnippetsEmptyStateView(style: style)

        super.init(frame: .zero)

        // The shared header, so this title lands where the other nine do. It was
        // the last section still placing its own, and it also stacked an empty
        // eyebrow and an empty blurb to do it.
        header = DashboardSectionHeader(title: "Snippets", trailing: [newButton], style: style)
        addSubview(header)
        addSubview(listCard)
        addSubview(editor)
        addSubview(emptyState)

        listCard.addSubview(filterField)
        listCard.addSubview(countLabel)
        listCard.addSubview(listRule)
        listCard.addSubview(emptyFilterLabel)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.documentView = listDocument
        listCard.addSubview(scroll)
        listCard.addSubview(fade)

        newButton.onClick = { [weak self] in self?.createSnippet() }
        filterField.onChange = { [weak self] text in
            self?.filter = text
            self?.reloadRows()
        }
        emptyState.onCreate = { [weak self] phrase, replacement in
            self?.createSnippet(phrase: phrase, replacement: replacement)
        }
        emptyState.onWriteOwn = { [weak self] in self?.createSnippet() }
        editor.onCommit = { [weak self] snippet in
            self?.store.upsert(snippet)
            self?.reload(select: snippet.id)
        }
        editor.onDelete = { [weak self] snippet in
            self?.delete(snippet)
        }

        reload(select: store.ordered.first?.id)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - State

    private var isEmpty: Bool { snippets.isEmpty }

    private func reload(select id: UUID? = nil) {
        snippets = store.ordered
        if let id, snippets.contains(where: { $0.id == id }) {
            selectedID = id
        } else if selectedID == nil || !snippets.contains(where: { $0.id == selectedID }) {
            selectedID = snippets.first?.id
        }

        let empty = isEmpty
        emptyState.isHidden = !empty
        listCard.isHidden = empty
        editor.isHidden = empty
        // The button stays. An empty state whose only way forward is a link
        // inside the illustration is an empty state that has hidden its own
        // primary action.
        reloadRows()
        if let selected = snippets.first(where: { $0.id == selectedID }) {
            editor.load(selected)
        }
        needsLayout = true
    }

    private func reloadRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []

        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        visible = needle.isEmpty ? snippets : snippets.filter {
            $0.phrase.lowercased().contains(needle) || $0.replacement.lowercased().contains(needle)
        }

        for snippet in visible {
            let row = SnippetRowView(snippet: snippet, style: style)
            row.isSelected = snippet.id == selectedID
            row.onClick = { [weak self] in self?.select(snippet.id) }
            listDocument.addSubview(row)
            rows.append(row)
        }
        emptyFilterLabel.isHidden = !visible.isEmpty
        countLabel.attributedStringValue = NSAttributedString(
            string: visible.count == 1 ? "1 phrase" : "\(visible.count) phrases",
            attributes: [.font: DashboardType.micro,
                         .foregroundColor: style.inkQuaternary,
                         .kern: DashboardType.tracking(for: DashboardType.micro)])
        needsLayout = true
    }

    private func select(_ id: UUID) {
        guard id != selectedID else { return }
        // Commit whatever is in the editor before moving on. Losing an edit
        // because you clicked the next row is the single most common way a
        // master-detail list betrays someone.
        editor.commitIfDirty()
        selectedID = id
        snippets = store.ordered
        for row in rows { row.isSelected = row.snippet.id == id }
        if let selected = snippets.first(where: { $0.id == id }) { editor.load(selected) }
    }

    private func createSnippet(phrase: String = "", replacement: String = "") {
        editor.commitIfDirty()
        let snippet = Snippet(phrase: phrase, replacement: replacement)
        store.upsert(snippet)
        filter = ""
        filterField.text = ""
        reload(select: snippet.id)
        editor.focusPhrase()
    }

    private func delete(_ snippet: Snippet) {
        let order = snippets
        let index = order.firstIndex { $0.id == snippet.id }
        store.remove(id: snippet.id)
        let remaining = store.ordered
        let next: UUID?
        if let index, !remaining.isEmpty {
            next = remaining[min(index, remaining.count - 1)].id
        } else {
            next = remaining.first?.id
        }
        selectedID = next
        reload(select: next)
    }


    // MARK: - Layout

    public override func layout() {
        super.layout()
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2

        header.frame = NSRect(x: padX, y: padY, width: width, height: header.height)

        // Title, actions, content — the same three things in the same order as
        // every other section. This one alone carried "24,683 characters not
        // typed" as a third header element, and paid for it by pushing the whole
        // page down by its own height. If the aggregate is worth keeping it
        // belongs beside "54m saved against typing it out" in Insights, which is
        // the screen that exists for numbers like it.
        var y = DashboardSectionHeader.contentTop(for: header)

        let columnHeight = max(240, bounds.height - y - padY)
        // The library is capped rather than fixed: at the window's minimum size a
        // 404-point rail would leave the editor too narrow for its own segmented
        // control, and the editor is the half doing the work.
        let listWidth = min(Metrics.listWidth, (width * 0.40).rounded())
        listCard.frame = NSRect(x: padX, y: y, width: listWidth, height: columnHeight)
        editor.frame = NSRect(x: padX + listWidth + Metrics.columnGap, y: y,
                              width: width - listWidth - Metrics.columnGap, height: columnHeight)
        emptyState.frame = NSRect(x: padX, y: y, width: width, height: columnHeight)

        layoutList()
    }

    private func layoutList() {
        let cardWidth = listCard.bounds.width
        let cardHeight = listCard.bounds.height
        guard cardWidth > 0 else { return }

        let countSize = countLabel.fittingSize
        filterField.frame = NSRect(x: 10, y: 10,
                                   width: cardWidth - 20 - countSize.width - 14, height: 32)
        countLabel.frame = NSRect(x: cardWidth - 14 - countSize.width,
                                  y: 10 + ((32 - countSize.height) / 2).rounded(),
                                  width: countSize.width, height: countSize.height)
        listRule.frame = NSRect(x: 1, y: Metrics.listHeaderHeight, width: cardWidth - 2, height: 1)

        let listTop = Metrics.listHeaderHeight + 1
        scroll.frame = NSRect(x: 1, y: listTop, width: cardWidth - 2, height: cardHeight - listTop - 1)
        let documentHeight = max(scroll.frame.height, CGFloat(rows.count) * Metrics.rowHeight + 6)
        listDocument.frame = NSRect(x: 0, y: 0, width: scroll.frame.width, height: documentHeight)
        for (index, row) in rows.enumerated() {
            row.isLastVisible = index == rows.count - 1
            row.followedBySelection = index + 1 < rows.count && rows[index + 1].isSelected
            row.frame = NSRect(x: 0, y: CGFloat(index) * Metrics.rowHeight,
                               width: listDocument.frame.width, height: Metrics.rowHeight)
        }
        // Only when there is genuinely something below the fold. A fade over a
        // list that does not scroll is decoration pretending to be information.
        fade.isHidden = documentHeight <= scroll.frame.height + 1
        fade.frame = NSRect(x: 1, y: cardHeight - 29, width: cardWidth - 2, height: 28)
        emptyFilterLabel.frame = NSRect(x: 0, y: listTop + 40, width: cardWidth, height: 18)
    }
}

// MARK: - Row

/// One snippet in the library.
///
/// Two lines, not one: the phrase is what you say, the second line is what it
/// types. Flow shows `phrase → replacement` on a single line, which works right
/// up until the replacement is a paragraph — and then the row is a sentence
/// fragment ending in nothing.
final class SnippetRowView: NSView {

    let snippet: Snippet
    var onClick: (() -> Void)?
    var isSelected: Bool = false { didSet { rebuild() } }
    var isLastVisible = false
    var followedBySelection = false

    private let style: DashboardStyle
    private let phrase: NSTextField
    private let preview: NSTextField
    private let count: NSTextField
    private let offChip: DashboardChip?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hover.animate(to: isHovered ? 1 : 0)
        }
    }
    private lazy var hover = DashboardTween(view: self)

    override var isFlipped: Bool { true }

    init(snippet: Snippet, style: DashboardStyle) {
        self.snippet = snippet
        self.style = style
        phrase = DashboardType.label("\u{201C}\(snippet.phrase)\u{201D}",
                                     font: .systemFont(ofSize: 13.5, weight: .medium),
                                     color: snippet.isEnabled ? style.ink : style.inkTertiary)
        preview = DashboardType.label(snippet.previewLine.isEmpty ? "Nothing to type yet" : snippet.previewLine,
                                      font: DashboardType.callout,
                                      color: snippet.previewLine.isEmpty ? style.inkQuaternary : style.inkTertiary)
        count = DashboardType.label(snippet.useCount > 0 ? "\(snippet.useCount)" : "—",
                                    font: DashboardType.mono, color: style.inkQuaternary,
                                    alignment: .right)
        offChip = snippet.isEnabled ? nil : DashboardChip(text: "Off", tone: .outline, style: style)
        super.init(frame: .zero)
        addSubview(phrase)
        addSubview(preview)
        addSubview(count)
        offChip.map(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        let font = NSFont.systemFont(ofSize: 13.5, weight: isSelected ? .semibold : .medium)
        phrase.attributedStringValue = NSAttributedString(
            string: "\u{201C}\(snippet.phrase)\u{201D}",
            attributes: [.font: font,
                         .foregroundColor: snippet.isEnabled ? style.ink : style.inkTertiary,
                         .kern: -0.1])
        DashboardType.recolor(preview, isSelected ? style.inkSecondary : style.inkTertiary)
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 20
        // One thing in the right-hand slot, not two on top of each other.
        //
        // The count sat at `width - 18 - max(34, …)` and the chip at
        // `width - 18 - ~40`, so the chip's rect fully contained the count's — and
        // `.outline` draws a stroke with no fill, so the digits read straight
        // through the word OFF. Invisible in the fixtures because every seeded
        // snippet is enabled.
        //
        // The count is what goes. A disabled snippet's firing count is not what a
        // person wants at the moment they are looking at whether it is on, and the
        // alternative — moving the chip left — would truncate the trigger phrase on
        // every row in the list to make room for a state most of them are not in.
        count.isHidden = offChip != nil
        let countSize = count.fittingSize
        count.frame = NSRect(x: bounds.width - 18 - max(34, countSize.width), y: 15,
                             width: max(34, countSize.width), height: countSize.height)
        if let offChip {
            offChip.frame = NSRect(x: bounds.width - 18 - offChip.frame.width, y: 14,
                                   width: offChip.frame.width, height: offChip.frame.height)
        }
        let textWidth = bounds.width - inset - 62
        let phraseSize = phrase.fittingSize
        phrase.frame = NSRect(x: inset, y: 14, width: min(phraseSize.width, textWidth), height: phraseSize.height)
        let previewSize = preview.fittingSize
        preview.frame = NSRect(x: inset, y: 36, width: min(previewSize.width, textWidth + 34), height: previewSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            let pill = NSRect(x: 6, y: 4, width: bounds.width - 12, height: bounds.height - 8)
            DashboardDraw.raisedSurface(pill, radius: DashboardRadius.row,
                                        fillColor: style.raised, topColor: style.raisedTop,
                                        style: style, shadow: style.shadowRaised, flipped: true)
            // The one mark of colour on the row. A selected pill alone is legible
            // in light mode and nearly invisible in dark, where "slightly lighter
            // grey" is most of the palette.
            DashboardDraw.fill(NSRect(x: 12, y: (bounds.height - 22) / 2, width: 2.5, height: 22),
                               radius: 1.25, color: style.accent)
        } else if hover.value > 0.001 {
            DashboardDraw.fill(NSRect(x: 6, y: 4, width: bounds.width - 12, height: bounds.height - 8),
                               radius: DashboardRadius.row, color: style.hover.faded(hover.value))
        }
        // The separator fades out as the hover fill comes in, so the two never
        // both appear during the crossover.
        guard !isSelected, !isLastVisible, !followedBySelection, hover.value < 1 else { return }
        style.hairline.faded(1 - hover.value).setFill()
        NSRect(x: 20, y: bounds.height - 1, width: bounds.width - 40, height: 1).fill()
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
        isHovered = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Editor

/// The detail pane. Always open, never a modal.
///
/// A modal editor is the wrong shape for this specific thing: the value of a
/// snippet library is comparing what you have, and a modal is a machine for
/// making you look at exactly one row at a time.
final class SnippetEditorView: NSView {

    var onCommit: ((Snippet) -> Void)?
    var onDelete: ((Snippet) -> Void)?

    private let style: DashboardStyle
    private var snippet: Snippet?
    private var isDirty = false { didSet { updateFooter() } }

    private let card: DashboardCardView
    private let phraseCaption: NSTextField
    private let phraseField: SnippetsField
    private let enabledLabel: NSTextField
    private let enabledToggle: SnippetsToggle

    private let replacementCaption: NSTextField
    private let lengthLabel: NSTextField
    private let replacementArea: SnippetsTextArea

    private let matchCaption: NSTextField
    private let modeControl: SnippetsSegmented

    private let previewPanel: SnippetsPreviewPanel

    private let footerRule: DashboardRule
    private let meta: NSTextField
    private let saveButton: DashboardButton
    private let deleteButton: DashboardButton

    override var isFlipped: Bool { true }

    init(style: DashboardStyle) {
        self.style = style
        card = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        phraseCaption = DashboardType.label("Trigger phrase", font: DashboardType.micro,
                                            color: style.inkTertiary)
        phraseField = SnippetsField(style: style, placeholder: "what you say",
                                    font: .systemFont(ofSize: 14, weight: .medium),
                                    badgeSymbol: "waveform")
        // Matched to `phraseCaption` exactly. It was a step louder than the label
        // of the field it sits above, which inverts the hierarchy of the header.
        enabledLabel = DashboardType.label("Enabled", font: DashboardType.micro, color: style.inkTertiary)
        enabledToggle = SnippetsToggle(isOn: true, style: style)

        replacementCaption = DashboardType.label("What it types", font: DashboardType.micro,
                                                 color: style.inkTertiary)
        lengthLabel = DashboardType.label("", font: DashboardType.micro, color: style.inkQuaternary,
                                          alignment: .right)
        replacementArea = SnippetsTextArea(style: style, placeholder: "the block of text that replaces it")

        matchCaption = DashboardType.label("Matching", font: DashboardType.micro,
                                           color: style.inkTertiary)
        modeControl = SnippetsSegmented(titles: Snippet.Mode.allCases.map(\.title),
                                        selectedIndex: 0, style: style)
        previewPanel = SnippetsPreviewPanel(style: style)

        footerRule = DashboardRule(color: style.hairline)
        meta = DashboardType.label("", font: DashboardType.caption, color: style.inkTertiary)
        saveButton = DashboardButton(title: "Save", kind: .primary, style: style)
        deleteButton = DashboardButton(title: "Delete", symbol: "trash", kind: .ghost, style: style)

        super.init(frame: .zero)

        addSubview(card)
        [phraseCaption, phraseField, enabledLabel, enabledToggle,
         replacementCaption, lengthLabel, replacementArea,
         matchCaption, modeControl, previewPanel,
         footerRule, meta, saveButton, deleteButton].forEach(card.addSubview)

        phraseField.onChange = { [weak self] _ in self?.markDirty() }
        phraseField.onCommit = { [weak self] in self?.commitIfDirty() }
        replacementArea.onChange = { [weak self] _ in self?.markDirty() }
        enabledToggle.onToggle = { [weak self] _ in self?.markDirty(); self?.commitIfDirty() }
        modeControl.onSelect = { [weak self] _ in self?.markDirty(); self?.commitIfDirty() }
        saveButton.onClick = { [weak self] in self?.commit() }
        deleteButton.onClick = { [weak self] in
            guard let self, let snippet = self.snippet else { return }
            self.onDelete?(snippet)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: State

    func load(_ snippet: Snippet) {
        self.snippet = snippet
        phraseField.text = snippet.phrase
        replacementArea.text = snippet.replacement
        enabledToggle.isOn = snippet.isEnabled
        modeControl.selectedIndex = Snippet.Mode.allCases.firstIndex(of: snippet.mode) ?? 0
        isDirty = false
        refreshDerived()
        needsLayout = true
    }

    func focusPhrase() { phraseField.focus() }

    private func markDirty() {
        isDirty = true
        refreshDerived()
    }

    private var edited: Snippet? {
        guard var snippet else { return nil }
        snippet.phrase = phraseField.text
        snippet.replacement = replacementArea.text
        snippet.isEnabled = enabledToggle.isOn
        snippet.mode = Snippet.Mode.allCases[modeControl.selectedIndex]
        return snippet
    }

    func commitIfDirty() {
        guard isDirty else { return }
        commit()
    }

    private func commit() {
        guard let edited else { return }
        snippet = edited
        isDirty = false
        onCommit?(edited)
    }

    /// Everything that is computed *from* the fields rather than stored beside
    /// them: the character count and the firing preview. Recomputed on every
    /// keystroke so the preview is never one edit behind the text it describes.
    private func refreshDerived() {
        guard let edited else { return }
        let characters = edited.replacement.count
        lengthLabel.attributedStringValue = NSAttributedString(
            string: characters == 1 ? "1 character" : "\(characters) characters",
            attributes: [.font: DashboardType.micro, .foregroundColor: style.inkQuaternary,
                         .kern: DashboardType.tracking(for: DashboardType.micro)])
        previewPanel.show(edited)
        updateFooter()
    }

    private func updateFooter() {
        guard let snippet else { return }
        DashboardType.recolor(meta, style.inkTertiary)
        meta.attributedStringValue = NSAttributedString(
            string: isDirty ? "Unsaved changes" : Self.metaLine(for: snippet),
            attributes: [.font: DashboardType.caption,
                         .foregroundColor: isDirty ? style.accentInk : style.inkTertiary])
        // A filled black button that says "Saved" is the strongest call to
        // action on the screen pointing at nothing. It goes quiet until there is
        // actually something to save, which leaves the page exactly one primary.
        saveButton.kind = isDirty ? .primary : .secondary
        needsLayout = true
    }

    private static func metaLine(for snippet: Snippet) -> String {
        guard snippet.useCount > 0 else { return "Never fired yet" }
        let uses = snippet.useCount == 1 ? "Fired once" : "Fired \(snippet.useCount) times"
        guard let last = snippet.lastUsed else { return uses }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(uses) · \(formatter.localizedString(for: last, relativeTo: Date()))"
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        card.frame = bounds
        let width = bounds.width
        let padX: CGFloat = 22
        let inner = width - padX * 2
        guard inner > 0 else { return }

        var y: CGFloat = 22
        let captionHeight = ceil(phraseCaption.fittingSize.height)
        phraseCaption.frame = NSRect(x: padX, y: y + 4, width: 200, height: captionHeight)
        enabledToggle.frame = NSRect(x: width - padX - 38, y: y, width: 38, height: 22)
        let enabledSize = enabledLabel.fittingSize
        enabledLabel.frame = NSRect(x: enabledToggle.frame.minX - 8 - enabledSize.width,
                                    y: y + ((22 - enabledSize.height) / 2).rounded(),
                                    width: enabledSize.width, height: enabledSize.height)
        y += 22 + 10
        phraseField.frame = NSRect(x: padX, y: y, width: inner, height: 42)
        y += 42 + 22

        replacementCaption.frame = NSRect(x: padX, y: y, width: 240, height: captionHeight)
        let lengthSize = lengthLabel.fittingSize
        lengthLabel.frame = NSRect(x: width - padX - lengthSize.width, y: y,
                                   width: lengthSize.width, height: captionHeight)
        y += captionHeight + 8
        let replacementTop = y

        // Built from the bottom up so the footer is pinned and the replacement
        // editor absorbs whatever height the window has left.
        let footerY = bounds.height - 22 - 36
        saveButton.frame = NSRect(x: width - padX - max(88, saveButton.intrinsicWidth), y: footerY,
                                  width: max(88, saveButton.intrinsicWidth), height: 36)
        let deleteWidth = deleteButton.intrinsicWidth
        deleteButton.frame = NSRect(x: saveButton.frame.minX - 8 - deleteWidth, y: footerY,
                                    width: deleteWidth, height: 36)
        let metaSize = meta.fittingSize
        meta.frame = NSRect(x: padX, y: footerY + ((36 - metaSize.height) / 2).rounded(),
                            width: min(metaSize.width, deleteButton.frame.minX - padX - 12),
                            height: metaSize.height)
        footerRule.frame = NSRect(x: padX, y: footerY - 20, width: inner, height: 1)

        // Below this the card cannot hold the demonstration *and* an editor big
        // enough to write in, and the editor wins. Squeezing both is how a pane
        // ends up with a 40-point text box and two labels sitting on each other.
        let showsPreview = bounds.height >= 520
        previewPanel.isHidden = !showsPreview
        let previewHeight = previewPanel.fittingHeight(width: inner)
        let previewY = footerRule.frame.minY - 22 - previewHeight
        if showsPreview {
            previewPanel.frame = NSRect(x: padX, y: previewY, width: inner, height: previewHeight)
        }

        let modeY = (showsPreview ? previewY : footerRule.frame.minY - 22) - 24 - 32
        let modeWidth = min(inner, 360)
        modeControl.frame = NSRect(x: padX, y: modeY, width: modeWidth, height: 32)
        matchCaption.frame = NSRect(x: padX, y: modeY - 8 - captionHeight, width: 200, height: captionHeight)

        let replacementHeight = max(90, matchCaption.frame.minY - 22 - replacementTop)
        replacementArea.frame = NSRect(x: padX, y: replacementTop, width: inner, height: replacementHeight)
    }
}

// MARK: - Firing preview

/// The substitution, computed by the shipping expander and shown as it will
/// happen.
///
/// This is the element Flow's page has no equivalent of, and the reason it
/// exists is trust: a snippet is an invisible rule that edits your words after
/// you have stopped speaking, and "say the words and find out" is not an
/// acceptable way to learn what it does.
final class SnippetsPreviewPanel: NSView {

    private let style: DashboardStyle
    private let spokenTag: NSTextField
    private let typedTag: NSTextField
    private let spokenLine: SnippetsHighlightLine
    private let typedLine: SnippetsHighlightLine
    private let disabledNote: NSTextField

    private static let gutter: CGFloat = 92
    private static let lineHeight: CGFloat = 24

    override var isFlipped: Bool { true }

    init(style: DashboardStyle) {
        self.style = style
        spokenTag = DashboardType.label("You say", font: DashboardType.micro,
                                        color: style.inkQuaternary)
        typedTag = DashboardType.label("Quill types", font: DashboardType.micro,
                                       color: style.inkQuaternary)
        spokenLine = SnippetsHighlightLine(font: .systemFont(ofSize: 12.5, weight: .regular),
                                          tint: style.accentSoft)
        // The output line is the payload, so it is the heavier of the two — and
        // its marker is neutral: `cardAlt` on a panel is invisible in light mode,
        // and a second accent here would put three oranges in one 500-point box.
        typedLine = SnippetsHighlightLine(font: .systemFont(ofSize: 12.5, weight: .medium),
                                          tint: style.hover)
        disabledNote = DashboardType.label("Turned off — this phrase is typed exactly as you say it.",
                                           font: DashboardType.callout, color: style.inkTertiary)
        super.init(frame: .zero)
        [spokenTag, typedTag, spokenLine, typedLine, disabledNote].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fittingHeight(width: CGFloat) -> CGFloat {
        disabledNote.isHidden ? Self.lineHeight * 2 + 12 + 28 : Self.lineHeight + 28
    }

    func show(_ snippet: Snippet) {
        let phrase = snippet.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !phrase.isEmpty && !snippet.replacement.isEmpty
        let off = hasContent && !snippet.isEnabled

        disabledNote.isHidden = !off
        [spokenTag, typedTag, spokenLine, typedLine].forEach { $0.isHidden = off }

        guard !off else { needsDisplay = true; needsLayout = true; return }
        guard hasContent else {
            spokenLine.set(text: "…", highlight: NSRange(location: 0, length: 0),
                           color: style.inkQuaternary, highlightColor: style.inkQuaternary)
            typedLine.set(text: "…", highlight: NSRange(location: 0, length: 0),
                          color: style.inkQuaternary, highlightColor: style.inkQuaternary)
            needsDisplay = true
            return
        }

        // The frame differs by mode because the modes genuinely differ: one
        // fires inside a sentence, the other only when it is the whole thing.
        // A single canned example would misrepresent one of them.
        let spoken = snippet.mode == .anywhere ? "… \(phrase) …" : phrase
        let result = SnippetExpander().expand(spoken, using: [snippet])
        let firing = result.firings.first

        // Full ink for the matched phrase, and let the marker behind it carry the
        // emphasis — the "Quill types" line below already does exactly this.
        //
        // It used `style.accentInk`, which is `.controlAccentColor`, and on a
        // Graphite accent that is a mid grey: the one phrase the panel exists to
        // point at came out three times LIGHTER than the ordinary text around it.
        // Emphasis by a hue that can be turned off is not emphasis.
        spokenLine.set(text: spoken,
                       highlight: firing?.sourceRange ?? NSRange(location: 0, length: 0),
                       color: style.inkSecondary, highlightColor: style.ink)

        let (typed, range) = Self.condense(result.text, highlight: firing?.outputRange)
        typedLine.set(text: typed, highlight: range,
                      color: style.ink, highlightColor: style.ink)
        needsDisplay = true
        needsLayout = true
    }

    /// One line, with the highlight clamped to whatever survives. A
    /// three-paragraph replacement still has to demonstrate itself inside a
    /// 500-point panel.
    static func condense(_ text: String, highlight: NSRange?) -> (String, NSRange) {
        let source = text as NSString
        var end = source.length
        let newline = source.rangeOfCharacter(from: .newlines)
        if newline.location != NSNotFound { end = newline.location }
        end = min(end, 74)

        var out = source.substring(to: end)
        if end < source.length {
            // Trailing punctuation goes first: a cut that lands after a full
            // stop otherwise reads "through.…", which looks like a rendering
            // fault rather than a truncation. Trailing *only* — trimming the
            // front would slide the highlight off the text it belongs to.
            let droppable = CharacterSet(charactersIn: " .,;:—-")
            while end > 0,
                  let scalar = out.unicodeScalars.last,
                  droppable.contains(scalar) {
                out.unicodeScalars.removeLast()
                end = (out as NSString).length
            }
            out += "…"
        }

        guard let highlight else { return (out, NSRange(location: 0, length: 0)) }
        return (out, NSIntersectionRange(highlight, NSRange(location: 0, length: end)))
    }

    override func layout() {
        super.layout()
        let padX: CGFloat = 16
        if !disabledNote.isHidden {
            let size = disabledNote.fittingSize
            disabledNote.frame = NSRect(x: padX, y: ((bounds.height - size.height) / 2).rounded(),
                                        width: min(size.width, bounds.width - padX * 2), height: size.height)
            return
        }
        var y: CGFloat = 14
        for (tag, line) in [(spokenTag, spokenLine), (typedTag, typedLine)] {
            let tagSize = tag.fittingSize
            tag.frame = NSRect(x: padX, y: y + ((Self.lineHeight - tagSize.height) / 2).rounded(),
                               width: Self.gutter - 12, height: tagSize.height)
            line.frame = NSRect(x: padX + Self.gutter, y: y,
                                width: bounds.width - padX * 2 - Self.gutter, height: Self.lineHeight)
            y += Self.lineHeight + 12
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.fill(bounds, radius: DashboardRadius.control, color: style.panel)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.control, color: style.hairline)
    }
}

// MARK: - Empty state

/// What the page looks like with nothing in it.
///
/// Flow fills this space with an advertisement for the feature. The three rows
/// below are the same three examples, except they are buttons: clicking one
/// creates that snippet, prefilled, with the editor open on it. The difference
/// between a poster and a doorway.
final class SnippetsEmptyStateView: NSView {

    var onCreate: ((String, String) -> Void)?

    var onWriteOwn: (() -> Void)?

    private let style: DashboardStyle
    private let card: DashboardCardView
    private let title: NSTextField
    private let body: NSTextField
    private let caption: NSTextField
    private let writeOwn: DashboardButton
    private var starters: [SnippetsStarterRow] = []

    override var isFlipped: Bool { true }

    /// Three examples that show the three shapes a snippet can take — a single
    /// line, a template with gaps to fill, and a block of prose — placeholders
    /// for the person using THEIR OWN app to fill in with their own words.
    ///
    /// This used to be the author's actual week: his email address, his
    /// deposit terms, his sign-off. Useful to exactly one person and shown to
    /// everybody, and shown MORE often after the snippet seed itself was
    /// emptied — every new install now lands on this screen rather than on a
    /// pre-filled list, so a starter row containing a stranger's real inbox
    /// address was one click away from being copied into somebody's own
    /// snippet without them ever having typed it.
    static let suggestions: [(String, String)] = [
        ("my email address", "you@example.com"),
        ("deposit terms", "50% to start, the rest on delivery. Invoice sent the same day, due within 7 days."),
        ("sign off", "Thanks,\nYour name"),
    ]

    init(style: DashboardStyle) {
        self.style = style
        card = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        title = DashboardType.label("Nothing to expand yet", font: DashboardType.title, color: style.ink,
                                    alignment: .center)
        body = DashboardType.label("A snippet is a phrase you say and a block of text Quill types in its place.",
                                   font: DashboardType.body, color: style.inkSecondary,
                                   lines: 2, lineHeight: 21, alignment: .center)
        caption = DashboardType.label("Start with one of these", font: DashboardType.micro,
                                      color: style.inkQuaternary, alignment: .center)
        writeOwn = DashboardButton(title: "Write your own", symbol: "plus", kind: .ghost, style: style)
        super.init(frame: .zero)
        addSubview(card)
        [title, body, caption, writeOwn].forEach(card.addSubview)
        writeOwn.onClick = { [weak self] in self?.onWriteOwn?() }
        for (phrase, replacement) in Self.suggestions {
            let row = SnippetsStarterRow(phrase: phrase, replacement: replacement, style: style)
            row.onClick = { [weak self] in self?.onCreate?(phrase, replacement) }
            card.addSubview(row)
            starters.append(row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The card is a centred column, not the whole content area.
    ///
    /// Filling 1,000 by 600 points with one paragraph and three rows leaves the
    /// composition swimming in its own container — the void reads as missing
    /// content rather than as space. Sized to the content and centred, the same
    /// emptiness reads as calm.
    override func layout() {
        super.layout()
        let padX: CGFloat = 44
        let cardWidth = min(620, bounds.width - 120)
        let contentWidth = cardWidth - padX * 2
        let bodyHeight = DashboardType.size(body, width: contentWidth).height
        let starterHeight: CGFloat = 46
        let titleSize = title.fittingSize
        let captionSize = caption.fittingSize

        let content = titleSize.height + 12 + bodyHeight + 32
            + captionSize.height + 12
            + CGFloat(starters.count) * (starterHeight + 8) - 8
            + 16 + 32
        let cardHeight = content + 44 * 2
        card.frame = NSRect(x: ((bounds.width - cardWidth) / 2).rounded(),
                            y: max(0, ((bounds.height - cardHeight) / 2).rounded()),
                            width: cardWidth, height: cardHeight)

        var y: CGFloat = 44
        title.frame = NSRect(x: padX, y: y, width: contentWidth, height: titleSize.height)
        y += titleSize.height + 12
        body.frame = NSRect(x: padX, y: y, width: contentWidth, height: bodyHeight)
        y += bodyHeight + 32

        caption.frame = NSRect(x: padX, y: y, width: contentWidth, height: captionSize.height)
        y += captionSize.height + 12

        for row in starters {
            row.frame = NSRect(x: padX, y: y, width: contentWidth, height: starterHeight)
            y += starterHeight + 8
        }
        y += 8
        let buttonWidth = writeOwn.intrinsicWidth
        writeOwn.frame = NSRect(x: ((cardWidth - buttonWidth) / 2).rounded(), y: y,
                                width: buttonWidth, height: 32)
    }
}

/// A suggested snippet, as a clickable row: phrase, arrow, what it would type.
final class SnippetsStarterRow: NSView {

    var onClick: (() -> Void)?

    private let style: DashboardStyle
    private let phrase: NSTextField
    private let arrow: DashboardIconView
    private let replacement: NSTextField
    private let plus: DashboardIconView
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hover.animate(to: isHovered ? 1 : 0)
        }
    }
    private lazy var hover = DashboardTween(view: self)

    override var isFlipped: Bool { true }

    init(phrase: String, replacement: String, style: DashboardStyle) {
        self.style = style
        self.phrase = DashboardType.label("\u{201C}\(phrase)\u{201D}",
                                          font: .systemFont(ofSize: 13, weight: .medium), color: style.ink)
        arrow = DashboardIconView(image: DashboardIcon.image("arrow.right", pointSize: 10, weight: .semibold,
                                                            color: style.inkQuaternary))
        self.replacement = DashboardType.label(
            replacement.replacingOccurrences(of: "\n", with: " "),
            font: DashboardType.callout, color: style.inkTertiary)
        plus = DashboardIconView(image: DashboardIcon.image("plus", pointSize: 11, weight: .semibold,
                                                           color: style.inkTertiary))
        super.init(frame: .zero)
        [self.phrase, arrow, self.replacement, plus].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Fixed phrase column, so the three arrows line up. Packed to each phrase's
    /// own width they stagger, and three staggered arrows in a stack of three
    /// rows is the first thing the eye finds.
    private static let phraseColumn: CGFloat = 150

    override func layout() {
        super.layout()
        let phraseSize = phrase.fittingSize
        phrase.frame = NSRect(x: 16, y: ((bounds.height - phraseSize.height) / 2).rounded(),
                              width: min(phraseSize.width, Self.phraseColumn), height: phraseSize.height)
        let arrowX = 16 + Self.phraseColumn + 8
        arrow.frame = NSRect(x: arrowX, y: (bounds.height - 14) / 2, width: 14, height: 14)
        plus.frame = NSRect(x: bounds.width - 16 - 14, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let replacementSize = replacement.fittingSize
        let textX = arrowX + 22
        let available = plus.frame.minX - 12 - textX
        replacement.frame = NSRect(x: textX,
                                   y: ((bounds.height - replacementSize.height) / 2).rounded(),
                                   width: max(0, min(replacementSize.width, available)),
                                   height: replacementSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Flat state always, raised state faded over the top. Crossfading two
        // whole surfaces is the only way to animate between them — a raised
        // surface is a gradient, a shadow and a lit edge, none of which
        // interpolate from a single colour.
        DashboardDraw.fill(bounds, radius: DashboardRadius.control, color: style.panel)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.control,
                             color: style.hairline.faded(1 - hover.value))
        guard hover.value > 0.001 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(hover.value)
        DashboardDraw.raisedSurface(bounds, radius: DashboardRadius.control,
                                    fillColor: style.raised, topColor: style.raisedTop,
                                    style: style, shadow: style.shadowContact, flipped: true)
        NSGraphicsContext.restoreGraphicsState()
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
        isHovered = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Provider

/// Plugs the section into the dashboard shell.
///
/// Handed a store rather than reaching for `SnippetStore.shared`, so the
/// preview renderer and the tests can supply one that never touches disk.
public final class SnippetsSectionProvider: NSObject, DashboardSectionProvider {

    private let store: SnippetStore

    public init(store: SnippetStore = .shared) {
        self.store = store
        super.init()
    }

    /// A provider backed by the seed fixture, for `DashboardPreviewRenderer`.
    public static func preview() -> SnippetsSectionProvider {
        SnippetsSectionProvider(store: .preview())
    }

    /// A provider with nothing in it, for rendering the empty state.
    public static func empty() -> SnippetsSectionProvider {
        SnippetsSectionProvider(store: SnippetStore(inMemory: []))
    }

    public func dashboardView(for section: DashboardSection, style: DashboardStyle) -> NSView? {
        guard section == .snippets else { return nil }
        return SnippetsSectionView(store: store, style: style)
    }
}
