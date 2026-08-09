import AVFoundation
import Foundation
import Speech

/// Streaming on-device transcription on `SpeechAnalyzer` + `SpeechTranscriber`.
///
/// Measured on this machine (M5 Air, macOS 27, en-AU, 20.8 s of speech): first
/// volatile result at ~1.0 s covering audio 0.000–1.100 s, median volatile lag
/// -0.085 s behind live audio — the hypothesis arrives *before* the audio it
/// describes has finished playing — and 68× real time in batch. Those numbers
/// come from `[.volatileResults, .fastResults]` specifically; dropping
/// `.fastResults` roughly doubles the wait for the first word.
///
/// Three things in here are not obvious and all three are load-bearing:
///
/// 1. `prepare()` builds the analyzer and warms the model *before* any audio
///    exists, with `ModelRetention.processLifetime` so the second dictation of a
///    session does not pay for a model load either.
/// 2. Every callback carries an integer session id. Speech results are
///    inherently late; without the fence a final belonging to the dictation you
///    just released can land inside the next one and paste stale text into
///    whatever the user is now typing in.
/// 3. `stop()` cannot block forever. If the analyzer never closes the results
///    stream, a watchdog returns the text collected so far and reports the
///    timeout rather than leaving the overlay spinning with the key released.
public final class SpeechAnalyzerTranscriber: Transcriber {

    // Read and written only on the main thread (set once at wiring time, read
    // inside main-queue hops).
    public weak var delegate: TranscriberDelegate?

    /// Live input level, 0…1, delivered on main. The overlay's waveform reads
    /// this; `inputLevel` is the same value for anyone who would rather poll.
    public var onLevel: ((Float) -> Void)?

    private let audio: AudioSource
    private let requestedLocale: Locale
    private let finalizeTimeout: Double
    private let prepareTimeout: Double

    private let lock = NSLock()
    private var _timeline = DictationTimeline()
    private var _level: Float = 0
    private var warm: WarmEngine?
    private var prepareTask: Task<Void, Never>?
    private var session: Session?
    private var sessionCounter = 0
    /// Only ever advances. A callback tagged with an older id is a ghost.
    private var liveSessionID = 0
    private var lastFinalText = ""

    public init(
        audio: AudioSource = AudioCapture(),
        locale: Locale = SpeechAssets.preferredLocale,
        finalizeTimeout: Double = 3.0,
        prepareTimeout: Double = 20.0
    ) {
        self.audio = audio
        self.requestedLocale = locale
        self.finalizeTimeout = finalizeTimeout
        self.prepareTimeout = prepareTimeout
    }

    // MARK: - Exposed state

    /// Every touch of the mutable state goes through here. It is a function
    /// rather than bare `lock()`/`unlock()` calls because `NSLock` is marked
    /// unavailable from async contexts — correctly, since holding it across an
    /// `await` would pin a cooperative thread. Nothing inside a `withLock` body
    /// suspends, and the compiler can see that.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// The two stamps this type is the only witness to are filled in here;
    /// `hotkeyDown`, `finalTranscript` and `textInserted` belong to the
    /// coordinator, which copies this value and completes it. `finalTranscript`
    /// is stamped as a floor so the log line is never empty if it forgets.
    public var timeline: DictationTimeline {
        lock.lock(); defer { lock.unlock() }
        return _timeline
    }

    public var inputLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    /// Call on hotkey-down, before `prepare()`, so time-to-first-word is measured
    /// from the key rather than from whenever the app got around to it.
    public func noteHotkeyDown(at date: Date = Date()) {
        lock.lock()
        _timeline = DictationTimeline()
        _timeline.hotkeyDown = date
        lock.unlock()
    }

    // MARK: - Transcriber

    /// Idempotent, and safe to call while a previous warm is still in flight —
    /// hotkey-down can arrive twice in quick succession and building two
    /// analyzers would double the model's memory for no benefit.
    public func prepare() async {
        enum Step { case alreadyWarm, joinInFlight(Task<Void, Never>), build }

        let step: Step = withLock {
            if warm != nil { return .alreadyWarm }
            if let running = prepareTask { return .joinInFlight(running) }
            return .build
        }

        switch step {
        case .alreadyWarm:
            return
        case .joinInFlight(let running):
            await running.value
            return
        case .build:
            break
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.buildWarmEngine()
        }
        withLock { prepareTask = task }

        // A model load that hangs must not hang the hotkey. If the deadline wins,
        // `warm` stays nil and start() reports honestly instead of never returning.
        let finished = await withDeadline(prepareTimeout) { await task.value }
        withLock { prepareTask = nil }
        if !finished { report(TranscriptionError.finalizeTimedOut(seconds: prepareTimeout)) }
    }

    public func start() async throws {
        await teardown(current: nil)
        await prepare()

        let engine: WarmEngine? = withLock {
            let e = warm
            warm = nil
            return e
        }

        guard let engine else { throw TranscriptionError.unavailable }

        audio.prepare()
        guard let captureFormat = audio.captureFormat else { throw AudioSourceError.noInputDevice }

        let feed = try await AnalyzerFeed.make(
            modules: [engine.module],
            captureFormat: captureFormat,
            analyzerFormat: engine.analyzerFormat
        )

        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (done, doneContinuation) = AsyncStream<Void>.makeStream()

        let session: Session = withLock {
            sessionCounter += 1
            liveSessionID = sessionCounter
            let new = Session(
                id: sessionCounter,
                module: engine.module,
                analyzer: engine.analyzer,
                feed: feed,
                inputs: inputContinuation,
                done: done,
                doneContinuation: doneContinuation
            )
            self.session = new
            // Only this dictation's stamps are cleared; hotkeyDown belongs to
            // whoever saw the key, and is only invented here if nobody did.
            _timeline.audioFirstBuffer = nil
            _timeline.firstPartial = nil
            _timeline.finalTranscript = nil
            _timeline.textInserted = nil
            if _timeline.hotkeyDown == nil { _timeline.hotkeyDown = Date() }
            return new
        }
        let id = session.id

        session.drain = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.drain(session)
        }

        do {
            try await engine.analyzer.start(inputSequence: inputs)
            audio.onBuffer = { [weak self] buffer, time in self?.ingest(buffer, at: time, session: id) }
            audio.onLevel = { [weak self] level in self?.publish(level: level) }
            try audio.start()
        } catch {
            // A throw here — no microphone, a refused analyzer — would otherwise
            // leave an installed session with a live drain task behind it, and
            // the caller has no handle to clean that up.
            await teardown(current: session)
            withLock { if self.session === session { self.session = nil } }
            throw error
        }
    }

    public func stop() async -> String {
        let live: Session? = withLock { session }
        guard let session = live else { return withLock { lastFinalText } }

        audio.onBuffer = nil
        audio.stop()

        // The converter is holding a partial frame of the last word. Dropping it
        // clips the final syllable, which reads as a typo rather than a bug.
        if let tail = try? session.feed.flush() {
            for input in tail { session.inputs.yield(input) }
        }
        session.inputs.finish()

        // Not awaited directly: if finalize itself stalls, the watchdog below is
        // what gets the user their text back.
        let finalize = Task { try? await session.analyzer.finalizeAndFinishThroughEndOfInput() }
        let settledInTime = await waitForDrain(session, timeout: finalizeTimeout)
        finalize.cancel()

        let text: String = withLock {
            // On a timeout the volatile hypothesis is the best text that exists;
            // handing back nothing because the analyzer went quiet is the worse bug.
            let settled = (session.settled + (settledInTime ? "" : session.volatile))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _timeline.finalTranscript = Date()
            lastFinalText = settled
            if self.session === session { self.session = nil }
            return settled
        }

        session.drain?.cancel()
        if !settledInTime { report(TranscriptionError.finalizeTimedOut(seconds: finalizeTimeout), session: session.id) }
        // Usually a duplicate of the last final the drain already sent — harmless,
        // because finals carry the whole utterance and a consumer replaces rather
        // than appends. It is not redundant when the watchdog fired: then this is
        // the only final that ever arrives, and without it the overlay would sit
        // on a volatile hypothesis forever.
        emit(Transcript(text: text, isFinal: true), session: session.id)
        rewarm()
        return text
    }

    public func cancel() async {
        let session: Session? = withLock {
            let live = self.session
            self.session = nil
            lastFinalText = ""
            return live
        }
        await teardown(current: session)
        rewarm()
    }

    // MARK: - Session lifecycle

    private final class Session {
        let id: Int
        let module: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let feed: AnalyzerFeeding
        let inputs: AsyncStream<AnalyzerInput>.Continuation
        let done: AsyncStream<Void>
        let doneContinuation: AsyncStream<Void>.Continuation
        var drain: Task<Void, Never>?
        /// Guarded by the transcriber's lock, not this object's.
        var settled = ""
        var volatile = ""

        init(
            id: Int,
            module: SpeechTranscriber,
            analyzer: SpeechAnalyzer,
            feed: AnalyzerFeeding,
            inputs: AsyncStream<AnalyzerInput>.Continuation,
            done: AsyncStream<Void>,
            doneContinuation: AsyncStream<Void>.Continuation
        ) {
            self.id = id
            self.module = module
            self.analyzer = analyzer
            self.feed = feed
            self.inputs = inputs
            self.done = done
            self.doneContinuation = doneContinuation
        }
    }

    private struct WarmEngine {
        let module: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let analyzerFormat: AVAudioFormat?
    }

    private func buildWarmEngine() async {
        guard SpeechTranscriber.isAvailable else {
            report(TranscriptionError.unavailable)
            return
        }
        guard let locale = await SpeechAssets.resolve(requestedLocale) else {
            report(TranscriptionError.localeUnsupported(requestedLocale.identifier))
            return
        }

        // Pins the model against eviction. Capped at five locales per process,
        // which Quill will never approach, and never triggers a download.
        await SpeechAssets.reserve(locale)

        let module = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )

        // Only `.unsupported` is worth refusing on: the inventory reports
        // `.supported` for a model the OS will materialise on first use, and
        // failing there would break a Mac that works fine.
        if await AssetInventory.status(forModules: [module]) == .unsupported {
            report(TranscriptionError.modelNotInstalled(locale.identifier(.bcp47)))
            return
        }

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )

        // Bias the model toward names it has never seen. This has to happen
        // before analysis starts — it changes what gets heard, and no amount of
        // post-processing can recover a proper noun the model split in two.
        let context = AnalysisContext()
        context.contextualStrings[.general] = Vocabulary.load().contextualStrings
        do {
            try await analyzer.setContext(context)
            let applied = await analyzer.context.contextualStrings[.general]?.count ?? 0
            NSLog("[quill] contextual biasing: %d terms applied", applied)
        } catch {
            // Not fatal — dictation still works, proper nouns just suffer. Worth a
            // log line rather than a silent degradation nobody can explain later.
            NSLog("[quill] contextual biasing REJECTED: %@", String(describing: error))
        }

        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            report(error)
            return
        }

        withLock { warm = WarmEngine(module: module, analyzer: analyzer, analyzerFormat: format) }
    }

    /// Re-warms in the background so the *next* hotkey-down finds a loaded model.
    /// The model itself is already resident thanks to `.processLifetime`; this
    /// just rebuilds the cheap wrappers around it.
    private func rewarm() {
        Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.prepare()
        }
    }

    private func teardown(current: Session?) async {
        let session: Session? = withLock {
            let live = current ?? self.session
            if current == nil { self.session = nil }
            return live
        }
        guard let session else { return }

        audio.onBuffer = nil
        audio.stop()
        session.inputs.finish()
        session.drain?.cancel()
        session.doneContinuation.finish()
        // Bounded, because the point of tearing down is to be able to start again.
        await withDeadline(1.0) { await session.analyzer.cancelAndFinishNow() }
    }

    // MARK: - Audio in

    private func ingest(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?, session id: Int) {
        let live: Session? = withLock {
            guard let session = self.session, session.id == id else { return nil }
            if _timeline.audioFirstBuffer == nil { _timeline.audioFirstBuffer = Date() }
            return session
        }
        guard let session = live else { return }

        do {
            for input in try session.feed.inputs(from: buffer, at: time) {
                session.inputs.yield(input)
            }
        } catch {
            report(error, session: id)
        }
    }

    private func publish(level: Float) {
        withLock { _level = level }
        onLevel?(level)
    }

    // MARK: - Results out

    private func drain(_ session: Session) async {
        do {
            for try await result in session.module.results {
                let text = String(result.text.characters)
                guard let payload = absorb(text, isFinal: result.isFinal, into: session) else { break }
                emit(payload, session: session.id)
            }
        } catch {
            report(error, session: session.id)
        }
        session.doneContinuation.yield(())
        session.doneContinuation.finish()
    }

    /// Folds one result into the session and returns what to publish, or nil once
    /// this session has been superseded — the fence that stops a late final from
    /// a released dictation writing into the one now running.
    private func absorb(_ text: String, isFinal: Bool, into session: Session) -> Transcript? {
        withLock {
            guard self.session === session else { return nil }
            if _timeline.firstPartial == nil { _timeline.firstPartial = Date() }
            if isFinal {
                session.settled += text
                session.volatile = ""
            } else {
                session.volatile = text
            }
            // Both kinds carry the whole utterance so far, not just the span that
            // changed: every consumer (overlay, paste, log) wants "the text right
            // now", and one that only renders the newest event would otherwise
            // flash a fragment each time a span settles.
            return Transcript(
                text: (session.settled + session.volatile)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                isFinal: isFinal
            )
        }
    }

    /// Returns true if the results stream closed on its own, false if the
    /// watchdog had to step in.
    private func waitForDrain(_ session: Session, timeout: Double) async -> Bool {
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

    // MARK: - Delivery

    /// `DispatchQueue.main` rather than `Task { @MainActor in }` because these
    /// have to arrive in the order they were produced — a partial overtaking the
    /// final it precedes would put stale text on screen — and only the queue
    /// guarantees FIFO.
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
}

/// Runs `work` with a deadline, and — the part that matters — never awaits an
/// uncancellable child while doing it. A watchdog implemented with a task group
/// still hangs when the thing it is watching hangs, because the group waits for
/// all of its children before it returns.
@discardableResult
func withDeadline(_ seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
    let (signal, continuation) = AsyncStream<Bool>.makeStream()
    let job = Task {
        await work()
        continuation.yield(true)
        continuation.finish()
    }
    let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        continuation.yield(false)
        continuation.finish()
    }
    var completed = false
    for await value in signal {
        completed = value
        break
    }
    timer.cancel()
    if !completed { job.cancel() }
    return completed
}
