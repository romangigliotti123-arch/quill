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
    private let header = NSView()
    private let listWell: DashboardCardView
    private let detail: DashboardCardView
    private var detailBody: NSView?
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
        listWell = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        detail = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    private func build() {
        let title = DashboardType.label("Transforms", font: DashboardType.display, color: style.ink)
        title.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        addSubview(header)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            title.topAnchor.constraint(equalTo: header.topAnchor),
            title.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        // How many of them survive with no network. The one number on this screen
        // worth putting in the header, because it is the claim Flow cannot make.
        let offlineCount = transforms.filter(\.worksOffline).count
        let counter = DashboardType.label(
            "\(transforms.count) transforms · \(offlineCount) work offline",
            font: DashboardType.caption, color: style.inkTertiary)
        counter.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(counter)
        NSLayoutConstraint.activate([
            counter.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: DashboardSpace.sm),
            counter.lastBaselineAnchor.constraint(equalTo: title.lastBaselineAnchor),
        ])

        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.documentView = listDocument

        addSubview(listWell)
        listWell.addSubview(scroll)
        addSubview(detail)

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

    private func rebuildDetail() {
        detailBody?.removeFromSuperview()
        guard let transform = selected else {
            let empty = DashboardType.label("Nothing selected", font: DashboardType.callout,
                                            color: style.inkTertiary, alignment: .center)
            detail.addSubview(empty)
            detailBody = empty
            needsLayout = true
            return
        }
        let body = TransformDetailView(transform: transform, style: style)
        detail.addSubview(body)
        detailBody = body
        needsLayout = true
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2
        guard width > 0 else { return }

        header.frame = NSRect(x: padX, y: padY, width: width, height: 26)
        let top = padY + 26 + DashboardSpace.lg
        let bottom = bounds.height - padY
        let height = max(120, bottom - top)

        // The list keeps a workable width and the detail takes the rest, with a
        // floor under the list so a narrow window truncates names rather than
        // reducing the column to a strip of initials.
        let listWidth = max(240, min(340, (width - DashboardSpace.md) * 0.36))
        listWell.frame = NSRect(x: padX, y: top, width: listWidth, height: height)
        scroll.frame = listWell.bounds
        detail.frame = NSRect(x: padX + listWidth + DashboardSpace.md, y: top,
                              width: width - listWidth - DashboardSpace.md, height: height)
        detailBody?.frame = detail.bounds

        var y: CGFloat = 0
        for row in rows {
            let h = row.preferredHeight(width: listWidth)
            row.frame = NSRect(x: 0, y: y, width: listWidth, height: h)
            y += h
        }
        listDocument.frame = NSRect(x: 0, y: 0, width: listWidth, height: max(y, listWell.bounds.height))
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
    private lazy var hover = DashboardTween(view: self)

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
        if isSelected {
            let pill = NSRect(x: 6, y: 3, width: bounds.width - 12, height: bounds.height - 6)
            DashboardDraw.raisedSurface(pill, radius: DashboardRadius.row,
                                        fillColor: style.raised, topColor: style.raisedTop,
                                        style: style, shadow: style.shadowRaised, flipped: true)
        } else if hover.value > 0.001 {
            DashboardDraw.fill(NSRect(x: 6, y: 3, width: bounds.width - 12, height: bounds.height - 6),
                               radius: DashboardRadius.row, color: style.hover.faded(hover.value))
        }
        guard !isSelected, showsSeparator, hover.value < 1 else { return }
        style.hairline.faded(1 - hover.value).setFill()
        NSRect(x: 14, y: bounds.height - 1, width: bounds.width - 28, height: 1).fill()
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
        NSCursor.arrow.set()
    }
    override func mouseUp(with event: NSEvent) {
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
        let title = DashboardType.label(transform.name, font: DashboardType.title, color: style.ink)
        add(title)

        if transform.isBuiltIn {
            add(DashboardType.label("Built in", font: DashboardType.caption, color: style.inkTertiary))
        }

        heading("What it does")
        add(DashboardType.label(transform.instruction, font: DashboardType.callout,
                                color: style.inkSecondary, lines: 6))

        heading("How to run it")
        if let hotkey = transform.hotkey {
            add(DashboardType.label("Press \(hotkey.displayName).", font: DashboardType.callout,
                                    color: style.inkSecondary))
        }
        if transform.triggers.isEmpty {
            add(DashboardType.label("No spoken trigger.", font: DashboardType.callout,
                                    color: style.inkTertiary))
        } else {
            // Every phrase, not a sample. These are matched exactly — that is what
            // makes them safe to say mid-sentence — so a user who only sees three
            // of seven will believe the other four do not work.
            let list = transform.triggers.map { "“\($0)”" }.joined(separator: "\n")
            add(DashboardType.label(list, font: DashboardType.callout,
                                    color: style.inkSecondary, lines: transform.triggers.count))
        }

        heading("With no network")
        if transform.worksOffline {
            let recipe = transform.offline.title
            let limit = transform.offline.limitation
            add(DashboardType.label(
                limit == nil ? "\(recipe). No approximation — this is the whole job."
                             : "\(recipe) — \(limit!). Less than the full transform, and Quill says so when it runs.",
                font: DashboardType.callout, color: style.inkSecondary, lines: 3))
        } else {
            // Named plainly. A transform that silently does nothing offline is
            // worse than one that refuses, and this is the screen where the user
            // finds out which they have.
            add(DashboardType.label(
                "This one refuses. There is no honest deterministic version of it, so offline it says so rather than returning something close.",
                font: DashboardType.callout, color: style.inkTertiary, lines: 3))
        }

        heading("Guards")
        let guards = [
            "Reads \(transform.target.title.lowercased()).",
            transform.preservesVocabulary
                ? "Every word from your dictionary must survive, checked afterwards rather than asked for in the prompt."
                : "Vocabulary is not enforced for this one.",
            "Refused if the result is under \(Int(transform.bounds.minRatio * 100))% or over \(Int(transform.bounds.maxRatio * 100))% of the original length.",
        ]
        add(DashboardType.label(guards.joined(separator: "\n"), font: DashboardType.callout,
                                color: style.inkSecondary, lines: 5))

        if transform.useCount > 0 {
            add(DashboardType.label("Used \(transform.useCount) time\(transform.useCount == 1 ? "" : "s")",
                                    font: DashboardType.caption, color: style.inkQuaternary))
        }
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
}
