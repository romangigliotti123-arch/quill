import AppKit
import ApplicationServices
import Foundation

/// The keystrokes live typing issues, behind a seam.
///
/// This exists because of what the default implementation does: it posts real
/// backspaces into whatever app is frontmost. A test that constructs a
/// coordinator without thinking about it would delete characters out of the
/// developer's editor while the suite runs — a self-test that damages the
/// machine it is checking. Making the emitter injectable means the damaging
/// implementation has to be asked for by name.
public protocol KeystrokeEmitting: Sendable {
    @discardableResult func type(_ text: String) -> Bool
    @discardableResult func backspace(times: Int) -> Bool
}

public struct SystemKeystrokes: KeystrokeEmitting {
    public init() {}
    @discardableResult public func type(_ text: String) -> Bool { SyntheticKeyboard.type(text) }
    @discardableResult public func backspace(times: Int) -> Bool {
        SyntheticKeyboard.backspace(times: times)
    }
}

/// Types words into the focused app while you are still speaking, and keeps them
/// honest as the recogniser changes its mind.
///
/// The whole design rests on one fact: `SpeechTranscriber` hands back the *entire*
/// best-so-far text on every update, not a delta, and it freely revises words it
/// already gave you. So this cannot simply append. It keeps a record of what it
/// believes is on screen, and on each update finds the longest prefix the two
/// still agree on, deletes back to it, and types the rest. In practice the
/// agreement point is near the end and the edit is a couple of characters — the
/// expensive case is a mid-sentence revision, which is exactly the case where
/// appending would have been wrong.
///
/// What it deliberately does not do is verify. There is no API that reports what
/// the focused app actually did with a synthetic keystroke, so `typed` is a
/// belief, not a reading. Everything below is built so that a wrong belief is
/// recoverable rather than destructive: it never deletes more than it typed, it
/// stops the moment focus moves, and it refuses to start at all when the two
/// conditions that silently swallow keystrokes are present.
@MainActor
public final class LiveTyper {

    /// Minimum gap between screen updates. Partials arrive faster than anyone can
    /// read, and every one of them costs real keystrokes in someone else's app.
    /// ~15/second is past the point where more looks like anything.
    public var minimumInterval: TimeInterval = 0.066

    /// What we believe is on screen in the target app.
    public private(set) var typed = ""

    /// Set when focus moved away mid-dictation. From then on this types nothing
    /// and deletes nothing — see `focusHeld` for why that is the only safe move.
    public private(set) var isAbandoned = false

    private let keyboard: KeystrokeEmitting
    private var targetPID: pid_t?
    /// The field the words are going into, not merely the app.
    private var targetElement: AXUIElement?
    private var lastUpdate: TimeInterval = 0
    private var pendingFlush: DispatchWorkItem?
    private var pendingText: String?

    // nonisolated: the default argument of a @MainActor initialiser is evaluated
    // wherever the caller is, and DictationCoordinator's own default arguments
    // are not main-isolated.
    nonisolated public init(keyboard: KeystrokeEmitting = SystemKeystrokes()) {
        self.keyboard = keyboard
    }

    public var hasTyped: Bool { !typed.isEmpty }

    // MARK: - Lifecycle

    /// Returns false when live typing cannot work, in which case the caller
    /// should use the ordinary paste-on-release path. Checked up front because
    /// both blockers are silent: keystrokes are simply discarded and there is
    /// nothing to detect afterwards.
    @discardableResult
    public func begin() -> Bool {
        cancelPending()
        typed = ""
        isAbandoned = false
        lastUpdate = 0
        guard !Permissions.secureInputEnabled,
              Permissions.state(of: .accessibility) == .granted
        else {
            targetPID = nil
            return false
        }
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        targetElement = focusedElement()
        return targetPID != nil
    }

    /// Throttled. Safe to call on every partial.
    public func update(to text: String) {
        guard !isAbandoned else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastUpdate >= minimumInterval {
            cancelPending()
            apply(text)
            return
        }
        // Schedule the tail rather than dropping it. Dropping is fine while speech
        // continues — the next partial carries the same text — but the last
        // partial before a pause has nothing behind it, and dropping that one is
        // precisely the "it only appears when I stop" behaviour this exists to fix.
        pendingText = text
        guard pendingFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.pendingFlush = nil
                if let queued = self.pendingText {
                    self.pendingText = nil
                    self.apply(queued)
                }
            }
        }
        pendingFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (minimumInterval - (now - lastUpdate)),
                                      execute: work)
    }

    /// Unthrottled, for the final text. Returns what the caller should report.
    public func finish(_ text: String) -> InsertionResult {
        cancelPending()
        if isAbandoned {
            return .failed(reason: "Focus moved while Quill was still typing.")
        }
        guard focusHeld() else {
            isAbandoned = true
            return .failed(reason: "Focus moved while Quill was still typing.")
        }
        let before = typed
        apply(text, force: true)
        // Report what actually happened, not what was attempted.
        //
        // This returned .inserted unconditionally, so an apply() that aborted
        // mid-edit — after the backspaces had already gone out — still told the
        // coordinator the text was on screen. The paste fallback then never
        // fired, and the user was left with a hole where their sentence had been
        // and nothing on the clipboard to put back.
        if isAbandoned || typed != text {
            return .failed(reason: "Live typing stopped before the text was complete.")
        }
        _ = before
        return .inserted
    }

    /// Takes back everything typed during this dictation. For Escape, and for a
    /// transcript that turned out to be empty.
    /// - Parameter extraCharactersToLeave: characters that arrived after ours and
    ///   are not ours to delete — the keystroke that cancelled the dictation,
    ///   when it was passed through to the app rather than swallowed.
    public func retract(extraCharactersToLeave: Int = 0) {
        cancelPending()
        guard !isAbandoned, !typed.isEmpty, focusHeld() else {
            typed = ""
            return
        }
        // Delete fewer than we typed, never more. Leaving one of our characters
        // behind is a visible smudge the user can remove; deleting one of theirs
        // is us destroying their work, and they may never notice which.
        let count = max(0, typed.count - extraCharactersToLeave)
        if count > 0 { keyboard.backspace(times: count) }
        typed = ""
    }

    public func reset() {
        cancelPending()
        typed = ""
        isAbandoned = false
        targetPID = nil
        targetElement = nil
    }

    // MARK: - The diff

    private func apply(_ text: String, force: Bool = false) {
        guard !isAbandoned else { return }
        guard focusHeld() else {
            // Everything already typed stays where it is, and nothing more is
            // typed or deleted.
            //
            // Deleting would be worse than useless: the backspaces would land in
            // whatever the user switched to and eat *their* text, which is the one
            // outcome a dictation app must never produce. Continuing to type would
            // scatter half a sentence across two apps. So this stops, the caller
            // falls back to pasting the whole thing into wherever focus now is,
            // and the user is left with a duplicate rather than a deletion.
            isAbandoned = true
            return
        }
        guard force || text != typed else { return }

        let edit = Self.edit(from: typed, to: text)

        if edit.deletions > 0 {
            guard keyboard.backspace(times: edit.deletions) else { isAbandoned = true; return }
        }
        if !edit.insertion.isEmpty {
            guard keyboard.type(edit.insertion) else { isAbandoned = true; return }
        }

        typed = text
        lastUpdate = ProcessInfo.processInfo.systemUptime
    }

    /// The smallest edit that turns what is on screen into what should be.
    ///
    /// Pure, and separated from the posting for exactly that reason: this is the
    /// part that can be wrong in a way that eats someone's paragraph, and it has
    /// to be checkable without a keyboard, a focused app or a microphone.
    ///
    /// Counts in grapheme clusters, not UTF-16 units — one backspace deletes one
    /// visible character, so counting anything smaller takes half an emoji off
    /// and leaves a fragment behind.
    nonisolated public static func edit(from current: String,
                                        to target: String) -> (deletions: Int, insertion: String) {
        var shared = 0
        var i = current.startIndex
        var j = target.startIndex
        while i < current.endIndex, j < target.endIndex, current[i] == target[j] {
            shared += 1
            i = current.index(after: i)
            j = target.index(after: j)
        }
        return (current.count - shared, String(target[j...]))
    }

    /// Whether the text is still going where it was going.
    ///
    /// The process is necessary and not sufficient. Comparing only the PID means
    /// a click into a different field of the SAME app — a browser address bar, a
    /// second document, another cell — still looks like the original target, so
    /// the backspaces for the next revision land in whatever the user just
    /// clicked into and delete their characters instead of ours.
    ///
    /// The focused element is asked for as well, through Accessibility. When AX
    /// declines to answer (it often does, and Electron apps are unreliable here)
    /// the check falls back to the process alone rather than abandoning a
    /// perfectly good dictation — the failure mode of being too strict is losing
    /// text, and of being too loose is what we already had.
    private func focusHeld() -> Bool {
        guard let targetPID else { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            return false
        }
        guard let target = targetElement, let now = focusedElement() else { return true }
        return CFEqual(target, now)
    }

    private func focusedElement() -> AXUIElement? {
        guard let targetPID else { return nil }
        let app = AXUIElementCreateApplication(targetPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success
        else { return nil }
        guard let element = value, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    private func cancelPending() {
        pendingFlush?.cancel()
        pendingFlush = nil
        pendingText = nil
    }
}
