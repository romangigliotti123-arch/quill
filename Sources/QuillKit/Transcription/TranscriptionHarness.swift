import AVFoundation
import Foundation

/// Runs the real transcription path against a file and reports what it measured.
///
/// This exists because "the transcriber works" is otherwise an unfalsifiable
/// claim: the microphone needs a TCC grant and a person, so the only way to
/// know the engine produces text — and how fast — on a build machine is to feed
/// it audio from disk through exactly the same code the microphone uses.
/// Nothing here is a mock: same `SpeechAnalyzerTranscriber`, same
/// `AnalyzerFeed`, same session fencing, same watchdog. Only `AudioSource` differs.
public enum TranscriptionHarness {

    public struct Report {
        public var transcript: String
        public var audioDuration: TimeInterval
        public var wallClock: TimeInterval
        /// Seconds from `start()` to the first partial reaching the delegate.
        public var firstPartial: TimeInterval?
        /// Seconds from `start()` to the first settled span.
        public var firstFinal: TimeInterval?
        public var partialCount: Int
        public var finalCount: Int
        public var peakLevel: Float
        public var timeline: DictationTimeline
        public var errors: [String]

        public var realtimeFactor: Double {
            wallClock > 0 ? audioDuration / wallClock : 0
        }

        public var summary: String {
            func s(_ v: TimeInterval?) -> String { v.map { String(format: "%.3f s", $0) } ?? "—" }
            var lines: [String] = []
            lines.append(String(format: "audio duration    : %.2f s", audioDuration))
            lines.append(String(format: "wall clock        : %.2f s", wallClock))
            lines.append(String(format: "real-time factor  : %.1fx", realtimeFactor))
            lines.append("first partial     : \(s(firstPartial))")
            lines.append("first final       : \(s(firstFinal))")
            lines.append("results           : \(partialCount) partial, \(finalCount) final")
            lines.append(String(format: "peak input level  : %.3f (0…1)", peakLevel))
            lines.append("timeline          : \(timeline.logLine)")
            if !errors.isEmpty { lines.append("errors            : \(errors.joined(separator: " | "))") }
            lines.append("transcript        : \(transcript)")
            return lines.joined(separator: "\n")
        }
    }

    /// - Parameter realtime: true feeds audio on a wall clock, the way a
    ///   microphone would, so the latency numbers mean what they say. False
    ///   feeds as fast as the file reads, which measures throughput instead.
    @MainActor
    public static func run(
        fileURL: URL,
        realtime: Bool = true,
        locale: Locale = SpeechAssets.preferredLocale,
        maxWait: TimeInterval = 120
    ) async throws -> Report {

        let source = AudioFileSource(url: fileURL, realtime: realtime)
        source.prepare()
        guard source.captureFormat != nil else {
            throw AudioSourceError.engineFailed("cannot open \(fileURL.path)")
        }

        let transcriber = SpeechAnalyzerTranscriber(audio: source, locale: locale)
        let collector = Collector()
        transcriber.delegate = collector
        transcriber.onLevel = { [weak collector] level in collector?.note(level: level) }

        let (ended, endedContinuation) = AsyncStream<Void>.makeStream()
        source.onEnded = {
            endedContinuation.yield(())
            endedContinuation.finish()
        }

        transcriber.noteHotkeyDown()
        await transcriber.prepare()

        let started = Date()
        collector.origin = started
        try await transcriber.start()

        // The file source signals the end of audio; the deadline is only here so
        // a stalled read cannot wedge a build.
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(maxWait * 1_000_000_000))
            endedContinuation.finish()
        }
        for await _ in ended { break }
        deadline.cancel()

        let transcript = await transcriber.stop()
        let wallClock = Date().timeIntervalSince(started)

        // Delegate callbacks land on the main queue; give the last one a beat to
        // arrive before reading the counters, or the report undercounts by one.
        try? await Task.sleep(nanoseconds: 50_000_000)

        return Report(
            transcript: transcript,
            audioDuration: source.duration,
            wallClock: wallClock,
            firstPartial: collector.firstPartial,
            firstFinal: collector.firstFinal,
            partialCount: collector.partialCount,
            finalCount: collector.finalCount,
            peakLevel: collector.peakLevel,
            timeline: transcriber.timeline,
            errors: collector.errors
        )
    }

    /// Transcribes every `.wav` in a directory and writes one JSON object per
    /// line: clip id, transcript, and the timings.
    ///
    /// This is the difference between an experiment that takes fifteen seconds
    /// and one that takes thirty-five minutes. Word error rate is scored on the
    /// *raw* recogniser output, so nothing downstream of the transcriber can move
    /// it — which means comparing two recogniser configurations needs no
    /// microphone, no loopback device, no synthetic keystrokes and no idle
    /// machine. Batch mode runs at roughly 40x real time.
    ///
    /// The loopback rig is still the only way to measure *Flow*, which is a black
    /// box. It is not the way to tune ours.
    @MainActor
    public static func runDirectoryIfRequested() async -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["QUILL_TRANSCRIBE_DIR"] else { return false }
        let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        let files = ((try? FileManager.default.contentsOfDirectory(at: root,
                                                                   includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let locale = env["QUILL_TRANSCRIBE_LOCALE"].map(Locale.init(identifier:))
            ?? SpeechAssets.preferredLocale
        // Batch feeding is ~40x faster and fine for a quick sweep, but it is not
        // what the app does: a microphone delivers at 1x, and the recogniser's
        // endpointing behaves differently when it is not being force-fed. Any
        // configuration choice that ships has to be decided on realtime numbers.
        let realtime = env["QUILL_TRANSCRIBE_REALTIME"] == "1"
        var lines: [String] = []
        for file in files {
            let id = file.deletingPathExtension().lastPathComponent
            do {
                let report = try await run(fileURL: file, realtime: realtime, locale: locale)
                let payload: [String: Any] = [
                    "clip": id,
                    "text": report.transcript,
                    "audio_s": report.audioDuration,
                    "wall_s": report.wallClock,
                    "partials": report.partialCount,
                    "finals": report.finalCount,
                    "first_partial_s": report.firstPartial as Any,
                    "first_final_s": report.firstFinal as Any,
                    "realtime": realtime,
                    "errors": report.errors,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                }
                FileHandle.standardError.write(Data("ok   \(id)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("FAIL \(id): \(error)\n".utf8))
            }
        }
        let out = env["QUILL_TRANSCRIBE_OUT"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let body = lines.joined(separator: "\n") + "\n"
        if let out { try? body.write(to: out, atomically: true, encoding: .utf8) }
        else { print(body) }
        return true
    }

    /// Launch hook: `QUILL_TRANSCRIBE_FILE=/path/to.wav` runs the harness,
    /// prints the report and returns true, so the app can exit instead of
    /// putting up a menu bar item. Returns false when the variable is unset.
    @discardableResult
    public static func runIfRequested() async -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["QUILL_TRANSCRIBE_FILE"] else { return false }
        let realtime = env["QUILL_TRANSCRIBE_BATCH"] != "1"
        let locale = env["QUILL_TRANSCRIBE_LOCALE"].map(Locale.init(identifier:)) ?? SpeechAssets.preferredLocale
        do {
            let report = try await run(fileURL: URL(fileURLWithPath: path), realtime: realtime, locale: locale)
            print(realtime ? "=== STREAMING (audio fed at 1x, as a microphone would) ==="
                           : "=== BATCH (audio fed as fast as it reads) ===")
            print(report.summary)
        } catch {
            print("harness failed: \(error)")
        }
        return true
    }

    /// Collects what the delegate is handed, with arrival times.
    /// Delegate traffic arrives on the main actor, so most of this is main-only
    /// and needs no locking. The level callback is the exception — it comes off
    /// the audio thread hundreds of times a second, so it gets a lock and stays
    /// nonisolated rather than hopping to main and distorting the very timings
    /// this harness exists to measure.
    private final class Collector: TranscriberDelegate, @unchecked Sendable {
        var origin = Date()
        var firstPartial: TimeInterval?
        var firstFinal: TimeInterval?
        var partialCount = 0
        var finalCount = 0
        var errors: [String] = []

        private let levelLock = NSLock()
        // nonisolated(unsafe) because conforming to a @MainActor protocol isolates
        // the whole class. The lock, not the actor, is what guards this one.
        nonisolated(unsafe) private var _peakLevel: Float = 0

        nonisolated var peakLevel: Float {
            levelLock.lock(); defer { levelLock.unlock() }
            return _peakLevel
        }

        func transcriber(didProduce transcript: Transcript) {
            let elapsed = Date().timeIntervalSince(origin)
            if transcript.isFinal {
                finalCount += 1
                if firstFinal == nil { firstFinal = elapsed }
            } else {
                partialCount += 1
                if firstPartial == nil { firstPartial = elapsed }
            }
        }

        func transcriber(didFail error: Error) {
            errors.append(error.localizedDescription)
        }

        nonisolated func note(level: Float) {
            levelLock.lock(); defer { levelLock.unlock() }
            _peakLevel = max(_peakLevel, level)
        }
    }
}
