import AppKit

/// A key-capable borderless panel — the one exception to `OverlayController`'s
/// rule that Quill's own panels never take keyboard focus. That rule exists
/// because normal dictation always lands in whatever app you were already in;
/// a quick note is the one case where the destination genuinely IS Quill
/// itself, so this panel has to be able to become key to receive it. Borderless
/// windows refuse key status by default — this is the whole reason the
/// subclass exists.
private final class QuickNoteBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Dictating a note straight from the overlay bar, with no window involved.
///
/// Click "New Note": a small bubble opens right above the bar with a blank
/// line already listening, and dictation starts the same instant — through
/// the exact same `DictationCoordinator` the held key and the bar's own
/// dictate button use, so it is genuinely a normal dictation and not a
/// second, parallel implementation of one. The only thing that differs from
/// dictating into any other app is *which* window is key when it starts: this
/// bubble's, so the words land here instead of wherever the cursor happened
/// to be. Click the bar again to stop, exactly like any other dictation; the
/// bubble holds what landed for a moment, then it is saved as a new Note and
/// the bubble closes.
@MainActor
public final class QuickNoteBubbleController {

    private var panel: NSPanel?
    private let textArea: SnippetsTextArea
    private var activeNoteID: UUID?
    private var settledObserver: NSObjectProtocol?
    private let store: NoteStore

    public init(store: NoteStore = .shared) {
        self.store = store
        textArea = SnippetsTextArea(style: DashboardStyle.resolve(nil), placeholder: "")

        settledObserver = NotificationCenter.default.addObserver(
            forName: .quillDictationSettled, object: nil, queue: .main
        ) { [weak self] _ in self?.finish() }
    }

    deinit {
        if let settledObserver { NotificationCenter.default.removeObserver(settledObserver) }
    }

    /// So a second click on "New Note" while one is already open is a no-op
    /// rather than a second note started mid-dictation.
    public var isCapturing: Bool { activeNoteID != nil }

    /// `barFrame` is the persistent bar's current on-screen frame — see
    /// `PersistentOverlayController.currentFrame`. Nothing happens if it is
    /// nil, which only occurs if the bar itself has never actually been shown.
    public func begin(near barFrame: NSRect?, coordinator: DictationCoordinator) {
        guard !isCapturing, let barFrame else { return }
        let created = store.upsert(Note())
        activeNoteID = created.id
        textArea.text = ""

        let panel = ensurePanel()
        position(panel, near: barFrame)
        panel.makeKeyAndOrderFront(nil)
        textArea.focus()

        coordinator.hotkeyPressed()
    }

    // MARK: - Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let size = PersistentOverlayMetrics.noteBubbleSize
        let created = QuickNoteBubblePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.level = .statusBar
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.animationBehavior = .none
        created.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                      .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        textArea.frame = NSRect(origin: .zero, size: size)
        textArea.autoresizingMask = [.width, .height]
        effect.addSubview(textArea)

        created.contentView = effect
        panel = created
        return created
    }

    /// Above the bar, on the side facing away from whichever screen edge it
    /// is docked to — "above" a bar someone has moved to the top of the
    /// screen would run straight off it, so this checks room rather than
    /// assuming the common bottom-docked case.
    private func position(_ panel: NSPanel, near barFrame: NSRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(barFrame) })
                ?? NSScreen.main else { return }
        let size = PersistentOverlayMetrics.noteBubbleSize
        let gap = PersistentOverlayMetrics.noteBubbleGap
        let usable = screen.visibleFrame

        let above = barFrame.maxY + gap
        let y = (above + size.height <= usable.maxY) ? above : (barFrame.minY - gap - size.height)
        let x = (barFrame.midX - size.width / 2).rounded()
        let clampedX = min(max(x, usable.minX + gap), usable.maxX - size.width - gap)
        panel.setFrame(NSRect(x: clampedX, y: y.rounded(), width: size.width, height: size.height),
                       display: false)
    }

    // MARK: - Ending

    /// Fires on every dictation's end, not just this one's — the guard on
    /// `activeNoteID` is what makes an unrelated dictation elsewhere a no-op
    /// here rather than reading this bubble's text at the wrong moment.
    private func finish() {
        guard let noteID = activeNoteID else { return }
        activeNoteID = nil
        let text = textArea.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // Escape, or a tap that never became a real dictation — nothing
            // was said, so the note this created up front is discarded rather
            // than left behind blank.
            store.remove(id: noteID)
            dismiss()
            return
        }
        var note = store.note(id: noteID) ?? Note(id: noteID)
        note.body = text
        note.updated = Date()
        _ = store.upsert(note)
        // Long enough to read the last couple of words that just landed —
        // the same lingering `OverlayState.inserted` already sits for
        // elsewhere in the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.dismiss() }
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }
}
