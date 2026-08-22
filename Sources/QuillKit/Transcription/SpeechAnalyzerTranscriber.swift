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
    /// Which session is entitled to touch the shared audio source.
    ///
    /// A dictation begun while the previous one is still finalising races it over
    /// the SHARED audio source: the old stop() sets onBuffer = nil and calls
    /// audio.stop(), silencing the session that just started. Measured at 1.5s
    /// between dictations: 10 of 40 clips produced no transcript at all.
    ///
    /// Making start() wait for stop() fixes the race and breaks the app — stop can
    /// take 4s and a user's next keypress will not wait. So ownership is tracked
    /// instead: a stop only tears down the audio if it still owns it.
    private var audioOwner = 0
    private var stopInFlight: (sessionID: Int?, task: Task<String, Never>)?

    /// How long to keep the microphone open past the key release when the
    /// recogniser has not committed to a single word yet.
    ///
    /// Only ever paid by a dictation that would otherwise return nothing, so the
    /// number is chosen to rescue the shortest real utterance rather than to be
    /// small. 1.5s covers "On my way." with room to spare; past about two
    /// seconds the recogniser was never going to answer and the wait is just a
    /// worse way to fail.
    public var shortUtteranceGrace: TimeInterval = 2.5

    /// Same floor the coordinator uses to decide "that device sent no sound at
    /// all". Duplicated as a nonisolated constant rather than reached for across
    /// the actor boundary: this is read on the audio thread, and the coordinator's
    /// copy is main-isolated. The two must agree, so they are asserted equal in
    /// the tests rather than left to drift.
    nonisolated static let silenceFloor: Float = 0.005

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

    /// Bumped by anything that abandons a start. `start()` is a long chain of
    /// awaits — `prepare()`, `AnalyzerFeed.make`, `analyzer.start` — and it used
    /// to check for cancellation at none of them.
    ///
    /// The hole that opened: a single tap of the trigger key, or Right-Option
    /// pressed as part of ⌥⌫ or ⌥←, begins a preroll. `cancel()` arrives 30-80ms
    /// later, while `start()` is still inside `audio.prepare()` — the ~155ms HAL
    /// open this file measures as micOpenMs — so `self.session` is not installed
    /// yet, `teardown` early-returns without touching audio, and `audio.stop()`
    /// would have been a no-op anyway because `running` is still false. Then
    /// `start()` carries on to `audio.start()` and opens the microphone for a
    /// gesture that was abandoned before it began.
    ///
    /// Nothing closed it. No dictation, no overlay, no state — just a live tap
    /// and a SpeechAnalyzer transcribing the room, with the orange indicator lit,
    /// until the next hotkey press happened to tear it down. Seconds, or hours.
    private var startGeneration = 0

    public func start() async throws {
        let generation = withLock { startGeneration }
        func abandoned() -> Bool { withLock { startGeneration != generation } }

        await teardown(current: nil)
        await prepare()
        // Before the HAL open, so an already-abandoned preroll does not pay for a
        // microphone it will never use.
        guard !abandoned() else { return }

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
            audioOwner = sessionCounter
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
            // The last gate, and the one that matters: everything above is
            // reversible, `audio.start()` is what actually opens the microphone.
            //
            // Returns rather than throws. The coordinator's catch calls `fail()`,
            // which would put "Could not start listening" on screen for a gesture
            // the user deliberately abandoned. `teardown`'s `audio.stop()` here is
            // a harmless no-op precisely because the tap was never installed.
            guard !abandoned() else {
                await teardown(current: session)
                withLock { if self.session === session { self.session = nil } }
                return
            }
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
        // Reentrancy, keyed to the session rather than to the transcriber.
        //
        // Sharing one in-flight stop across dictations is the same bug as
        // returning `lastFinalText`, arrived at from the other direction: a
        // second dictation's stop() would join the first one's task, receive the
        // FIRST utterance's text, and never finalise its own session — so the
        // second dictation's words are both wrong on screen and lost. The point
        // of this guard is only ever "two stops for the SAME dictation must not
        // both tear it down".
        let currentSession = withLock { session?.id }
        if let pending = withLock({ stopInFlight }), pending.sessionID == currentSession {
            return await pending.task.value
        }
        let task = Task<String, Never> { [weak self] in
            guard let self else { return "" }
            return await self.performStop()
        }
        withLock { stopInFlight = (sessionID: currentSession, task: task) }
        let result = await task.value
        withLock { if stopInFlight?.task == task { stopInFlight = nil } }
        return result
    }

    private func performStop() async -> String {
        let live: Session? = withLock { session }
        guard let session = live else {
            // Empty, never `lastFinalText`.
            //
            // This used to return the PREVIOUS dictation's transcript, and the
            // coordinator has no way to tell that apart from a real one: it is a
            // non-empty string, so it sails past the empty guard, gets cleaned,
            // and is pasted into whatever the user is typing in now — a sentence
            // they said a minute ago, appearing as though they had just said it,
            // with a history row to match. What they actually said is never
            // recorded at all.
            //
            // Reachable whenever a dictation ends before its session exists: the
            // key released during model warm-up, or during the rewarm that
            // follows every successful dictation. Two quick dictations in a row
            // is enough.
            //
            // Returning nothing is honest — the coordinator then shows "Nothing
            // was heard", which is exactly what happened.
            return ""
        }

        // Keep listening a moment longer when nothing has been recognised yet.
        //
        // The recogniser needs roughly two seconds of audio before it commits to
        // anything. Cut the microphone at the instant the key comes up and a
        // short utterance — "On my way.", "Sounds good.", "Booked in for Friday."
        // — finalises against a stream it never got to judge, and returns nothing
        // at all. Measured on Roman's own voice: 13 of 41 dictations produced no
        // text through the microphone, while every one of those same 50 clips
        // transcribed correctly when fed from disk. The audio was never the
        // problem; the deadline was.
        //
        // Deliberately conditional. A dictation that has already produced words
        // pays nothing — the common case still stops the instant you let go, and
        // release-to-text stays in single-digit milliseconds. Only the case that
        // was previously returning silence waits, and it waits for the shortest
        // thing that rescues it rather than a flat delay applied to everyone.
        // Only when there is something to wait FOR. Measured as the thing Roman
        // actually complains about: tap the key, change your mind, and the HUD
        // sits in front of you for 2.5s of grace plus the drain plus 1.6s of
        // "Nothing was heard" — about four seconds of being in the way, for a
        // gesture that carried no audio at all.
        if withLock({ session.settled.isEmpty && session.volatile.isEmpty && session.heardAnything }) {
            let deadline = Date().addingTimeInterval(shortUtteranceGrace)
            while Date() < deadline {
                // Abandon the grace the instant another dictation begins.
                //
                // Holding the microphone open past the key release is the whole
                // point of this wait, and it is also exactly how one dictation's
                // audio ends up inside the next one's transcript. Without this
                // check the rescue for short utterances becomes a contamination
                // bug for anyone who presses the key twice in quick succession —
                // trading a failure that is obvious for one that is not.
                if withLock({ liveSessionID != session.id }) { break }
                if withLock({ !session.settled.isEmpty || !session.volatile.isEmpty }) { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        // Only if this session still owns the microphone. A newer dictation may
        // have claimed it while this one was finalising, and pulling the tap out
        // from under it is what produced the silent failures.
        if withLock({ audioOwner == session.id }) {
            audio.onBuffer = nil
            audio.stop()
        }

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

        // Cancelling that Task stops US waiting; it does NOT stop the analyzer.
        // A timed-out analyzer carries on consuming its queued audio, and because
        // the model is retained for the process lifetime, its late results surface
        // inside the NEXT dictation — the transcript opens with the tail of the
        // previous utterance.
        //
        // Measured: with 1.5s between dictations, 6 of 41 transcripts were
        // contaminated and word error rate read 26.72%. With 6s between them,
        // zero contaminated and 2.77%. Same binary, same audio. So stop() has to
        // be a real barrier rather than a polite request.
        // Unconditional, not just on timeout. "It finished in time" means the
        // DRAIN saw a final, which is not the same as the analyzer having no work
        // left. Determinism here is worth more than the millisecond it costs, and
        // on an already-finished analyzer this is a no-op.
        await withDeadline(1.0) { await session.analyzer.cancelAndFinishNow() }

        var stillLive = false
        let text: String = withLock {
            // On a timeout the volatile hypothesis is the best text that exists;
            // handing back nothing because the analyzer went quiet is the worse bug.
            let settled = (session.settled + (settledInTime ? "" : session.volatile))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _timeline.finalTranscript = Date()
            lastFinalText = settled
            // Same mark as `cancel()`. A stop also ends whatever start may be in
            // flight behind it — otherwise a start that was still awaiting when
            // this ran would go on to open the microphone afterwards.
            startGeneration += 1
            // Whether this session was still the installed one. If something else
            // has already removed it, "the analyzer did not finish" is a statement
            // about a session we killed ourselves rather than about the analyzer,
            // and reporting it makes the coordinator fail a dictation that was
            // fine.
            stillLive = (self.session === session)
            if self.session === session { self.session = nil }
            return settled
        }

        session.drain?.cancel()
        // Only when nobody else pulled the session out from under us. A false
        // `finalizeTimedOut` reaches the coordinator's `fail()`, which puts
        // "Quill could not finish that one" on screen for a dictation that was
        // transcribed correctly.
        if !settledInTime, stillLive {
            report(TranscriptionError.finalizeTimedOut(seconds: finalizeTimeout), session: session.id)
        }
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
            // Anything still inside `start()` is now stale. This is the whole
            // mechanism: `cancel()` cannot reach into a start that has not
            // installed its session yet, so it leaves a mark that start looks for.
            startGeneration += 1
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
        /// Whether the microphone ever delivered a buffer above the silence
        /// floor. The short-utterance grace exists to give the recogniser enough
        /// audio to commit to a short phrase; if no audio arrived at all, waiting
        /// cannot rescue anything and the wait is pure delay in front of the user.
        var heardAnything = false
        /// Host time this session opened. Audio that predates it belongs to the
        /// PREVIOUS dictation and must not be transcribed into this one — see
        /// the check in ingest().
        let openedAtHostTime: UInt64 = mach_absolute_time()

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

        // `.fastResults` stays on, and the measurement that looked like a reason
        // to turn it off is the reason it stays.
        //
        // On the frozen 50-clip corpus, fed from disk, off scored better:
        //
        //   on    2.81% WER (32 errors)   first partial 1.93s
        //   off   2.46% WER (28 errors)   first partial 3.96s, never under 3.93s
        //
        // Four fewer errors in 1138 words looks like a clear win until the same
        // config is driven through a microphone. Then the first partial cannot
        // arrive before ~3.9s, and any utterance that ends before it does yields
        // an *empty* transcript — no text, no history row, nothing on screen.
        // Measured through the loopback: roughly a quarter of dictations produced
        // nothing at all, against a handful with it on.
        //
        // So the trade is not accuracy against latency. It is four errors in a
        // thousand words against losing one dictation in four, and there is no
        // version of that worth taking. A wrong word can be fixed by the person
        // reading it; a dictation that never appears is work they have to do
        // again, and they find out by looking at an empty cursor.
        //
        // `QUILL_FAST_RESULTS=0` still flips it, because the experiment should
        // stay repeatable.
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if ProcessInfo.processInfo.environment["QUILL_FAST_RESULTS"] != "0" {
            reporting.insert(.fastResults)
        }
        // DICTATION TRANSCRIBER: measured, rejected, do not re-run this.
        //
        // `SpeechTranscriber` holds a fixed window of audio before it will say
        // anything. Measured with the leading silence trimmed off six clips:
        // 1027, 1024, 1027, 1022, 1025, 1026ms. A 5ms spread across six different
        // speakers is not content-dependent, it is an internal buffer — and it is
        // about 85% of Quill's time to first word (1216ms median on Roman's own
        // dictations, of which 155ms is opening the microphone and the rest is
        // this).
        //
        // The SDK's other module looks purpose-built for the difference:
        // `DictationTranscriber` with `.shortForm` and `.progressiveShortDictation`,
        // where this one is built for long-form transcription. It IS faster. On
        // 20 clips, both with punctuation on, both fed at 1x:
        //
        //   SpeechTranscriber       1.98% WER  ( 9 errors)   first result 1028ms
        //   DictationTranscriber    9.23% WER  (42 errors)   first result  826ms
        //
        // 202ms for four and a half times the errors. That is the same trade as
        // the `.fastResults` one above and it fails for the same reason: the
        // latency is a fifth of a second nobody is timing, and the errors are in
        // the text he sends to clients. The other two presets, `.shortDictation`
        // and `.phrase`, are not progressive at all — they returned nothing until
        // the audio ended, 10.5s in.
        //
        // So the ~1s window stays, and time to first word is not a number this
        // app can move. The probe that produced these figures is standalone; the
        // two modules have different Result types and integrating one to find
        // that out would have been a refactor before the measurement.
        let module = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reporting,
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
        let (session, ownsIt): (Session?, Bool) = withLock {
            let live = current ?? self.session
            if current == nil { self.session = nil }
            // Whoever is finalising a session owns tearing it down. `performStop`
            // does all four of the analyser-side steps below at the end of its own
            // run; doing them from here as well destroys the dictation it is in
            // the middle of finishing.
            let mine = live.map { stopInFlight?.sessionID != $0.id } ?? false
            return (live, mine)
        }
        guard let session else { return }

        audio.onBuffer = nil
        audio.stop()

        // A NEW dictation must not kill the previous one's analyser.
        //
        // `start()` opens with `teardown(current: nil)`, which used to take
        // whatever session was installed — and a session stays installed until
        // the very end of `performStop`, through the short-utterance grace and the
        // drain. So pressing the key again while the last sentence was still
        // finalising cancelled its drain and finished its done-stream, which
        // resumed `waitForDrain` with no value. `performStop` then concluded the
        // analyser had timed out, reported `finalizeTimedOut`, and handed back "" —
        // for a dictation that was transcribed perfectly well and was killed by
        // the next keypress.
        //
        // The audio detach above still happens either way: `audioOwner` gates the
        // part that matters, and the new dictation genuinely does take the
        // microphone.
        guard ownsIt else { return }

        session.inputs.finish()
        session.drain?.cancel()
        session.doneContinuation.finish()
        // Bounded, because the point of tearing down is to be able to start again.
        await withDeadline(1.0) { await session.analyzer.cancelAndFinishNow() }
    }

    // MARK: - Audio in

    /// How far `earlier` precedes `later`, in seconds. Negative when it does not.
    /// Host ticks are not nanoseconds on Apple silicon, hence the timebase.
    private static func secondsBetween(_ earlier: UInt64, and later: UInt64) -> Double {
        guard later > earlier else { return -1 }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = Double(later - earlier)
        return ticks * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    private func ingest(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?, session id: Int) {
        let live: Session? = withLock {
            guard let session = self.session, session.id == id else { return nil }
            if _timeline.audioFirstBuffer == nil { _timeline.audioFirstBuffer = Date() }
            return session
        }
        guard let session = live else { return }

        // Reject audio recorded before this session opened.
        //
        // The engine keeps buffers queued, and a dictation that starts promptly
        // after the last one gets handed the tail of the previous utterance —
        // tagged with the NEW session id, so the id fence does not catch it. It
        // shows up as one transcript containing two utterances, and it inflated
        // a 50-clip eval from roughly 2% word error to 14.68%. On a person it
        // reads as "the start of my sentence has someone else's words in it".
        // Audio recorded before this session opened belongs to the PREVIOUS
        // dictation. The engine keeps buffers queued and hands them to whoever
        // starts next, tagged with the NEW session id, so the id fence does not
        // catch them. A tolerance rather than a hard boundary: the hardware
        // buffer already holds audio from a moment before the session object
        // exists, and rejecting that produced no transcript at all.
        if let time, time.isHostTimeValid,
           Self.secondsBetween(time.hostTime, and: session.openedAtHostTime) > 0.25 {
            return
        }

        do {
            for input in try session.feed.inputs(from: buffer, at: time) {
                session.inputs.yield(input)
            }
        } catch {
            report(error, session: id)
        }
    }

    private func publish(level: Float) {
        withLock {
            _level = level
            if level >= Self.silenceFloor { session?.heardAnything = true }
        }
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
