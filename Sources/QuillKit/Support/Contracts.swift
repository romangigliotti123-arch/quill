import Foundation

// The seams of the app. Every subsystem is written against these and nothing
// else, so any one of them can be swapped or faked in tests without the others
// noticing. Deliberately small — a seam that needs a paragraph to explain is a
// seam in the wrong place.

// MARK: - Hotkey

/// What the hotkey engine reports. Push-to-talk is a *hold*, so down and up are
/// separate events rather than one toggle.
///
/// @MainActor is enforced rather than merely requested: the tap callback runs on
/// its own runloop, and an engine that forwards straight from there would race
/// the coordinator's state. Making it a compile error is cheaper than finding it
/// as an intermittent bug later.
@MainActor
public protocol HotkeyEngineDelegate: AnyObject {
    /// The trigger went down, but it is not yet known whether this is dictation.
    /// Start capturing audio now and discard it later if this turns out to be a
    /// chord or a stray tap — the alternative is losing whatever was said during
    /// the arm delay and the audio engine's spin-up.
    func hotkeyMayBegin()
    /// The gesture resolved to something other than dictation. Throw the
    /// speculative capture away.
    func hotkeyAborted()
    func hotkeyPressed()
    func hotkeyReleased()
    /// The trigger went down together with ⌘, or without it — the gesture that
    /// gates voice-triggered transforms during dictation. Delivered right
    /// before `hotkeyMayBegin()`, so the coordinator knows before the gesture
    /// has even resolved to a real dictation.
    func hotkeyTriggerIncludesCommand(_ includesCommand: Bool)
    /// A transform's chord was pressed. The event has already been swallowed, so
    /// the key never reaches the user's document — run the transform on whatever
    /// is selected there.
    func hotkeyTransform(_ transform: Transform)
    /// Escape, or any keystroke that means "throw this dictation away".
    ///
    /// `userKeystroke` is the text the cancelling key actually inserted into the
    /// focused app — empty when it was swallowed, and empty for a key that
    /// produces no character at all (an arrow, a function key).
    ///
    /// It has to be the text and not a boolean. Backspaces delete from the caret
    /// backwards and that character is the LAST thing on screen, so there is no
    /// number of backspaces that removes what Quill typed and spares it: deleting
    /// one fewer takes the user's character first and leaves one of Quill's in
    /// its place. The only correct move is to take everything back and put their
    /// character in again, which needs the character.
    func hotkeyCancelled(userKeystroke: String)
    /// The tap died or could not be created. Carries something a human can act on.
    func hotkeyEngineUnavailable(reason: String)
}

public extension HotkeyEngine {
    /// Default for the fakes. Only the tap has a chord to decide.
    func noteSpeechHeard() {}
}

public extension HotkeyEngineDelegate {
    /// Default for the delegates that are not the running app. Only the
    /// coordinator has a document to reshape.
    func hotkeyTransform(_ transform: Transform) {}
    /// Default: no transform gate to arm.
    func hotkeyTriggerIncludesCommand(_ includesCommand: Bool) {}
}

public protocol HotkeyEngine: AnyObject {
    var delegate: HotkeyEngineDelegate? { get set }
    /// The microphone has heard something above the noise floor during the
    /// gesture currently in flight.
    ///
    /// This is what tells a chord from a dictation. The gesture machine cannot
    /// answer it — 130 ms after the trigger goes down it reports `.holding`
    /// whether the user is speaking or reaching for another key — and a clock
    /// cannot answer it either: measured on this Mac, a two-key reach from right
    /// Option to Delete takes over a second, which is well inside the time a
    /// short dictation takes. Only the audio knows.
    func noteSpeechHeard()
    /// Returns false if the tap could not be installed; the delegate gets the reason.
    @discardableResult func start() -> Bool
    func stop()
}

// MARK: - Transcription

public struct Transcript: Sendable, Equatable {
    /// Best text so far. For a volatile result this changes on the next update.
    public let text: String
    /// True once this span is settled and will not be revised.
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Same reasoning as HotkeyEngineDelegate: Speech delivers on its own queue, and
/// forwarding from there would race the coordinator.
@MainActor
public protocol TranscriberDelegate: AnyObject {
    /// Called for every partial and final.
    func transcriber(didProduce transcript: Transcript)
    func transcriber(didFail error: Error)
    /// The microphone went away part-way through, so there is no more audio
    /// coming. Distinct from `didFail` because there IS a transcript: whatever
    /// was heard before the device disappeared is real and must not be thrown
    /// away — it only has to stop being presented as the whole sentence.
    func transcriberDidLoseInput()
}

public extension TranscriberDelegate {
    /// Default for the delegates that are not a running app — the probe, the
    /// harness collector, the fakes. They have no dictation to end.
    func transcriberDidLoseInput() {}
}

public protocol Transcriber: AnyObject {
    var delegate: TranscriberDelegate? { get set }
    /// Live input level, 0...1, for the overlay's waveform. In the protocol
    /// rather than on the concrete type because a HUD animating to nothing is
    /// the difference between an instrument and a decoration.
    var onLevel: ((Float) -> Void)? { get set }
    /// Warm the model. Called on hotkey-down, before audio, so the first word
    /// is not paying for model load.
    func prepare() async
    func start() async throws
    /// Returns the settled full text for the session.
    func stop() async -> String
    func cancel() async
}

// MARK: - Insertion

public enum InsertionResult: Sendable, Equatable {
    case inserted
    /// Could not type into the focused app; text was put on the clipboard so
    /// the user does not lose it. Never fail silently.
    case fellBackToClipboard(reason: String)
    case failed(reason: String)
}

public protocol TextInserting: AnyObject {
    func insert(_ text: String) -> InsertionResult
}

// MARK: - Overlay

public enum OverlayState: Sendable, Equatable {
    case hidden
    case listening(level: Float)
    case transcribing
    case inserted(words: Int)
    case error(String)
}

public protocol OverlayPresenting: AnyObject {
    func show(_ state: OverlayState)
    func hide()
}

// MARK: - Instrumentation

/// murmur shipped three build passes with no latency number anywhere. This is
/// the fix: every dictation stamps the same five moments, so "is it fast
/// enough" is answerable from a log instead of a guess.
public struct DictationTimeline: Sendable {
    public var hotkeyDown: Date?
    public var audioFirstBuffer: Date?
    /// The first buffer with speech in it, rather than the first buffer.
    ///
    /// Without this, "time to first word" is one number covering three very
    /// different things: opening the microphone (ours), the pause before the
    /// person actually starts talking (theirs, and not a defect), and the
    /// recogniser deciding it has heard enough to guess (the model's). Measured
    /// on Roman's real dictations that number is 1216ms, and optimising it blind
    /// would mean trying to make him breathe faster.
    public var firstAudibleBuffer: Date?
    public var firstPartial: Date?
    /// The moment the key came back up — i.e. the moment the user stopped
    /// speaking and started waiting. Everything after this is latency they feel.
    public var hotkeyUp: Date?
    public var finalTranscript: Date?
    public var textInserted: Date?

    public init() {}

    private func ms(_ a: Date?, _ b: Date?) -> Int? {
        guard let a, let b else { return nil }
        // Rounded, not truncated. `Date` is a Double of seconds since 2001, so
        // at present-day magnitudes a difference of exactly 0.4s comes back as
        // 0.39999999990686774 and `Int()` floors it to 399. Every duration in
        // this app was quietly reported up to a millisecond short.
        return Int((b.timeIntervalSince(a) * 1000).rounded())
    }

    public var timeToFirstWordMs: Int? { ms(hotkeyDown, firstPartial) }
    public var finalToInsertedMs: Int? { ms(finalTranscript, textInserted) }

    /// **The number that decides the latency piece**, and the one Wispr Flow is
    /// measured on: let go of the key, how long until the text is there. 807ms
    /// for Flow.
    ///
    /// This is deliberately not `endToEndMs`. That one starts at key-*down*, so
    /// it includes however long the person spoke — a forty-second dictation
    /// scores forty seconds, and the median across a corpus of five-second clips
    /// reads as twelve. It is a fine diagnostic and a meaningless headline, and
    /// it was being shown on the Insights card under the label "key release to
    /// text on screen", which is this number and not that one.
    public var releaseToInsertedMs: Int? { ms(hotkeyUp, textInserted) }

    /// How long speech actually ran, for words-per-minute and time-saved.
    public var audioDurationMs: Int? { ms(audioFirstBuffer, finalTranscript) }

    /// Key-down to the first buffer off the microphone.
    ///
    /// The gap a person would have to wait through before speaking, if they had
    /// to wait at all. Capture is started at key-down precisely so they do not —
    /// but "designed not to" and "measured not to" are different claims, and
    /// only one of them belongs in an answer to "how long should I wait?".
    public var micOpenMs: Int? { ms(hotkeyDown, audioFirstBuffer) }

    /// Microphone open → the user actually starts speaking. Not a defect and not
    /// ours to fix; recorded so it stops being counted as though it were.
    public var speechOnsetMs: Int? { ms(audioFirstBuffer, firstAudibleBuffer) }

    /// Speech starts → the recogniser's first guess. THIS is the model latency,
    /// and the only part of "time to first word" that is worth tuning.
    public var recogniserFirstWordMs: Int? { ms(firstAudibleBuffer, firstPartial) }

    public var logLine: String {
        let f = { (v: Int?) in v.map(String.init) ?? "—" }
        return "micOpen=\(f(micOpenMs))ms onset=\(f(speechOnsetMs))ms "
            + "recog=\(f(recogniserFirstWordMs))ms ttfw=\(f(timeToFirstWordMs))ms "
            + "release→insert=\(f(releaseToInsertedMs))ms "
            + "final→insert=\(f(finalToInsertedMs))ms e2e=\(f(endToEndMs))ms"
    }

    /// Key-down to text. Kept because it is the honest measure of a whole
    /// interaction, and because every record written before this file grew a
    /// release stamp has only this.
    public var endToEndMs: Int? { ms(hotkeyDown, textInserted) }
}
