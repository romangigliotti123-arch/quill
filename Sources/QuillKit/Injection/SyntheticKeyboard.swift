import CoreGraphics
import Foundation

/// The keystrokes Quill posts on the user's behalf, stamped so the rest of the
/// app can tell them apart from the user's own typing.
public enum SyntheticKeyboard {

    /// ANSI virtual key codes are positional, not character-based; 9 is the key
    /// labelled V on a US layout and stays that key on every other layout, which
    /// is what makes ⌘V portable.
    public static let keyV: CGKeyCode = 9

    /// ANSI Delete — the key labelled ⌫. Used to take back text Quill typed
    /// speculatively while you were still speaking.
    public static let keyBackspace: CGKeyCode = 51

    /// ANSI Return. Used by the "finish, then Enter" gesture — see
    /// `DictationCoordinator.hotkeyAborted()`.
    public static let keyReturn: CGKeyCode = 36

    /// Defensive chunk size in UTF-16 units for the typing fallback.
    /// `keyboardSetUnicodeString` takes a length, but long strings are unreliable
    /// across apps and truncation is silent — there is no return value, no error,
    /// just a missing tail. Small chunks cost microseconds.
    public static let chunkLimit = 16

    // MARK: - Posting

    /// Posts a modified chord (down, then up).
    ///
    /// Returns false only when the events could not be constructed. A true here
    /// says the event was posted, never that the focused app acted on it —
    /// CoreGraphics has no API that tells you that, which is why the caller has
    /// to be honest about the difference.
    @discardableResult
    public static func postChord(key: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = makeSource(),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }

        down.flags = flags
        up.flags = flags
        stamp(down)
        stamp(up)
        // Explicit flags on the key events are enough for ⌘V everywhere Quill
        // targets; synthesising the Command key's own down/up around them adds
        // two more events that can interleave with the user's real modifiers.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// The fallback: hand characters to the focused app directly, no clipboard
    /// involved. Slower than pasting and it loses to aggressive autocomplete, but
    /// it survives apps that ignore a synthetic ⌘V.
    @discardableResult
    public static func type(_ text: String) -> Bool {
        guard !text.isEmpty, let source = makeSource() else { return false }

        for chunk in chunks(of: text) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }

            for event in [down, up] {
                chunk.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count,
                                                   unicodeString: buffer.baseAddress)
                }
                // Virtual key 0 is the A key. An app that honours the key code
                // instead of the attached string types "aaaa" — there is no code
                // meaning "no key", and that hazard is a large part of why typing
                // is the fallback rather than the primary path.
                event.flags = []
                stamp(event)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)

            // Chunks are independent events. Apps that coalesce input can drop
            // characters when several land in one run-loop turn; a sub-millisecond
            // gap is cheap insurance on a path that only runs when paste failed.
            usleep(1_500)
        }
        return true
    }

    /// Posts `count` backspaces.
    ///
    /// One event per character, because there is no "delete N" keystroke — and
    /// with a gap between them, because a text view that coalesces input drops
    /// backspaces that arrive in the same run-loop turn. Dropping one is not a
    /// cosmetic bug: it leaves a stale character in the middle of the sentence
    /// and every subsequent edit is off by one.
    @discardableResult
    public static func backspace(times count: Int, gap: useconds_t = 700) -> Bool {
        guard count > 0 else { return true }
        guard let source = makeSource() else { return false }
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyBackspace, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyBackspace, keyDown: false)
            else { return false }
            down.flags = []
            up.flags = []
            stamp(down)
            stamp(up)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(gap)
        }
        return true
    }

    // MARK: - Chunking

    /// Splits text into UTF-16 runs that are safe to hand to one event.
    ///
    /// The split happens on grapheme-cluster boundaries, never mid-unit. A
    /// surrogate pair broken across two events types two replacement characters;
    /// a ZWJ emoji sequence broken across two types its component people. Both
    /// are silent corruption of text the user spoke, which is the failure this
    /// whole subsystem exists to prevent.
    ///
    /// A single cluster longer than `limit` gets its own oversized chunk — better
    /// to risk one truncation than to guarantee corruption.
    public static func chunks(of text: String, limit: Int = chunkLimit) -> [[UniChar]] {
        var out: [[UniChar]] = []
        var current: [UniChar] = []

        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty && current.count + units.count > limit {
                out.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Event plumbing

    /// A private source state, deliberately — not `.combinedSessionState`.
    ///
    /// A combined source starts from whatever modifiers are physically down.
    /// Push-to-talk means the user's hand may still be on a modifier when the
    /// paste goes out, and ⌘⇧V is "paste and match style" in half the apps on
    /// the machine. A private state starts clean, so the flags we set are the
    /// flags the target sees.
    private static func makeSource() -> CGEventSource? {
        CGEventSource(stateID: .privateState)
    }

    /// Every event Quill posts carries the marker in `.eventSourceUserData`.
    ///
    /// Without it the hotkey tap reads our own ⌘V as the user pressing a key
    /// mid-dictation and throws the session away. The symptom — "pasting cancels
    /// the dictation that produced the paste" — is not something you would ever
    /// guess from the outside.
    private static func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: QuillSyntheticEventMarker)
    }
}
