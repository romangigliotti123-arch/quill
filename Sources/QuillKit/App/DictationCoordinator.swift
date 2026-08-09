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
        snippets: SnippetStore = .shared
    ) {
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
                    guard let self, self.isDictating else { return }
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
        // mid-dictation, and what matters is what was heard.
        capturedInputDevice = AudioDeviceInfo.currentInputName()

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
        overlay.show(.listening(level: 0))
    }

    private func endDictation() {
        guard isDictating else { return }
        isDictating = false
        isSpeculating = false
        let session = sessionID
        overlay.show(.transcribing)

        Task { [transcriber, cleaner, inserter, overlay, history, snippets, cleanupDeadline] in
            let raw = await transcriber.stop()
            guard session == self.sessionID else { return }

            self.timeline.finalTranscript = Date()

            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

            let result = inserter.insert(final)
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
                    audioDurationMs: nil,
                    usedThoroughCleanup: usedThorough
                )
            ))

            NSLog("[quill] %@", self.timeline.logLine)

            try? await Task.sleep(for: .milliseconds(900))
            overlay.hide()
        }
    }

    private func cancelDictation() {
        guard isDictating else { return }
        isDictating = false
        isSpeculating = false
        sessionID += 1
        Task { [transcriber, overlay] in
            await transcriber.cancel()
            overlay.hide()
        }
    }

    private func fail(_ message: String) {
        isDictating = false
        isSpeculating = false
        overlay.show(.error(message))
    }

    /// Returns nil if the operation did not finish in time. The operation is
    /// left running rather than cancelled — it is harmless, and cancelling a
    /// model inference mid-flight is not reliably cheap.
    private static func withDeadline<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
    }

    public func transcriber(didFail error: Error) {
        fail(error.localizedDescription)
    }
}
