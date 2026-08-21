import AppKit

/// Help, as a live health check rather than a list of links.
///
/// Flow's version of this screen is a support address and a docs link, and for a
/// cloud product that is the correct answer: when Flow breaks it is usually their
/// server, and there is nothing on the user's machine to inspect. Every one of
/// Quill's failure modes is local, and every one of them is silent — a denied
/// permission, Secure Input, a tap the system refused. The key just stops
/// working and nothing says why.
///
/// So this screen answers one question: is Quill working right now, and if not,
/// exactly what to do. It runs the real checks — the same ones the command-line
/// report runs, through `Diagnostics.run()` — including the one that matters
/// most, which is whether the system will actually hand over an event tap.
public final class HelpSectionView: NSView {

    private let style: DashboardStyle
    private var checks: [Diagnostics.Check]

    private let scroll = NSScrollView()
    private let content = HelpFlippedView()
    private var header: DashboardSectionHeader!
    private var summary: NSTextField?
    private var groups: [NSView] = []

    public override var isFlipped: Bool { true }

    public convenience init(style: DashboardStyle) {
        self.init(style: style, checks: Diagnostics.run())
    }

    public init(style: DashboardStyle, checks: [Diagnostics.Check]) {
        self.style = style
        self.checks = checks
        super.init(frame: .zero)
        wantsLayer = true
        build()
        watchForGrants()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Build

    private func build() {
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

        header = DashboardSectionHeader(title: "Help", style: style)
        content.addSubview(header)

        rebuildGroups()
    }

    private func rebuildGroups() {
        groups.forEach { $0.removeFromSuperview() }
        summary?.removeFromSuperview()

        let failing = checks.filter { $0.status == .fail }
        let warning = checks.filter { $0.status == .warn }
        // States what is true, and nothing else. "All good!" on a screen whose
        // whole job is honesty would be the first thing to distrust.
        let verdict: String
        if !failing.isEmpty {
            verdict = failing.count == 1
                ? "One thing is stopping Quill working."
                : "\(failing.count) things are stopping Quill working."
        } else if !warning.isEmpty {
            verdict = "Quill works. \(warning.count) thing\(warning.count == 1 ? "" : "s") to be aware of."
        } else {
            verdict = "Everything Quill needs is in place."
        }
        let field = DashboardType.label(verdict, font: DashboardType.body, color: style.inkSecondary)
        content.addSubview(field)
        summary = field

        let statusGroup = SettingsGroup(title: "Right now", style: style, rows: checks.map { check in
            let control: NSView
            if let remedy = check.remedy, check.status != .pass,
               let permission = Permission.allCases.first(where: { $0.rawValue == check.title }) {
                let button = DashboardButton(title: "Grant", kind: .secondary, style: style)
                button.onClick = { Permissions.request(permission) }
                button.frame.size = NSSize(width: button.intrinsicWidth, height: 28)
                control = button
                _ = remedy
            } else {
                control = HelpStatusPip(status: check.status, style: style)
            }
            // The detail line carries the remedy where there is no button for it,
            // because "Secure Input is on" without "quit the terminal that turned
            // it on" is a diagnosis with no treatment.
            let text = [check.detail, check.remedy].compactMap { $0 }.joined(separator: " ")
            // Uncapped. A line cap here is a truncation waiting for a narrower
            // column, and this is the screen whose entire job is telling you what
            // to do about a failure — "remove Quill from the" is not advice. The
            // group measures its rows, so letting them wrap costs nothing but
            // height, and height is what this page has spare.
            let detail = DashboardType.label(text, font: DashboardType.caption,
                                             color: style.inkTertiary, lines: 0)
            return .init(label: check.title, detail: detail, control: control)
        })
        content.addSubview(statusGroup)
        groups.append(statusGroup)

        let settings = QuillSettings.shared
        let hold = settings.hold.displayName
        let shortcutRows: [SettingsGroup.Row] = [
            .init(label: "Dictate", detail: nil,
                  control: HelpKeycap("Hold \(hold)", style: style)),
            .init(label: settings.toggleSharesHoldKey ? "Hands-free" : "Push to talk", detail: nil,
                  control: HelpKeycap(settings.toggleSharesHoldKey
                                        ? "Double-tap \(hold)" : "Tap \(settings.toggle.displayName)",
                                      style: style)),
            .init(label: "Throw the dictation away", detail: nil,
                  control: HelpKeycap("Escape", style: style)),
        ]
        let shortcuts = SettingsGroup(title: "Keys", style: style, rows: shortcutRows)
        content.addSubview(shortcuts)
        groups.append(shortcuts)

        let knownRows: [SettingsGroup.Row] = [
            .init(label: "The key does nothing, and there is no error",
                  detail: DashboardType.label(
                    "Almost always Secure Input, or Accessibility granted to an older build. The grant is tied to the code signature, so a rebuild leaves a dead entry behind — remove Quill from the list and add it again.",
                    font: DashboardType.caption, color: style.inkTertiary, lines: 0),
                  control: NSView()),
            .init(label: "Text lands in the wrong app",
                  detail: DashboardType.label(
                    "Quill types into whatever had focus when the key went down. If focus moves mid-sentence it stops rather than typing the rest somewhere else.",
                    font: DashboardType.caption, color: style.inkTertiary, lines: 0),
                  control: NSView()),
            .init(label: "It heard the room instead of your headset",
                  detail: DashboardType.label(
                    "Settings ▸ Input picks the microphone. A device that has been unplugged falls back to the system default, and the transcript records which one was actually used.",
                    font: DashboardType.caption, color: style.inkTertiary, lines: 0),
                  control: NSView()),
        ]
        let known = SettingsGroup(title: "When something is wrong", style: style, rows: knownRows)
        content.addSubview(known)
        groups.append(known)

        needsLayout = true
    }

    /// A permission granted in System Settings changes nothing here until the
    /// screen looks again, and nothing tells an app that a TCC switch moved.
    private func watchForGrants() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let fresh = Diagnostics.run()
                guard fresh != self.checks else { return }
                self.checks = fresh
                self.rebuildGroups()
            }
        }
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        scroll.frame = bounds
        let x = DashboardMetrics.contentPaddingX
        let width = max(0, bounds.width - x * 2)

        header.frame = NSRect(x: x, y: DashboardMetrics.contentPaddingY,
                              width: width, height: header.height)
        var top = DashboardMetrics.contentPaddingY + header.height + DashboardSpace.xs
        if let summary {
            let height = DashboardType.size(summary, width: width).height
            summary.frame = NSRect(x: x, y: top, width: width, height: height)
            top += height + DashboardSpace.lg
        } else {
            top += DashboardSpace.lg - DashboardSpace.xs
        }

        // Same two-column packing as Settings, for the same reason: a 620pt
        // column of health checks pinned left leaves most of a 1350pt window
        // empty, and these two screens have to look like each other.
        let blocks = groups.compactMap { $0 as? SettingsGroup }
        let (places, used) = DashboardColumns.pack(blocks.map { group in
            { group.fittedHeight(width: $0) }
        }, width: width, originX: x, originY: top)
        for (group, place) in zip(blocks, places) {
            group.frame = NSRect(x: place.x, y: place.y, width: place.width, height: place.height)
        }
        let y = top + used
        content.frame = NSRect(x: 0, y: 0, width: bounds.width,
                               height: max(bounds.height, y + DashboardSpace.md))
    }
}

final class HelpFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Pips and keycaps

/// A coloured dot and a word. Not a button, because there is nothing to press.
final class HelpStatusPip: NSView {

    private let dot: DashboardStatusDot
    private let label: NSTextField

    override var isFlipped: Bool { true }

    init(status: Diagnostics.Check.Status, style: DashboardStyle) {
        let (color, text): (NSColor, String) = {
            switch status {
            case .pass: return (style.accent, "OK")
            case .warn: return (.systemOrange, "Check")
            case .fail: return (.systemRed, "Blocked")
            }
        }()
        dot = DashboardStatusDot(color: color)
        label = DashboardType.label(text, font: DashboardType.callout, color: style.inkSecondary)
        super.init(frame: .zero)
        addSubview(dot)
        addSubview(label)
        frame.size = intrinsicContentSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.fittingSize.width) + 16, height: 20)
    }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 0, y: (bounds.height - 7) / 2, width: 7, height: 7)
        let size = label.fittingSize
        label.frame = NSRect(x: 14, y: ((bounds.height - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
    }
}

/// A key, drawn as a key.
final class HelpKeycap: NSView {

    private let label: NSTextField
    private let style: DashboardStyle

    override var isFlipped: Bool { true }

    init(_ text: String, style: DashboardStyle) {
        self.style = style
        label = DashboardType.label(text, font: .systemFont(ofSize: 12, weight: .medium),
                                    color: style.ink)
        super.init(frame: .zero)
        addSubview(label)
        frame.size = intrinsicContentSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.fittingSize.width) + 22, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.raisedSurface(bounds, radius: DashboardRadius.chip,
                                    fillColor: style.raised, topColor: style.raisedTop,
                                    style: style, shadow: style.shadowContact, flipped: true)
    }

    override func layout() {
        super.layout()
        let size = label.fittingSize
        label.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                             y: ((bounds.height - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
    }
}
