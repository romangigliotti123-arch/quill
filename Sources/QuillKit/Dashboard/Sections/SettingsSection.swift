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
    private var header: DashboardSectionHeader!
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

        // The shared header, like every other section. This built its own out of
        // a bare NSView and a constrained label, which is how the title ended up
        // in a different place here than on the screen next to it.
        header = DashboardSectionHeader(title: "Settings", style: style)
        content.addSubview(header)

        // Order matters here, not just membership: DashboardColumns.pack lays
        // groups out in this order, always into whichever column is currently
        // shorter — so the order is what decides how evenly the two columns'
        // bottoms land, not just which group ends up in which column.
        groups = [dictationGroup(), dataGroup(), overlayGroup(), inputGroup(), permissionsGroup(), aboutGroup()]
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

        let note = DashboardType.label("", font: DashboardType.caption, color: style.inkTertiary,
                                       lines: 2, lineHeight: 16)
        pushNote = note

        let live = DashboardSwitch(isOn: settings.liveText, style: style)
        live.onToggle = { [weak self] on in self?.settings.setLiveText(on) }

        let numbers = DashboardMenuButton(title: settings.numberStyle.label, style: style) {
            [weak self] in
            guard let self else { return [] }
            let chosen = self.settings.numberStyle
            return QuillSettings.Values.NumberStyle.allCases.map { style in
                .init(title: style.label, isSelected: style == chosen) { [weak self] in
                    self?.settings.setNumberStyle(style)
                    self?.refreshNumberStyle()
                }
            }
        }
        numberPicker = numbers

        let numbersNote = DashboardType.label(settings.numberStyle.detail,
                                              font: DashboardType.caption,
                                              color: style.inkTertiary, lines: 2, lineHeight: 16)
        numberNote = numbersNote

        let undo = DashboardSwitch(isOn: settings.undoChord, style: style)
        undo.onToggle = { [weak self] on in self?.settings.setUndoChord(on) }
        let undoNote = DashboardType.label(
            "⌥⌫ deletes the last thing Quill inserted. Off, it deletes the previous word, as it does everywhere else.",
            font: DashboardType.caption, color: style.inkTertiary, lines: 2, lineHeight: 16)

        let context = DashboardSwitch(isOn: settings.contextRecovery, style: style)
        context.onToggle = { [weak self] on in self?.settings.setContextRecovery(on) }
        // Two lines. The comment that used to sit here said one, "because the row
        // truncates rather than wraps" — but `SettingsGroup` measures its detail
        // with `DashboardType.size(detail, width:)` and lays it out at that height,
        // so it has wrapped for some time. The single-line cap only started
        // costing anything when the column narrowed to make room for a second one,
        // and this sentence lost its last three words to an ellipsis.
        let contextNote = DashboardType.label(
            "Fixes “flour” heard as “flower”, and endings lost when you talk fast.",
            font: DashboardType.caption, color: style.inkTertiary, lines: 2, lineHeight: 16)

        let finishThenEnter = DashboardSwitch(isOn: settings.finishThenEnterEnabled, style: style)
        finishThenEnter.onToggle = { [weak self] on in self?.settings.setFinishThenEnterEnabled(on) }
        let finishThenEnterNote = DashboardType.label(
            "Release, then tap again right away — Quill sends Return once it's actually finished, not before.",
            font: DashboardType.caption, color: style.inkTertiary, lines: 2, lineHeight: 16)

        // One row rather than its own section — a whole header for one row
        // read as more clutter than the setting was worth, and it belongs
        // here anyway: it is what "cleanup" means once the deterministic
        // pass above stops being able to help.
        var changeRef: NSView?
        let change = actionButton("Change…") { [weak self] in
            guard let self, let changeRef else { return }
            self.showAIKeyPopover(anchoredTo: changeRef)
        }
        changeRef = change
        let aiNote = DashboardType.label("", font: DashboardType.caption, color: style.inkTertiary,
                                         lines: 2, lineHeight: 16)
        aiKeyNote = aiNote
        refreshAIKeyNote()

        return SettingsGroup(title: "Dictation", style: style, rows: [
            .init(label: "Hold to talk", detail: nil, control: hold),
            .init(label: "Push to talk", detail: note, control: push),
            .init(label: "Show text as you speak", detail: nil, control: live),
            .init(label: "Take back what was just inserted", detail: undoNote, control: undo),
            .init(label: "Numbers", detail: numbersNote, control: numbers),
            .init(label: "Work out a word from context", detail: contextNote, control: context),
            .init(label: "AI cleanup key", detail: aiNote, control: change),
            .init(label: "Tap again to send", detail: finishThenEnterNote, control: finishThenEnter),
        ])
    }

    private var aiKeyNote: NSTextField?
    private var aiKeyPopover: NSPopover?

    private func refreshAIKeyNote() {
        guard let aiKeyNote else { return }
        let text: String
        if let key = NIMKey.load() {
            text = "Set (\(NIMKey.fingerprint(key))) — Shorter, Summarise, More casual and Email are available."
        } else {
            text = "Not set — everything runs on this Mac. Four transforms that need a model stay unavailable."
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 16
        paragraph.maximumLineHeight = 16
        paragraph.lineBreakMode = .byWordWrapping
        aiKeyNote.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: DashboardType.caption,
                         .foregroundColor: style.inkTertiary,
                         .paragraphStyle: paragraph])
        relayout()
    }

    /// The exact same field, Check and Remove `OnboardingKeyStep` shows during
    /// setup, in a popover instead of the whole onboarding window — changing a
    /// key later should not mean walking back through account choice and
    /// permissions to get to it.
    private func showAIKeyPopover(anchoredTo view: NSView) {
        let width: CGFloat = 340
        let inset: CGFloat = 16
        let step = OnboardingKeyStep(style: style)
        let stepWidth = width - inset * 2
        let stepHeight = step.fittingHeight(width: stepWidth)
        step.frame = NSRect(x: inset, y: inset, width: stepWidth, height: stepHeight)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: stepHeight + inset * 2))
        container.addSubview(step)

        let controller = NSViewController()
        controller.view = container

        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = container.frame.size
        aiKeyPopover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    private var overlayPositionPicker: DashboardMenuButton?

    /// The always-on button at the edge of the screen — Wispr Flow's bar. A
    /// click starts or stops a dictation without holding a key at all; the
    /// held key still works exactly as it always has either way.
    private func overlayGroup() -> SettingsGroup {
        let enabled = DashboardSwitch(isOn: settings.overlayBarEnabled, style: style)
        enabled.onToggle = { [weak self] on in self?.settings.setOverlayBarEnabled(on) }

        let position = DashboardMenuButton(title: settings.overlayBarPosition.label, style: style) {
            [weak self] in
            guard let self else { return [] }
            let chosen = self.settings.overlayBarPosition
            return QuillSettings.Values.OverlayBarPosition.allCases.map { position in
                .init(title: position.label, isSelected: position == chosen) { [weak self] in
                    self?.settings.setOverlayBarPosition(position)
                    self?.refreshOverlayPosition()
                }
            }
        }
        overlayPositionPicker = position

        let newNote = DashboardSwitch(isOn: settings.overlayShowsNewNoteButton, style: style)
        newNote.onToggle = { [weak self] on in self?.settings.setOverlayShowsNewNoteButton(on) }
        let newNoteNote = DashboardType.label(
            "A second button on the bar for starting a note straight into a fresh dictation.",
            font: DashboardType.caption, color: style.inkTertiary, lines: 2, lineHeight: 16)

        return SettingsGroup(title: "Overlay", style: style, rows: [
            .init(label: "Always-on button", detail: nil, control: enabled),
            .init(label: "Position", detail: nil, control: position),
            .init(label: "New note button", detail: newNoteNote, control: newNote),
        ])
    }

    /// Same shape as `refreshNumberStyle` — a menu button does not restate
    /// itself, so the screen would keep showing the old answer.
    private func refreshOverlayPosition() {
        overlayPositionPicker?.title = settings.overlayBarPosition.label
        relayout()
    }

    private var retentionPicker: DashboardMenuButton?
    private var retentionNote: NSTextField?

    /// The picker's own title and caption, after the menu changed the value.
    /// Same shape as `refreshNumberStyle` — a menu button does not restate
    /// itself, so the screen would keep showing the old answer.
    private func refreshRetention() {
        retentionPicker?.title = settings.historyRetention.label
        retentionNote?.stringValue = settings.historyRetention.detail
        relayout()
    }

    private var numberPicker: DashboardMenuButton?
    private var numberNote: NSTextField?

    /// The example under the picker has to follow the choice, or the row says one
    /// thing and does another.
    private func refreshNumberStyle() {
        numberPicker?.title = settings.numberStyle.label
        numberNote?.stringValue = settings.numberStyle.detail
        relayout()
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

        let keep = DashboardMenuButton(title: settings.historyRetention.label, style: style) {
            [weak self] in
            guard let self else { return [] }
            let chosen = self.settings.historyRetention
            return QuillSettings.Values.HistoryRetention.allCases.map { option in
                .init(title: option.label, isSelected: option == chosen) { [weak self] in
                    self?.settings.setHistoryRetention(option)
                    self?.refreshRetention()
                }
            }
        }
        retentionPicker = keep
        let keepNote = DashboardType.label(settings.historyRetention.detail,
                                           font: DashboardType.caption,
                                           color: style.inkTertiary, lines: 2, lineHeight: 16)
        retentionNote = keepNote

        let erase = actionButton("Erase…") { [weak self] in self?.confirmErase() }
        let eraseNote = DashboardType.label(
            "Deletes every dictation, your Dictionary, transforms, notes, settings and API key, then restarts Quill. There is no undo.",
            font: DashboardType.caption, color: style.inkTertiary, lines: 3, lineHeight: 16)

        return SettingsGroup(title: "Files", style: style, rows: [
            .init(label: "Vocabulary", detail: nil, control: vocabulary),
            .init(label: "History", detail: nil, control: history),
            .init(label: "Keep dictations for", detail: keepNote, control: keep),
            .init(label: "Erase everything", detail: eraseNote, control: erase),
        ])
    }

    /// One row, deliberately its own group and the last one on the screen.
    ///
    /// "Erase everything" above empties Quill and leaves it installed, which is
    /// the right shape for someone who wants a clean slate. This is the other
    /// question — someone who is done with the app entirely — and it does not
    /// belong under "Files" pretending to be one more file operation. Grouping
    /// alone should tell you this one takes the app itself, before you have read
    /// a word of the label.
    private func aboutGroup() -> SettingsGroup {
        let uninstall = actionButton("Uninstall…") { [weak self] in self?.confirmUninstall() }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let uninstallNote = DashboardType.label(
            "Erases everything Quill knows, moves Quill.app to the Trash, and quits. Version \(version).",
            font: DashboardType.caption, color: style.inkTertiary, lines: 2, lineHeight: 16)

        return SettingsGroup(title: "About", style: style, rows: [
            .init(label: "Uninstall Quill", detail: uninstallNote, control: uninstall),
        ])
    }

    /// Same two-question shape as `confirmErase`, one step more final: this one
    /// also takes the application file itself. The bundle is confirmed removable
    /// BEFORE anything is erased — a failed uninstall must never leave someone
    /// with a wiped, still-installed app, which is worse than the state they
    /// started in.
    private func confirmUninstall() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Quill?"
        alert.informativeText = """
            This erases every dictation, your Dictionary, transforms, notes, settings and API key, then moves Quill.app to the Trash and quits.

            This cannot be undone from inside Quill. Recovering it means recovering Quill.app from the Trash yourself, and your data will already be gone.
            """
        alert.addButton(withTitle: "Cancel")
        let uninstall = alert.addButton(withTitle: "Uninstall and quit")
        uninstall.hasDestructiveAction = true
        alert.window.defaultButtonCell = alert.buttons.first?.cell as? NSButtonCell

        guard alert.runModal() == .alertSecondButtonReturn else { return }

        // The bundle first. If macOS refuses to move it — read-only volume,
        // System Integrity Protection on an unexpected install path — stop here
        // with the data still intact rather than erasing everything and leaving
        // a hollowed-out app that still runs.
        let bundleURL = Bundle.main.bundleURL
        do {
            try FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "Couldn't remove Quill.app"
            failure.informativeText = """
                \(error.localizedDescription)

                Nothing was erased. Quit Quill and drag \(bundleURL.lastPathComponent) to the Trash yourself, or run:

                rm -rf "\(bundleURL.path)"
                """
            failure.runModal()
            return
        }

        let removed = QuillData.erase()
        NSLog("[quill] uninstalling: moved %@ to Trash, erased %d file(s): %@",
              bundleURL.lastPathComponent, removed.count, removed.joined(separator: ", "))
        NSApp.terminate(nil)
    }

    /// Two questions, not one, and the first one names what it is about to take.
    ///
    /// The rule this follows is that a destructive action must be refusable by
    /// someone who clicked it by accident and irreversible only for someone who
    /// meant it. So: the alert lists the files and their sizes rather than saying
    /// "everything" and asking to be trusted, the destructive button is not the
    /// default one, and Escape cancels.
    private func confirmErase() {
        let summary = QuillData.summary()
        guard !summary.isEmpty else {
            let nothing = NSAlert()
            nothing.messageText = "There is nothing to erase"
            nothing.informativeText = "Quill has not written anything yet."
            nothing.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Erase everything Quill knows?"
        alert.informativeText = """
            This deletes \(summary.count) file\(summary.count == 1 ? "" : "s") and cannot be undone:

            \(summary.map { "\($0.name) — \(Self.readable($0.bytes))" }.joined(separator: "\n"))

            Quill will restart with nothing in it, exactly as it was the first             time you opened it.
            """
        alert.addButton(withTitle: "Cancel")
        let erase = alert.addButton(withTitle: "Erase and restart")
        erase.hasDestructiveAction = true
        // Cancel is the default, so Return does the safe thing. Someone who
        // reached this dialog by mistake has to read a word before losing a year
        // of transcripts.
        alert.window.defaultButtonCell = alert.buttons.first?.cell as? NSButtonCell

        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let removed = QuillData.erase()
        NSLog("[quill] erased %d file(s): %@", removed.count, removed.joined(separator: ", "))
        Self.relaunch()
    }

    private static func readable(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Start a second copy and stand down.
    ///
    /// Deleting the files is only half of "as if you just installed it": every
    /// store in this app holds its records in memory and writes the whole file on
    /// the next change, so a Quill left running would put its history back within
    /// one dictation. The relaunch is what makes the erase stick, and it is also
    /// what makes the result actually indistinguishable from a fresh install.
    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
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
        // Rebuilt rather than recoloured, so it keeps the paragraph style that
        // lets it wrap. Assigning a plain attributed string here would silently
        // drop the two-line allowance the label was created with.
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 16
        paragraph.maximumLineHeight = 16
        paragraph.lineBreakMode = .byWordWrapping
        pushNote.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: DashboardType.caption,
                         .foregroundColor: style.inkTertiary,
                         .paragraphStyle: paragraph])
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

        header.frame = NSRect(x: x, y: DashboardMetrics.contentPaddingY,
                              width: width, height: header.height)

        // Two columns when there is room for two readable ones. The row measure
        // stays capped — a label and its control a hand's width apart is genuinely
        // worse to read — and the page gets a second column instead of four
        // hundred and fifty points of empty window.
        let top = DashboardSectionHeader.contentTop(for: header)
        let (places, used) = DashboardColumns.pack(groups.map { group in
            { group.fittedHeight(width: $0) }
        }, width: width, originX: x, originY: top)
        for (group, place) in zip(groups, places) {
            group.frame = NSRect(x: place.x, y: place.y, width: place.width, height: place.height)
        }
        let y = top + used

        // The document is as tall as its contents or the viewport, whichever is
        // more — shorter than the viewport and the whole thing sticks to the
        // bottom of an unflipped clip view.
        content.frame = NSRect(x: 0, y: 0, width: bounds.width,
                               height: max(bounds.height, y + DashboardSpace.md))
    }
}

extension SettingsSectionView: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        aiKeyPopover = nil
        refreshAIKeyNote()
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

    /// Measured, not assumed.
    ///
    /// This reserved a flat 16 points for a detail line, which is right for the
    /// one-liner under "Push to talk" and wrong for Help, where a row explains a
    /// failure in three. The extra lines drew straight through the row beneath.
    private func height(of row: Row, width: CGFloat) -> CGFloat {
        guard let detail = row.detail else { return Self.rowHeight }
        let available = max(120, width - Self.inset * 2 - Self.controlGutter)
        return Self.rowHeight + DashboardType.size(detail, width: available).height + 4
    }

    func fittedHeight(width: CGFloat) -> CGFloat {
        Self.headingHeight + DashboardSpace.xs + rows.reduce(0) { $0 + height(of: $1, width: width) }
    }

    /// Room kept clear on the right for whatever control the row carries, so a
    /// wrapped detail never runs under a switch or a button.
    private static let controlGutter: CGFloat = 130

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 2, y: 0, width: bounds.width - 4, height: Self.headingHeight)
        let cardTop = Self.headingHeight + DashboardSpace.xs
        card.frame = NSRect(x: 0, y: cardTop, width: bounds.width,
                            height: bounds.height - cardTop)

        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let rowHeight = height(of: row, width: bounds.width)
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
                let available = max(120, card.bounds.width - Self.inset * 2 - Self.controlGutter)
                let height = DashboardType.size(detail, width: available).height
                detail.frame = NSRect(x: Self.inset, y: label.frame.maxY + 2,
                                      width: available, height: height)
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
