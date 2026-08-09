import AVFoundation
import Foundation
import Speech

/// The fallback transcriber, on `SFSpeechRecognizer`.
///
/// It is not deprecated in the macOS 27 SDK — checked, not assumed — so it stays
/// as the answer to "the new stack broke on this machine" without changing a
/// line anywhere else: same `Transcriber` protocol, same `AudioSource`.
///
/// Two behaviours make it a fallback rather than a peer, and both are worked
/// around here rather than left for a caller to discover:
///
/// * It **finalizes on every pause**. A mid-dictation `isFinal` is a segment
///   boundary, not the end of what the user is saying, so this type accumulates
///   the segment, immediately opens a fresh one, and only reports a real final
///   once `stop()` has been called. A naive implementation loses everything the
///   user says after their first breath.
/// * A single request **caps out near one minute** of audio. The same
///   restart-on-final path covers that, so a long dictation survives — but the
///   seam between segments is where its punctuation and casing go wrong, which
///   is the real reason `SpeechAnalyzerTranscriber` is the default.
///
/// It also needs its own TCC grant (Speech Recognition, distinct from
/// Microphone) and an `NSSpeechRecognitionUsageDescription` in Info.plist.
public final class SpeechRecognizerTranscriber: Transcriber {

    public weak var delegate: TranscriberDelegate?
    public var onLevel: ((Float) -> Void)?

    private let audio: AudioSource
    private let recognizer: SFSpeechRecognizer?
    private let finalizeTimeout: Double
    /// A recognizer that errors out mid-dictation is usually recoverable by
    /// restarting the segment; a recognizer that errors out immediately, every
    /// time, is not, and looping on it forever burns a core.
    private static let maxErrorRestarts = 8

    private let lock = NSLock()
    private var _timeline = DictationTimeline()
    private var _level: Float = 0
    private var session: Session?
    private var sessionCounter = 0
    private var liveSessionID = 0
    private var lastFinalText = ""

    public init(
        audio: AudioSource = AudioCapture(),
        locale: Locale = SpeechAssets.preferredLocale,
        finalizeTimeout: Double = 3.0
    ) {
        self.audio = audio
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
        self.finalizeTimeout = finalizeTimeout
    }

    public var timeline: DictationTimeline {
        lock.lock(); defer { lock.unlock() }
        return _timeline
    }

    public var inputLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    public var isAvailable: Bool { recognizer?.isAvailable ?? false }

    public func noteHotkeyDown(at date: Date = Date()) {
        withLock {
            _timeline = DictationTimeline()
            _timeline.hotkeyDown = date
        }
    }

    /// See the note on the same helper in `SpeechAnalyzerTranscriber`: `NSLock`
    /// is unavailable from async contexts, and nothing in these bodies suspends.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - Transcriber

    /// There is no model to warm here — the recognizer loads on first use — so
    /// this only clears the authorization prompt, which is the one thing that
    /// would otherwise block the first dictation behind a modal.
    public func prepare() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }

        // Asking without the Info.plist string does not return a denial — the OS
        // sends SIGABRT and the app is simply gone. Confirmed the hard way: a
        // bundle-less test binary died here with no output at all. Quill's own
        // Info.plist has the key, so this only fires on a mis-packaged build —
        // which is exactly when a readable error beats a silent process death.
        let key = "NSSpeechRecognitionUsageDescription"
        guard Bundle.main.object(forInfoDictionaryKey: key) != nil else {
            report(TranscriptionError.missingUsageDescription(key))
            return
        }

        await withDeadline(10.0) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
    }

    public func start() async throws {
        await cancel()

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionError.notAuthorized
        }
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.unavailable
        }

        audio.prepare()

        let (done, doneContinuation) = AsyncStream<Void>.makeStream()
        let session: Session = withLock {
            sessionCounter += 1
            liveSessionID = sessionCounter
            let new = Session(id: sessionCounter, done: done, doneContinuation: doneContinuation)
            self.session = new
            _timeline.audioFirstBuffer = nil
            _timeline.firstPartial = nil
            _timeline.finalTranscript = nil
            _timeline.textInserted = nil
            if _timeline.hotkeyDown == nil { _timeline.hotkeyDown = Date() }
            return new
        }
        let id = session.id

        startSegment(for: session, on: recognizer)

        audio.onBuffer = { [weak self] buffer, _ in self?.ingest(buffer, session: id) }
        audio.onLevel = { [weak self] level in self?.publish(level: level) }
        do {
            try audio.start()
        } catch {
            // Same reason as in SpeechAnalyzerTranscriber: a failed mic must not
            // strand a recognition task nobody can reach.
            await cancel()
            throw error
        }
    }

    public func stop() async -> String {
        let pending: (Session, SFSpeechAudioBufferRecognitionRequest?)? = withLock {
            guard let session = self.session else { return nil }
            session.finishing = true
            return (session, session.request)
        }
        guard let (session, request) = pending else { return withLock { lastFinalText } }

        audio.onBuffer = nil
        audio.stop()

        if let request {
            request.endAudio()
        } else {
            // Between segments: there is nothing in flight to finalize, so the
            // accumulated text is already the answer.
            session.doneContinuation.yield(())
            session.doneContinuation.finish()
        }

        let settledInTime = await waitForFinal(session, timeout: finalizeTimeout)

        let text: String = withLock {
            let joined = (settledInTime ? session.accumulated : Self.join(session.accumulated, session.volatile))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _timeline.finalTranscript = Date()
            lastFinalText = joined
            if self.session === session {
                self.session = nil
                session.task?.cancel()
                session.task = nil
                session.request = nil
            }
            return joined
        }

        if !settledInTime { report(TranscriptionError.finalizeTimedOut(seconds: finalizeTimeout), session: session.id) }
        emit(Transcript(text: text, isFinal: true), session: session.id)
        return text
    }

    public func cancel() async {
        let (session, task, request): (Session?, SFSpeechRecognitionTask?, SFSpeechAudioBufferRecognitionRequest?) = withLock {
            let live = self.session
            self.session = nil
            lastFinalText = ""
            let t = live?.task
            let r = live?.request
            live?.task = nil
            live?.request = nil
            return (live, t, r)
        }

        audio.onBuffer = nil
        audio.stop()
        task?.cancel()
        request?.endAudio()
        session?.doneContinuation.finish()
    }

    // MARK: - Segments

    private final class Session {
        let id: Int
        let done: AsyncStream<Void>
        let doneContinuation: AsyncStream<Void>.Continuation
        /// All of the following are guarded by the transcriber's lock.
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var accumulated = ""
        var volatile = ""
        var finishing = false
        var errorRestarts = 0

        init(id: Int, done: AsyncStream<Void>, doneContinuation: AsyncStream<Void>.Continuation) {
            self.id = id
            self.done = done
            self.doneContinuation = doneContinuation
        }
    }

    private func startSegment(for session: Session, on recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Quill is an offline app. If the device cannot do it locally it does not
        // do it at all — sending audio to Apple's servers would make the app's
        // one promise a lie.
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true

        lock.lock()
        guard self.session === session else { lock.unlock(); return }
        session.request = request
        lock.unlock()

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result, error, session: session, recognizer: recognizer)
        }

        lock.lock()
        if self.session === session { session.task = task } else { task.cancel() }
        lock.unlock()
    }

    private func handle(
        _ result: SFSpeechRecognitionResult?,
        _ error: Error?,
        session: Session,
        recognizer: SFSpeechRecognizer
    ) {
        var payload: Transcript?
        var failure: Error?
        var restart = false
        var finished = false

        lock.lock()
        guard self.session === session else { lock.unlock(); return }

        if let result {
            session.errorRestarts = 0
            let text = result.bestTranscription.formattedString
            if _timeline.firstPartial == nil { _timeline.firstPartial = Date() }

            if result.isFinal {
                session.accumulated = Self.join(session.accumulated, text)
                session.volatile = ""
                session.request = nil
                session.task = nil
                if session.finishing {
                    finished = true
                } else {
                    // A pause, or the ~1-minute cap — not the end of the dictation.
                    restart = true
                }
                payload = Transcript(text: session.accumulated, isFinal: true)
            } else {
                session.volatile = text
                payload = Transcript(text: Self.join(session.accumulated, text), isFinal: false)
            }
        } else if let error {
            session.request = nil
            session.task = nil
            if session.finishing {
                finished = true
            } else if session.errorRestarts < Self.maxErrorRestarts {
                session.errorRestarts += 1
                restart = true
            } else {
                failure = error
            }
        }
        lock.unlock()

        if let payload { emit(payload, session: session.id) }
        if let failure { report(failure, session: session.id) }
        if restart { startSegment(for: session, on: recognizer) }
        if finished {
            session.doneContinuation.yield(())
            session.doneContinuation.finish()
        }
    }

    private func waitForFinal(_ session: Session, timeout: Double) async -> Bool {
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            session.doneContinuation.finish()
        }
        var completed = false
        for await _ in session.done {
            completed = true
            break
        }
        timer.cancel()
        return completed
    }

    // MARK: - Audio in

    private func ingest(_ buffer: AVAudioPCMBuffer, session id: Int) {
        lock.lock()
        guard let session = self.session, session.id == id else { lock.unlock(); return }
        if _timeline.audioFirstBuffer == nil { _timeline.audioFirstBuffer = Date() }
        let request = session.request
        lock.unlock()
        request?.append(buffer)
    }

    private func publish(level: Float) {
        lock.lock(); _level = level; lock.unlock()
        onLevel?(level)
    }

    // MARK: - Delivery

    private func emit(_ transcript: Transcript, session id: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = self.liveSessionID
            self.lock.unlock()
            guard live == id else { return }
            self.delegate?.transcriber(didProduce: transcript)
        }
    }

    /// `session: nil` is for failures that happen outside a dictation (warm-up,
    /// authorization) and so cannot be fenced against one.
    private func report(_ error: Error, session id: Int? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let id {
                self.lock.lock()
                let live = self.liveSessionID
                self.lock.unlock()
                guard live == id else { return }
            }
            self.delegate?.transcriber(didFail: error)
        }
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
