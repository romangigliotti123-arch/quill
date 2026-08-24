import AppKit
import ApplicationServices
import Foundation

/// The whole text of whatever field has focus, behind a seam.
///
/// A protocol for the same reason `CaretTextReading` is one: the real
/// implementation asks another process over Accessibility, so the answer depends
/// on which window happens to be focused on the machine running the test.
public protocol FocusedTextReading: Sendable {
    /// The focused element's full text in `pid`, or nil when the app will not say.
    ///
    /// Nil is ordinary, not exceptional. Measured on this Mac while building the
    /// undo chord: TextEdit answers exactly, Ghostty reports a caret frozen at 0,
    /// Chrome reports an `AXGroup` with no text, and VS Code reports no focused
    /// element at all. Three of the four apps most dictated into cannot be read,
    /// which is the fact that shapes this whole feature — see `EditWatcher`.
    func focusedText(pid: pid_t) -> String?
}

public struct AccessibilityFocusedTextReader: FocusedTextReading {
    public init() {}

    public func focusedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        // Without a timeout one unresponsive app blocks this for the AX default
        // of six seconds. Same ceiling the caret reader and SelectionReader use.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }

        // swiftlint:disable:next force_cast — guarded by the type-id check above.
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty
        else { return nil }
        return text
    }
}

/// Watches what the user does to the sentence Quill just inserted, and teaches
/// the style profile from the difference.
///
/// # Why this exists
///
/// Every part of learning a writing style was already here — `StyleLearner` with
/// eight detectors, `StyleProfile` with tallied traits, the Style screen showing
/// them with their evidence — and `StyleStore.recordCorrection`, the one function
/// that feeds all of it, **had no callers at all**. The profile could only ever
/// show its seeded defaults, and the header counting "corrections seen" could
/// only ever say zero. The learner's own doc comment warns about exactly this
/// shape shipping, which is a good warning to have written and not enough on its
/// own.
///
/// Corrections happen in the app the text landed in, not inside Quill. So this
/// watches there.
///
/// # What it will and will not see
///
/// It reads the focused field over Accessibility, which many apps decline to
/// answer. Measured on this Mac: TextEdit answers exactly, Ghostty's caret is
/// frozen at zero, Chrome exposes an `AXGroup` with no text, VS Code exposes no
/// focused element. **So this learns in some apps and not others, and there is no
/// fixing that from here.** It is built to notice the difference and stay quiet
/// rather than to guess: a watch that cannot read the field simply expires.
///
/// That is also why the destination is recorded on every dictation
/// (`DictationRecord.destinationBundleID`) whether or not the text can be read
/// back — knowing where your words went does not depend on being able to re-read
/// them, and it is the other half of what was asked for.
///
/// # Why the guards are strict
///
/// A wrong correction is worse than a missed one. A missed one costs nothing; a
/// wrong one silently teaches the profile a preference the user never expressed,
/// and that profile is what `VoiceExport` hands to Claude. So every ambiguity is
/// a refusal — see `InsertedSpan.Verdict.Reason` for the list, and the stability
/// requirement below for the rest.
public final class EditWatcher: @unchecked Sendable {

    /// How often to look, and for how long.
    ///
    /// Not a live observer, because Accessibility has no notification for "the
    /// value of this field changed" that arrives reliably from every app, and
    /// polling something this cheap once a second is not the cost worth
    /// optimising. The window is a minute and a half: long enough to reread a
    /// sentence and fix it, short enough that a watch is not still running when
    /// the next dictation starts.
    static let interval: TimeInterval = 1.2
    static let window: TimeInterval = 90

    /// An edit has to hold still before it counts.
    ///
    /// Mid-typing states are not corrections. Someone fixing "recieve" passes
    /// through "recve", "recei", "receiv" on the way, and every one of those is a
    /// perfectly readable field value that says nothing true about how they
    /// spell. Two identical consecutive readings — about two and a half seconds
    /// of not typing — is the cheapest available definition of "they stopped".
    static let stableSamples = 2

    private let reader: FocusedTextReading
    private let store: StyleStore
    private let settings: QuillSettings
    private let now: @Sendable () -> Date
    /// False in tests, which call `sample()` themselves. A repeating timer
    /// running alongside a test that is also stepping the clock is a race, and
    /// this project has already lost a full test run to one of those.
    private let usesTimer: Bool

    private let lock = NSLock()
    private var watch: Watch?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.romangigliotti.quill.editwatcher")

    /// Nothing here holds the field's text. Only the anchors, the sentence Quill
    /// wrote, and the candidate currently being confirmed.
    private struct Watch {
        let anchors: InsertedSpan.Anchors
        let pid: pid_t
        let bundleID: String?
        let startedAt: Date
        var pending: String?
        var pendingCount = 0
    }

    /// What the last watch concluded, for the Style screen to show and for tests
    /// to assert on. Deliberately not persisted: it is a live status, and a stale
    /// one read back after a relaunch would be a claim about a session that is over.
    ///
    /// Behind the lock like everything else here: it is written from the timer's
    /// queue and read from main.
    public var lastOutcome: Outcome? { lock.withLock { outcome } }
    private var outcome: Outcome?

    public enum Outcome: Equatable, Sendable {
        case learned(from: String, to: String, bundleID: String?)
        case keptAsWritten
        case couldNotRead(bundleID: String?)
        case ignored(InsertedSpan.Verdict.Reason)
    }

    public init(reader: FocusedTextReading = AccessibilityFocusedTextReader(),
                store: StyleStore = .shared,
                settings: QuillSettings = .shared,
                now: @escaping @Sendable () -> Date = { Date() },
                usesTimer: Bool = true) {
        self.reader = reader
        self.store = store
        self.settings = settings
        self.now = now
        self.usesTimer = usesTimer
    }

    deinit { timer?.cancel() }

    /// Start watching the sentence Quill just put into `pid`.
    ///
    /// Called from the one branch of the coordinator where the text is believed
    /// to be on screen — the same gate `InsertionUndo.record` uses, because a
    /// sentence that never landed has nothing to watch and a clipboard fallback
    /// went somewhere this cannot see.
    public func begin(inserted: String, pid: pid_t, bundleID: String?) {
        guard settings.learnFromEdits, store.profile.isLearningEnabled else { return }
        guard let field = reader.focusedText(pid: pid) else {
            finish(.couldNotRead(bundleID: bundleID))
            return
        }
        // The field does not contain what we just inserted, or contains it twice.
        // Either way there is nothing here that can be attributed later.
        guard let anchors = InsertedSpan.anchors(inserted: inserted, in: field) else {
            finish(.ignored(.notFound))
            return
        }
        lock.withLock {
            watch = Watch(anchors: anchors, pid: pid, bundleID: bundleID, startedAt: now())
        }
        startTimer()
    }

    /// Stop watching without concluding anything — a new dictation has started,
    /// so the previous sentence is no longer the one being edited.
    public func cancel() {
        lock.withLock { watch = nil }
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        guard usesTimer else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        t.setEventHandler { [weak self] in self?.sample() }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    /// One look. Exposed so a test can step time rather than wait for it.
    func sample() {
        guard var current = lock.withLock({ watch }) else { stopTimer(); return }

        if now().timeIntervalSince(current.startedAt) > Self.window {
            // Expired with nothing conclusive. The commonest real outcome, and
            // it is not a failure: most dictations are simply left alone.
            finish(current.pending == nil ? .keptAsWritten : .ignored(.anchorsLost))
            return
        }

        guard let field = reader.focusedText(pid: current.pid) else {
            // The window closed, focus moved, or the app never answered. Not
            // conclusive either way, so keep waiting until the window expires.
            return
        }

        switch InsertedSpan.verdict(for: current.anchors, in: field) {
        case .unchanged:
            // Reset any half-confirmed edit: they typed and then put it back.
            lock.withLock { watch?.pending = nil; watch?.pendingCount = 0 }

        case .notComparable(let reason):
            // `deleted` is conclusive and worth stopping for — the sentence is
            // gone and it is not coming back. The others may recover on the next
            // look, so they wait.
            if reason == .deleted { finish(.ignored(reason)) }

        case .corrected(let edited):
            if current.pending == edited {
                current.pendingCount += 1
                if current.pendingCount >= Self.stableSamples {
                    _ = store.recordCorrection(dictated: current.anchors.inserted,
                                               edited: edited, at: now())
                    finish(.learned(from: current.anchors.inserted, to: edited,
                                    bundleID: current.bundleID))
                    return
                }
            } else {
                current.pending = edited
                current.pendingCount = 1
            }
            lock.withLock {
                watch?.pending = current.pending
                watch?.pendingCount = current.pendingCount
            }
        }
    }

    private func finish(_ result: Outcome) {
        lock.withLock {
            watch = nil
            outcome = result
        }
        stopTimer()
        NotificationCenter.default.post(name: .quillStyleLearned, object: nil)
    }
}

public extension Notification.Name {
    /// Posted when a watch concludes. The Style screen rebuilds on it, so a
    /// correction shows up without needing the tab reopened.
    static let quillStyleLearned = Notification.Name("com.romangigliotti.quill.styleLearned")
}
