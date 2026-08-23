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
    /// Loudest input level seen during the current dictation.
    private var peakLevel: Float = 0
    /// Whether ANY level arrived, as distinct from levels that were all silent.
    ///
    /// The difference decides whether a quick tap is binned. A peak of zero can
    /// mean the microphone heard nothing — bin it — or that no buffer ever
    /// reached us, which is a different failure and one the user needs told
    /// about. It also stops the guard firing in tests, where the transcriber is a
    /// double that produces text without ever publishing a level: without this
    /// the whole coordinator suite came back with every dictation silently
    /// discarded, which is the guard working exactly as written and exactly
    /// wrongly.
    private var sawLevels = false
    var sawLevelsForTesting: Bool { sawLevels }
    private let history: HistoryStore
    private let snippets: SnippetStore
    private let settings: QuillSettings
    /// Puts words on screen while you are still speaking. Only used when the
    /// setting is on and the focused app can actually take synthetic keystrokes;
    /// otherwise the release-and-paste path below runs exactly as it always did.
    private let liveTyper: LiveTyper
    private var isLive = false
    /// The token `liveTyper.begin()` handed this dictation. Every later call
    /// presents it, so a session that was superseded mid-finalise cannot type
    /// through the one that replaced it.
    private var liveGeneration = 0
    /// True from the moment a dictation stops recording until its text has landed.
    ///
    /// The session fence stops a finalising dictation from INSERTING into the one
    /// that replaced it. It does not stop the two from being in the same field at
    /// once: the older one's live-typed partials are already sitting there, and
    /// the newer one would start streaming its own on top of them. Two sentences
    /// interleaving character by character in somebody's document is not something
    /// a fence can tidy up afterwards.
    ///
    /// So a dictation started while another is still finishing does not live-type
    /// at all — it falls back to paste-on-release, which lands in one piece after
    /// the older one is done. Roman's call, asked directly.
    private var isFinalising = false
    /// "Finish, then Enter" — see `hotkeyAborted()`. Armed by a quick tap of
    /// the dictation key that lands while a dictation is still finalising,
    /// or shortly after one just landed; cleared the moment Return actually
    /// gets sent.
    private var pendingReturnAfterInsertion = false
    /// When the last dictation's text actually landed — not when the key
    /// was released. A tap arriving after `finishThenEnterWindow` has
    /// passed is not "right after" anything any more and is left alone.
    private var lastInsertionAt: Date?
    private static let finishThenEnterWindow: TimeInterval = 1.2
    /// Set by `hotkeyTriggerIncludesCommand(_:)` right before the current
    /// gesture starts, and read once at the end of it — see
    /// `hotkeyTriggerIncludesCommand(_:)` for why plain-Option dictation must
    /// never fall into voice-triggered transform routing.
    private var transformGestureActive = false
    private let transforms: (router: CommandRouter, engine: TransformEngine)?
    /// What Quill last inserted, so "make that shorter" has something to act on.
    ///
    /// Read by the transform engine through a closure rather than passed in, so
    /// the engine sees the latest value rather than whatever existed when the app
    /// launched.
    public private(set) var lastInsertion: TransformEngine.LastDictation?
    /// Remembers the last insertion so ⌥⌫ can take it back. Optional because
    /// every path in this file works without one, and a test that does not care
    /// about the chord should not have to build one.
    private let undo: InsertionUndo?

    private var timeline = DictationTimeline()
    /// A `didSet` rather than a post at each of the four call sites that flip
    /// this — `beginDictation()`, `endDictation()`, `cancelDictation()`,
    /// `fail()` — because a fifth call site added later would silently miss
    /// the notification if it were the caller's job to remember it.
    private var isDictating = false {
        didSet {
            guard oldValue != isDictating else { return }
            NotificationCenter.default.post(name: .quillDictationStateChanged, object: isDictating)
        }
    }
    /// Whether a dictation is live right now, for anything outside this file
    /// that needs to know — the persistent overlay button, so a click toggles
    /// rather than always starting.
    public var isCurrentlyDictating: Bool { isDictating }
    /// Capturing, but not yet committed: the key is down and the gesture has not
    /// resolved. Audio recorded in this window is kept if the gesture becomes a
    /// dictation and thrown away if it does not.
    private var isSpeculating = false
    private var capturedInputDevice: String?
    /// Where the words are going, decided at key-down.
    ///
    /// Captured with the focus rather than read at insertion time, for the same
    /// reason the live typer captures its target then: the app you were in when
    /// you started speaking is the one you meant, and formatting decided against
    /// whatever happens to be frontmost a second later would be formatting for an
    /// app the user never chose.
    private var capturedContext: AppContext = .prose
    /// How the destination is decided, injected so it can be pinned.
    ///
    /// `AppContext.current()` reads the frontmost application — process-wide
    /// state that a unit test does not own. Three tests of the dictation path
    /// started passing or failing depending on which window happened to be
    /// focused on the machine running them: focused on a terminal, the formatter
    /// correctly lower-cased the first letter and stripped the trailing full
    /// stop, and the assertions were written against prose. A test whose result
    /// depends on where the mouse was last clicked is not a test.
    private let context: @MainActor () -> AppContext
    private let sendReturn: @MainActor () -> Void
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
        liveTyper: LiveTyper = LiveTyper(),
        undo: InsertionUndo? = nil,
        /// Turns a finished utterance into a transform, or leaves it as content.
        /// Nil means the feature is off and every utterance is content — which is
        /// what shipped for the whole life of the Transforms screen.
        transforms: (router: CommandRouter, engine: TransformEngine)? = nil,
        context: @escaping @MainActor () -> AppContext = { AppContext.current() },
        /// Posts the Return keystroke for "finish, then Enter" — injectable
        /// for the same reason `context` is: a test that actually posted a
        /// real Return to whatever app the test machine happens to have
        /// focused would be a bug pretending to be a feature.
        sendReturn: @escaping @MainActor () -> Void = {
            SyntheticKeyboard.postChord(key: SyntheticKeyboard.keyReturn, flags: [])
        }
    ) {
        self.context = context
        self.sendReturn = sendReturn
        self.undo = undo
        self.transforms = transforms
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
                    // The loudest thing the microphone heard. Kept so that an
                    // empty transcript can tell the user which of the two very
                    // different things went wrong.
                    self.sawLevels = true
                    // Told to the tap, not just kept here. It is what lets ⌥⌫ tell
                    // a chord from a dictation: the gesture machine says .holding
                    // 130 ms after the trigger goes down whether the user is
                    // speaking or reaching for Delete, and only the audio knows
                    // which. Above the floor only, so a quiet room does not read
                    // as speech.
                    if level >= DictationCoordinator.silenceFloor { self.hotkey.noteSpeechHeard() }
                    self.peakLevel = max(self.peakLevel, level)
                    // The moment speech actually starts, as distinct from the
                    // moment the microphone opened. Uses the same floor that
                    // decides "that device sent no sound at all", so the two
                    // cannot disagree about what counts as audible.
                    if self.timeline.firstAudibleBuffer == nil,
                       level >= DictationCoordinator.silenceFloor,
                       self.isDictating || self.isSpeculating {
                        self.timeline.firstAudibleBuffer = Date()
                    }
                    guard self.isDictating else { return }
                    self.overlay.show(.listening(level: level))
                }
            }
        }
    }

    /// How long the key can be down and still count as a tap rather than an
    /// utterance.
    ///
    /// 400ms. His shortest real dictation is "On my way." at 855ms, and the
    /// shortest thing anyone can say and mean is a good deal longer than a key
    /// bounce. Set well under the former so nothing he actually said is thrown
    /// away, and well over the latter so a change of mind is caught.
    nonisolated static let tapDuration: TimeInterval = 0.4

    /// Whether this gesture was over before it began.
    private var heldBriefly: Bool {
        guard let down = timeline.hotkeyDown, let up = timeline.hotkeyUp else { return false }
        return up.timeIntervalSince(down) < Self.tapDuration
    }

    /// The whole decision, as a function of three numbers.
    ///
    /// Pulled out of `endDictation` so it can be tested without a clock. The
    /// integration version of this test passed alone and failed in the suite,
    /// because the press and the release are wall-clock timestamps and the gap
    /// between them grows when the machine is busy — the same wall-clock
    /// dependence already documented for one other test here. A flaky test is
    /// worse than no test; a pure one asks the same question and always gets the
    /// same answer.
    ///
    /// - Parameters:
    ///   - heldFor: seconds between key down and key up.
    ///   - sawLevels: whether ANY audio level arrived. A peak of zero with no
    ///     levels means the microphone never delivered a buffer, which is a
    ///     different failure and must still be reported.
    ///   - peak: the loudest level heard.
    nonisolated static func isChangeOfMind(heldFor: TimeInterval, sawLevels: Bool, peak: Float) -> Bool {
        sawLevels && peak < silenceFloor && heldFor < tapDuration
    }

    /// Below this the input is not quiet, it is not connected to anything.
    ///
    /// Ordinary room tone on the built-in microphone sits around 0.01–0.03 even
    /// with nobody speaking; a loopback device with no app playing into it
    /// returns exact zeros. The floor is set under the quietest real room and
    /// well above digital silence, so the specific message only appears when the
    /// device genuinely delivered nothing.
    nonisolated static let silenceFloor: Float = 0.005

    @discardableResult
    public func start() -> Bool { hotkey.start() }

    // MARK: - Lifecycle

    /// Called the instant the key goes down. Everything expensive happens here —
    /// model warm-up and opening the microphone — because by the time the gesture
    /// has been recognised, whatever was said in the meantime is already gone.
    private func speculativelyBegin() {
        guard !isDictating, !isSpeculating else {
            NSLog("[quill] key-down IGNORED: already %@",
                  isDictating ? "dictating" : "speculating")
            return
        }
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
        // Per dictation, not per launch: last time's loud sentence must not vouch
        // for this time's dead microphone.
        peakLevel = 0
        sawLevels = false

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

    /// "Finish, then Enter": release the dictation key, tap it again right
    /// away, and Quill sends Return — but only once cleanup and insertion
    /// have actually finished, never the instant the tap happens. A tap this
    /// soon after releasing the key already lands here as an aborted
    /// gesture — too short to become a new dictation on its own — which is
    /// what makes it safe to read as "send it" without watching a second
    /// key: nothing else in normal use means anything by a tap this quick,
    /// right after one just ended.
    private func maybeArmFinishThenEnter() {
        guard settings.finishThenEnterEnabled else { return }
        let recentlyLanded = lastInsertionAt.map {
            Date().timeIntervalSince($0) < Self.finishThenEnterWindow
        } ?? false
        guard isFinalising || recentlyLanded else { return }
        pendingReturnAfterInsertion = true
        if !isFinalising {
            // The text already landed before this tap arrived — nothing left
            // to wait for.
            fireDeferredReturnIfPending()
        }
    }

    private func fireDeferredReturnIfPending() {
        guard pendingReturnAfterInsertion else { return }
        pendingReturnAfterInsertion = false
        sendReturn()
    }

    /// For the tests below: whether a tap right now would be armed, without
    /// actually sending anything.
    var pendingReturnAfterInsertionForTesting: Bool { pendingReturnAfterInsertion }

    /// The gesture is confirmed as dictation. Audio has been recording since
    /// key-down, so there is nothing to start here — only something to show.
    private func beginDictation() {
        guard !isDictating else { return }

        if !isSpeculating {
            // Defensive: a confirmation with no speculation behind it. Start now
            // and accept the lost milliseconds rather than record nothing at all.
            //
            // BEFORE `isDictating = true`, which is the whole of it. This ran
            // after, and `speculativelyBegin()`'s first guard is `!isDictating` —
            // so the recovery this comment describes could never once have run.
            // It logged "key-down IGNORED: already dictating" and returned.
            //
            // The path is real: the speculation's `transcriber.start()` throws
            // (the chosen microphone was unplugged, AirPods changed profile,
            // another app holds the device), `fail()` clears `isSpeculating`, and
            // 120 ms later the arm timer confirms the gesture. Roman then speaks a
            // paragraph into a coordinator that believes it is dictating and has
            // no capture session at all. On release: "Transcribing", then an empty
            // transcript, then "MacBook Air Microphone sent no sound at all. Pick
            // a different microphone in Settings" — about a microphone that was
            // fine. No insertion, no clipboard, no history row. The paragraph is
            // simply gone.
            speculativelyBegin()
        }
        isDictating = true
        inputLost = false
        isSpeculating = false
        // Here and nowhere else on the way in: this is the moment a gesture stops
        // being speculative and becomes something that will write to the caret.
        insertionEpoch += 1
        // Decided here, once, rather than per partial: the focused app is
        // whatever the user was in when they pressed the key, and it is the only
        // window it is ever safe to type into during this dictation.
        capturedContext = context()
        // The undo record is NOT thrown away here.
        //
        // It used to be, on the reasoning that live typing is about to write into
        // the same field — true, but not yet true at this instant, and this
        // instant is 120 ms after the trigger went down. The shipped trigger is
        // right Option, so ⌥⌫ *is* a trigger press followed by a ⌫, and any hand
        // slower than the arm delay arrived here to find the record already gone.
        // The feature the record exists for was killed by its own gesture.
        //
        // It is discarded the moment text actually lands instead — the first
        // live-typed character below, and the insert path, which either replaces
        // the record with the new sentence or discards it. Every real keystroke,
        // click, app switch and blind spell still throws it away, so the argument
        // for overriding a standard binding is unchanged: what is gone is only the
        // window where a dictation had started and written nothing.
        // Not while the previous dictation is still landing its text. This one
        // pastes on release instead, which arrives whole rather than interleaved.
        let live = liveTyper.begin()
        liveGeneration = live.generation
        isLive = settings.liveText && live.ok && !isFinalising
        overlay.show(.listening(level: 0))
    }

    /// Which CONFIRMED dictation owns the caret, as distinct from which capture
    /// session is installed.
    ///
    /// `sessionID` moves on every speculative key-down, because that is what the
    /// transcriber's start/stop tasks have to be fenced against. Fencing the
    /// INSERTION on it too meant that any abandoned gesture — a stray isolated
    /// tap, a chord that arms and aborts — superseded a dictation that was still
    /// finalising and pushed its sentence to the clipboard instead of into the
    /// document.
    ///
    /// The shape that made this routine: hands-free is taught as a double-tap and
    /// nothing anywhere says stopping is a single tap, so people double-tap to
    /// stop. Tap one stops it and starts the finalise, which is hundreds of
    /// milliseconds of drain and barrier. Tap two, 150 ms later, lands in `.idle`
    /// and opens a speculation — enough to invalidate the sentence the user was
    /// in the middle of dictating. They get "You started again before that
    /// finished — it is on your clipboard", for a gesture they made to STOP.
    ///
    /// A gesture that was abandoned has by definition inserted nothing, so it has
    /// no business invalidating the previous sentence. A confirmed hold or a new
    /// hands-free still supersedes, which is the case the rescue branch is
    /// actually defending against.
    private var insertionEpoch = 0

    /// The microphone disappeared during this dictation.
    ///
    /// Changes two decisions and nothing else: the change-of-mind shortcut must
    /// not bin the recording (this was not a change of mind), and the user has to
    /// be told the sentence is short because the device went away rather than
    /// because that is all they said.
    private var inputLost = false

    private func endDictation() {
        guard isDictating else { return }
        isDictating = false
        isSpeculating = false
        // Stamped first, before anything else in this method can cost time. This
        // is the moment the user stopped talking, and everything after it is
        // latency they sit through.
        timeline.hotkeyUp = Date()
        let epoch = insertionEpoch

        // A tap, not a dictation.
        //
        // Roman: "when I hold the right option key and then just sort of press it
        // and change my mind, the transcribing thing sits there for a couple
        // seconds and it's kind of annoying."
        //
        // He is right and it was worse than he thought: the key came up, the
        // recogniser had nothing, so stop() waited out its 2.5s short-utterance
        // grace, then the drain, then the empty-transcript path put "Nothing was
        // heard" on screen for another 1.6s. Four seconds of HUD for a gesture
        // that carried no sound.
        //
        // Both halves of the test matter. Short alone would bin a fast "Yes." —
        // measured at 855ms in his own corpus. Silent alone would show the error
        // for a long hold at a dead microphone, which is exactly when he needs to
        // be told. Only short AND silent is a change of mind, and the right answer
        // to a change of mind is to leave no trace.
        //
        // Not when the microphone was pulled out from under it, though. A short,
        // silent recording is a change of mind when the user made it one and a
        // truncation when the device decided — and binning a truncation without a
        // word is the same silent loss from the other end.
        let held = timeline.hotkeyDown.map { timeline.hotkeyUp?.timeIntervalSince($0) ?? 0 } ?? 0
        if !inputLost, Self.isChangeOfMind(heldFor: held, sawLevels: sawLevels, peak: peakLevel) {
            isSpeculating = false
            sessionID += 1
            if isLive { liveTyper.retract(generation: liveGeneration) }
            isLive = false
            overlay.hide()
            NotificationCenter.default.post(name: .quillDictationSettled, object: nil)
            Task { [transcriber] in await transcriber.cancel() }
            return
        }

        overlay.show(.transcribing)

        isFinalising = true
        Task { [transcriber, cleaner, inserter, overlay, history, snippets] in
            // Cleared on every exit from this Task, including the two early
            // returns below. A flag that leaks true would silently disable live
            // typing for the rest of the session.
            //
            // The deferred Return is checked here too, not only inside the
            // `.inserted` case below — a tap that lands between insertion
            // actually happening and this Task actually exiting arms
            // `pendingReturnAfterInsertion` with `isFinalising` still true
            // (see `maybeArmFinishThenEnter()`), and the `.inserted` case
            // that would otherwise fire it has already run and will not run
            // again. Without this, that tap is armed forever and nothing
            // ever sends it.
            defer {
                self.isFinalising = false
                self.fireDeferredReturnIfPending()
                NotificationCenter.default.post(name: .quillDictationSettled, object: nil)
            }
            let raw = await transcriber.stop()
            guard epoch == self.insertionEpoch else {
                // A newer DICTATION was confirmed while this one was finalising.
                //
                // Not inserting is right: pasting a sentence from thirty seconds
                // ago into whatever the user is typing in NOW is the failure this
                // fence exists to prevent. Throwing the sentence away is not — it
                // was said, it was transcribed, and it used to vanish with no
                // insertion, no clipboard and no history row, surviving only in a
                // log line nobody reads.
                //
                // The window is not narrow either. When nothing has been
                // recognised yet, stop() holds the microphone for the short-
                // utterance grace, then waits on the drain, then on a bounded
                // cancel — several seconds during which any press of the trigger
                // supersedes this session.
                //
                // So it goes to history and to the clipboard, and the user is
                // told where to find it. Losing words is the one thing this app
                // may never do.
                let rescued = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rescued.isEmpty {
                    let cleaned = cleaner.cleanFast(rescued)
                    history.append(DictationRecord(
                        id: UUID(), date: Date(), rawText: rescued, insertedText: "",
                        wordCount: cleaned.split(whereSeparator: \.isWhitespace).count,
                        inputDevice: self.capturedInputDevice,
                        timings: .init(timeToFirstWordMs: self.timeline.timeToFirstWordMs,
                                       finalToInsertedMs: nil,
                                       endToEndMs: self.timeline.endToEndMs,
                                       audioDurationMs: self.timeline.audioDurationMs,
                                       usedThoroughCleanup: false,
                                       releaseToInsertedMs: nil)))
                    // Only when there is something to put there. Cleanup can
                    // reduce an utterance to nothing — a dictation that was
                    // entirely filler — and the old code cleared the clipboard,
                    // wrote "", and told the user their words were on it. They
                    // lost whatever they had copied AND got nothing back.
                    if !cleaned.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cleaned, forType: .string)
                        overlay.show(.error("You started again before that finished — it is on your clipboard."))
                        try? await Task.sleep(for: .milliseconds(1_800))
                    }
                }
                // Repaint regardless. An aborted speculation leaves nothing else
                // to clear the HUD, and it would sit on "Transcribing" forever.
                if !self.isDictating { overlay.hide() }
                return
            }

            self.timeline.finalTranscript = Date()

            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Nothing was said, but something may already be on screen: a
                // volatile hypothesis the recogniser later withdrew. Take it back,
                // or the user is left with words they never spoke.
                if self.isLive { self.liveTyper.retract(generation: self.liveGeneration) }
                self.isLive = false

                // Say so. This used to hide the overlay and return, which means
                // the user held a key, spoke a sentence, let go, and watched
                // absolutely nothing happen — indistinguishable from the app
                // being broken, from the key not registering, and from the
                // microphone being dead.
                //
                // It is not a rare path either: driving the recogniser at the
                // edge of its endpointing produced an empty transcript in a
                // quarter of attempts. Whatever the cause on any given day, the
                // one thing that must never happen is silence.
                NSLog("[quill] empty transcript after %@ (peak level %.3f)",
                      self.timeline.releaseToInsertedMs.map { "\($0)ms" } ?? "an unknown wait",
                      self.peakLevel)
                // Two very different failures wear the same face here, and only
                // one of them is the user's to fix. If the microphone delivered
                // buffers that never rose off the floor, the recogniser did not
                // mishear anything — nothing reached it. That is what a loopback
                // device selected as the system input looks like from in here,
                // and it is not hypothetical: an eval run left this Mac's input
                // on BlackHole 2ch, and every dictation after it recorded silence
                // while the app said "nothing was heard, try again".
                //
                // Telling someone to try again, when trying again cannot work, is
                // worse than saying nothing.
                let device = self.capturedInputDevice ?? "Your microphone"
                if self.inputLost {
                    // Not the user's microphone choice and not a mishearing: the
                    // device went away mid-sentence. Telling them to pick a
                    // different one would send them to fix something that is not
                    // broken.
                    overlay.show(.error("\(device) disconnected — nothing was captured."))
                } else {
                    overlay.show(.error(self.peakLevel < DictationCoordinator.silenceFloor
                        ? "\(device) sent no sound at all. Pick a different microphone in Settings."
                        : "Nothing was heard — try again, or check the microphone in Settings."))
                }
                try? await Task.sleep(for: .milliseconds(1_600))
                overlay.hide()
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
            // What live typing has actually put on screen so far, captured while
            // it is still ours. After the await below, a newer dictation's
            // `begin()` may have reset `typed` to "" — so this is the only moment
            // a superseded session can still find out what it left behind.
            let liveOnScreen = self.isLive ? self.liveTyper.typed : ""

            // One budget, not two.
            //
            // It used to be 250ms unless `SelfCorrection.needsModelPass(fast)`
            // said otherwise — but self-correction is not the only pass behind
            // this deadline. Context recovery and homophone repair are gated
            // inside the cleaner on their own conditions, and on those dictations
            // the request went out, was waited on, and was thrown away unread at
            // 250ms: the table above says only 11% of calls land inside it. Paying
            // the latency and discarding the answer is the worst of both.
            //
            // Making the coordinator re-derive the gates is the wrong direction —
            // it would need to know about contextRecovery, homophones, and whether
            // the offline resolver already absorbed the retraction, and that copy
            // would drift from the cleaner within a release. The deadline is an
            // upper bound, and `cleanThorough` already returns in microseconds
            // when no gate fires, so a smaller bound buys nothing on the fast
            // path. It is the cleaner's job to not make a call it does not need,
            // which NIMCleaner does — noted because `TranscriptCleaning` does not
            // enforce it.
            let budget = AIConfig.recommendedCleanupDeadline

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

            // Last, because it is the only step that knows where the text is
            // going. A shell command does not want the full stop the cleanup just
            // added, and deleting it by hand every time is the kind of small tax
            // that quietly ends the habit of dictating at all.
            final = AppContextFormatter.apply(final, context: self.capturedContext,
                                              numbers: self.settings.numberStyle)

            // The fence, re-checked. The cleanup await above suspends for the
            // whole budget in the overwhelming majority of cases, and the main
            // actor is free throughout it — so by here the user may well have
            // pressed the key again, armed a new dictation and started typing
            // into it. Everything below writes into the CURRENT dictation's
            // world: the insertion, `isLive`, the timeline, the undo record and
            // the history row. None of it may be written by a session that has
            // been superseded.
            guard epoch == self.insertionEpoch else {
                // The sentence is not thrown away — losing words is the one thing
                // this app may never do — but it is NOT re-inserted either, and
                // this is where that differs from the earlier rescue above.
                //
                // There, nothing had been typed. Here live typing may already have
                // put a prefix into the document, and the record of how long it
                // was has been destroyed by the newer dictation's `begin()`. So
                // retracting is impossible (backspaces would eat the new
                // session's characters) and offering a clipboard copy would invite
                // the user to paste a third copy of a sentence that is already
                // half on screen.
                //
                // History gets the truth: what was said, and what actually landed.
                let rescued = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rescued.isEmpty {
                    history.append(DictationRecord(
                        id: UUID(), date: Date(), rawText: rescued, insertedText: liveOnScreen,
                        wordCount: final.split(whereSeparator: \.isWhitespace).count,
                        inputDevice: self.capturedInputDevice,
                        timings: .init(timeToFirstWordMs: self.timeline.timeToFirstWordMs,
                                       finalToInsertedMs: nil,
                                       endToEndMs: self.timeline.endToEndMs,
                                       audioDurationMs: self.timeline.audioDurationMs,
                                       usedThoroughCleanup: usedThorough,
                                       releaseToInsertedMs: nil)))
                    if liveOnScreen.isEmpty {
                        // Nothing reached the document, so the clipboard is a
                        // genuine offer rather than a duplicate.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(final, forType: .string)
                        overlay.show(.error("You started again before that finished — it is on your clipboard."))
                        try? await Task.sleep(for: .milliseconds(1_800))
                    }
                }
                return
            }

            // Is this something to type, or something to DO?
            //
            // Asked here, after cleanup and before insertion, because the router
            // reads a finished sentence and the transform has to happen instead of
            // the insertion rather than after it.
            //
            // `CommandRouter` is the most conservative file in the app on purpose:
            // treating a command as content types five words the user deletes,
            // while treating content as a command deletes what they said. It fires
            // only when the ENTIRE utterance is an instruction.
            if let transforms = self.transforms, self.transformGestureActive {
                let routing = transforms.router.route(final, transforms: TransformStore.shared.ordered)
                if case .content = routing.decision {} else {
                    // Take the command itself back off the screen first. Live
                    // typing has been writing "make that shorter" since the first
                    // partial, and it must not be left behind next to the result.
                    if self.isLive { self.liveTyper.retract(generation: self.liveGeneration) }
                    self.isLive = false
                    self.undo?.discard()

                    overlay.show(.transcribing)
                    let outcome = await transforms.engine.run(routing)
                    switch outcome {
                    case .done(let success):
                        overlay.show(.inserted(words: success.text.split(whereSeparator: \.isWhitespace).count))
                    case .failed(let reason):
                        // The words are never thrown away: `TransformEngine` does
                        // not touch the target until it has a result, so a refusal
                        // leaves the document as it was — but the user asked for
                        // something and has to be told it did not happen.
                        overlay.show(.error(reason))
                    }
                    self.timeline.textInserted = Date()
                    return
                }
            }

            // Two ways in, and the difference is whether the text is already
            // there. Live typing has been writing this sentence since the first
            // partial, so finishing it means reconciling the last edit — usually
            // nothing, sometimes the sentence the model rewrote. Pasting the whole
            // thing here instead would insert it twice.
            let result: InsertionResult
            if self.isLive, !self.liveTyper.isAbandoned {
                let live = self.liveTyper.finish(final, generation: self.liveGeneration)
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
                // Recorded here and only here: this is the one branch where text
                // is believed to be on screen, and the undo chord may not fire
                // against a sentence that never landed.
                self.undo?.record(final)
                // So "make that shorter" has something to act on.
                self.lastInsertion = .init(text: final, insertedAt: Date())
                // The text is on screen now — the moment "finish, then
                // Enter" exists to wait for. Fires the deferred Return if a
                // tap already asked for one; otherwise just records when.
                self.lastInsertionAt = Date()
                self.fireDeferredReturnIfPending()
                // Split on whitespace, not on the space character: a transform
                // that returns a bullet list is one word by the old count.
                if self.inputLost {
                    // Say it plainly. The text is real and it is inserted, but it
                    // is only as much of the sentence as reached the app before
                    // the device disappeared — and a half-thought that reads as a
                    // whole one is the failure mode this message exists to break.
                    overlay.show(.error("\(self.capturedInputDevice ?? "The microphone") disconnected — kept what was heard."))
                } else {
                    overlay.show(.inserted(words: final.split(whereSeparator: \.isWhitespace).count))
                }
            case .fellBackToClipboard(let reason):
                self.undo?.discard()
                overlay.show(.error("Copied to clipboard — \(reason)"))
            case .failed(let reason):
                self.undo?.discard()
                overlay.show(.error(reason))
            }

            history.append(DictationRecord(
                id: UUID(),
                date: Date(),
                rawText: raw,
                insertedText: final,
                wordCount: final.split(whereSeparator: \.isWhitespace).count,
                inputDevice: self.capturedInputDevice,
                timings: .init(
                    timeToFirstWordMs: self.timeline.timeToFirstWordMs,
                    finalToInsertedMs: self.timeline.finalToInsertedMs,
                    endToEndMs: self.timeline.endToEndMs,
                    audioDurationMs: self.timeline.audioDurationMs,
                    usedThoroughCleanup: usedThorough,
                    releaseToInsertedMs: self.timeline.releaseToInsertedMs,
                    micOpenMs: self.timeline.micOpenMs,
                    speechOnsetMs: self.timeline.speechOnsetMs,
                    recogniserFirstWordMs: self.timeline.recogniserFirstWordMs
                )
            ))

            NSLog("[quill] %@", self.timeline.logLine)

            try? await Task.sleep(for: .milliseconds(900))
            overlay.hide()
        }
    }

    private func cancelDictation(userTyped: String = "") {
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
        // The cancelling keystroke, if it reached the app, is sitting at the end
        // of the text we are about to take back. Deleting our own character count
        // would eat it and leave one of ours in its place.
        if isLive { liveTyper.retract(restoring: userTyped, generation: liveGeneration) }
        isLive = false
        NotificationCenter.default.post(name: .quillDictationSettled, object: nil)
        Task { [transcriber, overlay] in
            await transcriber.cancel()
            overlay.hide()
        }
    }

    private func fail(_ message: String) {
        // Only for a dictation that never began.
        //
        // Failures reach here from two very different places. One is start()
        // throwing, where there is no audio, no transcript and no history row,
        // and the user is owed the error. The other is the analyzer being rebuilt
        // in the background — rewarm() runs at the end of every dictation and
        // after every cancel — and those failures arrive with no session attached
        // and are delivered unconditionally.
        //
        // The second kind used to run this whole method. So a rewarm that failed
        // while the NEXT dictation was already live and typing would call
        // liveTyper.retract() and delete every word the user was watching appear
        // in their own document, then set isDictating false so the key release
        // did nothing. A background maintenance task, silently eating a sentence.
        //
        // If audio has been captured or words are on screen, this dictation began
        // — whatever just failed did not stop it, and this method has no business
        // tearing it down.
        let began = timeline.audioFirstBuffer != nil || liveTyper.hasTypedAnything
        if began, isDictating {
            NSLog("[quill] ignoring a failure that arrived mid-dictation: %@", message)
            return
        }
        NSLog("[quill] dictation FAILED to start: %@", message)
        isDictating = false
        isSpeculating = false
        if isLive { liveTyper.retract(generation: liveGeneration) }
        isLive = false
        NotificationCenter.default.post(name: .quillDictationSettled, object: nil)
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
    /// Whether a dictation starting right now would live-type.
    ///
    /// Exposed because the rule is a decision, not an implementation detail: a
    /// dictation begun while the previous one is still landing its text must
    /// paste on release instead, so the two sentences cannot interleave in the
    /// same field. Asserting it through the real coordinator would need a
    /// microphone, an analyzer and a focused text field.
    @MainActor
    public static func wouldLiveType(liveTextEnabled: Bool,
                                     typerAvailable: Bool,
                                     previousStillFinalising: Bool) -> Bool {
        liveTextEnabled && typerAvailable && !previousStillFinalising
    }

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
    public func hotkeyAborted() {
        maybeArmFinishThenEnter()
        abandonSpeculation()
    }
    public func hotkeyPressed() { beginDictation() }
    public func hotkeyReleased() { endDictation() }
    /// Arms or disarms the transform gate for the gesture about to start.
    ///
    /// Plain-Option dictation used to run `CommandRouter` on every finished
    /// utterance, which meant saying a transform's trigger phrase as an
    /// ordinary sentence — "make that a bullet list" as a real bullet list you
    /// were dictating about, not an instruction — silently ran the transform
    /// instead of typing your words. Roman: too easy to trigger by accident.
    /// Now only a gesture that also held ⌘ reaches the router at all; plain
    /// dictation always lands as content, no matter what it says.
    public func hotkeyTriggerIncludesCommand(_ includesCommand: Bool) {
        transformGestureActive = includesCommand
    }

    /// A transform's chord. The tap has already swallowed the key.
    public func hotkeyTransform(_ transform: Transform) {
        guard let transforms else { return }
        // Not on top of a dictation. The voice route runs a transform *instead*
        // of an insertion, at a point where the coordinator owns the caret; a
        // chord arriving while a sentence is being typed or finalised would be a
        // second writer to the same one.
        guard !isDictating, !isSpeculating, !isFinalising else { return }

        overlay.show(.transcribing)
        Task { [transforms, overlay] in
            switch await transforms.engine.run(transform) {
            case .done(let success):
                overlay.show(.inserted(words: success.text.split(whereSeparator: \.isWhitespace).count))
            case .failed(let reason):
                // The engine does not touch the target until it has a result, so
                // a refusal leaves the document exactly as it was — but the user
                // pressed a key and has to be told nothing came of it.
                overlay.show(.error(reason))
            }
        }
    }
    public func hotkeyCancelled(userKeystroke: String) {
        cancelDictation(userTyped: userKeystroke)
    }
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
        // Formatted for the destination here too, not only at the end. The live
        // stream and the final text have to agree, or the last edit becomes a
        // visible flicker as a capital letter or a full stop is taken back.
        // Same formatting as the closing edit, number style included: the live
        // stream and the final text have to agree, or the last edit becomes a
        // visible flicker as "four" is taken back and retyped.
        liveTyper.update(to: AppContextFormatter.apply(cleaner.cleanFast(transcript.text),
                                                       context: capturedContext,
                                                       numbers: settings.numberStyle),
                         generation: liveGeneration)
        // Here rather than at beginDictation(): this is the first moment anything
        // is actually at the caret, and until it happens the previous insertion is
        // still the last thing there and still safe to take back. See the note in
        // beginDictation().
        if liveTyper.hasTypedAnything { undo?.discard() }
    }

    public func transcriber(didFail error: Error) {
        fail(error.localizedDescription)
    }

    /// The device went away mid-sentence. End the dictation now rather than wait
    /// for a key release that will arrive against a dead microphone.
    ///
    /// Deliberately not `fail()`: fail tears the session down and shows an error,
    /// which would throw away words the user actually said. Everything heard up
    /// to the disconnect is a real transcript and goes in exactly as it would
    /// have — the only thing that changes is that the user is told why it stops
    /// where it does.
    public func transcriberDidLoseInput() {
        guard isDictating else {
            // Still speculating: nothing has been shown and nothing was said, so
            // there is nothing to tell anyone about. Bin it quietly.
            abandonSpeculation()
            return
        }
        inputLost = true
        endDictation()
    }
}

public extension Notification.Name {
    /// Posted with the new `Bool` as `object` whenever a dictation starts or
    /// ends, from any trigger — held key, transform command, or the
    /// persistent overlay button.
    static let quillDictationStateChanged = Notification.Name("com.romangigliotti.quill.dictationStateChanged")
    /// Posted once a dictation cycle is truly over — nothing more will be
    /// typed, whether it ended by landing, by being cancelled, or by failing
    /// to start. Distinct from `quillDictationStateChanged`: that flips the
    /// instant the key comes up, well before an insertion that is still being
    /// cleaned up and typed has actually finished landing. Something that
    /// needs to know when the words are truly done arriving — the quick-note
    /// capture bubble reading back what it just caught — needs this one.
    static let quillDictationSettled = Notification.Name("com.romangigliotti.quill.dictationSettled")
}
