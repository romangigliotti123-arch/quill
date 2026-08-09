import AppKit

/// The floating HUD. Owns one non-activating panel and hands state to the view
/// inside it.
///
/// The panel never takes focus, on purpose: the whole app is "hold a key, talk,
/// text lands in the app you were already in". A HUD that activates Quill even
/// for a frame moves the insertion point somewhere else and the dictation goes
/// into the wrong window.
///
/// The consequence of `ignoresMouseEvents` is that the HUD can never offer a
/// clickable affordance — a close button here would be dead pixels. Cancel is
/// therefore a key (Escape, via `HotkeyEngineDelegate.hotkeyCancelled`), and
/// the listening state names that key rather than drawing a button.
public final class OverlayController: OverlayPresenting {

    private var panel: NSPanel?
    private let host = OverlayHostView(frame: NSRect(origin: .zero, size: OverlayMetrics.panelSize))
    private var screenObserver: NSObjectProtocol?

    public init() {
        host.onDismissed = { [weak self] in self?.panel?.orderOut(nil) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            self.reposition(panel)
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    public func show(_ state: OverlayState) {
        onMain {
            if case .hidden = state { self.hide(); return }
            let panel = self.ensurePanel()
            if !panel.isVisible {
                self.reposition(panel)
                panel.orderFrontRegardless()
            }
            self.host.present(state)
        }
    }

    public func hide() {
        onMain {
            guard self.panel != nil else { return }
            // Ordering out happens in the dismissal callback, once the exit
            // animation has actually played. Doing it here would make every
            // dictation end with the HUD vanishing on a hard cut.
            self.host.dismiss()
        }
    }

    // MARK: - Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let created = NSPanel(
            contentRect: NSRect(origin: .zero, size: OverlayMetrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.level = .statusBar
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = false
        created.ignoresMouseEvents = true
        created.hidesOnDeactivate = false
        created.becomesKeyOnlyIfNeeded = true
        created.isReleasedWhenClosed = false
        // AppKit's own fade would run against the entry spring and produce a
        // double animation on every show.
        created.animationBehavior = .none
        created.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                      .fullScreenAuxiliary, .ignoresCycle]
        created.contentView = host
        host.frame = NSRect(origin: .zero, size: OverlayMetrics.panelSize)
        panel = created
        return created
    }

    /// The screen under the pointer, not `NSScreen.main`. `main` follows the key
    /// window, and this app deliberately never has one — on a two-display setup
    /// that pins the HUD to whichever screen was last active rather than the one
    /// being looked at.
    private var activeScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = activeScreen else { return }
        let size = OverlayMetrics.panelSize
        // `visibleFrame` already excludes the menu bar, the notch's reserved
        // strip and the Dock; safeAreaInsets covers the displays where the Dock
        // is hidden but the rounded corners still eat the bottom edge.
        let usable = screen.visibleFrame
        let bottom = usable.minY + screen.safeAreaInsets.bottom + OverlayMetrics.bottomGap
        // The pill sits centred in a much taller transparent panel, so the panel
        // has to be dropped by half the slack for the pill to land on `bottom`.
        let slack = (size.height - OverlayMetrics.pillHeight) / 2
        let origin = NSPoint(x: (usable.midX - size.width / 2).rounded(),
                             y: (bottom - slack).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// Transcription and audio callbacks arrive on their own queues. Rather than
    /// make every caller remember that AppKit is main-thread-only, the HUD hops
    /// itself — a dropped frame is a better failure than a crash mid-dictation.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
