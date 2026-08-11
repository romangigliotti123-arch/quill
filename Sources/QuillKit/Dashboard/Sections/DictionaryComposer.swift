import AppKit

/// Adding a word, and being shown which words are worth adding.
///
/// The Dictionary shipped with an "Add word" button and an "Import" button and
/// no handler behind either of them. They drew, they highlighted on hover, and
/// clicking them did nothing — on the screen whose entire purpose is maintaining
/// the list those buttons edit.
///
/// This is the panel behind both. It opens in place rather than as a sheet: a
/// modal over a screen that is already a form is a second context to get out of,
/// and the thing being added is one short string.
///
/// Import is not a file picker. The words a developer needs in a dictionary are
/// the names of their own projects, and those are already on the disk — so
/// Import reads the folder names under the projects directories and proposes the
/// ones that are not ordinary English. Nothing is added without a click, because
/// a dictionary that grows by itself starts rewriting speech into terms the user
/// never chose. See VocabularyHarvest for what it is allowed to read: names,
/// never contents, and never off this machine.
final class DictionaryComposer: NSView {

    /// More than this and the panel is taller than the screen it opens on.
    static let maximumChips = 24

    enum Mode {
        case add
        case suggestions([VocabularyHarvest.Suggestion])
    }

    /// Called with the term once it has been written to the vocabulary file.
    var onAdded: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private let style: DashboardStyle
    let mode: Mode
    private let book: VocabularyBook

    private let heading: NSTextField
    private let note: NSTextField
    private let field: SnippetsField?
    private let saveButton: DashboardButton?
    private let closeButton: DashboardButton
    private var chips: [DictionarySuggestionChip] = []

    override var isFlipped: Bool { true }

    init(mode: Mode, style: DashboardStyle, book: VocabularyBook = .shared) {
        self.style = style
        self.mode = mode
        self.book = book

        switch mode {
        case .add:
            heading = DashboardType.label("Add a word", font: DashboardType.title, color: style.ink)
            note = DashboardType.label(
                "A name the recogniser keeps getting wrong. Quill repairs it after transcription, so it works on the next dictation — no relaunch.",
                font: DashboardType.caption, color: style.inkSecondary, lines: 2, lineHeight: 17)
            field = SnippetsField(style: style, placeholder: "Craigieburn", badgeSymbol: "textformat.abc")
            saveButton = DashboardButton(title: "Add", symbol: "plus", kind: .primary, style: style)
        case .suggestions(let found):
            heading = DashboardType.label(
                found.isEmpty ? "Nothing new found" : "Found \(found.count) on this Mac",
                font: DashboardType.title, color: style.ink)
            // Say when the list is cut off. A panel that shows 24 of 37 and does
            // not mention the other 13 reads as "this is everything".
            let shown = min(found.count, DictionaryComposer.maximumChips)
            let capped = found.count > shown ? " Showing the first \(shown)." : ""
            note = DashboardType.label(
                found.isEmpty
                    ? "Every project name Quill could see is already in your dictionary."
                    : "Folder and package names from your projects, minus anything that is ordinary English. Click one to add it — nothing is added on its own.\(capped)",
                font: DashboardType.caption, color: style.inkSecondary, lines: 2, lineHeight: 17)
            field = nil
            saveButton = nil
        }
        closeButton = DashboardButton(title: "Done", symbol: "xmark", kind: .secondary, style: style)

        super.init(frame: .zero)
        wantsLayer = true

        addSubview(heading)
        addSubview(note)
        field.map(addSubview)
        saveButton.map(addSubview)
        addSubview(closeButton)

        if case .suggestions(let found) = mode {
            for suggestion in found.prefix(DictionaryComposer.maximumChips) {
                let chip = DictionarySuggestionChip(suggestion: suggestion, style: style)
                chip.onClick = { [weak self, weak chip] in
                    guard let self, let chip, !chip.isAdded else { return }
                    if self.book.add(suggestion.term) {
                        chip.markAdded()
                        self.onAdded?(suggestion.term)
                    }
                }
                addSubview(chip)
                chips.append(chip)
            }
        }

        field?.onCommit = { [weak self] in self?.commit() }
        saveButton?.onClick = { [weak self] in self?.commit() }
        closeButton.onClick = { [weak self] in self?.onDismiss?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func focus() { field.map { window?.makeFirstResponder($0.subviews.compactMap { $0 as? NSTextField }.first) } }

    private func commit() {
        guard let field else { return }
        let term = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if book.add(term) {
            field.text = ""
            onAdded?(term)
        } else {
            // Already present, or the write failed. Saying nothing here would
            // read as "added" and the word would appear to have vanished.
            note.stringValue = "\"\(term)\" is already in your dictionary."
            needsLayout = true
        }
    }

    /// Height this panel needs at a given width. The section asks before laying
    /// out, so the list below it moves by exactly the right amount.
    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = width - 40
        var y: CGFloat = 18 + heading.fittingSize.height + 6
        y += DashboardType.size(note, width: inner - 90).height
        switch mode {
        case .add:
            y += 14 + 36
        case .suggestions:
            y += 14 + chipRows(width: inner).height
        }
        return y + 18
    }

    override func layout() {
        super.layout()
        let padX: CGFloat = 20
        let inner = bounds.width - padX * 2
        var y: CGFloat = 18

        let closeWidth = closeButton.intrinsicWidth
        closeButton.frame = NSRect(x: bounds.width - padX - closeWidth, y: y - 2,
                                   width: closeWidth, height: 32)

        let headingSize = heading.fittingSize
        heading.frame = NSRect(x: padX, y: y, width: headingSize.width, height: headingSize.height)
        y += headingSize.height + 6

        let noteWidth = inner - closeWidth - 16
        let noteHeight = DashboardType.size(note, width: noteWidth).height
        note.frame = NSRect(x: padX, y: y, width: noteWidth, height: noteHeight)
        y += noteHeight + 14

        if let field, let saveButton {
            let saveWidth = saveButton.intrinsicWidth
            field.frame = NSRect(x: padX, y: y, width: inner - saveWidth - 10, height: 36)
            saveButton.frame = NSRect(x: bounds.width - padX - saveWidth, y: y,
                                      width: saveWidth, height: 36)
        } else {
            let rows = chipRows(width: inner)
            for (chip, origin) in zip(chips, rows.origins) {
                chip.frame = NSRect(x: padX + origin.x, y: y + origin.y,
                                    width: chip.intrinsicWidth, height: 30)
            }
        }
    }

    /// Wrapped flow layout for the suggestion chips. Names vary wildly in length,
    /// so a fixed grid would either clip "roman design co" or leave a column of
    /// air beside "nxt".
    private func chipRows(width: CGFloat) -> (height: CGFloat, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        for chip in chips {
            let chipWidth = chip.intrinsicWidth
            if x > 0, x + chipWidth > width {
                x = 0
                y += 38
            }
            origins.append(CGPoint(x: x, y: y))
            x += chipWidth + 8
        }
        return (chips.isEmpty ? 0 : y + 30, origins)
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.fill(bounds, radius: DashboardRadius.card, color: style.raised)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.card, color: style.hairline, width: 1)
    }
}

/// One proposed term. Clicking adds it; it then says so and stops responding,
/// because a chip that still looks clickable after it has been used invites the
/// user to wonder whether the first click worked.
final class DictionarySuggestionChip: NSView {

    var onClick: (() -> Void)?
    private(set) var isAdded = false

    private let label: NSTextField
    private let icon: DashboardIconView
    private let style: DashboardStyle
    private var isHovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    var intrinsicWidth: CGFloat { 30 + ceil(label.fittingSize.width) + 14 }

    init(suggestion: VocabularyHarvest.Suggestion, style: DashboardStyle) {
        self.style = style
        label = DashboardType.label(suggestion.term, font: DashboardType.caption, color: style.ink)
        icon = DashboardIconView(image: DashboardIcon.image(
            "plus", pointSize: 10, weight: .bold, color: style.inkSecondary))
        super.init(frame: .zero)
        toolTip = suggestion.source
        addSubview(icon)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func markAdded() {
        isAdded = true
        DashboardType.recolor(label, style.accentInk)
        icon.image = DashboardIcon.image("checkmark", pointSize: 10, weight: .bold, color: style.accentInk)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: ((bounds.height - 14) / 2).rounded(), width: 14, height: 14)
        let size = label.fittingSize
        label.frame = NSRect(x: 30, y: ((bounds.height - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracking.map(removeTrackingArea)
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { if !isAdded { isHovered = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        guard !isAdded, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isAdded ? style.accentSoft : (isHovered ? style.raisedTop : style.raised)
        DashboardDraw.fill(bounds, radius: DashboardRadius.control, color: fill)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.control,
                             color: isAdded ? style.accentSoft : style.hairline, width: 1)
    }
}
