import AppKit

/// Transforms: one named reshaping of text, invoked by voice or by a chord.
///
/// The engine behind this screen has existed for some time — 1,300 lines of
/// routing, length guards, vocabulary preservation and offline recipes — with no
/// way to see or change any of it. So this is not a new feature; it is the
/// missing window onto one, and the job is to expose what is already true rather
/// than to invent a second model of it.
///
/// Flow ships six transforms (Polish, Prompt Engineer, Turn to List, Translate,
/// Empathize, Custom) and, being cloud-only, has nothing to say when the network
/// is gone. Every transform here names what it does without a network and how
/// far short of the full job that falls. That column is the one Flow cannot fill
/// in, so it is the one this screen leads with.
public final class TransformsSectionView: NSView {

    private let style: DashboardStyle
    private let store: TransformStore
    private var transforms: [Transform]
    private var selected: Transform?

    private let scroll = NSScrollView()
    private let listDocument = TransformsFlippedView()
    private var header: DashboardSectionHeader!
    private let listRule: DashboardRule
    private var hero: TransformDetailView?
    private var rows: [TransformRowView] = []

    public override var isFlipped: Bool { true }

    public convenience init(style: DashboardStyle) {
        self.init(style: style, store: .shared)
    }

    public init(style: DashboardStyle, store: TransformStore) {
        self.style = style
        self.store = store
        self.transforms = store.ordered
        self.selected = transforms.first
        listRule = DashboardRule(color: style.hairline)
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    private func build() {
        // How many of them survive with no network. The one number on this screen
        // worth putting in the header, because it is the claim Flow cannot make.
        //
        // It used to be constrained to the title's trailing edge and its baseline,
        // which put it halfway across the window on a line of its own, aligned to
        // nothing — the shared header carries it as a meta line now, in the same
        // place every other section puts one.
        let offlineCount = transforms.filter(\.worksOffline).count
        header = DashboardSectionHeader(
            title: "Transforms",
            meta: "\(transforms.count) transforms  \u{00B7}  \(offlineCount) work offline",
            style: style)
        addSubview(header)

        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.documentView = listDocument

        addSubview(listRule)
        addSubview(scroll)

        rebuildList()
        rebuildDetail()
    }

    private func rebuildList() {
        rows.forEach { $0.removeFromSuperview() }
        rows = transforms.enumerated().map { index, transform in
            let row = TransformRowView(transform: transform, style: style)
            row.isSelected = transform.id == selected?.id
            row.showsSeparator = index < transforms.count - 1
            row.onClick = { [weak self] in
                guard let self else { return }
                self.selected = transform
                self.rows.forEach { $0.isSelected = $0.transform.id == transform.id }
                self.rebuildDetail()
            }
            row.onToggle = { [weak self] isOn in
                guard let self else { return }
                var edited = transform
                edited.isEnabled = isOn
                _ = self.store.upsert(edited)
                self.transforms = self.store.ordered
                if self.selected?.id == edited.id { self.selected = edited }
                self.rebuildDetail()
            }
            listDocument.addSubview(row)
            return row
        }
        needsLayout = true
    }

    /// Cross-fade the open transform, the same way Dictation swaps its record.
    private func rebuildDetail() {
        let outgoing = hero
        hero = nil
        guard let transform = selected else {
            outgoing?.removeFromSuperview()
            needsLayout = true
            return
        }
        let body = TransformDetailView(transform: transform, style: style)
        addSubview(body)
        hero = body
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard !DashboardMotion.isReduced, outgoing != nil else {
            outgoing?.removeFromSuperview()
            return
        }
        body.alphaValue = 0
        DashboardMotion.spring(DashboardMotion.selectSpring) { _ in
            body.animator().alphaValue = 1
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

        // The same shape as Dictation, and for the same reason. This was a 340pt
        // list beside a half-window card: eight rows in a well tall enough for
        // eighteen, next to a card holding four short paragraphs in seven hundred
        // points of height. Both halves were mostly empty at once.
        //
        // A transform list has one axis, so it is a column: the open transform is
        // a hero sized to what is in it, and the list underneath takes whatever
        // height is left and can never leave a hole.
        if let hero {
            let height = hero.fittingHeight(width: width)
            hero.frame = NSRect(x: padX, y: y, width: width, height: height)
            y += height + DashboardSpace.xl
        }

        listRule.frame = NSRect(x: padX, y: y, width: width, height: 1)
        y += 1

        let listHeight = max(0, bounds.height - y - padY)
        scroll.frame = NSRect(x: padX, y: y, width: width, height: listHeight)

        var rowY: CGFloat = 0
        for row in rows {
            let h = row.preferredHeight(width: width)
            row.frame = NSRect(x: 0, y: rowY, width: width, height: h)
            rowY += h
        }
        listDocument.frame = NSRect(x: 0, y: 0, width: width, height: rowY + DashboardSpace.md)
    }
}

final class TransformsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Row

/// One transform in the list: name, how it is invoked, and whether it is on.
final class TransformRowView: NSView {

    let transform: Transform
    var onClick: (() -> Void)?
    var onToggle: ((Bool) -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { rebuild() } } }
    var showsSeparator = true { didSet { needsDisplay = true } }

    private let style: DashboardStyle
    private let name: NSTextField
    private let meta: NSTextField
    private let toggle: DashboardSwitch
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

    init(transform: Transform, style: DashboardStyle) {
        self.transform = transform
        self.style = style
        name = DashboardType.label(transform.name, font: DashboardType.bodyMedium, color: style.ink)
        // How you actually fire it. A transform with neither a chord nor a spoken
        // trigger is unreachable, and saying so here is more useful than a tidy
        // blank.
        let invocation: String
        if let hotkey = transform.hotkey {
            invocation = hotkey.displayName
        } else if let first = transform.triggers.first {
            invocation = "“\(first)”"
        } else {
            invocation = "no trigger yet"
        }
        // "offline" leads, and the trigger phrase follows.
        //
        // As a suffix it truncated to "off…" at a narrow window, which reads as
        // the exact opposite of what it means — the transform being switched off,
        // beside a switch. The rule the rest of this window follows applies here
        // too: the part that carries meaning keeps its width and the prose gives
        // way, so the word that can be misread is the one that cannot be cut.
        let prefix = transform.worksOffline ? "offline  ·  " : ""
        meta = DashboardType.label(prefix + invocation,
                                   font: DashboardType.caption, color: style.inkTertiary)
        toggle = DashboardSwitch(isOn: transform.isEnabled, style: style)
        super.init(frame: .zero)
        addSubview(name)
        addSubview(meta)
        addSubview(toggle)
        toggle.onToggle = { [weak self] on in self?.onToggle?(on) }
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func preferredHeight(width: CGFloat) -> CGFloat { 56 }

    private func rebuild() {
        DashboardType.recolor(name, isSelected ? style.ink : style.inkSecondary)
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let toggleSize = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: bounds.width - pad - toggleSize.width,
                              y: ((bounds.height - toggleSize.height) / 2).rounded(),
                              width: toggleSize.width, height: toggleSize.height)

        let x = pad
        let available = max(0, toggle.frame.minX - x - DashboardSpace.sm)
        let nameSize = name.fittingSize
        name.frame = NSRect(x: x, y: 11, width: min(nameSize.width, available), height: nameSize.height)
        let metaSize = meta.fittingSize
        meta.frame = NSRect(x: x, y: 31, width: min(metaSize.width, available), height: metaSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The same treatment a dictation row gets, and that is the point: two
        // full-width lists in one app drew their selection two different ways.
        //
        // This used `raisedSurface`, which strokes a hairline around the fill —
        // and `style.raised` in light mode is 75% white on a white page, so the
        // fill vanished and only the stroke survived. The selected row read as an
        // outlined BOX rather than a highlighted row, in light mode only.
        let body = bounds.insetBy(dx: 0, dy: 1)
        if isSelected {
            DashboardDraw.fill(body, radius: DashboardRadius.row, color: style.raised)
            NSGraphicsContext.saveGraphicsState()
            DashboardDraw.path(body, DashboardRadius.row).addClip()
            style.accent.setFill()
            NSRect(x: body.minX, y: body.minY, width: 2.5, height: body.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else if hover.value > 0.001 {
            DashboardDraw.fill(body, radius: DashboardRadius.row, color: style.hover.faded(hover.value))
        }
        if press.value > 0.001 {
            DashboardDraw.fill(body, radius: DashboardRadius.row,
                               color: NSColor(white: style.isDark ? 1 : 0, alpha: 0.07 * press.value))
        }
        // No separator between rows. Roman asked for that twice about the
        // dictation list, and the argument is the same here: each row is two
        // lines with its own hierarchy, so the vertical rhythm already separates
        // them and a rule between every pair turns a list into a table.
        _ = showsSeparator
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
    override func mouseDown(with event: NSEvent) {
        isPressed = !toggle.frame.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        let point = convert(event.locationInWindow, from: nil)
        // The switch is a control inside a row that is itself a control. Let it
        // have its own clicks, or turning a transform off also selects it.
        guard bounds.contains(point), !toggle.frame.contains(point) else { return }
        onClick?()
    }
}

// MARK: - Detail

/// What the selected transform actually does, in the order someone asks it:
/// what it is for, how to fire it, what it does with no network, and what it is
/// forbidden from doing to the text.
final class TransformDetailView: NSView {

    private let style: DashboardStyle
    private let transform: Transform
    /// Kept as (view, isHeading) pairs rather than inferred later from the font.
    /// The first version compared `field.font` against `DashboardType.headline`,
    /// which is a computed property handing back a fresh NSFont each call — an
    /// identity test that is true only by luck of caching. Spacing that depends
    /// on luck is spacing that will be wrong on someone else's machine.
    private var blocks: [(view: NSTextField, isHeading: Bool)] = []

    override var isFlipped: Bool { true }

    init(transform: Transform, style: DashboardStyle) {
        self.transform = transform
        self.style = style
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        add(DashboardType.label(transform.name, font: DashboardType.title, color: style.ink))

        // The first sentence of the instruction, not the whole thing.
        //
        // `instruction` is the system prompt handed to the model — an order,
        // written for a model, several sentences long: "Rewrite the text as a
        // bullet list. One point per line, each line starting with '- '. Keep
        // every fact and every name; do not add, merge or invent points. No
        // heading, no preamble." The first sentence is the description; the rest
        // is prompt engineering on a screen a person reads to decide whether to
        // use a feature.
        add(DashboardType.label(TransformDetailView.firstSentence(of: transform.instruction),
                                font: DashboardType.body, color: style.inkSecondary, lines: 2,
                                lineHeight: 20))

        heading("How to run it")
        var invocations: [String] = []
        if let hotkey = transform.hotkey { invocations.append("Press \(hotkey.displayName)") }
        if transform.triggers.isEmpty {
            invocations.append("no spoken trigger yet")
        } else {
            // Every phrase, not a sample. These are matched exactly — that is what
            // makes them safe to say mid-sentence — so a user who only sees three
            // of seven will believe the other four do not work. Wrapped as one
            // paragraph rather than stacked one per line: seven lines of quoted
            // fragments is a column of noise, and the same seven read fine as a
            // sentence.
            invocations.append(transform.triggers.map { "\u{201C}\($0)\u{201D}" }
                                .joined(separator: "   \u{00B7}   "))
        }
        add(DashboardType.label(invocations.joined(separator: "   \u{00B7}   "),
                                font: DashboardType.callout, color: style.inkSecondary,
                                lines: 3, lineHeight: 19))

        heading("With no network")
        if transform.worksOffline {
            let limit = transform.offline.limitation
            add(DashboardType.label(
                limit == nil ? "\(transform.offline.title). No approximation — this is the whole job."
                             : "\(transform.offline.title) — \(limit!). Quill says so when it runs.",
                font: DashboardType.callout, color: style.inkSecondary, lines: 3, lineHeight: 19))
        } else {
            // Named plainly. A transform that silently does nothing offline is
            // worse than one that refuses, and this is the screen where the user
            // finds out which they have.
            add(DashboardType.label(
                "This one refuses. There is no honest deterministic version of it, so offline it says so rather than returning something close.",
                font: DashboardType.callout, color: style.inkTertiary, lines: 3, lineHeight: 19))
        }

        // The "Guards" section is gone, and this is the cut Roman asked for by
        // name: *"I don't really want any unneeded little bits of information or
        // little bits of text. Only the things that the average user is actually
        // going to use."*
        //
        // It printed three lines of engineering: that the dictionary is checked
        // after the round trip rather than asked for in the prompt, and that a
        // result is refused under 60% or over 160% of the original length. Those
        // are real and they still run — they are just implementation, and nobody
        // reading "what does Shorter do" has a decision to make about a ratio.
        //
        // What survives is the one line that changes what the user does: which
        // text the transform will act on.
        let usage = transform.useCount > 0
            ? "Reads \(transform.target.title.lowercased())  \u{00B7}  used \(transform.useCount) time\(transform.useCount == 1 ? "" : "s")"
            : "Reads \(transform.target.title.lowercased())"
        add(DashboardType.label(usage, font: DashboardType.caption, color: style.inkQuaternary))
    }

    /// Up to the first full stop, keeping the stop. Falls back to the whole
    /// string when there is no sentence break to find.
    static func firstSentence(of text: String) -> String {
        guard let stop = text.firstIndex(of: ".") else { return text }
        return String(text[...stop])
    }

    /// The height this transform wants, so the page can size the hero to it
    /// rather than stretching it to fill a half-window card.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let pad = DashboardSpace.lg
        let inner = max(40, width - pad * 2)
        var height = pad
        for (index, block) in blocks.enumerated() {
            if block.isHeading, index > 0 { height += DashboardSpace.md }
            height += DashboardType.size(block.view, width: inner).height + DashboardSpace.xs
        }
        return ceil(height + pad - DashboardSpace.xs)
    }

    private func heading(_ text: String) {
        let field = DashboardType.label(text, font: DashboardType.headline, color: style.ink)
        addSubview(field)
        blocks.append((field, true))
    }

    private func add(_ field: NSTextField) {
        addSubview(field)
        blocks.append((field, false))
    }

    override func layout() {
        super.layout()
        let pad = DashboardSpace.lg
        let width = max(0, bounds.width - pad * 2)
        var y = pad
        for (index, block) in blocks.enumerated() {
            let height = DashboardType.size(block.view, width: width).height
            // Space above a heading, not below it, so a heading sits with the
            // paragraph it introduces rather than floating between two.
            if block.isHeading, index > 0 { y += DashboardSpace.md }
            block.view.frame = NSRect(x: pad, y: y, width: width, height: height)
            y += height + DashboardSpace.xs
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // A tint of the page rather than a slab on it, the same as the Dictation
        // record. This used to be a subview of a `DashboardCardView`, which drew
        // the surface for it; standing on the page it has to draw its own.
        DashboardDraw.fill(bounds, radius: DashboardRadius.card, color: style.card)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.card, color: style.hairline)
    }
}
