import CoreGraphics
import Foundation

/// ⌥⌫ — "take back what you just inserted" — as a decision rather than a
/// keystroke.
///
/// Pure, and separated from the tap for the same reason the gesture grammar is:
/// this is the part that decides whether Quill deletes text out of somebody
/// else's document, and it has to be checkable without a keyboard.
///
/// It is not part of `HotkeyStateMachine` because it is not a gesture — there is
/// no hold, no double-tap and no timer in it. It does have to know what the
/// gesture machine is doing, which is why the state comes in as an argument.
public enum UndoChord {

    /// The key labelled ⌫. Shared with `SyntheticKeyboard` so the code that
    /// swallows the chord and the code that puts it back cannot drift apart.
    public static let keyCode: UInt16 = SyntheticKeyboard.keyBackspace
    public static let flags: CGEventFlags = .maskAlternate

    /// Whether this keystroke should be claimed by Quill instead of reaching the
    /// app.
    ///
    /// Every clause is a way of not firing, which is the point: ⌥⌫ deletes the
    /// previous word in every macOS text field, and an override that fires when
    /// it should not is worse than no override at all.
    public static func claims(keyCode: UInt16,
                              flags: CGEventFlags,
                              gesture: HotkeyStateMachine.State,
                              hasInsertion: Bool) -> Bool {
        guard hasInsertion else { return false }
        guard keyCode == Self.keyCode else { return false }
        // Exactly Option. ⇧⌥⌫ and ⌘⌥⌫ are other people's bindings and are left
        // alone; `chordMask` is what strips the fn and numeric-pad bits that
        // arrive set on a built-in keyboard.
        guard flags.intersection(HotkeyBinding.chordMask) == Self.flags else { return false }

        switch gesture {
        case .idle:
            return true
        case .armed:
            // The dictation key may itself be an Option — right Option is the
            // default. Pressing ⌥⌫ therefore arms a speculation with the modifier
            // and delivers the ⌫ a few milliseconds later, and without this clause
            // the chord would never work for anyone using the shipped binding.
            // Nobody starts a dictation and types a backspace inside the 120ms arm
            // delay, so this is the chord and not a gesture.
            return true
        case .holding, .handsFree:
            // The user is speaking. A ⌫ here means "cancel this dictation", which
            // the state machine already handles, and claiming it would delete the
            // PREVIOUS sentence as well as binning the current one.
            return false
        }
    }
}
