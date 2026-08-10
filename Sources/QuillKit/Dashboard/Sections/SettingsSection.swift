import AppKit

/// The settings screen, laid out the way macOS lays out settings.
///
/// System Settings is a stack of grouped lists: a quiet header above each group,
/// one row per setting, label left and control right, hairlines between rows and
/// never around them. That shape is not decoration — it is what makes a screen of
/// unrelated switches scannable. Nothing here is a card with a shadow, nothing
/// explains itself in a paragraph, and a row only carries a second line when the
/// setting genuinely changes meaning depending on another one.
public final class SettingsSectionView: NSView {

    private let style: DashboardStyle
    private let settings: QuillSettings

    /// Everything scrolls, including the title.
    ///
    /// Four groups do not fit the 1060x700 minimum window — the last one was cut
    /// off by the panel edge with nothing to say so, which is the same failure as
    /// two elements overlapping and harder to notice. A settings screen grows
    /// every time a setting is added, so this cannot be solved by keeping the
    /// list short.
    private let scroll = NSScrollView()
    private let content = SettingsFlippedView()
    private let header = NSView()
    private var groups: [SettingsGroup] = []
    private var holdRecorder: KeyRecorderControl?
    private var pushRecorder: KeyRecorderControl?
    private var pushNote: NSTextField?

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle, settings: QuillSettings = .shared) {
        self.style = style
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    private func build() {
        // Backgroundless and borderless: the panel behind is already drawn, and
        // NSScrollView's own chrome is the default look this window exists to avoid.
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

        let title = DashboardType.label("Settings", font: DashboardType.display, color: style.ink)
        title.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        content.addSubview(header)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            title.topAnchor.constraint(equalTo: header.topAnchor),
            title.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        groups = [dictationGroup(), inputGroup(), permissionsGroup(), dataGroup()]
        groups.forEach(content.addSubview)
        refreshPushNote()
        watchForGrants()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Granting a permission means leaving for System Settings and coming back,
    /// and nothing tells an app that a TCC switch was flipped. Without this the
    /// screen still offers "Open Settings" for something already granted, which
    /// reads as the grant not having worked.
    ///
    /// Deliberately only asks for a rebuild when a state actually changed —
    /// reloading the section on every activation would throw away whatever the
    /// user was in the middle of on any other screen.
    private func watchForGrants() {
        renderedPermissions = Permission.allCases.map { Permissions.state(of: $0) }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let now = Permission.allCases.map { Permissions.state(of: $0) }
                guard now != self.renderedPermissions else { return }
                NotificationCenter.default.post(name: .quillDashboardNeedsReload, object: nil)
            }
        }
    }

    private var renderedPermissions: [PermissionState] = []

    private func dictationGroup() -> SettingsGroup {
        let hold = KeyRecorderControl(binding: settings.hold, style: style)
        hold.onPick = { [weak self] binding in
            self?.settings.setHold(binding)
            self?.refreshPushNote()
        }
        holdRecorder = hold

        let push = KeyRecorderControl(binding: settings.toggle, style: style)
        push.onPick = { [weak self] binding in
            self?.settings.setToggle(binding)
            self?.refreshPushNote()
        }
        pushRecorder = push

        let note = DashboardType.label("", font: DashboardType.caption, color: style.inkTertiary)
        pushNote = note

        let live = DashboardSwitch(isOn: settings.liveText, style: style)
        live.onToggle = { [weak self] on in self?.settings.setLiveText(on) }

        return SettingsGroup(title: "Dictation", style: style, rows: [
            .init(label: "Hold to talk", detail: nil, control: hold),
            .init(label: "Push to talk", detail: note, control: push),
            .init(label: "Show text as you speak", detail: nil, control: live),
        ])
    }

    private func inputGroup() -> SettingsGroup {
        let picker = DashboardMenuButton(title: currentMicrophoneTitle(), style: style) { [weak self] in
            guard let self else { return [] }
            let chosen = self.settings.inputDeviceUID
            // Rebuilt on every open, so a microphone plugged in while this window
            // is showing is in the list without a relaunch.
            var items: [DashboardMenuButton.Item] = [
                .init(title: "System default", isSelected: chosen == nil) { [weak self] in
                    self?.settings.setInputDeviceUID(nil)
                    self?.refreshMicrophone()
                }
            ]
            for device in AudioDeviceInfo.inputDevices() {
                items.append(.init(title: device.name, isSelected: chosen == device.uid) { [weak self] in
                    self?.settings.setInputDeviceUID(device.uid)
                    self?.refreshMicrophone()
                })
            }
            return items
        }
        microphonePicker = picker

        return SettingsGroup(title: "Input", style: style, rows: [
            .init(label: "Microphone", detail: nil, control: picker),
        ])
    }

    private var microphonePicker: DashboardMenuButton?

    private func permissionsGroup() -> SettingsGroup {
        let rows = Permission.allCases.map { permission -> SettingsGroup.Row in
            let granted = Permissions.state(of: permission) == .granted
            let control: NSView
            if granted {
                control = SettingsStatusLabel(text: "Granted", tone: .good, style: style)
            } else {
                let button = DashboardButton(title: "Open Settings", kind: .secondary, style: style)
                button.onClick = { Permissions.request(permission) }
                button.frame.size = NSSize(width: button.intrinsicWidth, height: 28)
                control = button
            }
            return .init(label: permission.rawValue, detail: nil, control: control)
        }
        return SettingsGroup(title: "Permissions", style: style, rows: rows)
    }

    /// The two files Quill keeps, reachable from the screen rather than only from
    /// a menu-bar item nobody opens twice. Both already existed; neither had a
    /// way in from here.
    private func dataGroup() -> SettingsGroup {
        let vocabulary = actionButton("Open") {
            let url = Vocabulary.defaultURL
            if !FileManager.default.fileExists(atPath: url.path) {
                Vocabulary.seed.save(to: url)
            }
            NSWorkspace.shared.open(url)
        }
        let history = actionButton("Reveal") {
            NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.defaultURL])
        }
        return SettingsGroup(title: "Files", style: style, rows: [
            .init(label: "Vocabulary", detail: nil, control: vocabulary),
            .init(label: "History", detail: nil, control: history),
        ])
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> NSView {
        let button = DashboardButton(title: title, kind: .secondary, style: style)
        button.onClick = action
        button.frame.size = NSSize(width: button.intrinsicWidth, height: 28)
        return button
    }

    // MARK: - Live state

    private func currentMicrophoneTitle() -> String {
        guard let uid = settings.inputDeviceUID else { return "System default" }
        return AudioDeviceInfo.inputDevices().first { $0.uid == uid }?.name
            // The saved device is unplugged. Say so, rather than showing a name
            // that is no longer recording anything.
            ?? "Unavailable — using system default"
    }

    private func refreshMicrophone() {
        microphonePicker?.title = currentMicrophoneTitle()
        relayout()
    }

    /// The one line on this screen that has to exist: with both keys bound to the
    /// same modifier, push-to-talk is a double-tap, and nothing on screen would
    /// otherwise say so.
    private func refreshPushNote() {
        guard let pushNote else { return }
        let shared = settings.toggleSharesHoldKey
        let text: String
        if shared {
            text = "Double-tap, since it shares a key with hold to talk."
        } else if settings.toggle.isBusyKey {
            text = "\(settings.toggle.displayName) is used constantly while typing."
        } else {
            text = "Tap once to start, once to stop."
        }
        pushNote.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: DashboardType.caption, .foregroundColor: style.inkTertiary])
        holdRecorder?.setBinding(settings.hold)
        pushRecorder?.setBinding(settings.toggle)
        relayout()
    }

    /// A group lays its own rows out, and its frame has not changed — so asking
    /// the section to lay out again moves nothing. Each group has to be told.
    private func relayout() {
        groups.forEach { $0.needsLayout = true }
        needsLayout = true
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        scroll.frame = bounds

        let x = DashboardMetrics.contentPaddingX
        // The scroller is an overlay, so it costs no width — but leave the same
        // gutter on the right anyway, or a group's trailing edge sits under it.
        let width = max(0, bounds.width - x * 2)
        // Settings rows read badly at full width: the label and its control end
        // up a hand's width apart. System Settings caps its column too.
        let column = min(width, 620)

        header.frame = NSRect(x: x, y: DashboardMetrics.contentPaddingY,
                              width: column, height: 26)

        var y = header.frame.maxY + DashboardSpace.lg
        for group in groups {
            let height = group.fittedHeight(width: column)
            group.frame = NSRect(x: x, y: y, width: column, height: height)
            y += height + DashboardSpace.lg
        }

        // The document is as tall as its contents or the viewport, whichever is
        // more — shorter than the viewport and the whole thing sticks to the
        // bottom of an unflipped clip view.
        content.frame = NSRect(x: 0, y: 0, width: bounds.width,
                               height: max(bounds.height, y + DashboardSpace.md))
    }
}

/// Top-down inside a scroll view. `NSScrollView`'s document view is bottom-up by
/// default, which would put "Settings" at the bottom of the list.
final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Group

/// A titled list of rows. Hairlines *between* rows only: a box around a settings
/// group is what makes a preferences screen look like a form from 2003.
final class SettingsGroup: NSView {

    struct Row {
        let label: String
        let detail: NSTextField?
        let control: NSView
    }

    private let style: DashboardStyle
    private let heading: NSTextField
    private let rows: [Row]
    private var labels: [NSTextField] = []
    private var rules: [DashboardRule] = []
    private let card: DashboardCardView

    override var isFlipped: Bool { true }

    private static let rowHeight: CGFloat = 46
    private static let detailExtra: CGFloat = 16
    private static let headingHeight: CGFloat = 24
    private static let inset: CGFloat = DashboardSpace.md

    init(title: String, style: DashboardStyle, rows: [Row]) {
        self.style = style
        self.rows = rows
        heading = DashboardType.label(title, font: DashboardType.headline, color: style.inkSecondary)
        card = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        super.init(frame: .zero)
        addSubview(heading)
        addSubview(card)
        for (index, row) in rows.enumerated() {
            let label = DashboardType.label(row.label, font: DashboardType.body, color: style.ink)
            labels.append(label)
            card.addSubview(label)
            if let detail = row.detail { card.addSubview(detail) }
            card.addSubview(row.control)
            if index < rows.count - 1 {
                let rule = DashboardRule(color: style.hairline)
                rules.append(rule)
                card.addSubview(rule)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func height(of row: Row) -> CGFloat {
        Self.rowHeight + (row.detail == nil ? 0 : Self.detailExtra)
    }

    func fittedHeight(width: CGFloat) -> CGFloat {
        Self.headingHeight + DashboardSpace.xs + rows.reduce(0) { $0 + height(of: $1) }
    }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 2, y: 0, width: bounds.width - 4, height: Self.headingHeight)
        let cardTop = Self.headingHeight + DashboardSpace.xs
        card.frame = NSRect(x: 0, y: cardTop, width: bounds.width,
                            height: bounds.height - cardTop)

        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let rowHeight = height(of: row)
            let control = row.control
            let controlSize = control.intrinsicContentSize
            let controlWidth = controlSize.width > 0 ? controlSize.width : control.frame.width
            let controlHeight = controlSize.height > 0 ? controlSize.height : control.frame.height
            // The control keeps its width and the label truncates into what is
            // left — the rule the whole window follows, applied here so a long
            // microphone name never pushes its own menu off the panel.
            let controlX = card.bounds.width - Self.inset - controlWidth
            control.frame = NSRect(x: controlX,
                                   y: y + ((Self.rowHeight - controlHeight) / 2).rounded(),
                                   width: controlWidth, height: controlHeight)

            let label = labels[index]
            let labelSize = label.fittingSize
            let labelWidth = max(0, controlX - Self.inset - DashboardSpace.md)
            let labelY = row.detail == nil
                ? y + ((Self.rowHeight - labelSize.height) / 2).rounded()
                : y + 12
            label.frame = NSRect(x: Self.inset, y: labelY,
                                 width: min(labelSize.width, labelWidth), height: labelSize.height)

            if let detail = row.detail {
                let size = detail.fittingSize
                detail.frame = NSRect(x: Self.inset, y: label.frame.maxY + 2,
                                      width: min(size.width, labelWidth), height: size.height)
            }

            y += rowHeight
            if index < rows.count - 1 {
                rules[index].frame = NSRect(x: Self.inset, y: y,
                                            width: card.bounds.width - Self.inset * 2, height: 1)
            }
        }
    }
}

// MARK: - Status label

/// "Granted", in the affirmative colour, with a dot. Not a chip: a chip is a
/// thing you can click, and this is a statement of fact.
final class SettingsStatusLabel: NSView {

    enum Tone { case good, bad }

    private let dot = DashboardStatusDot(color: .systemGreen)
    private let label: NSTextField

    override var isFlipped: Bool { true }

    init(text: String, tone: Tone, style: DashboardStyle) {
        label = DashboardType.label(text, font: DashboardType.callout, color: style.inkSecondary)
        super.init(frame: .zero)
        dot.color = tone == .good ? style.accent : .systemRed
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
