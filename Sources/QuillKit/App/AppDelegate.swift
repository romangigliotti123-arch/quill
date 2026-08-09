import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var coordinator: DictationCoordinator?
    private var permissionPoll: Timer?
    /// Held for the app's lifetime: the window is closed, not destroyed, so
    /// reopening it keeps the selected section and the frame the user left it at.
    private var dashboard: DashboardWindowController?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Quill")
        item.button?.image?.isTemplate = true
        statusItem = item

        let coordinator = DictationCoordinator(
            hotkey: EventTapHotkeyEngine(),
            transcriber: SpeechAnalyzerTranscriber(),
            inserter: TextInserter(),
            overlay: OverlayController()
        )
        self.coordinator = coordinator
        coordinator.start()

        rebuildMenu()

        // The grant lands while the app is already running, and nothing notifies
        // us. Polling is what makes Quill come alive the moment the box is
        // ticked, instead of needing a relaunch nobody thinks to do.
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        permissionPoll?.invalidate()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let hint = NSMenuItem(title: "Hold Right ⌥ to dictate · double-tap to lock", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let dash = NSMenuItem(title: "Open Quill…", action: #selector(openDashboard), keyEquivalent: "0")
        dash.target = self
        menu.addItem(dash)
        menu.addItem(.separator())

        for p in Permissions.missing {
            let mi = NSMenuItem(title: "Grant \(p.rawValue)…", action: #selector(grant(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = p
            menu.addItem(mi)
        }
        if !Permissions.missing.isEmpty { menu.addItem(.separator()) }

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

    private func statusLine() -> String {
        if Permissions.secureInputEnabled { return "Blocked — Secure Input is on" }
        let missing = Permissions.missing
        if missing.isEmpty { return "Ready" }
        return "Needs \(missing.map(\.rawValue).joined(separator: ", "))"
    }

    @objc private func grant(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Permission else { return }
        Permissions.request(p)
    }

    @objc private func openDashboard() {
        if dashboard == nil { dashboard = DashboardWindowController() }
        dashboard?.present()
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
