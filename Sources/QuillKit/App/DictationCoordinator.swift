import AppKit
import Foundation

/// One dictation, start to finish: key down, listen, transcribe, clean, insert.
///
/// Deliberately narrow. murmur's equivalent grew to 633 lines by also owning
/// history, learning, note syncing and command chaining, and became the least
/// debuggable thing in that app. This owns the lifecycle and delegates the rest;
/// anything that is not "what happens between key-down and text-inserted"
/// belongs somewhere else.
@MainActor
public final class DictationCoordinator {

    private let hotkey: HotkeyEngine
    private let transcriber: Transcriber
    private let inserter: TextInserting
    private let overlay: OverlayPresenting
    private let cleaner: TranscriptCleaning
    private let history: HistoryStore
    private let snippets: SnippetStore
    private let settings: QuillSettings
    /// Puts words on screen while you are still speaking. Only used when the
    /// setting is on and the focused app can actually take synthetic keystrokes;
    /// otherwise the release-and-paste path below runs exactly as it always did.
    private let liveTyper: LiveTyper
    private var isLive = false

    /// How long the thorough cleanup is allowed to take before we give up on it
    /// and insert the fast version. Past roughly a quarter second the pause
    /// between releasing the key and seeing text becomes the thing you notice,
    /// which is exactly the piece we are trying to win.
    private let cleanupDeadline: Duration = .milliseconds(250)

    private var timeline = DictationTimeline()
    private var isDictating = false
    /// Capturing, but not yet committed: the key is down and the gesture has not
    /// resolved. Audio recorded in this window is kept if the gesture becomes a
    /// dictation and thrown away if it does not.
    private var isSpeculating = false
    private var capturedInputDevice: String?
    /// Guards against a late result from a previous dictation landing in this
    /// one — it would paste stale text into whatever you are now typing in.
    private var sessionID = 0

    public init(
        hotkey: HotkeyEngine,
        transcriber: Transcriber,
        inserter: TextInserting,
        overlay: OverlayPresenting,
        cleaner: TranscriptCleaning = FastCleaner(),
        history: HistoryStore = HistoryStore(),
        snippets: SnippetStore = .shared,
        settings: QuillSettings = .shared,
        liveTyper: LiveTyper = LiveTyper()
    ) {
        self.settings = settings
        self.liveTyper = liveTyper
        self.hotkey = hotkey
        self.transcriber = transcriber
        self.inserter = inserter
        self.overlay = overlay
        self.cleaner = cleaner
        self.history = history
        self.snippets = snippets
        self.hotkey.delegate = self
        self.transcriber.delegate = self
        // Drive the waveform from real input. The callback arrives on the audio
        // thread, so it hops to main before touching any UI.
        self.transcriber.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // The first level is the first buffer off the microphone, so
                    // this is where audio actually began.
                    //
                    // It has to be stamped here rather than read back from the
                    // transcriber: both transcribers keep a `DictationTimeline`
                    // of their own and dutifully record `audioFirstBuffer` into
                    // it, and nothing ever read that copy. The coordinator's
                    // timeline — the one written to history — had the field nil
                    // on all 230 records on this Mac, which is why Insights has
                    // been reporting "not enough dictations yet" for speaking
                    // pace and "needs the length of what you spoke" for time
                    // saved since the day they were built.
                    //
                    // Stamped before the isDictating guard: audio starts during
                    // speculation, which is the whole point of speculation.
                    if self.timeline.audioFirstBuffer == nil,
                       self.isDictating || self.isSpeculating {
                        self.timeline.audioFirstBuffer = Date()
                    }
                    guard self.isDictating else { return }
                    self.overlay.show(.listening(level: level))
                }
            }
        }
    }

    @discardableResult
    public func start() -> Bool { hotkey.start() }

    // MARK: - Lifecycle

    /// Called the instant the key goes down. Everything expensive happens here —
    /// model warm-up and opening the microphone — because by the time the gesture
    /// has been recognised, whatever was said in the meantime is already gone.
    private func speculativelyBegin() {
        guard !isDictating, !isSpeculating else { return }
        isSpeculating = true
        sessionID += 1
        let session = sessionID

        timeline = DictationTimeline()
        // The honest start of the dictation, not the moment we worked out it was one.
        timeline.hotkeyDown = Date()
        // Captured at the start, not the end: the default device can change
        // mid-dictation, and what matters is what was heard. Reports the device
        // chosen in Settings when there is one, falling back to the system
        // default when it has been unplugged — the same fallback the capture
        // itself makes, so the stamp never claims a microphone that recorded
        // nothing.
        capturedInputDevice = AudioDeviceInfo.activeInputName(uid: settings.inputDeviceUID)

        Task { [transcriber] in
            await transcriber.prepare()
            guard session == self.sessionID, self.isSpeculating || self.isDictating else { return }
            do {
                try await transcriber.start()
            } catch {
                self.fail("Could not start listening: \(error.localizedDescription)")
            }
        }
    }

    /// The gesture was a chord or a stray tap. Bin the audio without a trace —
    /// no overlay was ever shown, so nothing needs undoing on screen.
    private func abandonSpeculation() {
        guard isSpeculating, !isDictating else { return }
        isSpeculating = false
        sessionID += 1
        Task { [transcriber] in await transcriber.cancel() }
    }

    /// The gesture is confirmed as dictation. Audio has been recording since
    /// key-down, so there is nothing to start here — only something to show.
    private func beginDictation() {
        guard !isDictating else { return }
        isDictating = true

        if !isSpeculating {
            // Defensive: a confirmation with no speculation behind it. Start now
            // and accept the lost milliseconds rather than record nothing at all.
            speculativelyBegin()
        }
        isSpeculating = false
        // Decided here, once, rather than per partial: the focused app is
        // whatever the user was in when they pressed the key, and it is the only
        // window it is ever safe to type into during this dictation.
        isLive = settings.liveText && liveTyper.begin()
        overlay.show(.listening(level: 0))
    }

    private func endDictation() {
        guard isDictating else { return }
        isDictating = false
        isSpeculating = false
        // Stamped first, before anything else in this method can cost time. This
        // is the moment the user stopped talking, and everything after it is
        // latency they sit through.
        timeline.hotkeyUp = Date()
        let session = sessionID
        overlay.show(.transcribing)

        Task { [transcriber, cleaner, inserter, overlay, history, snippets, cleanupDeadline] in
            let raw = await transcriber.stop()
            guard session == self.sessionID else { return }

            self.timeline.finalTranscript = Date()

            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Nothing was said, but something may already be on screen: a
                // volatile hypothesis the recogniser later withdrew. Take it back,
                // or the user is left with words they never spoke.
                if self.isLive { self.liveTyper.retract() }
                self.isLive = false
                overlay.show(.hidden)
                return
            }

            // Race the thorough pass against the deadline. Whatever is ready
            // wins; the fast pass is always ready.
            let fast = cleaner.cleanFast(raw)
            var final = fast
            var usedThorough = false

            // How long the race gets depends on whether there is anything to race
            // for. Almost every dictation is already right after the fast pass,
            // and waiting to be told so is latency spent on nothing — but a
            // transcript carrying a spoken self-correction is the one case where a
            // model earns its round trip, and 250ms cannot finish one. Measured
            // from Melbourne on a warm connection, share of calls landing inside a
            // deadline: 250ms -> 11%, 350ms -> 78%, 450ms -> 97%. The limit is the
            // network, not the GPU, so no model choice fixes it.
            let budget = SelfCorrection.needsModelPass(fast)
                ? AIConfig.recommendedCleanupDeadline
                : cleanupDeadline

            if let better = await Self.withDeadline(budget, operation: {
                await cleaner.cleanThorough(raw, deadline: budget)
            }), better != fast {
                final = better
                usedThorough = true
            }

            // Snippet expansion goes here and nowhere else: after cleanup, so the
            // cleaner never sentence-cases an email address or "repairs" a URL,
            // and before insertion, so nothing is typed and then rewritten inside
            // an app we do not control. Returns the text unchanged when nothing
            // matched, which is the overwhelmingly common case.
            final = snippets.expand(final)

            // Two ways in, and the difference is whether the text is already
            // there. Live typing has been writing this sentence since the first
            // partial, so finishing it means reconciling the last edit — usually
            // nothing, sometimes the sentence the model rewrote. Pasting the whole
            // thing here instead would insert it twice.
            let result: InsertionResult
            if self.isLive, !self.liveTyper.isAbandoned {
                let live = self.liveTyper.finish(final)
                // The one failure mode: focus moved mid-sentence. The partial text
                // stays where it was typed and the finished text goes wherever the
                // user is now — a duplicate, which they can see and delete, rather
                // than a silent loss.
                result = (live == .inserted) ? live : inserter.insert(final)
            } else {
                if self.isLive { self.liveTyper.reset() }
                result = inserter.insert(final)
            }
            self.isLive = false
            self.timeline.textInserted = Date()

            switch result {
            case .inserted:
                overlay.show(.inserted(words: final.split(separator: " ").count))
            case .fellBackToClipboard(let reason):
                overlay.show(.error("Copied to clipboard — \(reason)"))
            case .failed(let reason):
                overlay.show(.error(reason))
            }

            history.append(DictationRecord(
                id: UUID(),
                date: Date(),
                rawText: raw,
                insertedText: final,
                wordCount: final.split(separator: " ").count,
                inputDevice: self.capturedInputDevice,
                timings: .init(
                    timeToFirstWordMs: self.timeline.timeToFirstWordMs,
                    finalToInsertedMs: self.timeline.finalToInsertedMs,
                    endToEndMs: self.timeline.endToEndMs,
                    audioDurationMs: self.timeline.audioDurationMs,
                    usedThoroughCleanup: usedThorough,
                    releaseToInsertedMs: self.timeline.releaseToInsertedMs
                )
            ))

            NSLog("[quill] %@", self.timeline.logLine)

            try? await Task.sleep(for: .milliseconds(900))
            overlay.hide()
        }
    }

    private func cancelDictation() {
        // `isSpeculating` too, and this is not defensive tidying — it was a
        // permanent deadlock.
        //
        // Capture starts at key-down, but isDictating only becomes true when the
        // gesture is confirmed ~120ms later. A cancel landing in that window hit
        // the old `guard isDictating` and returned early, leaving isSpeculating
        // true forever — and speculativelyBegin() refuses to start while it is.
        // The app then stops dictating silently, with no error and no overlay,
        // until it is relaunched.
        //
        // Seen in a traced run as a 112-second gap in which three dictations were
        // requested and no session started at all.
        guard isDictating || isSpeculating else { return }
        isDictating = false
        isSpeculating = false
        sessionID += 1
        // Escape means "pretend this never happened", and with live typing on,
        // part of it already did. Take every character back before anything else.
        if isLive { liveTyper.retract() }
        isLive = false
        Task { [transcriber, overlay] in
            await transcriber.cancel()
            overlay.hide()
        }
    }

    private func fail(_ message: String) {
        isDictating = false
        isSpeculating = false
        if isLive { liveTyper.retract() }
        isLive = false
        overlay.show(.error(message))
    }

    /// Returns nil if the operation did not finish in time.
    ///
    /// This deliberately does NOT use withTaskGroup. A task group awaits every
    /// child at scope exit, so `cancelAll()` only *requests* cancellation — if
    /// the operation does not honour it (a URLSession call has its own ~60s
    /// timeout), the group blocks until the slow child finishes and the deadline
    /// bounds nothing at all. That is not theoretical: it stalled a dictation for
    /// 59 seconds during an eval run, which presents as "it just didn't paste".
    ///
    /// So the loser is abandoned rather than awaited. The orphaned task finishes
    /// into a continuation that has already been resumed, which is harmless, and
    /// the caller is never held hostage by a network it cannot cancel.
    static func withDeadlineForTesting<T: Sendable>(
        _ duration: Duration, _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withDeadline(duration, operation: operation)
    }

    private static func withDeadline<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        let box = ResumeOnce<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            box.attach(continuation)
            Task { let value = await operation(); box.finish(value) }
            Task { try? await Task.sleep(for: duration); box.finish(nil) }
        }
    }
}

/// Test seam. The race is the part that broke, so it has to be reachable from a
/// test without booting an NSApplication and a microphone.
public enum DictationCoordinatorTestHooks {
    public static func withDeadline<T: Sendable>(
        _ duration: Duration, _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await DictationCoordinator.withDeadlineForTesting(duration, operation)
    }
}

/// Guarantees a continuation is resumed exactly once, whichever racer arrives
/// first. Resuming a checked continuation twice is a crash, not a warning.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    func attach(_ c: CheckedContinuation<T?, Never>) {
        lock.lock(); defer { lock.unlock() }
        continuation = c
    }

    func finish(_ value: T?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

// MARK: - Hotkey

extension DictationCoordinator: HotkeyEngineDelegate {
    public func hotkeyMayBegin() { speculativelyBegin() }
    public func hotkeyAborted() { abandonSpeculation() }
    public func hotkeyPressed() { beginDictation() }
    public func hotkeyReleased() { endDictation() }
    public func hotkeyCancelled() { cancelDictation() }
    public func hotkeyEngineUnavailable(reason: String) {
        overlay.show(.error(reason))
    }
}

// MARK: - Transcription

extension DictationCoordinator: TranscriberDelegate {
    public func transcriber(didProduce transcript: Transcript) {
        if timeline.firstPartial == nil, !transcript.text.isEmpty {
            timeline.firstPartial = Date()
        }
        guard isLive, isDictating else { return }
        // Cleaned, not raw. Typing the raw hypothesis would mean the final pass
        // capitalises the first letter and re-punctuates — a change at character
        // zero, which is a delete-and-retype of the entire sentence at the exact
        // moment the user is waiting for it to finish. Running the deterministic
        // pass on every partial costs microseconds and makes the closing edit
        // almost always empty.
        liveTyper.update(to: cleaner.cleanFast(transcript.text))
    }

    public func transcriber(didFail error: Error) {
        fail(error.localizedDescription)
    }
}
