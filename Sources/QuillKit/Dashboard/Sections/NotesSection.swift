import AppKit

// The Notes screen.
//
// Two fields and nothing else: a title and a place to talk into. No folders,
// no tags, no formatting, no manual save button — the body is a real
// `NSTextView`, so holding the dictation key while it's focused inserts text
// through the exact same path as dictating into any other app. That is the
// entire feature; everything else here is just enough chrome to create one,
// find it again, and delete it.

/// One row in the list: title, when it was last touched, delete.
final class NoteRowView: NSView {

    private let title: NSTextField
    private let subtitle: NSTextField
    private let deleteButton: DashboardButton
    private let rule: DashboardRule
    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hover.animate(to: isHovered ? 1 : 0)
        }
    }
    private lazy var hover = DashboardTween(view: self)
    private let style: DashboardStyle

    static let height: CGFloat = 56

    override var isFlipped: Bool { true }

    init(note: Note, style: DashboardStyle) {
        self.style = style
        title = DashboardType.label(note.displayTitle, font: DashboardType.bodyMedium, color: style.ink)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        subtitle = DashboardType.label("Edited \(formatter.localizedString(for: note.updated, relativeTo: Date()))",
                                       font: DashboardType.caption, color: style.inkTertiary)
        deleteButton = DashboardButton(title: "Delete", symbol: "trash", kind: .ghost, style: style)
        rule = DashboardRule(color: style.hairline)
        super.init(frame: .zero)
        addSubview(title)
        addSubview(subtitle)
        addSubview(deleteButton)
        addSubview(rule)
        deleteButton.onClick = { [weak self] in self?.onDelete?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let deleteWidth = deleteButton.intrinsicWidth
        deleteButton.frame = NSRect(x: bounds.width - deleteWidth, y: (Self.height - 28) / 2,
                                    width: deleteWidth, height: 28)
        let inner = bounds.width - deleteWidth - DashboardSpace.sm
        let titleSize = title.fittingSize
        title.frame = NSRect(x: 0, y: 10, width: min(titleSize.width, inner), height: titleSize.height)
        let subtitleSize = subtitle.fittingSize
        subtitle.frame = NSRect(x: 0, y: 30, width: min(subtitleSize.width, inner), height: subtitleSize.height)
        rule.frame = NSRect(x: 0, y: Self.height - 1, width: bounds.width, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hover.value > 0.001 else { return }
        DashboardDraw.fill(NSRect(x: -8, y: 0, width: bounds.width + 16, height: Self.height - 1),
                           radius: DashboardRadius.row, color: style.hover.faded(hover.value))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { isHovered = false; NSCursor.arrow.set() }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), !deleteButton.frame.contains(point) else { return }
        onOpen?()
    }
}

/// The title-and-body editor, always full-width, replacing the list rather
/// than sitting beside it — one thing on screen at a time, matching how
/// simple the feature itself is.
final class NoteEditorView: NSView {

    var onChange: ((Note) -> Void)?
    var onDelete: (() -> Void)?
    var onBack: (() -> Void)?

    private var note: Note
    private let backButton: DashboardButton
    private let titleField: SnippetsField
    private let deleteButton: DashboardButton
    private let card: DashboardCardView
    private let body: SnippetsTextArea
    private var saveTimer: Timer?

    override var isFlipped: Bool { true }

    init(note: Note, style: DashboardStyle) {
        self.note = note
        backButton = DashboardButton(title: "Notes", symbol: "chevron.left", kind: .ghost, style: style)
        titleField = SnippetsField(style: style, placeholder: "Untitled note",
                                   font: DashboardType.title, badgeSymbol: nil)
        deleteButton = DashboardButton(title: "Delete", symbol: "trash", kind: .ghost, style: style)
        card = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        body = SnippetsTextArea(style: style, placeholder: "Hold \u{2325} anywhere in here and start talking.")

        super.init(frame: .zero)
        addSubview(backButton)
        addSubview(titleField)
        addSubview(deleteButton)
        addSubview(card)
        card.addSubview(body)

        titleField.text = note.title
        body.text = note.body

        backButton.onClick = { [weak self] in self?.onBack?() }
        deleteButton.onClick = { [weak self] in self?.onDelete?() }
        titleField.onChange = { [weak self] _ in self?.scheduleSave() }
        body.onChange = { [weak self] _ in self?.scheduleSave() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { saveTimer?.invalidate() }

    /// A new, still-blank note opens ready to be named — the flow Roman
    /// described, "they can name it and then start talking in it."
    func focusTitle() {
        titleField.window?.makeFirstResponder(titleField)
    }

    /// The quick-capture path from the overlay button or its hotkey: the
    /// note already exists and the point is to start talking immediately,
    /// so this focuses the body instead of the title.
    func focusBody() {
        body.window?.makeFirstResponder(body)
    }

    /// Half a second after the last keystroke — long enough that a fast
    /// typist or an in-progress dictation doesn't write to disk on every
    /// character, short enough that closing the note a moment later never
    /// loses anything.
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.commit()
        }
    }

    private func commit() {
        note.title = titleField.text
        note.body = body.text
        onChange?(note)
    }

    /// Called right before the editor is torn down, so navigating away
    /// immediately after typing never loses the debounce window.
    func flush() {
        guard saveTimer != nil else { return }
        saveTimer?.invalidate()
        saveTimer = nil
        commit()
    }

    override func layout() {
        super.layout()
        let backWidth = backButton.intrinsicWidth
        backButton.frame = NSRect(x: 0, y: 0, width: backWidth, height: 28)
        let deleteWidth = deleteButton.intrinsicWidth
        deleteButton.frame = NSRect(x: bounds.width - deleteWidth, y: 0, width: deleteWidth, height: 28)

        var y: CGFloat = 28 + DashboardSpace.md
        titleField.frame = NSRect(x: 0, y: y, width: bounds.width, height: 40)
        y += 40 + DashboardSpace.md

        card.frame = NSRect(x: 0, y: y, width: bounds.width, height: bounds.height - y)
    }
}

/// The Notes tab itself: empty state, list, or editor — exactly one at a time.
public final class NotesSectionView: NSView {

    private let store: NoteStore
    private let style: DashboardStyle

    private var header: DashboardSectionHeader!
    private let newButton: DashboardButton

    private let scroll = NSScrollView()
    private let content = SettingsFlippedView()
    private var rows: [NoteRowView] = []
    private var notes: [Note] = []

    private var emptyState: DashboardMessageView?
    private var editor: NoteEditorView?
    private var openNoteID: UUID?
    /// Set right after creating a note, so its editor focuses the title
    /// instead of the body — see `NoteEditorView.focusTitle()`.
    private var shouldFocusTitleOnOpen = false

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle, store: NoteStore = .shared) {
        self.style = style
        self.store = store
        newButton = DashboardButton(title: "New note", symbol: "plus", kind: .primary, style: style)
        super.init(frame: .zero)
        wantsLayer = true

        header = DashboardSectionHeader(title: "Notes", trailing: [newButton], style: style)
        addSubview(header)

        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.documentView = content
        addSubview(scroll)

        newButton.onClick = { [weak self] in self?.createNote() }

        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - State

    private func reload() {
        notes = store.ordered
        rebuild()
    }

    private func createNote() {
        let created = store.upsert(Note())
        notes = store.ordered
        shouldFocusTitleOnOpen = true
        open(created.id)
    }

    private func open(_ id: UUID) {
        guard let note = store.note(id: id) else { return }
        editor?.flush()
        openNoteID = id
        newButton.isHidden = true

        let view = NoteEditorView(note: note, style: style)
        view.onChange = { [weak self] updated in
            self?.store.upsert(updated)
        }
        view.onBack = { [weak self] in self?.closeEditor() }
        view.onDelete = { [weak self] in self?.deleteOpenNote() }
        content.subviews.forEach { $0.removeFromSuperview() }
        content.addSubview(view)
        editor = view
        scroll.isHidden = false

        if shouldFocusTitleOnOpen { view.focusTitle() } else { view.focusBody() }
        shouldFocusTitleOnOpen = false
        needsLayout = true
    }

    private func closeEditor() {
        editor?.flush()
        editor = nil
        openNoteID = nil
        newButton.isHidden = false
        reload()
    }

    private func deleteOpenNote() {
        guard let id = openNoteID else { return }
        store.remove(id: id)
        closeEditor()
    }

    private func rebuild() {
        content.subviews.forEach { $0.removeFromSuperview() }
        rows = []

        if notes.isEmpty {
            newButton.isHidden = false
            scroll.isHidden = true
            let view = DashboardMessageView(symbol: "note.text",
                                            title: "No notes yet",
                                            body: "A place to talk into that isn't any particular app \u{2014} "
                                                + "a list, an idea, a draft that doesn't have a home yet.",
                                            steps: [],
                                            action: "New note",
                                            actionSymbol: "plus",
                                            style: style,
                                            elevation: .raised)
            view.onAction = { [weak self] in self?.createNote() }
            addSubview(view)
            emptyState = view
            needsLayout = true
            return
        }

        emptyState?.removeFromSuperview()
        emptyState = nil
        scroll.isHidden = false
        for note in notes {
            let row = NoteRowView(note: note, style: style)
            row.onOpen = { [weak self] in self?.open(note.id) }
            row.onDelete = { [weak self] in
                self?.store.remove(id: note.id)
                self?.reload()
            }
            content.addSubview(row)
            rows.append(row)
        }
        needsLayout = true
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2
        guard width > 0 else { return }

        header.frame = NSRect(x: padX, y: padY, width: width, height: header.height)
        let top = DashboardSectionHeader.contentTop(for: header)

        if let emptyState {
            let cardWidth: CGFloat = 520
            let cardHeight = emptyState.fittingHeight(width: cardWidth)
            let room = max(200, bounds.height - top - padY)
            emptyState.frame = NSRect(x: padX + ((width - cardWidth) / 2).rounded(),
                                      y: top + ((room - cardHeight) * 0.42).rounded(),
                                      width: cardWidth, height: cardHeight)
            return
        }

        scroll.frame = NSRect(x: padX, y: top, width: width, height: bounds.height - top - padY)

        if let editor {
            editor.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height - top - padY)
            content.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.bounds.height, editor.frame.height))
            return
        }

        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: NoteRowView.height)
            y += NoteRowView.height
        }
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.bounds.height, y))
    }
}
