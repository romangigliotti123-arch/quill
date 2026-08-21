import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var coordinator: DictationCoordinator?
    private var permissionPoll: Timer?
    /// Held for the app's lifetime: the window is closed, not destroyed, so
    /// reopening it keeps the selected section and the frame the user left it at.
    private var dashboard: DashboardWindowController?
    /// Also held for the app's lifetime: it owns a global mouse monitor and a
    /// workspace observer, and letting it go would silently stop ⌥⌫ noticing
    /// that the caret has moved.
    private var undo: InsertionUndo?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Quill")
        item.button?.image?.isTemplate = true
        statusItem = item

        let overlay = OverlayController()
        // Dashboard sections are built by a registry that has no reference to the
        // overlay, so they say what happened through a notification rather than
        // by failing quietly.
        NotificationCenter.default.addObserver(
            forName: .quillOverlayMessage, object: nil, queue: .main
        ) { note in
            guard let message = note.object as? String else { return }
            MainActor.assumeIsolated {
                overlay.show(.error(message))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { overlay.hide() }
            }
        }

        // One store, shared: the event tap decides whether to swallow ⌥⌫ from it,
        // and the coordinator is what fills it in. Two instances would mean a
        // chord that swallows against a record nobody wrote.
        let undo = InsertionUndo()
        undo.beginWatching()
        self.undo = undo

        let coordinator = DictationCoordinator(
            hotkey: EventTapHotkeyEngine(undo: undo),
            transcriber: SpeechAnalyzerTranscriber(),
            inserter: TextInserter(),
            overlay: overlay,
            // NIMCleaner *contains* FastCleaner rather than replacing it: the fast
            // path is byte-identical and the thorough path adds spoken
            // self-correction. With no key and no network it degrades to the
            // deterministic repair, so this needs no setting behind it — there is
            // no configuration in which it is worse.
            cleaner: NIMCleaner(),
            undo: undo
        )
        self.coordinator = coordinator
        coordinator.start()

        // A second launch hands over to this instance instead of starting a rival.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.romangigliotti.quill.showWindow"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openDashboard() }
        }

        // The grant lands while the app is already running, and nothing notifies
        // us. Polling is what makes Quill come alive the moment the box is
        // ticked, instead of needing a relaunch nobody thinks to do.
        //
        // But it was polling every two seconds forever, and each pass asked TCC
        // about all three permissions twice — once to build the status line and
        // once to build the grant items — so a fully-granted, idle Quill was
        // making six synchronous IPC calls into tccd every two seconds for as
        // long as it ran. On the main thread, which is the thread the event tap's
        // delegate callbacks have to land on.
        //
        // So: poll only while something is actually missing, take one snapshot
        // per pass, and rebuild only when the answer changed.
        startPermissionPollIfNeeded()

        // Re-check when the user comes back from System Settings, which is where
        // they went to change it. This is also what restarts the poll after it
        // has stopped.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }

        // The menu names the dictation key. With the poll now stopping once
        // everything is granted, nothing else would ever redraw it, and a rebind
        // would leave the menu telling you to hold a key that no longer works.
        NotificationCenter.default.addObserver(
            forName: .quillSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildMenu() }
        }
    }

    /// Clicking the Dock icon — or double-clicking the app when it is already
    /// running — opens the window rather than doing nothing.
    ///
    /// LSUIElement apps get no Dock tile of their own, but a user who drags Quill
    /// to the Dock has made one, and a launcher that appears to do nothing when
    /// clicked is indistinguishable from a broken app. The window controller
    /// flips the activation policy to .regular while a window is open, so the
    /// tile behaves normally from then on.
    public func applicationShouldHandleReopen(_ sender: NSApplication,
                                              hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openDashboard() }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        permissionPoll?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    /// One snapshot of everything the menu asks TCC about, taken per pass rather
    /// than per menu item.
    private struct PermissionSnapshot: Equatable {
        let missing: [Permission]
        let secureInput: Bool
    }

    private var lastSnapshot: PermissionSnapshot?

    private func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(missing: Permissions.missing,
                           secureInput: Permissions.secureInputEnabled)
    }

    private func startPermissionPollIfNeeded() {
        permissionPoll?.invalidate()
        permissionPoll = nil
        let now = snapshot()
        lastSnapshot = now
        rebuildMenu(now)
        // Nothing to wait for. The activation observer will restart this if a
        // permission is ever revoked while Quill is running.
        guard !now.missing.isEmpty || now.secureInput else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    private func refreshPermissions() {
        let now = snapshot()
        guard now != lastSnapshot else { return }
        lastSnapshot = now
        rebuildMenu(now)
        if now.missing.isEmpty, !now.secureInput {
            permissionPoll?.invalidate()
            permissionPoll = nil
        } else if permissionPoll == nil {
            startPermissionPollIfNeeded()
        }
    }

    private func rebuildMenu(_ state: PermissionSnapshot? = nil) {
        let state = state ?? snapshot()
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine(state), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let hint = NSMenuItem(title: hintLine(), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let dash = NSMenuItem(title: "Open Quill…", action: #selector(openDashboard), keyEquivalent: "0")
        dash.target = self
        menu.addItem(dash)
        menu.addItem(.separator())

        for p in state.missing {
            let mi = NSMenuItem(title: "Grant \(p.rawValue)…", action: #selector(grant(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = p
            menu.addItem(mi)
        }
        if !state.missing.isEmpty { menu.addItem(.separator()) }

        // The safety net, at the top of the menu where it can be found in a hurry.
        //
        // Every insertion path in this app can fail for reasons outside it: focus
        // moved, the target refused a synthetic paste, Secure Input came on
        // mid-sentence. The text always exists — it is in history a millisecond
        // later — but "open the dashboard, find the row, select the text, copy it"
        // is not something anyone does while the thought is still warm. One click.
        let recover = NSMenuItem(title: "Copy Last Dictation",
                                 action: #selector(copyLastDictation), keyEquivalent: "c")
        recover.keyEquivalentModifierMask = [.command, .shift]
        recover.target = self
        menu.addItem(recover)
        menu.addItem(.separator())

        let scan = NSMenuItem(title: "Find New Words…", action: #selector(scanVocabulary), keyEquivalent: "")
        scan.target = self
        menu.addItem(scan)

        let vocab = NSMenuItem(title: "Edit Vocabulary…", action: #selector(editVocabulary), keyEquivalent: "")
        vocab.target = self
        menu.addItem(vocab)

        let hist = NSMenuItem(title: "Reveal History…", action: #selector(revealHistory), keyEquivalent: "")
        hist.target = self
        menu.addItem(hist)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Quill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    /// Reads the live bindings, so a key changed in Settings is reflected here on
    /// the next poll rather than telling the user to hold a key that no longer
    /// does anything.
    private func hintLine() -> String {
        let settings = QuillSettings.shared
        let hold = settings.hold.displayName
        if settings.toggleSharesHoldKey {
            return "Hold \(hold) to dictate · double-tap to lock"
        }
        return "Hold \(hold) to dictate · tap \(settings.toggle.displayName) for hands-free"
    }

    private func statusLine(_ state: PermissionSnapshot) -> String {
        if state.secureInput { return "Blocked — Secure Input is on" }
        if state.missing.isEmpty { return "Ready" }
        return "Needs \(state.missing.map(\.rawValue).joined(separator: ", "))"
    }

    @objc private func grant(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Permission else { return }
        Permissions.request(p)
    }

    @objc private func openDashboard() {
        if dashboard == nil { dashboard = DashboardWindowController() }
        dashboard?.present()
    }

    /// Puts the last thing you dictated back on the clipboard.
    ///
    /// Reads history rather than caching a copy in memory, so it still works
    /// after the dictation that produced it has been forgotten by everything
    /// else, and so it survives the app being busy with the next one.
    @objc private func copyLastDictation() {
        guard let last = HistoryStore().all.first else {
            NSSound.beep()
            return
        }
        let text = last.insertedText.isEmpty ? last.rawText : last.insertedText
        guard !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Offers the proper nouns found on this Mac, and adds only what is accepted.
    ///
    /// Shown rather than applied. A dictionary that grows by itself is one that
    /// starts rewriting speech into words the user never chose, and the terms in
    /// it are precisely the ones the corrector is allowed to substitute — so the
    /// list has to be seen before it takes effect. The source of each word is
    /// named for the same reason: a suggestion that cannot be judged can only be
    /// accepted on faith.
    @objc private func scanVocabulary() {
        let found = VocabularyHarvest.suggestions()
        let alert = NSAlert()
        guard !found.isEmpty else {
            alert.messageText = "No new words found"
            alert.informativeText = """
                Quill looked at your project folders and package names and found                 nothing that is not already in your dictionary.
                """
            alert.runModal()
            return
        }

        let shown = found.prefix(40)
        alert.messageText = "Found \(found.count) word\(found.count == 1 ? "" : "s") on this Mac"
        alert.informativeText = """
            These came from folder and package names — the words a recogniser has             never seen and mangles every time. Nothing has been added yet.

            """ + shown.map { "  \($0.term)   ·   \($0.source)" }.joined(separator: "\n")
            + (found.count > shown.count ? "\n  …and \(found.count - shown.count) more" : "")
        alert.addButton(withTitle: "Add \(found.count)")
        alert.addButton(withTitle: "Not now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var vocabulary = Vocabulary.load()
        vocabulary.terms.append(contentsOf: found.map(\.term))
        vocabulary.save()
    }

    @objc private func editVocabulary() {
        let url = Vocabulary.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            Vocabulary.seed.save(to: url)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealHistory() {
        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.defaultURL])
    }
}
