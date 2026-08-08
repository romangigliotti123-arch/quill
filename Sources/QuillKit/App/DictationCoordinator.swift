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

    /// How long the thorough cleanup is allowed to take before we give up on it
    /// and insert the fast version. Past roughly a quarter second the pause
    /// between releasing the key and seeing text becomes the thing you notice,
    /// which is exactly the piece we are trying to win.
    private let cleanupDeadline: Duration = .milliseconds(250)

    private var timeline = DictationTimeline()
    private var isDictating = false
    /// Guards against a late result from a previous dictation landing in this
    /// one — it would paste stale text into whatever you are now typing in.
    private var sessionID = 0

    public init(
        hotkey: HotkeyEngine,
        transcriber: Transcriber,
        inserter: TextInserting,
        overlay: OverlayPresenting,
        cleaner: TranscriptCleaning = FastCleaner(),
        history: HistoryStore = HistoryStore()
    ) {
        self.hotkey = hotkey
        self.transcriber = transcriber
        self.inserter = inserter
        self.overlay = overlay
        self.cleaner = cleaner
        self.history = history
        self.hotkey.delegate = self
        self.transcriber.delegate = self
    }

    @discardableResult
    public func start() -> Bool { hotkey.start() }

    // MARK: - Lifecycle

    private func beginDictation() {
        guard !isDictating else { return }
        isDictating = true
        sessionID += 1
        let session = sessionID

        timeline = DictationTimeline()
        timeline.hotkeyDown = Date()
        overlay.show(.listening(level: 0))

        Task { [transcriber] in
            // Warm the model on key-down rather than on first audio, so the
            // first word is not paying for model load.
            await transcriber.prepare()
            guard session == self.sessionID else { return }
            do {
                try await transcriber.start()
            } catch {
                self.fail("Could not start listening: \(error.localizedDescription)")
            }
        }
    }

    private func endDictation() {
        guard isDictating else { return }
        isDictating = false
        let session = sessionID
        overlay.show(.transcribing)

        Task { [transcriber, cleaner, inserter, overlay, history, cleanupDeadline] in
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
            if let better = await Self.withDeadline(cleanupDeadline, operation: {
                await cleaner.cleanThorough(raw, deadline: cleanupDeadline)
            }), better != fast {
                final = better
                usedThorough = true
            }

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
        sessionID += 1
        Task { [transcriber, overlay] in
            await transcriber.cancel()
            overlay.hide()
        }
    }

    private func fail(_ message: String) {
        isDictating = false
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
