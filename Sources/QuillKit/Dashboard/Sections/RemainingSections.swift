import AppKit

// Scratchpad, Style and Notetaker. Two are real. The third is deliberately not
// faked — see below.
//
// All three were Auto Layout inside an unflipped view, stacking an EMPTY eyebrow
// label above the title and a three-line deck below it, while the other seven
// sections laid out manual frames in a flipped one. That is why their headings
// sat twenty-four points lower than everywhere else — the drift Roman named —
// and why none of them filled the window. They are rewritten here on the same
// two pieces every other section now uses: `DashboardSectionHeader` for the top
// of the page, `DashboardMessageView` for a page with nothing on it.

// MARK: - Shared card

/// One card chrome, so three sections cannot drift into three different looks.
///
/// Manual layout, and it measures itself. The constraint-based version could
/// only be given a height by whoever placed it, which is how Style ended up with
/// two 210pt cards and three hundred points of nothing under them.
final class SectionCard: NSView {

    private let style: DashboardStyle
    private let heading: NSTextField
    private let trailing: NSTextField?
    private var body: [NSView] = []
    private var bodyHeights: [(NSView, (CGFloat) -> CGFloat)] = []

    static let headerHeight: CGFloat = 46
    static let inset: CGFloat = DashboardSpace.md

    override var isFlipped: Bool { true }

    init(style: DashboardStyle, title: String, trailing: String? = nil) {
        self.style = style
        heading = DashboardType.label(title, font: DashboardType.headline, color: style.ink)
        self.trailing = trailing.map {
            DashboardType.label($0, font: DashboardType.caption, color: style.inkTertiary,
                                alignment: .right)
        }
        super.init(frame: .zero)
        addSubview(heading)
        self.trailing.map(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Adds a row and says how tall it is at a given width. The closure is what
    /// lets the card fit itself before anyone places it.
    func add(_ view: NSView, height: @escaping (CGFloat) -> CGFloat) {
        addSubview(view)
        body.append(view)
        bodyHeights.append((view, height))
    }

    func fittedHeight(width: CGFloat) -> CGFloat {
        let inner = width - SectionCard.inset * 2
        let rows = bodyHeights.reduce(0) { $0 + $1.1(inner) }
        return SectionCard.headerHeight + rows + SectionCard.inset
    }

    override func layout() {
        super.layout()
        let inset = SectionCard.inset
        let inner = bounds.width - inset * 2
        guard inner > 0 else { return }

        let headingSize = heading.fittingSize
        let trailingWidth = trailing.map { min($0.fittingSize.width, inner * 0.5) } ?? 0
        heading.frame = NSRect(x: inset, y: inset,
                               width: min(headingSize.width, inner - trailingWidth - DashboardSpace.sm),
                               height: headingSize.height)
        if let trailing {
            let size = trailing.fittingSize
            trailing.frame = NSRect(x: bounds.width - inset - trailingWidth,
                                    y: (heading.frame.midY - size.height / 2).rounded(),
                                    width: trailingWidth, height: size.height)
        }

        var y = SectionCard.headerHeight
        for (view, height) in bodyHeights {
            let h = height(inner)
            view.frame = NSRect(x: inset, y: y, width: inner, height: h)
            y += h
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.sunkenSurface(bounds, radius: DashboardRadius.card, style: style, flipped: true)
    }
}

/// A label / value line inside a card. The value keeps its width and the label
/// truncates into what is left — the rule the whole window follows.
final class SectionKeyValueRow: NSView {

    private let name: NSTextField
    private let value: NSTextField

    static let height: CGFloat = 26

    override var isFlipped: Bool { true }

    init(_ label: String, _ text: String, style: DashboardStyle, muted: Bool = false) {
        name = DashboardType.label(label, font: DashboardType.callout, color: style.inkSecondary)
        value = DashboardType.label(text, font: DashboardType.callout,
                                    color: muted ? style.inkTertiary : style.ink, alignment: .right)
        super.init(frame: .zero)
        addSubview(name)
        addSubview(value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let valueSize = value.fittingSize
        let valueWidth = min(valueSize.width, bounds.width * 0.6)
        value.frame = NSRect(x: bounds.width - valueWidth,
                             y: ((bounds.height - valueSize.height) / 2).rounded(),
                             width: valueWidth, height: valueSize.height)
        let nameSize = name.fittingSize
        name.frame = NSRect(x: 0, y: ((bounds.height - nameSize.height) / 2).rounded(),
                            width: min(nameSize.width, bounds.width - valueWidth - DashboardSpace.sm),
                            height: nameSize.height)
    }
}

/// A label on the left, a button on the right — `SectionKeyValueRow`'s shape
/// with an action in the value slot instead of text.
final class SectionButtonRow: NSView {

    private let name: NSTextField
    let button: DashboardButton

    static let height: CGFloat = 34

    override var isFlipped: Bool { true }

    init(_ label: String, buttonTitle: String, style: DashboardStyle) {
        name = DashboardType.label(label, font: DashboardType.callout, color: style.inkSecondary)
        button = DashboardButton(title: buttonTitle, kind: .secondary, style: style)
        super.init(frame: .zero)
        addSubview(name)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let buttonWidth = button.intrinsicWidth
        button.frame = NSRect(x: bounds.width - buttonWidth,
                              y: ((bounds.height - 28) / 2).rounded(),
                              width: buttonWidth, height: 28)
        let nameSize = name.fittingSize
        name.frame = NSRect(x: 0, y: ((bounds.height - nameSize.height) / 2).rounded(),
                            width: min(nameSize.width, bounds.width - buttonWidth - DashboardSpace.sm),
                            height: nameSize.height)
    }
}

/// A bulleted line that wraps. Used where a card is prose rather than data.
final class SectionBulletRow: NSView {

    private let dot: NSTextField
    private let text: NSTextField

    override var isFlipped: Bool { true }

    init(_ body: String, style: DashboardStyle) {
        dot = DashboardType.label("\u{00B7}", font: DashboardType.body, color: style.inkQuaternary)
        text = DashboardType.label(body, font: DashboardType.callout, color: style.inkSecondary,
                                   lines: 3, lineHeight: 19)
        super.init(frame: .zero)
        addSubview(dot)
        addSubview(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat {
        DashboardType.size(text, width: max(40, width - 14)).height + 10
    }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 0, y: 1, width: 10, height: dot.fittingSize.height)
        text.frame = NSRect(x: 14, y: 0, width: max(40, bounds.width - 14),
                            height: DashboardType.size(text, width: max(40, bounds.width - 14)).height)
    }
}

// MARK: - Scratchpad

/// Somewhere to dictate that is not a text field.
///
/// One note used to render as a 138x160 card alone in the top-left corner of a
/// 1116x798 page — five per cent of the screen covered — and the "New note"
/// button was drawn in `style.panel`, which is `.clear`, so it was a white pill
/// with nothing written on it.
///
/// The shape is now the one Dictation and Transforms use: the open note is a hero
/// sized to what is in it, then the rest of the notes as full-width rows. Three
/// screens, one arrangement, which is the answer to *"it's just not how the other
/// tabs have been styled."* It also fixes the real problem, which was that a
/// scratchpad listed notes and gave you no way to read one.
public final class ScratchpadSectionView: NSView {

    private static let rowHeight: CGFloat = 56

    private let style: DashboardStyle
    private let notes: [Note]
    private let header: DashboardSectionHeader
    private let newNote: DashboardButton
    private var hero: ScratchpadNoteView?
    private var rows: [ScratchpadRow] = []
    private var rule: DashboardRule?
    /// The list scrolls. Without it the eighth note onward was laid out past the
    /// bottom of the section and simply never seen — a notes app that silently
    /// stops showing your notes.
    private let scroll = NSScrollView()
    private let listDocument = DictationFlippedView()
    private var empty: DashboardMessageView?
    private var selectedID: UUID?

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle, notes: [Note]) {
        self.style = style
        self.notes = notes.sorted { $0.isPinned == $1.isPinned ? $0.modified > $1.modified : $0.isPinned }
        let action = DashboardSection.scratchpad.primaryAction
        newNote = DashboardButton(title: action.title, symbol: action.symbol, kind: .primary, style: style)
        // No count under the title. Dictation shows one only while a filter is
        // narrowing the list, which is when a count answers something; a standing
        // "1 note" over a list of one note is the list read aloud.
        header = DashboardSectionHeader(title: "Scratchpad", trailing: [newNote], style: style)
        super.init(frame: .zero)

        newNote.onClick = {
            NoteStore.shared.upsert(Note())
            NotificationCenter.default.post(name: .quillDashboardNeedsReload, object: nil)
        }
        addSubview(header)

        guard !self.notes.isEmpty else {
            let view = DashboardMessageView(
                symbol: "square.and.pencil",
                title: "Nothing here yet",
                body: "Hold the dictation key with no text field focused and whatever you say lands here, as a note.",
                // No button. "New note" is already in the header, where it stays
                // once notes exist — the card offering it a second time two
                // hundred points below is the same action twice on one screen.
                steps: [], action: nil, actionSymbol: nil,
                style: style, elevation: .raised)
            addSubview(view)
            empty = view
            return
        }

        selectedID = self.notes.first?.id
        rebuildHero()

        // Only the notes that are NOT open get a row. A list whose first entry is
        // a smaller copy of the thing already open above it is a list repeating
        // itself, and on a one-note scratchpad it is the entire list.
        let line = DashboardRule(color: style.hairline)
        addSubview(line)
        rule = line

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

        buildRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = notes.filter { $0.id != selectedID }.map { note in
            let row = ScratchpadRow(note: note, style: style)
            row.onClick = { [weak self] in self?.select(note) }
            listDocument.addSubview(row)
            return row
        }
        rule?.isHidden = rows.isEmpty
        scroll.isHidden = rows.isEmpty
    }

    private func select(_ note: Note) {
        guard selectedID != note.id else { return }
        selectedID = note.id
        rebuildHero()
        buildRows()
        needsLayout = true
    }

    /// Cross-fade, the same as Dictation swapping a record. A hard cut between two
    /// notes reads as a glitch.
    private func rebuildHero() {
        let outgoing = hero
        hero = nil
        guard let selectedID, let note = notes.first(where: { $0.id == selectedID }) else {
            outgoing?.removeFromSuperview()
            return
        }
        let view = ScratchpadNoteView(note: note, style: style)
        addSubview(view)
        hero = view
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard !DashboardMotion.isReduced, outgoing != nil else {
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

    public override func layout() {
        super.layout()
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2
        guard width > 0 else { return }

        header.frame = NSRect(x: padX, y: padY, width: width, height: header.height)
        var y = DashboardSectionHeader.contentTop(for: header)

        if let empty {
            let cardWidth: CGFloat = 520
            let cardHeight = empty.fittingHeight(width: cardWidth)
            let room = max(200, bounds.height - y - padY)
            empty.frame = NSRect(x: padX + ((width - cardWidth) / 2).rounded(),
                                 y: y + ((room - cardHeight) * 0.42).rounded(),
                                 width: cardWidth, height: cardHeight)
            return
        }

        if let hero {
            // The hero takes the room the list does not need, up to a cap. A note
            // is prose — unlike a dictation it can be pages long — so it earns
            // more height than a transcript does, and the rest of the page is a
            // short list rather than the other way round.
            // Capped at four rows' worth. The list scrolls, so a note count of
            // forty must not squeeze the open note down to its floor — past a few
            // rows the list has said "there are more" and the rest is scrolling.
            let visibleRows = min(CGFloat(rows.count), 4)
            let listHeight = visibleRows * ScratchpadSectionView.rowHeight
                + (rows.isEmpty ? 0 : DashboardSpace.xl + 1)
            let available = max(160, bounds.height - y - padY - listHeight)
            hero.frame = NSRect(x: padX, y: y, width: width,
                                height: min(available, hero.fittingHeight(width: width)))
            y += hero.frame.height + DashboardSpace.xl
        }

        guard !rows.isEmpty else { return }
        rule?.frame = NSRect(x: padX, y: y, width: width, height: 1)
        y += 1
        scroll.frame = NSRect(x: padX, y: y, width: width, height: max(0, bounds.height - y - padY))

        var rowY: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: rowY, width: width, height: ScratchpadSectionView.rowHeight)
            rowY += ScratchpadSectionView.rowHeight
        }
        listDocument.frame = NSRect(x: 0, y: 0, width: width, height: rowY)
    }
}

/// The open note: its title, when it was touched, and the text itself.
///
/// There is no note editor yet, so this reads rather than edits — but it reads,
/// which the previous screen did not do at all. An empty note says so instead of
/// showing a blank card, because a blank card and a broken card look the same.
final class ScratchpadNoteView: NSView {

    private static let pad = DashboardSpace.lg
    private static let bodyFont = NSFont.systemFont(ofSize: 15, weight: .regular)
    private static let bodyLeading: CGFloat = 24
    private static let bodyMaxWidth: CGFloat = 760

    private let style: DashboardStyle
    private let note: Note
    private let title: NSTextField
    private let meta: NSTextField
    private let body: NSTextField
    private let copyButton: DashboardButton

    override var isFlipped: Bool { true }

    init(note: Note, style: DashboardStyle) {
        self.style = style
        self.note = note
        title = DashboardType.label(note.displayTitle, font: DashboardType.section, color: style.ink)
        meta = DashboardType.label(
            (note.isPinned ? "Pinned  \u{00B7}  " : "")
            + DictationFormat.plural(note.wordCount, "word")
            + "  \u{00B7}  edited " + ScratchpadRow.relative(note.modified),
            font: DashboardType.caption, color: style.inkTertiary)

        let empty = note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ScratchpadNoteView.bodyLeading
        paragraph.maximumLineHeight = ScratchpadNoteView.bodyLeading
        paragraph.lineBreakMode = .byWordWrapping
        let field = NSTextField(labelWithString: "")
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = !empty
        field.maximumNumberOfLines = 14
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = false
        field.attributedStringValue = NSAttributedString(
            string: empty ? "Nothing in this note yet. Hold the dictation key with no text field focused and it lands here."
                          : note.body,
            attributes: [.font: ScratchpadNoteView.bodyFont,
                         .foregroundColor: empty ? style.inkQuaternary : style.ink,
                         .paragraphStyle: paragraph])
        body = field

        copyButton = DashboardButton(title: "Copy", symbol: "doc.on.doc", kind: .secondary, style: style)
        super.init(frame: .zero)
        addSubview(title)
        addSubview(meta)
        addSubview(body)
        copyButton.isHidden = empty
        copyButton.onClick = { [weak self] in self?.copyNote() }
        addSubview(copyButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func copyNote() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.body, forType: .string)
        NotificationCenter.default.post(name: .quillOverlayMessage, object: "Note copied.")
    }

    /// The measure grows with the window, but slowly, and never to the edge.
    ///
    /// A fixed cap is the right typographic answer and the wrong one for a card:
    /// at 1700 points the text sat in the left half of a bordered box and the
    /// right half was empty, which reads as a layout that failed rather than as a
    /// column that was set. Scaling at 62% keeps the line inside a readable
    /// measure at every size the window can be dragged to, and the floor stops it
    /// getting narrower than it was at 1350.
    private func textWidth(for width: CGFloat) -> CGFloat {
        let inner = width - ScratchpadNoteView.pad * 2
        return min(inner, max(ScratchpadNoteView.bodyMaxWidth, min(inner * 0.62, 980)))
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        let pad = ScratchpadNoteView.pad
        return ceil(pad + ceil(title.fittingSize.height) + 4 + ceil(meta.fittingSize.height)
                    + DashboardSpace.md
                    + DashboardType.size(body, width: textWidth(for: width)).height
                    + pad)
    }

    override func layout() {
        super.layout()
        let pad = ScratchpadNoteView.pad
        let width = bounds.width
        guard width > pad * 2 else { return }

        let buttonWidth = copyButton.intrinsicWidth
        copyButton.frame = NSRect(x: width - pad - buttonWidth, y: pad - 3, width: buttonWidth, height: 30)

        let titleSize = title.fittingSize
        title.frame = NSRect(x: pad, y: pad,
                             width: min(titleSize.width, copyButton.frame.minX - pad - DashboardSpace.md),
                             height: titleSize.height)
        let metaSize = meta.fittingSize
        meta.frame = NSRect(x: pad, y: title.frame.maxY + 4,
                            width: min(metaSize.width, width - pad * 2), height: metaSize.height)

        let text = textWidth(for: width)
        body.frame = NSRect(x: pad, y: meta.frame.maxY + DashboardSpace.md, width: text,
                            height: max(0, bounds.height - meta.frame.maxY - DashboardSpace.md - pad))
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.fill(bounds, radius: DashboardRadius.card, color: style.card)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.card, color: style.hairline)
    }
}

/// One note in the list under the open one: title, its first line, and when it
/// was touched. The same three-column shape as a dictation row, because they are
/// the same kind of list.
final class ScratchpadRow: NSView {

    var onClick: (() -> Void)?

    private let style: DashboardStyle
    private let note: Note
    private let title: NSTextField
    private let preview: NSTextField
    private let meta: NSTextField

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

    init(note: Note, style: DashboardStyle) {
        self.style = style
        self.note = note
        title = DashboardType.label(note.displayTitle, font: DashboardType.bodyMedium, color: style.ink)
        preview = DashboardType.label(note.body.replacingOccurrences(of: "\n", with: "  "),
                                      font: DashboardType.callout, color: style.inkTertiary)
        meta = DashboardType.label(
            (note.isPinned ? "Pinned  \u{00B7}  " : "")
            + DictationFormat.plural(note.wordCount, "word")
            + "  \u{00B7}  " + ScratchpadRow.relative(note.modified),
            font: DashboardType.caption, color: style.inkQuaternary, alignment: .right)
        super.init(frame: .zero)
        addSubview(title)
        addSubview(preview)
        addSubview(meta)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inset = DashboardSpace.sm
        let metaWidth: CGFloat = 200
        let textWidth = max(40, bounds.width - inset * 2 - metaWidth - DashboardSpace.md)

        // The text block is centred as a block, and the meta is centred on the
        // TITLE rather than on the row.
        //
        // The title was pinned at a hard y: 10 while the meta centred in the row,
        // so they only agreed when the note had a body line under the title — and
        // an empty note is exactly what the "New note" button produces. Every
        // freshly made note therefore read as a broken row, with its own metadata
        // sitting eleven points below its name.
        //
        // Keyed off `note.body.isEmpty`, not off the preview's fitting height: an
        // empty NSTextField still reports a non-zero height, so a height test does
        // not detect the empty case at all.
        let titleSize = title.fittingSize
        let hasPreview = !note.body.isEmpty
        let previewSize = preview.fittingSize
        let blockHeight = titleSize.height + (hasPreview ? previewSize.height + 3 : 0)
        let top = ((bounds.height - blockHeight) / 2).rounded()

        title.frame = NSRect(x: inset, y: top, width: min(titleSize.width, textWidth),
                             height: titleSize.height)
        preview.isHidden = !hasPreview
        preview.frame = NSRect(x: inset, y: top + titleSize.height + 3,
                               width: textWidth, height: previewSize.height)

        let metaSize = meta.fittingSize
        meta.frame = NSRect(x: bounds.width - inset - metaWidth,
                            y: (title.frame.midY - metaSize.height / 2).rounded(),
                            width: metaWidth, height: metaSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0, dy: 1)
        if hover.value > 0.001 {
            DashboardDraw.fill(body, radius: DashboardRadius.row, color: style.hover.faded(hover.value))
        }
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

    static func relative(_ date: Date, from now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86400: return "\(Int(seconds / 3600))h ago"
        case ..<604800: return "\(Int(seconds / 86400))d ago"
        default:
            let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM")
            return f.string(from: date)
        }
    }
}

// MARK: - Style

/// What Quill has learned about how you write, and the tone it starts from.
public final class StyleSectionView: NSView {

    private let header: DashboardSectionHeader
    private let traits: SectionCard
    private let trust: SectionCard
    private let presets: SectionCard
    private let chips: [StyleToneRow]
    private let exportButton: DashboardButton

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle, profile: StyleProfile) {
        // "Copy for AI" rather than "Export": the verb people already have for
        // handing something to a chat window is paste, and a button that ends
        // in the pasteboard should say so rather than making them go find a
        // file first. It writes the file too — see the click handler — for
        // whichever tool wants an attachment instead of pasted text.
        exportButton = DashboardButton(title: "Copy for AI", symbol: "doc.on.doc",
                                       kind: .secondary, style: style)
        header = DashboardSectionHeader(title: "Style", trailing: [exportButton], style: style)

        // Traits, with their evidence. A learned setting shown without its support
        // count is indistinguishable from a guess, and this is a feature people
        // are right to distrust.
        // No count until there is one. "0 corrections seen" sat directly above two
        // rows reading "british · 2" and "uses them · 2", so the card contradicted
        // itself in a single glance — and the rows are not wrong: those are seeded
        // traits at full support, and `promptRules()` emits them on every dictation.
        // The header was the false half. Same shape as the trust card beside it,
        // which already passes nil when it has nothing to report.
        traits = SectionCard(style: style, title: "What Quill has learned",
                             trailing: profile.correctionCount == 0 ? nil
                                 : "\(DictationFormat.plural(profile.correctionCount, "correction")) seen")
        // An unlearned trait says so. Showing a default as though it were a
        // finding is how a learning feature earns distrust it cannot recover from.
        // No support count. It rendered as a bare "· 2" beside each value — a
        // vote tally, in a column of plain English, that a person cannot act on
        // and cannot interpret. How much evidence there is behind the card is
        // already stated once, in its header.
        func described<V>(_ trait: StyleTrait<V>, _ render: (V) -> String) -> String {
            guard let value = trait.value else { return "not learned yet" }
            return render(value)
        }
        let sentence = profile.sentenceLength.average.map { "\(Int($0.rounded())) words" } ?? "not learned yet"
        let rows: [(String, String)] = [
            ("Spelling", described(profile.spelling) { $0.title }),
            ("Contractions", described(profile.contractions) { $0 ? "Uses them" : "Avoids them" }),
            ("Formality", described(profile.formality) { $0.title }),
            ("Oxford comma", described(profile.oxfordComma) { $0 ? "Yes" : "No" }),
            ("Typical sentence", sentence),
        ]

        let accepted = profile.modelAccepted
        let reverted = profile.modelReverted
        let judged = accepted + reverted
        trust = SectionCard(style: style, title: "Do you keep what it writes?",
                            trailing: judged == 0 ? nil
                                : "\(Int(Double(accepted) / Double(judged) * 100))% kept")

        presets = SectionCard(style: style, title: "Tone",
                              trailing: "applies before anything is learned")
        chips = StylePreset.allCases.map {
            StyleToneRow(preset: $0, selected: $0 == profile.preset, style: style)
        }

        super.init(frame: .zero)
        addSubview(header)

        // Read fresh at click time rather than closed over the `profile`
        // parameter above: the button can sit on screen for a long time, and
        // the whole point of Style is that it keeps learning while it does.
        exportButton.onClick = {
            guard let (url, text) = VoiceExport.write(profile: StyleStore.shared.profile,
                                                       records: HistoryStore().all)
            else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        for (name, value) in rows {
            let row = SectionKeyValueRow(name, value, style: style,
                                         muted: value == "not learned yet")
            traits.add(row) { _ in SectionKeyValueRow.height }
        }

        // Its own row, its own confirmation, reachable from nowhere else. See
        // the comment on QuillData.files for why "Erase everything" and
        // "Uninstall" both leave this alone.
        let deleteRow = SectionButtonRow("Delete what's been learned",
                                         buttonTitle: "Delete…", style: style)
        deleteRow.button.onClick = { [weak self] in self?.confirmDeleteStyle() }
        traits.add(deleteRow) { _ in SectionButtonRow.height }

        let trustBody = DashboardType.label(
            judged == 0
              ? "Nothing to judge yet. This fills in as you accept or undo Quill's cleanup."
              // The second sentence — "the model is being too clever and the fast
              // pass should win more often" — is a note to whoever tunes the
              // cleanup, on a card a user reads to find out whether to trust it.
              : "\(accepted) kept, \(reverted) undone.",
            font: DashboardType.callout, color: style.inkSecondary, lines: 3, lineHeight: 19)
        trust.add(trustBody) { width in DashboardType.size(trustBody, width: width).height }

        // Rows, not a strip of four bare chips.
        //
        // `StylePreset.summary` has existed for the whole life of this screen —
        // "How you'd write to someone you know. Contractions, no sales voice." —
        // and nothing displayed it. So the one question a person actually has here
        // ("what does Casual DO to my text?") had no answer on the screen, while
        // the card holding the answer was 96 points tall in a 798-point page.
        //
        // Four titled rows is also how macOS picks between named modes.
        for chip in chips {
            presets.add(chip) { _ in StyleToneRow.height }
        }

        addSubview(traits)
        addSubview(trust)
        addSubview(presets)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Two questions, not one — the same shape `confirmErase` and
    /// `confirmUninstall` already use, for the same reason: refusable by
    /// someone who clicked it by accident, irreversible only for someone who
    /// meant it. What differs is the blast radius: this is the one button in
    /// the app that can only ever cost the learned voice, never a dictation,
    /// a snippet, a transform, or the app itself.
    private func confirmDeleteStyle() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete what Quill has learned about how you write?"
        alert.informativeText = "Spelling, tone, sentence length, the tone preset — all of it, back to "
            + "nothing learned. Your dictations, Dictionary and everything else stay exactly as they are. "
            + "There is no undo."
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.window.defaultButtonCell = alert.buttons.first?.cell as? NSButtonCell

        guard alert.runModal() == .alertSecondButtonReturn else { return }
        StyleStore.shared.reset()
        NotificationCenter.default.post(name: .quillDashboardNeedsReload, object: nil)
    }

    public override func layout() {
        super.layout()
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2
        guard width > 0 else { return }

        header.frame = NSRect(x: padX, y: padY, width: width, height: header.height)
        var y = DashboardSectionHeader.contentTop(for: header)

        // Two cards side by side, both as tall as the taller one's content, then
        // the tone strip under them at full width. Heights come from the cards
        // rather than from two constants that were 210 and 108 and left three
        // hundred points of nothing under the page.
        let gap = DashboardSpace.lg
        let half = ((width - gap) / 2).rounded(.down)
        let rowHeight = max(traits.fittedHeight(width: half), trust.fittedHeight(width: half))
        traits.frame = NSRect(x: padX, y: y, width: half, height: rowHeight)
        trust.frame = NSRect(x: padX + half + gap, y: y, width: width - half - gap, height: rowHeight)
        y += rowHeight + gap

        presets.frame = NSRect(x: padX, y: y, width: width,
                               height: presets.fittedHeight(width: width))
    }
}

/// One tone preset, as a row: what it is called, and what picking it does.
///
/// Drawn rather than a `HoverControl` with a label inside it, so the selected
/// state can be a filled surface rather than a border colour and the press can be
/// a scrim rather than an opacity change — which is the difference between this
/// and every other picker in the app looking like the same picker.
final class StyleToneRow: NSView {

    static let height: CGFloat = 44

    private let preset: StylePreset
    private let style: DashboardStyle
    private let selected: Bool
    private let title: NSTextField
    private let summary: NSTextField
    private let tick: DashboardIconView?

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

    init(preset: StylePreset, selected: Bool, style: DashboardStyle) {
        self.preset = preset
        self.style = style
        self.selected = selected
        title = DashboardType.label(preset.title,
                                    font: selected ? DashboardType.bodyMedium : DashboardType.body,
                                    color: style.ink)
        summary = DashboardType.label(preset.summary, font: DashboardType.caption,
                                      color: style.inkTertiary)
        // The tick, not a border. A selected row marked only by a coloured outline
        // disappears entirely on a Graphite accent, which is what this Mac is set
        // to — the same trap that made an "emphasised" metric read as the disabled
        // one on the record card.
        tick = selected
            ? DashboardIconView(image: DashboardIcon.image("checkmark", pointSize: 11,
                                                           weight: .bold, color: style.ink))
            : nil
        super.init(frame: .zero)
        addSubview(title)
        addSubview(summary)
        tick.map(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inset = DashboardSpace.sm
        let tickWidth: CGFloat = 24
        tick?.frame = NSRect(x: bounds.width - inset - tickWidth,
                             y: (bounds.height - 16) / 2, width: tickWidth, height: 16)

        let titleSize = title.fittingSize
        title.frame = NSRect(x: inset, y: ((bounds.height - titleSize.height) / 2).rounded(),
                             width: min(titleSize.width, bounds.width * 0.35), height: titleSize.height)
        let summarySize = summary.fittingSize
        let summaryX = inset + 108
        summary.frame = NSRect(x: summaryX,
                               y: ((bounds.height - summarySize.height) / 2).rounded(),
                               width: max(40, min(summarySize.width,
                                                  bounds.width - summaryX - inset - tickWidth - DashboardSpace.sm)),
                               height: summarySize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0, dy: 2)
        if selected {
            DashboardDraw.fill(body, radius: DashboardRadius.row, color: style.rowSelected)
        } else if hover.value > 0.001 {
            DashboardDraw.fill(body, radius: DashboardRadius.row, color: style.hover.faded(hover.value))
        }
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
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        StyleStore.shared.setPreset(preset)
        NotificationCenter.default.post(name: .quillDashboardNeedsReload, object: nil)
    }
}

// MARK: - Notetaker

/// Deliberately NOT built, and deliberately not faked.
///
/// Flow's Notetaker joins calendar meetings and records both sides of a call.
/// That needs system-audio capture (a TCC permission separate from the
/// microphone), calendar access, and a participant-consent story — none of which
/// exist here. A convincing-looking screen backed by nothing would have scored
/// well in review and been a lie in the app.
///
/// What changed is only how the absence is presented. It used to be a heading, a
/// four-line paragraph and a bulleted card jammed into the top quarter of the
/// page with four hundred and sixty points of nothing under them, which reads as
/// unfinished rather than as deliberate. The same words in the same centred card
/// every other empty screen uses read as a decision.
public final class NotetakerSectionView: NSView {

    private let header: DashboardSectionHeader
    private let message: DashboardMessageView

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle) {
        header = DashboardSectionHeader(title: "Notetaker", style: style)
        message = DashboardMessageView(
            symbol: "record.circle",
            title: "Not built yet",
            // Written for the person reading it, not for whoever built it. The
            // body used to spend its second sentence on why the team chose not to
            // fake the screen — which is a note to reviewers — and the three rows
            // named TCC permissions and speaker diarisation by their engineering
            // names. Same three facts, in the language of someone who wants to
            // record a meeting.
            body: "Quill can't sit in on a meeting yet. Three things have to land first.",
            steps: ["Hearing the other side of the call, not just your microphone.",
                    "Knowing from your calendar when a meeting starts.",
                    "Telling one voice from another in the transcript."],
            action: nil, actionSymbol: nil,
            style: style, elevation: .raised)
        super.init(frame: .zero)
        addSubview(header)
        addSubview(message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2
        guard width > 0 else { return }

        header.frame = NSRect(x: padX, y: padY, width: width, height: header.height)
        let top = DashboardSectionHeader.contentTop(for: header)
        let cardWidth: CGFloat = 560
        let cardHeight = message.fittingHeight(width: cardWidth)
        let room = max(200, bounds.height - top - padY)
        message.frame = NSRect(x: padX + ((width - cardWidth) / 2).rounded(),
                               y: top + ((room - cardHeight) * 0.42).rounded(),
                               width: cardWidth, height: cardHeight)
    }
}
