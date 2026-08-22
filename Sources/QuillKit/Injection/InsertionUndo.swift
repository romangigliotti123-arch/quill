import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// What the focused field says is sitting immediately before the caret.
public enum CaretReading: Equatable, Sendable {
    /// Accessibility answered, and this is the text.
    case text(String)
    /// There is a live selection. The first backspace eats it instead of our
    /// text, so every count after that is wrong. Always refuse — this is a real
    /// hazard rather than a gap in what the app will tell us.
    case selection
    /// The field says there is text behind the caret, but less of it than our
    /// sentence. So our sentence is not there. Always refuse.
    case shorterThanOurs
    /// The field tracks no caret, but it does expose its visible text.
    ///
    /// This is what a terminal looks like from the outside, and it is not the
    /// same as declining. Measured on Ghostty: `AXTextArea`, `AXNumberOfCharacters`
    /// in the thousands and rising as the screen fills, `AXValue` carrying the
    /// live screen — and `AXSelectedTextRange` returning (0, 0) every time, on an
    /// attribute that is not even settable. A caret at index 0 of a live
    /// two-thousand-character buffer is not a caret; it is a stub.
    ///
    /// Worth its own case because the text it carries is better evidence than the
    /// disturbance guards: if Quill's sentence is on the screen, it is on the
    /// screen, whatever the caret says.
    case screenOnly(String)
    /// Accessibility declined to say. Ordinary rather than exceptional —
    /// Electron apps, web views, terminals, and anything else that does not
    /// expose its text. Also the answer when a field reports its caret at
    /// position zero forever, which is what terminals do: measured on this Mac,
    /// Ghostty reports `AXTextArea` and a caret that never leaves 0, Chrome
    /// reports an `AXGroup` with no caret at all, and VS Code reports no focused
    /// element. TextEdit, by contrast, answers exactly. Three of the four apps
    /// open on the machine cannot verify anything, and they are the three the
    /// user actually dictates into.
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
        guard length > 0 else { return .shorterThanOurs }

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
        else { return Self.visibleText(of: element).map(CaretReading.screenOnly) ?? .unknown }

        var caret = CFRange()
        // swiftlint:disable:next force_cast — guarded by the type-id check above.
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &caret) else {
            return Self.visibleText(of: element).map(CaretReading.screenOnly) ?? .unknown
        }
        // A live selection is deleted whole by the first backspace, so every
        // count after it would be wrong.
        guard caret.length == 0 else { return .selection }
        // A caret at zero is not "the field is empty". It is what a terminal
        // reports whether or not there is anything on the line — Ghostty answers
        // AXTextArea and location 0 forever, on an attribute that is not settable
        // — so it says nothing about the text and must not be read as a refusal
        // on its own. What that app WILL give us is the screen.
        guard caret.location > 0 else {
            return Self.visibleText(of: element).map(CaretReading.screenOnly) ?? .unknown
        }
        // Past zero the number means something: the field is telling us it holds
        // less than our sentence, so our sentence is not what is behind the
        // caret.
        guard caret.location >= length else { return .shorterThanOurs }

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

    /// The whole visible text of an element, when it has any.
    ///
    /// Only asked for once the caret has turned out to be useless, so the cost
    /// falls on the apps that were going to refuse anyway.
    private static func visibleText(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty
        else { return nil }
        return text
    }
}

/// Every decision on the ⌥⌫ path, printed, when `QUILL_LOG_UNDO=1`.
///
/// This path has more ways of silently declining than any other in the app —
/// four guards in `claims`, five in `undoLastInsertion`, and a record that eight
/// different callers can throw away — and every one of them looks identical from
/// the outside: you press the chord and a word disappears, exactly as it would
/// have without Quill. "It doesn't work" is the only report the user can make,
/// and it does not distinguish between them.
public enum UndoTrace {
    public static let on = ProcessInfo.processInfo.environment["QUILL_LOG_UNDO"] == "1"

    /// Written to a file as well as the log, because the log is the harder of the
    /// two to read: this path runs on the tap thread and on main, in a GUI app
    /// launched by `open`, and `log show` needs the right predicate and the right
    /// window to show anything at all. A file is `tail -f`.
    public static let path = NSString(string: "~/Library/Application Support/Quill/undo-trace.log")
        .expandingTildeInPath

    private static let queue = DispatchQueue(label: "com.romangigliotti.quill.undotrace")

    public static func say(_ message: @autoclosure () -> String) {
        guard on else { return }
        let line = message()
        NSLog("[quill/undo] %@", line)
        let stamped = "\(Self.stamp()) \(line)\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func stamp() -> String { formatter.string(from: Date()) }
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
    /// Same, but naming what happened. Only `QUILL_LOG_UNDO=1` reads the reason;
    /// it exists because "the record was gone by the time the chord arrived" is
    /// the single most common way this feature fails and the hardest to see.
    func discard(because reason: String)
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
        let at: Date
    }

    /// How long an insertion stays deletable when nothing can confirm it is
    /// still there.
    ///
    /// Only the unverified path uses it. A field that answers is checked against
    /// the actual characters and needs no clock; a field that will not answer is
    /// being taken on trust, and trust should not outlive the moment. A minute is
    /// far longer than the gesture takes — you say a sentence, you see it is
    /// wrong, you take it back — and far shorter than the time in which a
    /// document can quietly become something else.
    static let unverifiedWindow: TimeInterval = 60

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
            UndoTrace.say("record REFUSED (empty=\(text.isEmpty), pid=\(String(describing: pid)))")
            pending = nil
            return
        }
        UndoTrace.say("record ARMED \(text.count) chars, pid \(pid)")
        pending = Pending(text: text, pid: pid, at: Date())
    }

    /// Deliberately blunt. This is called from the event tap on every real
    /// keystroke, from a mouse monitor on every click, on every app switch and at
    /// the start of every dictation, and in each case the cheapest correct answer
    /// is to stop believing the record rather than to reason about whether that
    /// particular key could have moved the caret.
    public func discard() { discard(because: "unspecified") }

    public func discard(because reason: String) {
        lock.lock()
        defer { lock.unlock() }
        if pending != nil { UndoTrace.say("record DISCARDED — \(reason)") }
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

        guard let record else {
            UndoTrace.say("undo REFUSED — no record by the time it reached main")
            return putBack()
        }
        // The record is dropped on app switches, but a switch in the gap between
        // the tap's check and this line has not been seen yet.
        guard frontmost() == record.pid else {
            UndoTrace.say("undo REFUSED — frontmost is \(String(describing: frontmost())), record was for \(record.pid)")
            return putBack()
        }

        switch caret.textBeforeCaret(pid: record.pid, length: record.text.utf16.count) {
        case .text(let before):
            guard before == record.text else {
                UndoTrace.say("undo REFUSED — the field holds something else behind the caret")
                return putBack()
            }
        case .selection:
            UndoTrace.say("undo REFUSED — there is a live selection; the first backspace would eat that")
            return putBack()
        case .shorterThanOurs:
            UndoTrace.say("undo REFUSED — the field holds less than our sentence, so ours is not there")
            return putBack()
        case .screenOnly(let visible):
            // Better evidence than the guards, and available in exactly the app
            // this feature was reported broken in. The caret is a stub, but the
            // screen is real, so ask the screen.
            guard Self.screen(visible, shows: record.text) else {
                UndoTrace.say("undo REFUSED — our sentence is not on the screen any more")
                return putBack()
            }
            UndoTrace.say("undo VERIFIED against the visible screen")

        case .unknown:
            // Accessibility would not say. Fall back to the disturbance guards.
            //
            // This was a refusal, and the refusal was measured: a probe asked
            // every app running on this Mac what it exposes about its caret.
            // Ghostty reports an AXTextArea whose caret never leaves 0; Chrome
            // reports an AXGroup with no caret; VS Code reports no focused
            // element at all; TextEdit answers exactly. Three of the four, and
            // the three anyone actually dictates into. So the strict version did
            // not make the feature careful — it made it not exist, while looking
            // identical to a bug, because a refusal passes the chord back and the
            // app deletes a word exactly as it always did.
            //
            // What is left to go on is the record still being armed, which is not
            // nothing: every keystroke, every click, every app switch, every
            // moment the event tap was blind, and the start of every dictation
            // all throw it away. The gap those cannot see is an app that rewrites
            // its own text with no input — an autocorrect, an editor formatting
            // on save. Hence the clock: taken on trust, and only for as long as
            // the gesture actually takes.
            guard Date().timeIntervalSince(record.at) <= Self.unverifiedWindow else {
                UndoTrace.say("undo REFUSED — unverifiable and older than \(Int(Self.unverifiedWindow))s")
                return putBack()
            }
            UndoTrace.say("undo UNVERIFIED — nothing has disturbed it, deleting on the guards alone")
        }

        // Graphemes, not UTF-16 units: one backspace removes one visible
        // character, so counting anything smaller takes half an emoji off and
        // leaves the fragment behind.
        UndoTrace.say("undo FIRED — \(record.text.count) backspaces")
        return keyboard.backspace(times: record.text.count)
    }

    /// Whether the visible text still contains what Quill inserted.
    ///
    /// Whitespace-insensitive, because a terminal wraps: the sentence goes in as
    /// one line and comes back off the screen broken across the width of the
    /// window, sometimes with a box-drawing frame down the side of it. Comparing
    /// the characters that carry meaning and ignoring the ones that carry layout
    /// is the only comparison that survives that.
    static func screen(_ visible: String, shows inserted: String) -> Bool {
        func squeeze(_ s: String) -> String {
            String(s.unicodeScalars.filter { scalar in
                // Box drawing (U+2500–257F) and block elements (U+2580–259F) are
                // the frame a TUI paints around its input, not content.
                !(0x2500...0x259F).contains(scalar.value)
            })
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        }
        let needle = squeeze(inserted)
        guard !needle.isEmpty else { return false }
        return squeeze(visible).contains(needle)
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
