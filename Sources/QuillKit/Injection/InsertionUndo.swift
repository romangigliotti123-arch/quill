import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// What the focused field says is sitting immediately before the caret.
public enum CaretReading: Equatable, Sendable {
    /// Accessibility answered, and this is the text.
    case text(String)
    /// Accessibility answered, and the answer rules out a safe delete: there is
    /// a live selection, which the first backspace would eat instead of our
    /// text, or the field does not hold enough characters to contain what we are
    /// looking for.
    case unsafe
    /// Accessibility declined to say. Ordinary rather than exceptional —
    /// Electron apps, web views, and anything that does not expose its text.
    case unknown
}

/// Reads the text just behind the caret, behind a seam.
///
/// A protocol because the real one talks to another process over Accessibility:
/// the answer depends on which window happens to be focused on the machine
/// running the test, which is the one thing the arithmetic below must not.
public protocol CaretTextReading: Sendable {
    /// The `length` UTF-16 units immediately before the caret in the focused
    /// element of `pid`. UTF-16 because every AX range is counted in those, and
    /// mixing them with grapheme counts is how an emoji gets cut in half.
    func textBeforeCaret(pid: pid_t, length: Int) -> CaretReading
}

public struct AccessibilityCaretReader: CaretTextReading {
    public init() {}

    public func textBeforeCaret(pid: pid_t, length: Int) -> CaretReading {
        guard length > 0 else { return .unsafe }

        let app = AXUIElementCreateApplication(pid)
        // Without this, one unresponsive app hangs the caller for the AX default
        // of six seconds, on the main actor, having already swallowed the user's
        // keystroke. Same ceiling SelectionReader settled on.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return .unknown }

        // swiftlint:disable:next force_cast — guarded by the type-id check above.
        let element = focusedRef as! AXUIElement
        // Set on the element as well as the application: they are different
        // objects and a per-object timeout is the only one documented to apply.
        AXUIElementSetMessagingTimeout(element, 0.25)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return .unknown }

        var caret = CFRange()
        // swiftlint:disable:next force_cast — guarded by the type-id check above.
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &caret) else { return .unknown }
        // A live selection is deleted whole by the first backspace, so every
        // count after it would be wrong.
        guard caret.length == 0 else { return .unsafe }
        // Not enough text behind the caret to be ours, so it is not ours.
        guard caret.location >= length else { return .unsafe }

        var wanted = CFRange(location: caret.location - length, length: length)
        guard let parameter = AXValueCreate(.cfRange, &wanted) else { return .unknown }
        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString,
                parameter, &textRef) == .success,
              let text = textRef as? String
        else { return .unknown }
        return .text(text)
    }
}

/// The half of the undo that the event tap can see.
///
/// Everything on it is either lock-guarded arithmetic or a hop to main: the tap
/// callback runs on its own thread against a deadline, and a callback that
/// misses that deadline gets the tap force-disabled by the system.
public protocol InsertionUndoing: AnyObject, Sendable {
    /// Whether there is an insertion the chord could take back. Asked on the tap
    /// thread for every keystroke, so it must stay a lock and a comparison.
    var isArmed: Bool { get }
    /// Something happened that could have moved the caret or changed the text.
    func discard()
    /// Take the last insertion back. Hops to main itself.
    func requestUndo()
}

/// Takes back the last thing Quill inserted, in one keystroke.
///
/// Roman: "when I'm transcribing something and I decide to get rid of all of it,
/// instead of having to delete a word or select it all and then click delete, I
/// should just be able to click delete plus option."
///
/// ⌥⌫ already means "delete the previous word" in every macOS text field, so
/// this overrides a binding people rely on without thinking. The override is
/// only defensible while it is certain, which is what the guards are for: the
/// record is thrown away the instant anything could have moved the caret or
/// changed the text — any keystroke, any click, any app switch, any new
/// dictation — and when it survives all that, Accessibility is asked to confirm
/// our sentence is still sitting immediately behind the caret. When any of it
/// fails, the chord is put back on the wire and the app deletes a word exactly
/// as it always did.
///
/// The asymmetry is the whole design. Not firing costs the user one extra
/// gesture; firing wrongly deletes a sentence they wrote themselves, in a
/// document Quill cannot read back, and they find out later with nothing to
/// blame.
public final class InsertionUndo: InsertionUndoing, @unchecked Sendable {

    /// What we believe is on screen, and where. A belief, never a reading —
    /// there is no API that reports what an app did with a synthetic paste.
    private struct Pending {
        let text: String
        let pid: pid_t
    }

    private let lock = NSLock()
    private var pending: Pending?
    private let keyboard: KeystrokeEmitting
    private let caret: CaretTextReading
    private let frontmost: @MainActor () -> pid_t?
    private var clickMonitor: Any?
    private var activation: NSObjectProtocol?

    /// `frontmost` is injected for the same reason `DictationCoordinator` injects
    /// its context: it reads process-wide state that a unit test does not own,
    /// and a test whose result depends on which window was last clicked is not a
    /// test.
    public init(keyboard: KeystrokeEmitting = SystemKeystrokes(),
                caret: CaretTextReading = AccessibilityCaretReader(),
                frontmost: @escaping @MainActor () -> pid_t? = {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier
                }) {
        self.keyboard = keyboard
        self.caret = caret
        self.frontmost = frontmost
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
    }

    // MARK: - The record

    public var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }

    /// Called once an insertion has actually landed. Reads the destination now,
    /// not at delete time, for the same reason `LiveTyper` captures its target at
    /// `begin()`: the app the words went into is the app that was frontmost when
    /// they went in.
    @MainActor
    public func record(_ text: String) {
        record(text, pid: frontmost())
    }

    func record(_ text: String, pid: pid_t?) {
        lock.lock()
        defer { lock.unlock() }
        guard !text.isEmpty, let pid else {
            pending = nil
            return
        }
        pending = Pending(text: text, pid: pid)
    }

    /// Deliberately blunt. This is called from the event tap on every real
    /// keystroke, from a mouse monitor on every click, on every app switch and at
    /// the start of every dictation, and in each case the cheapest correct answer
    /// is to stop believing the record rather than to reason about whether that
    /// particular key could have moved the caret.
    public func discard() {
        lock.lock()
        defer { lock.unlock() }
        pending = nil
    }

    // MARK: - Taking it back

    /// Called from the tap thread, which has already swallowed the chord.
    ///
    /// `DispatchQueue.main` rather than `Task { @MainActor }` for the same reason
    /// the hotkey engine hops that way: only the queue guarantees these arrive in
    /// the order they were decided. `self` is captured strongly on purpose — the
    /// block is short, there is no cycle, and a store that vanished mid-flight
    /// would leave the swallowed keystroke nowhere.
    public func requestUndo() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.undoLastInsertion() }
        }
    }

    /// The whole decision, on main, where AppKit and Accessibility live.
    ///
    /// Returns whether the text was taken back. When it was not, the chord goes
    /// back out to the app so ⌥⌫ still deletes a word: the tap swallowed it on
    /// the strength of a cheap check, and this is where that promise is kept.
    ///
    /// Internal rather than public because of what a refusal does: it posts a
    /// real ⌥⌫. Calling this without having swallowed one first would delete a
    /// word out of somebody's document for no reason, so the only caller allowed
    /// is `requestUndo`, and the only caller of that is the tap.
    @discardableResult
    @MainActor
    func undoLastInsertion() -> Bool {
        lock.lock()
        let record = pending
        // Consumed either way. One chord, one attempt — a second press must reach
        // the app rather than try again against a field we have just failed to
        // recognise.
        pending = nil
        lock.unlock()

        guard let record else { return putBack() }
        // The record is dropped on app switches, but a switch in the gap between
        // the tap's check and this line has not been seen yet.
        guard frontmost() == record.pid else { return putBack() }

        switch caret.textBeforeCaret(pid: record.pid, length: record.text.utf16.count) {
        case .text(let before):
            guard before == record.text else { return putBack() }
        case .unsafe:
            return putBack()
        case .unknown:
            // Accessibility would not say, which is the ordinary case in Electron
            // and every web view — i.e. in a large share of where dictation is
            // actually used. Falling back to the disturbance guards is the same
            // trade `LiveTyper` already makes every time it backspaces, and
            // refusing here would mean the feature never fires in the apps it is
            // most wanted in. It is also the one place this can still be wrong:
            // an app that rewrote our text by itself, with no keystroke and no
            // click, would be invisible from here.
            break
        }

        // Graphemes, not UTF-16 units: one backspace removes one visible
        // character, so counting anything smaller takes half an emoji off and
        // leaves the fragment behind.
        return keyboard.backspace(times: record.text.count)
    }

    @discardableResult
    private func putBack() -> Bool {
        keyboard.chord(key: UndoChord.keyCode, flags: UndoChord.flags)
        return false
    }

    // MARK: - What invalidates a record

    /// Starts watching the two things that move a caret without a keystroke.
    ///
    /// Not done in `init`, because constructing this in a test must not install a
    /// process-wide event monitor.
    @MainActor
    public func beginWatching() {
        guard clickMonitor == nil else { return }
        // The event tap is keyboard-only by design, so a click — the ordinary way
        // to move a caret — is invisible to it.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in self?.discard() }
        // Leaving an app and coming back does not put the caret where it was.
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.discard() }
    }
}
