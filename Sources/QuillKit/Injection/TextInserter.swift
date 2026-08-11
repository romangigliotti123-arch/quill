import AppKit
import Foundation

/// Puts transcribed text into whatever app has focus.
///
/// One rule outranks every other decision in this file: **the text must never
/// vanish**. A dictation app that loses a sentence is worse than one that never
/// inserted it, because the user finds out later, somewhere else, with nothing
/// to blame. So every failure path here ends with the text on the clipboard and
/// a reason a human can read.
///
/// Why paste and not Accessibility: `AXUIElementSetAttributeValue` looks like the
/// clean answer and is a trap. In Electron apps (VS Code, Slack, Discord — a
/// large share of where dictation actually gets used) it returns `.success` and
/// then inserts at the wrong offset, or replaces the whole field. A silent wrong
/// answer is the worst failure shape available, worse than an outright refusal.
/// AX is worth keeping for *cursor-relative editing* — reading a selection range,
/// deleting the last sentence — where the caller can verify what happened. It is
/// not worth it for insertion.
///
/// Call `insert` on the main thread: it touches AppKit's pasteboard and schedules
/// the restore on the main queue.
public final class TextInserter: TextInserting {

    public enum Strategy: Sendable {
        /// Snapshot the clipboard, paste, put it back. The only method that
        /// behaves identically in native, Electron and browser text fields.
        case paste
        /// Synthesise the characters one run at a time. For the apps that refuse
        /// a synthetic ⌘V.
        case typing
    }

    /// How long our text sits on the clipboard before the user's own contents go
    /// back. See `scheduleRestore` for why this number cannot be made correct.
    public var restoreDelay: TimeInterval = 0.25
    public var strategy: Strategy = .paste

    private let pasteboard: NSPasteboard

    /// The pasteboard is injectable so tests can use a private named one. Nothing
    /// automated should ever be pointed at `.general` — eating the developer's
    /// clipboard on every test run is its own small betrayal.
    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    // MARK: - TextInserting

    public func insert(_ text: String) -> InsertionResult {
        guard !text.isEmpty else {
            return .failed(reason: "There was nothing to insert.")
        }
        if let blocked = blockingReason() {
            return park(text, because: blocked)
        }
        switch strategy {
        case .paste:  return insertByPasting(text)
        case .typing: return insertByTyping(text)
        }
    }

    // MARK: - Preflight

    /// The two states that turn every synthetic keystroke into a no-op.
    ///
    /// Both are silent at the API level: `CGEvent.post` returns nothing either
    /// way and the keystroke simply never arrives. They have to be checked
    /// beforehand, because there is nothing to detect afterwards.
    private func blockingReason() -> String? {
        if Permissions.secureInputEnabled {
            return "Secure Input is on, so macOS is refusing synthetic keystrokes. "
                + "It is usually a password field, or a terminal with Secure Keyboard Entry turned on."
        }
        if Permissions.state(of: .accessibility) != .granted {
            return "Quill has no Accessibility permission, so it cannot type into other apps. "
                + "Grant it in \(Permission.accessibility.settingsPath)."
        }
        return nil
    }

    // MARK: - Strategies

    private func insertByPasting(_ text: String) -> InsertionResult {
        let previous = PasteboardSnapshot.capture(from: pasteboard)

        guard previous.isFaithful else {
            // The clipboard holds something we could not copy out — file
            // promises, lazily-provided data. Pasting means clearing it, and we
            // would have nothing to put back. Type instead and never touch it.
            return insertByTyping(text)
        }

        guard let ourChangeCount = PasteboardSnapshot.write(text, to: pasteboard, transient: true) else {
            // Another process is holding the pasteboard. Typing needs no
            // clipboard at all, so it is the one route still open.
            //
            // But `write` declares its types before it discovers it cannot write,
            // and declaring clears the board — so by the time it reports failure
            // the user's clipboard is already gone. Put it back before walking
            // away. Losing someone's clipboard as a side effect of a dictation
            // that then took a different route is a bad trade for them and an
            // invisible one for us.
            previous.restore(to: pasteboard)
            return insertByTyping(text)
        }

        guard SyntheticKeyboard.postChord(key: SyntheticKeyboard.keyV, flags: .maskCommand) else {
            // Our text is already on the clipboard, and it stays there: restoring
            // the old contents to be tidy would trade away the only copy of what
            // the user just said.
            return .fellBackToClipboard(
                reason: "Quill could not synthesise ⌘V. The text is on your clipboard — press ⌘V."
            )
        }

        scheduleRestore(of: previous, ourChangeCount: ourChangeCount)

        // Optimistic, and openly so. CoreGraphics reports that the event was
        // posted, never that the focused app consumed it. Confirming would mean
        // reading the target's contents back over AX — the API that lies in
        // Electron — and a retry on a false negative inserts the sentence twice.
        return .inserted
    }

    private func insertByTyping(_ text: String) -> InsertionResult {
        guard SyntheticKeyboard.type(text) else {
            return park(text, because: "Quill could not synthesise keystrokes for this text.")
        }
        return .inserted
    }

    // MARK: - The safety net

    /// Leaves the text on the clipboard and says why.
    ///
    /// Deliberately does not restore anything: at this point the clipboard holds
    /// the only copy of the dictation, and the user has been told to press ⌘V.
    /// Not marked transient either — if they have to paste it by hand, it belongs
    /// in their clipboard history like anything else they copied.
    private func park(_ text: String, because reason: String) -> InsertionResult {
        guard PasteboardSnapshot.write(text, to: pasteboard, transient: false) != nil else {
            // Everything failed, including the fallback. Say that plainly rather
            // than reporting a clipboard the user will trust and find empty.
            return .failed(reason: reason + " Writing it to the clipboard also failed, so the text is gone.")
        }
        return .fellBackToClipboard(reason: reason + " The text is on your clipboard — press ⌘V.")
    }

    // MARK: - Restore

    private func scheduleRestore(of snapshot: PasteboardSnapshot, ourChangeCount: Int) {
        let board = pasteboard
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // Honest about the race, because it cannot be closed: no app tells you
            // it has finished reading the pasteboard. The delay is a guess. Too
            // short and a busy machine, or an app that reads the clipboard lazily,
            // pastes the user's *old* clipboard instead of their dictation. Too
            // long and their clipboard is wrong for longer than they expect.
            //
            // The changeCount guard below only covers the other half of the race —
            // someone copying something new in the gap. Nothing covers the first
            // half, and pretending otherwise with a bigger number would just move
            // the failure somewhere harder to reproduce.
            guard PasteboardSnapshot.restoreIsSafe(
                ourChangeCount: ourChangeCount,
                currentChangeCount: board.changeCount
            ) else { return }
            snapshot.restore(to: board)
        }
    }
}
