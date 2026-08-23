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
    /// Whether a presentation is in progress, as distinct from whether the panel
    /// is ordered in. The two come apart — see `show` — and only this one is a
    /// safe answer to "has the HUD already been put where it belongs".
    private var isShowing = false
    /// Cancels the fallback order-out when the exit animation gets there first.
    private var exitFallback: DispatchWorkItem?

    /// The panel, for tests that need to see where it ended up. There is no other
    /// way to check that the HUD was raised: everything this class does happens
    /// to a window, and a window is not a return value.
    var panelForTesting: NSPanel? { panel }

    /// The real display link's real per-frame gap, for `OverlayFrameStressTest`.
    var frameObserverForTesting: ((CFTimeInterval) -> Void)? {
        get { host.frameObserver }
        set { host.frameObserver = newValue }
    }

    public init() {
        host.onDismissed = { [weak self] in
            guard let self else { return }
            self.exitFallback?.cancel()
            self.exitFallback = nil
            self.isShowing = false
            self.panel?.orderOut(nil)
        }
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
            // Gated on our own state, not on `panel.isVisible`.
            //
            // `isVisible` only says the panel was ordered in at some point. It
            // does not say the panel is still in front of anything, and — the
            // part that bites — it does not say the dismissal that was supposed
            // to order it out ever finished. AppKit runs the exit animation off
            // the view's display link, and it pauses that link the moment the
            // window stops being visible: a Space switch or Mission Control
            // landing on a fade-out freezes the exit where it stands, so
            // `onDismissed` never fires and the panel stays "visible" for the
            // rest of the launch. From then on this branch was never taken
            // again, and the HUD was never re-raised or re-positioned however
            // far behind it had fallen.
            //
            // Stated precisely, because half of that is measured and half is
            // inferred: the display-link pause and the stranded `isVisible == true`
            // are both reproducible. That this is what Roman saw when his HUD did
            // not appear is the best-supported explanation and NOT a confirmed
            // reproduction — it needs a Space switch or Mission Control landing
            // inside a fade-out, which has not been driven end to end.
            //
            // OR, not instead. `isShowing` is our bookkeeping and `isVisible` is
            // AppKit's truth, and each catches what the other cannot: ours knows
            // about an exit that froze, theirs knows about an order-out that never
            // came through `hide()` at all. `NSApp.hide(nil)` is exactly that —
            // Re-insert calls it, and Cmd-H reaches the app while the dashboard
            // holds it at `.regular` — and a hidden app does not honour
            // `orderFrontRegardless`. Gating on `isShowing` alone would try once
            // and give up, which is the mirror image of the bug being fixed here.
            //
            // Raising a panel that is already front is free.
            if !self.isShowing || !panel.isVisible {
                self.isShowing = true
                self.exitFallback?.cancel()
                self.exitFallback = nil
                self.reposition(panel)
                panel.orderFrontRegardless()
            }
            self.host.present(state)
        }
    }

    public func hide() {
        onMain {
            guard let panel = self.panel else { return }
            // Ordering out happens in the dismissal callback, once the exit
            // animation has actually played. Doing it here would make every
            // dictation end with the HUD vanishing on a hard cut.
            self.host.dismiss()
            // From here the HUD is no longer where it was put, so the next
            // presentation has to place and raise it again rather than assume.
            self.isShowing = false
            // Unless the animation never plays. It needs display-link frames and
            // those stop arriving whenever the window stops being visible, which
            // leaves a half-faded pill ordered in with nothing left to finish it.
            // The runloop keeps running through all of that, so a plain timer is
            // the one thing here that still works.
            self.exitFallback?.cancel()
            // Nothing to re-check inside: every path that clears `exitFallback`
            // cancels it first, and a cancelled work item never runs its block. A
            // `!= nil` guard here would be unreachable, and — worse — it is a
            // presence test rather than an identity test, so on the one ordering
            // where it could run it would pass while a NEWER item was stored and
            // order out a live HUD. `isShowing` is already false: `hide()` set it
            // three lines up and only `show()` sets it back, which cancels this.
            let fallback = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.exitFallback = nil
                panel.orderOut(nil)
            }
            self.exitFallback = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitGrace, execute: fallback)
        }
    }

    /// Long enough that the exit spring always wins in the ordinary case — it
    /// settles in about a third of a second — and short enough that a HUD frozen
    /// by a Space switch is gone before the next dictation starts.
    private static let exitGrace: TimeInterval = 1.0

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
