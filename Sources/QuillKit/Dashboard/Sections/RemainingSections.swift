import AppKit

// Style — the third of what were originally three sections here (Scratchpad and
// Notetaker were removed at Roman's request). It was Auto Layout inside an
// unflipped view, stacking an EMPTY eyebrow label above the title and a
// three-line deck below it, while the other sections laid out manual frames in
// a flipped one. That is why its heading sat twenty-four points lower than
// everywhere else — the drift Roman named — and why it did not fill the window.
// Rewritten here on the same two pieces every other section uses:
// `DashboardSectionHeader` for the top of the page, `DashboardMessageView` for a
// page with nothing on it.

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

// MARK: - Style

/// What Quill has learned about how you write, and the tone it starts from.
public final class StyleSectionView: NSView {

    private let scroll = NSScrollView()
    private let content = SettingsFlippedView()
    private let header: DashboardSectionHeader
    private let traits: SectionCard
    private let changes: SectionCard
    private let destinations: SectionCard?
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

        // What you said versus what you meant to type, which is the question this
        // screen is for. `StylePhrasing` has held these pairs since the profile
        // existed and nothing ever showed them — because nothing ever recorded
        // one: `StyleStore.recordCorrection` had no callers until `EditWatcher`.
        let noticed = profile.phrasings.sorted {
            ($0.count, $0.lastObserved ?? .distantPast) > ($1.count, $1.lastObserved ?? .distantPast)
        }
        changes = SectionCard(style: style, title: "What you changed",
                              trailing: noticed.isEmpty ? nil
                                  : "\(DictationFormat.plural(noticed.count, "pair")) noticed")

        // Where the text actually went. Recorded on every dictation whether or
        // not the app will let Quill read the field back afterwards — knowing
        // where your words went does not depend on being able to re-read them.
        let places = Self.destinationTally()
        destinations = places.isEmpty ? nil
            : SectionCard(style: style, title: "Where your words went")

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

        // Four cards and a tone strip no longer fit an 850-point window, and a
        // fixed layout that does not fit does not complain — it just stops
        // drawing the bottom of itself. Same scroll shape as Settings, MCP and
        // Help.
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
        content.addSubview(header)

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

        if noticed.isEmpty {
            // An empty state that says what would fill it, and admits the one
            // thing that stops it filling. "Nothing yet" on its own reads as
            // broken on a feature nobody can see working.
            let blank = DashboardType.label(
                "Nothing yet. After a dictation Quill watches the sentence it inserted — only that "
                    + "sentence — and when you fix something it records what you said against what you "
                    + "meant. Terminals, Chrome and VS Code don't hand their text to Quill, so edits "
                    + "made in those can't be read back; TextEdit, Mail and Notes can.",
                font: DashboardType.callout, color: style.inkTertiary, lines: 6, lineHeight: 19)
            changes.add(blank) { width in DashboardType.size(blank, width: width).height }
        } else {
            for phrasing in noticed.prefix(6) {
                let row = SectionKeyValueRow(
                    "\u{201C}\(phrasing.from)\u{201D} \u{2192} \u{201C}\(phrasing.to)\u{201D}",
                    phrasing.count == 1 ? "once" : "\(phrasing.count) times",
                    style: style)
                changes.add(row) { _ in SectionKeyValueRow.height }
            }
        }

        if let destinations {
            for (name, count) in places.prefix(5) {
                let row = SectionKeyValueRow(name, DictationFormat.plural(count, "dictation"),
                                            style: style)
                destinations.add(row) { _ in SectionKeyValueRow.height }
            }
        }

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

        content.addSubview(traits)
        content.addSubview(changes)
        if let destinations { content.addSubview(destinations) }
        content.addSubview(trust)
        content.addSubview(presets)
    }

    /// Dictations grouped by the app they landed in, most-used first.
    ///
    /// Reads the history rather than keeping a second tally, so it cannot drift
    /// from what actually happened, and skips records written before the
    /// destination was recorded rather than counting them as "unknown" — an
    /// "unknown: 84" row at the top of this card would say nothing except that
    /// the feature is new.
    private static func destinationTally() -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for record in HistoryStore().all where !record.isMeasurement {
            guard let id = record.destinationBundleID else { continue }
            counts[id, default: 0] += 1
        }
        return counts
            .map { (Self.appName(for: $0.key), $0.value) }
            .sorted { ($0.1, $1.0) > ($1.1, $0.0) }
    }

    /// "TextEdit", not "com.apple.TextEdit". Falls back to the identifier when
    /// the app has been deleted since — which is still more use than nothing.
    private static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
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
        scroll.frame = bounds
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2
        guard width > 0 else { return }

        header.frame = NSRect(x: padX, y: padY, width: width, height: header.height)
        var y = DashboardSectionHeader.contentTop(for: header)

        // Cards in pairs, each pair as tall as the taller one's content, then the
        // tone strip under them at full width. Heights come from the cards rather
        // than from constants that were 210 and 108 and left three hundred points
        // of nothing under the page.
        let gap = DashboardSpace.lg
        let half = ((width - gap) / 2).rounded(.down)

        func pair(_ left: SectionCard, _ right: SectionCard?) {
            guard let right else {
                left.frame = NSRect(x: padX, y: y, width: width,
                                    height: left.fittedHeight(width: width))
                y += left.frame.height + gap
                return
            }
            let height = max(left.fittedHeight(width: half), right.fittedHeight(width: half))
            left.frame = NSRect(x: padX, y: y, width: half, height: height)
            right.frame = NSRect(x: padX + half + gap, y: y,
                                 width: width - half - gap, height: height)
            y += height + gap
        }

        pair(traits, trust)
        // Full width when there is nothing to sit beside it — a half-width card
        // with a paragraph of empty state in it is a tall thin column of text
        // next to nothing at all.
        pair(changes, destinations)

        presets.frame = NSRect(x: padX, y: y, width: width,
                               height: presets.fittedHeight(width: width))
        y += presets.frame.height

        content.frame = NSRect(x: 0, y: 0, width: bounds.width,
                               height: max(bounds.height, y + DashboardSpace.md))
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

