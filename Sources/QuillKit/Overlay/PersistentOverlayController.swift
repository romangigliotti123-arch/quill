import AppKit

/// The always-on button at the edge of the screen — Wispr Flow's persistent
/// bar. A second, independent overlay from `OverlayController`'s: that one
/// is the rich listening HUD and appears only during a dictation, however it
/// was started; this one is present whenever `overlayBarEnabled` is on, and
/// is what lets someone start a dictation with a click instead of holding a
/// key at all.
///
/// Two separate panels rather than one panel with two jobs. `OverlayController`
/// ignores mouse events on purpose — a HUD only Escape can dismiss, so a
/// dictation never loses focus to it. This one has to catch clicks, which is
/// exactly the property the other one cannot have.
public final class PersistentOverlayController {

    private var panel: NSPanel?
    private let host = PersistentOverlayHostView(frame: NSRect(origin: .zero,
                                                                size: PersistentOverlayMetrics.panelSize))
    private var settingsObserver: NSObjectProtocol?
    private var dictationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    /// Fired on a click. The controller decides press vs release from
    /// `DictationCoordinator.isCurrentlyDictating` — the one place that
    /// truth actually lives — rather than this view keeping its own guess
    /// that could drift out of sync with a dictation started by the key.
    public var onToggle: (() -> Void)?
    /// Fired from the second segment, shown only when
    /// `overlayShowsNewNoteButton` is on.
    public var onNewNote: (() -> Void)?

    var panelForTesting: NSPanel? { panel }

    /// Where the bar actually is on screen right now, for anything that needs
    /// to put itself relative to it — the quick-note bubble, so far. `nil`
    /// only if the bar has never been shown at all.
    public var currentFrame: NSRect? { panel?.frame }

    public init() {
        host.onClick = { [weak self] in self?.onToggle?() }
        host.onNewNote = { [weak self] in self?.onNewNote?() }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .quillSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.applySettings() }

        dictationObserver = NotificationCenter.default.addObserver(
            forName: .quillDictationStateChanged, object: nil, queue: .main
        ) { [weak self] note in
            self?.host.setActive((note.object as? Bool) ?? false)
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            self.reposition(panel)
        }

        applySettings()
    }

    deinit {
        [settingsObserver, dictationObserver, screenObserver].forEach {
            $0.map(NotificationCenter.default.removeObserver)
        }
    }

    private func applySettings() {
        host.applyStyle(host.effectiveAppearance)
        if QuillSettings.shared.overlayBarEnabled {
            let panel = ensurePanel()
            host.configure(anchor: Self.anchor(for: QuillSettings.shared.overlayBarPosition), label: "Dictate",
                          showsNewNoteButton: QuillSettings.shared.overlayShowsNewNoteButton)
            reposition(panel)
            panel.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    // MARK: - Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = NSPanel(
            contentRect: NSRect(origin: .zero, size: PersistentOverlayMetrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.level = .statusBar
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = false
        // The one setting that has to differ from `OverlayController`'s panel:
        // this bar exists to be clicked.
        created.ignoresMouseEvents = false
        created.hidesOnDeactivate = false
        created.becomesKeyOnlyIfNeeded = true
        created.isReleasedWhenClosed = false
        created.animationBehavior = .none
        created.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                      .fullScreenAuxiliary, .ignoresCycle]
        created.contentView = host
        host.frame = NSRect(origin: .zero, size: PersistentOverlayMetrics.panelSize)
        panel = created
        return created
    }

    private static func anchor(for position: QuillSettings.Values.OverlayBarPosition) -> PersistentOverlayAnchor {
        switch position {
        case .bottomCenter:            return .center
        case .bottomLeft, .topLeft:    return .left
        case .bottomRight, .topRight:  return .right
        }
    }

    /// The screen under the pointer, matching `OverlayController.activeScreen`
    /// — a HUD that stays on whichever display was last active rather than
    /// following `NSScreen.main`, which this app deliberately never sets.
    private var activeScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = activeScreen else { return }
        let size = PersistentOverlayMetrics.panelSize
        let usable = screen.visibleFrame
        let gap = PersistentOverlayMetrics.edgeGap
        let bottom = usable.minY + screen.safeAreaInsets.bottom + gap
        let top = usable.maxY - size.height - gap

        let origin: NSPoint
        switch QuillSettings.shared.overlayBarPosition {
        case .bottomCenter:
            origin = NSPoint(x: (usable.midX - size.width / 2).rounded(), y: bottom.rounded())
        case .bottomLeft:
            origin = NSPoint(x: (usable.minX + gap).rounded(), y: bottom.rounded())
        case .bottomRight:
            origin = NSPoint(x: (usable.maxX - size.width - gap).rounded(), y: bottom.rounded())
        case .topLeft:
            origin = NSPoint(x: (usable.minX + gap).rounded(), y: top.rounded())
        case .topRight:
            origin = NSPoint(x: (usable.maxX - size.width - gap).rounded(), y: top.rounded())
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}
