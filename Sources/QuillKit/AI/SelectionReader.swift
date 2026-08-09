import AppKit
import ApplicationServices
import Foundation

/// Reading what the user has selected in whatever app has focus.
///
/// This is the mirror image of `TextInserter`, and it inherits that file's one
/// rule — never destroy anything the user cannot get back — with an extra
/// wrinkle: the fallback path *uses* the clipboard, so it has to be able to give
/// it back before it is allowed to borrow it.
///
/// # Why there are two paths
///
/// Accessibility is the right way to ask, and it works in native text views. It
/// also returns nothing at all in Chrome, Safari, VS Code, Slack, Discord and
/// every other Electron app — `kAXSelectedTextAttribute` is simply not
/// implemented on their web-backed elements, so the call errors or hands back an
/// empty string. Since that is most of where dictation actually gets used, an
/// AX-only reader would report "nothing selected" for the majority of real
/// selections, which is indistinguishable from the feature being broken.
///
/// Note this is the opposite conclusion to `TextInserter`, and for a consistent
/// reason. There, AX *lies* — it reports success and writes to the wrong offset,
/// so it is refused. Here, AX *declines* — it returns nothing and is detectably
/// wrong, so it is tried first and fallen through. The distinction that matters
/// is not whether an API works, it is whether its failures are visible.
///
/// # The fallback, and what it costs
///
/// Synthesise ⌘C and watch `NSPasteboard.changeCount`. That means:
///
///   * The user's clipboard is read, briefly overwritten by the focused app, and
///     put back. If it holds something that cannot be copied out — a file
///     promise, a lazily-rendered image — it cannot be put back, and this reader
///     refuses to run rather than eat it.
///   * ⌘C with nothing selected does not change `changeCount`, so "no selection"
///     costs the full timeout and then reports honestly.
///   * The ⌘C is stamped with `QuillSyntheticEventMarker`, or Quill's own hotkey
///     tap would see it as the user pressing a key mid-gesture.
@MainActor
public protocol SelectionReading: AnyObject {
    func readSelection() async -> SelectionOutcome
}

public enum SelectionSource: String, Sendable, Equatable {
    case accessibility
    case clipboard
}

public enum SelectionOutcome: Sendable, Equatable {
    case selected(String, via: SelectionSource)
    /// The read worked and there was nothing selected.
    case empty
    /// The read could not be attempted. Carries something a human can act on.
    case unavailable(reason: String)

    public var text: String? {
        if case .selected(let text, _) = self { return text }
        return nil
    }
}

// MARK: - The clipboard probe

/// The ⌘C-and-watch loop, with every side effect behind a closure.
///
/// Split out from the reader for one reason: this loop is where the bugs are —
/// the two-phase pasteboard write, the app that never answers, the user who
/// copies something else mid-poll — and none of them can be reproduced against a
/// real pasteboard and a real focused app inside a test.
@MainActor
public struct ClipboardCopyProbe {

    public enum Outcome: Sendable, Equatable {
        case copied(String)
        /// ⌘C went out and the pasteboard never changed. Almost always "nothing
        /// was selected"; occasionally "this app ignores ⌘C".
        case nothingHappened
        case couldNotCopy(reason: String)
    }

    public var changeCount: () -> Int
    /// Returns false if the keystroke could not even be constructed.
    public var copy: () -> Bool
    public var readString: () -> String?
    /// Hands back the change count observed at the moment the copy landed, so
    /// the implementation can decline to restore over someone else's newer
    /// clipboard. It must be the count from *detection*, not from the moment of
    /// restoring — comparing the current count against itself always says yes,
    /// which is a guard that reads like a guard and is not one.
    public var restore: (Int) -> Void
    public var sleep: (Duration) async -> Void

    /// How long to wait for the focused app to answer.
    ///
    /// 300ms. A local ⌘C into the pasteboard is a handful of milliseconds in
    /// every app measured; the tail is an app doing work on its main thread, and
    /// past a third of a second the user has already decided nothing happened.
    public var timeout: Duration
    public var pollInterval: Duration
    /// Reads to attempt once `changeCount` moves.
    ///
    /// Not one. `NSPasteboard` is written in two steps — `declareTypes` bumps
    /// `changeCount`, `setString` puts the bytes in — so a poll that lands
    /// between them sees a changed clipboard holding nothing, and a reader that
    /// trusted the first read would report an empty selection for a selection
    /// that was there.
    public var settleAttempts: Int

    public init(changeCount: @escaping () -> Int,
                copy: @escaping () -> Bool,
                readString: @escaping () -> String?,
                restore: @escaping (Int) -> Void,
                sleep: @escaping (Duration) async -> Void,
                timeout: Duration = .milliseconds(300),
                pollInterval: Duration = .milliseconds(12),
                settleAttempts: Int = 4) {
        self.changeCount = changeCount
        self.copy = copy
        self.readString = readString
        self.restore = restore
        self.sleep = sleep
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.settleAttempts = settleAttempts
    }

    public func run() async -> Outcome {
        let before = changeCount()
        guard copy() else {
            return .couldNotCopy(reason: "Quill could not synthesise ⌘C.")
        }

        var waited = Duration.zero
        while waited < timeout {
            await sleep(pollInterval)
            waited += pollInterval
            let landed = changeCount()
            guard landed != before else { continue }

            var text = readString()
            var attempt = 1
            while (text ?? "").isEmpty, attempt < settleAttempts {
                await sleep(pollInterval)
                text = readString()
                attempt += 1
            }

            // Restore before returning, and always — a clipboard left holding
            // the user's own selection is a clipboard we broke, even though the
            // contents look harmless. The count handed over is the one from
            // detection, so a copy the user made during the settle loop stops
            // the restore instead of being overwritten by it.
            restore(landed)

            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .nothingHappened
            }
            return .copied(text)
        }
        // Nothing was written, so nothing needs putting back.
        return .nothingHappened
    }
}

// MARK: - Reader

@MainActor
public final class SelectionReader: SelectionReading {

    /// ANSI positional code for the key labelled C. Same reasoning as
    /// `SyntheticKeyboard.keyV`: positional codes survive keyboard layouts.
    public static let keyC: CGKeyCode = 8

    private let pasteboard: NSPasteboard
    private let timeout: Duration
    private let pollInterval: Duration

    /// The pasteboard is injectable so tests can use a private named one.
    /// Nothing automated should ever be pointed at `.general`.
    public init(pasteboard: NSPasteboard = .general,
                timeout: Duration = .milliseconds(300),
                pollInterval: Duration = .milliseconds(12)) {
        self.pasteboard = pasteboard
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public func readSelection() async -> SelectionOutcome {
        if Permissions.state(of: .accessibility) != .granted {
            return .unavailable(reason:
                "Quill has no Accessibility permission, so it cannot read the selection. "
                + "Grant it in \(Permission.accessibility.settingsPath).")
        }

        // Cheap, silent, and correct in native text views. Costs one IPC round
        // trip when it fails, which is the whole reason it is tried first.
        if let text = Self.accessibilitySelection(), !text.isEmpty {
            return .selected(text, via: .accessibility)
        }

        if Permissions.secureInputEnabled {
            return .unavailable(reason:
                "Secure Input is on, so macOS is refusing synthetic keystrokes and Quill cannot copy "
                + "the selection. It is usually a password field, or a terminal with Secure Keyboard Entry on.")
        }

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        guard snapshot.isFaithful else {
            // Same call as TextInserter's: the clipboard holds something we
            // could not copy out, so borrowing it means losing it. Reading a
            // selection is never worth that.
            return .unavailable(reason:
                "Your clipboard holds something Quill cannot copy and put back — a file promise or a "
                + "lazily-provided image — so it will not borrow the clipboard to read the selection. "
                + "Copy the text yourself, or clear the clipboard and try again.")
        }

        let board = pasteboard
        let probe = ClipboardCopyProbe(
            changeCount: { board.changeCount },
            copy: { SyntheticKeyboard.postChord(key: Self.keyC, flags: .maskCommand) },
            readString: { board.string(forType: .string) },
            restore: { observed in
                guard PasteboardSnapshot.restoreIsSafe(ourChangeCount: observed,
                                                       currentChangeCount: board.changeCount)
                else { return }
                snapshot.restore(to: board)
            },
            sleep: { try? await Task.sleep(for: $0) },
            timeout: timeout,
            pollInterval: pollInterval
        )

        switch await probe.run() {
        case .copied(let text):        return .selected(text, via: .clipboard)
        case .nothingHappened:         return .empty
        case .couldNotCopy(let why):   return .unavailable(reason: why)
        }
    }

    // MARK: - Accessibility

    /// The focused element's selected text, or nil if this app does not answer.
    ///
    /// Nil and "" are treated the same by the caller on purpose. A native field
    /// with no selection returns ""; Chrome returns an error; a web view inside a
    /// native app has been seen to return "" while holding a real selection.
    /// Since the ⌘C fallback answers all three correctly and costs a few hundred
    /// milliseconds only when there was nothing to find, there is no reason to
    /// trust an empty AX answer.
    static func accessibilitySelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        // Without this, one unresponsive app hangs the reader for the AX default
        // of six seconds, on the main actor, with the overlay up.
        //
        // Set on the system-wide element it becomes the process-wide default,
        // which is deliberate — nothing else in Quill uses AX, and 250ms is the
        // right ceiling for anything that would. It is set on the focused
        // element as well rather than relying on that: the focused element is a
        // different object, and a per-object timeout is the only thing that is
        // documented to apply to it.
        AXUIElementSetMessagingTimeout(system, 0.25)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }

        // swiftlint:disable:next force_cast — guarded by the type-id check above.
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextAttribute as CFString, &valueRef) == .success
        else { return nil }
        return valueRef as? String
    }
}

// MARK: - Test double

/// A selection reader that returns whatever it was given.
///
/// Lives beside the real one rather than in the test target because
/// `TransformEngine` is the thing worth testing and it needs a selection from
/// somewhere; the dashboard's preview renderer needs the same.
@MainActor
public final class StubSelectionReader: SelectionReading {
    public var outcome: SelectionOutcome
    public private(set) var readCount = 0

    public init(_ outcome: SelectionOutcome) {
        self.outcome = outcome
    }

    public func readSelection() async -> SelectionOutcome {
        readCount += 1
        return outcome
    }
}
