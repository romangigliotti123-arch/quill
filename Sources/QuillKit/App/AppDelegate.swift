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
    /// Held for the app's lifetime, same reasoning as `undo` above: it owns a
    /// panel and three notification observers, and letting it go silently
    /// stops the always-on bar from following settings changes.
    private var persistentOverlay: PersistentOverlayController?
    /// Held for the same reason: it owns the quick-note bubble's own panel.
    private var quickNoteBubble: QuickNoteBubbleController?

    /// The live record, reachable by the rehearsal hook in main.swift. Nothing in
    /// the app reads it; it exists so the undo path can be driven against a real
    /// window without speaking into a microphone.
    public private(set) static var sharedUndo: InsertionUndo?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Captured before anything can create the settings file. `isFirstRun` is
        // "settings.json does not exist", and half the setup below writes it.
        let needsSetup = OnboardingWindowController.isFirstRun

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
        AppDelegate.sharedUndo = undo

        // Transforms, connected at last.
        //
        // The engine, the router and the selection reader are 1,300 lines of
        // tested code that nothing ever constructed — so the Transforms screen
        // listed eight of them, each captioned with the phrase that runs it, and
        // saying any of those phrases typed it into the document as content.
        //
        // Built here rather than inside the coordinator because the engine needs
        // the same NIM client the cleaner uses and the coordinator needs to hand
        // it the last thing it inserted. The closure is what keeps that current:
        // a value passed in would be whatever existed at launch, forever.
        let transformEngine = TransformEngine(
            completer: NIMClient(),
            selection: SelectionReader(),
            inserter: TextInserter(),
            lastDictation: { [weak self] in
                MainActor.assumeIsolated { self?.coordinator?.lastInsertion }
            }
        )

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
            undo: undo,
            transforms: (CommandRouter(), transformEngine)
        )
        self.coordinator = coordinator
        coordinator.start()

        // The always-on bottom bar: a click starts or stops a dictation
        // through the exact same coordinator the held key does, so the two
        // triggers can never disagree about what state a dictation is in.
        let persistentOverlay = PersistentOverlayController()
        persistentOverlay.onToggle = { [weak coordinator] in
            guard let coordinator else { return }
            if coordinator.isCurrentlyDictating {
                coordinator.hotkeyReleased()
            } else {
                coordinator.hotkeyPressed()
            }
        }
        persistentOverlay.onNewNote = { [weak self] in self?.startQuickNote() }
        self.persistentOverlay = persistentOverlay
        quickNoteBubble = QuickNoteBubbleController()

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

        // Touched, not called: `SyncEngine.shared` registers its account
        // observer the moment it is first read, which is what lets sync start
        // the instant the app launches — already signed in from a prior
        // session — rather than waiting for someone to open Settings.
        _ = SyncEngine.shared

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

        // Last, and only on a Mac that has never run this before.
        //
        // Everything Quill needs fails silently when it is missing: no
        // microphone is "nothing was heard", no Accessibility is a hotkey that
        // does nothing with no error anywhere, and no key is a cleanup pass that
        // quietly never runs. A stranger who cloned this would meet all three as
        // "it doesn't work", in an order they did not choose, from a menu-bar
        // icon with nothing to click. So they are asked for once, in order,
        // before any of them can fail.
        if needsSetup {
            DispatchQueue.main.async { OnboardingWindowController.present() }
        } else {
            showUpdateNoticeIfPermissionsWereDropped()
        }
    }

    /// The first launch after an update, when macOS has quietly taken the
    /// permissions away.
    ///
    /// A TCC grant is bound to the app's Designated Requirement, which for a
    /// self-signed app names the signing certificate. Change the certificate and
    /// every grant stops applying — and the System Settings toggle keeps reading
    /// ON, pointing at a hash that no longer exists, so there is nothing on
    /// screen anywhere that says what happened. The releases before v1.0.4 each
    /// shipped a different certificate, so this happened on every single update:
    /// the user's dictation key stopped working, the toggles all looked correct,
    /// and the README's advice — remove Quill from the list and add it again —
    /// was findable only by someone who already knew what to search for.
    ///
    /// From v1.0.4 the certificate is pinned, so this should never fire again.
    /// It stays because "should never" is not "cannot": a lost signing key, or
    /// a real Developer ID certificate one day, would do exactly this, and the
    /// cost of being wrong is a user concluding the app is broken.
    ///
    /// Deliberately not on every launch — only when the version actually
    /// changed. Someone who has considered Accessibility and decided against it
    /// gets told once, not every time they log in.
    @MainActor
    private func showUpdateNoticeIfPermissionsWereDropped() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let previous = QuillSettings.shared.noteLaunch(of: version)
        // nil means an install from before this was recorded, which is every
        // build up to v1.0.3 — and those are exactly the installs whose grants
        // the update to v1.0.4 drops. Treat it as the update it is.
        guard previous != version else { return }
        guard !Permissions.missing.isEmpty else { return }

        // The Help screen already lists each permission with its real state and
        // a button that opens the right pane. Better than an alert that says the
        // same thing and then goes away.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.dashboard == nil { self.dashboard = DashboardWindowController(selection: .help) }
            self.dashboard?.present()
            self.dashboard?.rootView.showSection(.help)
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

    /// Who asked us to quit, and from where.
    ///
    /// Roman: "it just crashed and i think it always crashed whenever you open
    /// the interface, x out of it and try and dictate."
    ///
    /// It is not crashing. `RBSProcessExitContext| voluntary` and
    /// `termination reported by launchd (0, 0, 0)` — exit status zero, no
    /// signal, no `.ips`. The app is quitting itself, which from the outside is
    /// indistinguishable from a crash: the menu bar item disappears and the next
    /// dictation does nothing.
    ///
    /// That distinction is the whole reason this exists. A crash leaves a report
    /// naming the faulting frame; a voluntary exit leaves nothing at all, and
    /// there is no way to tell an intentional Quit from a stray `terminate(nil)`
    /// after the fact. So the app now says so itself, with the call stack, every
    /// time — and the two legitimate callers (Uninstall, and the relaunch after
    /// Erase) will be named in it just as plainly as an accidental one.
    ///
    /// Never blocks the quit. An instrument that changes the thing it measures
    /// is not an instrument, and a user who chose Quit must get one.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The WHOLE stack, not just our frames.
        //
        // The first version of this filtered to symbols containing "Quill",
        // which threw away the only frames that could still answer the question.
        // Three reproductions in, we know the terminate is graceful, is not our
        // Quit menu item, and carries no Quill frames at all — so the caller is
        // AppKit or the system, and its name is in exactly the frames that were
        // being discarded. An instrument that filters out the answer is worse
        // than none, because it looks like it worked.
        let stack = Thread.callStackSymbols
            .prefix(24)
            .map { $0.split(separator: " ").dropFirst(3).joined(separator: " ") }
            .joined(separator: " | ")

        let state = [
            "sender=\(Self.appleEventSender())",
            "dashboard=\(dashboard == nil ? "nil" : "alive")",
            "policy=\(NSApp.activationPolicy().rawValue)",
            "active=\(NSApp.isActive)",
            "windows=\(NSApp.windows.count)",
            "visibleWindows=\(NSApp.windows.filter(\.isVisible).count)",
            "dictations=\(Self.dictationsThisLaunch)",
        ].joined(separator: " ")

        // An idle-app cleaner does not get to interrupt a sentence.
        //
        // The sender in Roman's log is Vorssaint, a menu-bar utility whose
        // `autoQuitEnabled` setting quits apps it judges unused. Quill looks
        // unused to that kind of tool almost all the time: it is `LSUIElement`,
        // it holds no window, and between dictations it genuinely is idle. The
        // fix for the general case is Vorssaint's exclusion list, not this — but
        // whatever the requester, being asked to quit in the middle of a
        // dictation must not cost the user the words they are currently saying.
        //
        // Only refused for an Apple Event, and only mid-dictation. A quit the
        // user chose — the menu, ⌘Q, logging out — is honoured immediately, in
        // every state. Refusing one of those would be a far worse bug than the
        // one this is guarding.
        if Self.dictationInFlight, NSAppleEventManager.shared().currentAppleEvent != nil {
            NSLog("[quill] refused a quit from %@ — a dictation is in flight", Self.appleEventSender())
            Self.recordExit(state: "REFUSED (dictating) " + state, stack: "")
            return .terminateCancel
        }

        NSLog("[quill] TERMINATING — %@ — %@", state, stack)
        Self.recordExit(state: state, stack: stack)
        return .terminateNow
    }

    /// True from key-down until the words have landed. Read by
    /// `applicationShouldTerminate` and nothing else.
    nonisolated(unsafe) static var dictationInFlight = false

    /// Which process asked us to quit, by name.
    ///
    /// The stack from the last reproduction ended in `_handleAEQuit` ←
    /// `AEProcessAppleEvent`: somebody sent Quill a quit Apple Event, the same
    /// thing `osascript -e 'tell application "Quill" to quit'` sends. Nothing in
    /// Quill sends it — there is no `NSRunningApplication.terminate()` anywhere
    /// in the app — and the system log brokers these without naming either end,
    /// so the sender cannot be recovered from outside.
    ///
    /// It can be recovered from inside. The event is still current while this
    /// handler runs, and it carries the sender's pid as an attribute. That turns
    /// "something quit it" into a process name, which is the difference between
    /// a fix and another round trip.
    static func appleEventSender() -> String {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return "none (not an Apple Event — menu, code, or the system)"
        }
        var description = "event=\(event.eventClass):\(event.eventID)"
        // `keySenderPIDAttr` is 'spid'. Foundation does not expose a constant.
        let senderPID = AEKeyword(0x73706964)
        if let pidDescriptor = event.attributeDescriptor(forKeyword: senderPID) {
            let pid = pid_t(pidDescriptor.int32Value)
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? "pid \(pid)"
            description += " from=\(name)(pid \(pid))"
        } else {
            description += " from=unknown"
        }
        return description
    }

    /// How many dictations have finished since launch.
    ///
    /// Roman, on the sharpest reproduction yet: "i clicked option it was fine,
    /// clicked again it crashed." If that is real, the count in the exit line is
    /// the cheapest possible confirmation — it will read 1 every time.
    nonisolated(unsafe) static var dictationsThisLaunch = 0

    /// A file, not just `NSLog`, because the log is not readable here.
    ///
    /// Nothing this app writes with `NSLog` comes back out of `log show` on this
    /// Mac — checked repeatedly while chasing this, with the app running and the
    /// predicate matching other processes fine. A diagnosis you cannot read is
    /// not a diagnosis, so the reason goes somewhere it can always be read.
    ///
    /// Appends, bounded, next to the other stores. Every quit gets one line: when
    /// it happened, whether the window was open, and who asked. A deliberate Quit
    /// names the AppKit menu frames; an accidental `terminate(nil)` names the
    /// code that called it; an outside kill names nothing, which is itself the
    /// answer.
    private static func recordExit(state: String, stack: String) {
        let url = QuillData.directory.appendingPathComponent("exits.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)\t\(state)\n\t\(stack)\n"

        // Keep the tail rather than the head: the interesting quit is the most
        // recent one, and a log that grows forever is its own bug.
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        existing += line
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 50 { existing = lines.suffix(50).joined(separator: "\n") }
        try? existing.write(to: url, atomically: true, encoding: .utf8)
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

    /// The overlay bar's "New Note" segment. No window opens: a small bubble
    /// appears right above the bar and starts recording into it immediately,
    /// the same way the bar's main segment starts any other dictation — a
    /// second click on that same segment (now showing the live-mic dot)
    /// stops it, exactly as it always does.
    @MainActor
    private func startQuickNote() {
        guard let coordinator else { return }
        quickNoteBubble?.begin(near: persistentOverlay?.currentFrame, coordinator: coordinator)
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

        // `loadOutcome`, not `load`. This is a read-modify-write, and `load`
        // cannot tell "no file yet" from "a file I could not read" — both hand
        // back the shipped seed. Writing after the second one puts thirty stock
        // terms over everything the user has added, permanently. The guard exists
        // and every other writer already uses it; this path did not.
        let (loaded, damaged) = Vocabulary.loadOutcome()
        guard !damaged else {
            let warning = NSAlert()
            warning.messageText = "Your vocabulary file could not be read"
            warning.informativeText = """
                Nothing was changed. A copy has been kept next to it so you can                 open it and fix it by hand — adding these words now would write                 over everything already in there.
                """
            warning.addButton(withTitle: "Show me the file")
            warning.addButton(withTitle: "Not now")
            if warning.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([Vocabulary.defaultURL])
            }
            return
        }
        var vocabulary = loaded
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
