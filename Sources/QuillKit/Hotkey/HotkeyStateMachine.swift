import Foundation

/// The whole gesture grammar of the dictation key, with no event tap anywhere in
/// sight.
///
/// Everything time-dependent arrives either as the `now` parameter or as an
/// explicit `.armTimerFired` input, so tap-vs-hold-vs-double-tap can be driven
/// from a test in microseconds. The alternative — the way this was written the
/// first time — is a state machine welded to a CGEventTap, which can only be
/// checked by a human pressing a key and believing what they see.
public struct HotkeyStateMachine: Equatable, Sendable {

    public struct Timing: Equatable, Sendable {
        /// How long the trigger must stay down before a hold counts as a hold.
        ///
        /// This is a real, perceptible floor on start-of-recording latency: every
        /// push-to-talk dictation starts 120 ms after the user's finger lands, and
        /// no amount of model pre-warming wins that back. What it buys is the
        /// ability to tell a tap from a hold at all, which is the only reason
        /// double-tap hands-free can coexist with push-to-talk on one key. Lower
        /// it and taps start being heard as holds; raise it and the app feels lazy.
        public var armDelay: TimeInterval
        /// Maximum gap between the two taps of a double-tap. Above a comfortable
        /// double-tap, below the rate at which two *separate* deliberate taps get
        /// glued into one gesture.
        public var doubleTapWindow: TimeInterval

        public init(armDelay: TimeInterval = 0.12, doubleTapWindow: TimeInterval = 0.42) {
            self.armDelay = armDelay
            self.doubleTapWindow = doubleTapWindow
        }

        public static let `default` = Timing()
    }

    /// Physical facts, already stripped of CoreGraphics. `isolated` and `isBare`
    /// are decided by the caller because deciding them needs flag masks; what
    /// happens as a result is decided here because that is the part with rules.
    public enum Input: Equatable, Sendable {
        /// The bound trigger modifier went down. `isolated` is false when any
        /// other modifier is also held — i.e. this is a chord, not a gesture.
        case triggerDown(isolated: Bool)
        case triggerUp
        /// The *push-to-talk* key went down: a key whose single tap starts and
        /// stops hands-free dictation, with nothing to hold. Only ever produced
        /// when it is a different physical key from the hold trigger — when the
        /// two are bound to the same key, hands-free is reached by double-tapping
        /// and this input never arrives.
        case toggleDown(isolated: Bool)
        case toggleUp
        /// Some *other* modifier changed while a gesture was in flight.
        case otherModifierChanged
        /// `isBare` means no ⌘⌥⌃⇧ held; see HotkeyBinding.chordMask for why fn
        /// is excluded from that question.
        case keyDown(keyCode: UInt16, isBare: Bool)
        case armTimerFired(token: Int)
        /// The tap was disabled out from under us, so any key-up we were waiting
        /// on has already been missed.
        case tapInterrupted
    }

    public enum Effect: Equatable, Sendable {
        /// Start capturing audio the instant the key goes down, BEFORE we know
        /// whether this is a hold, a tap or the start of a chord.
        ///
        /// Without this, the microphone does not open until the arm delay has
        /// elapsed and the audio engine has spun up — measured together at a few
        /// hundred milliseconds — and anything said in that window is gone. It is
        /// the difference between "it dropped my first word" and not. The cost is
        /// that a discarded gesture briefly opened the microphone; the recording
        /// is thrown away and never transcribed.
        case beginPreroll
        /// The gesture turned out not to be dictation. Throw the audio away.
        case abortPreroll
        case notifyPressed
        case notifyReleased
        case notifyCancelled
        case startArmTimer(token: Int, delay: TimeInterval)
        case cancelArmTimer
        /// Swallow the event that caused this, so it never reaches the focused
        /// app. Only Escape earns it — swallowing a modifier's flagsChanged would
        /// leave the system believing that modifier is still held.
        case swallowEvent
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Trigger is down but the arm delay has not elapsed; still could be a tap.
        case armed(token: Int)
        /// Push-to-talk: recording, and it ends when the trigger comes back up.
        case holding
        /// Double-tapped: recording, and the trigger is no longer held.
        case handsFree
    }

    public private(set) var state: State = .idle
    public var timing: Timing

    /// Monotonic so a stale arm timer that fires after its gesture was abandoned
    /// can be recognised and dropped, rather than starting a phantom recording.
    private var nextToken = 1
    private var lastTapAt: TimeInterval?
    /// A trigger-down arrived during hands-free with another modifier held, and
    /// we are waiting to find out whether it was a stop or the start of a chord.
    /// See the `.handsFree` trigger-down clause.
    private var pendingStop = false

    public init(timing: Timing = .default) {
        self.timing = timing
    }

    public var isRecording: Bool {
        state == .holding || state == .handsFree
    }

    public mutating func reset() {
        state = .idle
        lastTapAt = nil
        pendingStop = false
    }

    public mutating func handle(_ input: Input, at now: TimeInterval) -> [Effect] {
        switch (state, input) {

        case let (.idle, .triggerDown(isolated)):
            // The Option+Space guard. A trigger pressed as part of a chord is the
            // user typing, and must not so much as arm.
            guard isolated else { return [] }
            let token = nextToken
            nextToken += 1
            state = .armed(token: token)
            return [.beginPreroll, .startArmTimer(token: token, delay: timing.armDelay)]

        case let (.armed(token), .armTimerFired(fired)):
            guard fired == token else { return [] }
            state = .holding
            return [.notifyPressed]

        case (.armed, .triggerUp):
            if let last = lastTapAt, now - last <= timing.doubleTapWindow {
                // Consumed, so a third tap starts a fresh pair instead of
                // immediately toggling again.
                lastTapAt = nil
                state = .handsFree
                return [.cancelArmTimer, .notifyPressed]
            }
            lastTapAt = now
            state = .idle
            return [.cancelArmTimer, .abortPreroll]

        case (.idle, let .toggleDown(isolated)):
            // No arm delay and no preroll window to protect: there is no tap-vs-hold
            // ambiguity on a key that only ever toggles, so recording starts on the
            // press itself. `beginPreroll` still comes first because it is what
            // opens the microphone, and `notifyPressed` is what puts the HUD up.
            guard isolated else { return [] }
            lastTapAt = nil
            state = .handsFree
            return [.beginPreroll, .notifyPressed]

        case (.handsFree, .toggleDown):
            // Either bound key ends hands-free. Isolation is not required to stop:
            // refusing to stop because a stray ⇧ was also down would strand a
            // recording the user has plainly asked to end.
            lastTapAt = nil
            state = .idle
            return [.notifyReleased]

        case (.armed, .keyDown), (.armed, .otherModifierChanged), (.armed, .toggleDown):
            // It was the beginning of a chord. Abandon it, and refuse to let it
            // count as the first half of a double-tap.
            lastTapAt = nil
            state = .idle
            return [.cancelArmTimer, .abortPreroll]

        case (.armed, .tapInterrupted):
            lastTapAt = nil
            state = .idle
            return [.cancelArmTimer, .abortPreroll]

        case (.holding, .triggerUp):
            // A hold is not a tap; it must not seed a double-tap.
            lastTapAt = nil
            state = .idle
            return [.notifyReleased]

        case let (.holding, .keyDown(keyCode, isBare)):
            state = .idle
            if keyCode == HotkeyBinding.escapeKeyCode && isBare {
                return [.notifyCancelled, .swallowEvent]
            }
            // Any other key mid-hold means the user was typing a combination, not
            // dictating. Throw the audio away rather than inserting a surprise.
            return [.notifyCancelled]

        case (.holding, .tapInterrupted):
            // The key-up will never arrive now, so end the dictation rather than
            // stranding it — the user said words and deserves them.
            state = .idle
            return [.notifyReleased]

        case let (.handsFree, .triggerDown(isolated)):
            // One isolated tap ends hands-free. The matching .triggerUp lands in
            // .idle, where it is ignored, so the release cannot re-arm.
            guard isolated else {
                // A stray ⇧ or ⌃ held while the user taps the trigger to stop.
                //
                // Refusing outright — which is what this used to do — strands the
                // recording: the microphone stays open, the HUD stays up, and the
                // deliberate "stop" the user just made does nothing. The toggle
                // path a few lines down states the opposite rule in as many words,
                // and the shipped binding never reaches it, because hold and
                // toggle are the same key and the hold branch claims the event.
                //
                // But stopping here would be worse than stranding. Unlike a
                // dedicated toggle key, the trigger IS a chord modifier, and in
                // ⇧⌥→ or ⌘⌥← the other modifier lands first — so an unguarded stop
                // would fire on the ⌥ of a chord the user is typing, ending the
                // dictation and pasting the transcript over their own selection.
                // Wrong text inserted beats an ignored stop, in the wrong
                // direction.
                //
                // So neither: remember it, and let the next event say which it
                // was. A key-down means it was a chord; a release with nothing in
                // between means it was a tap.
                pendingStop = true
                return []
            }
            lastTapAt = nil
            pendingStop = false
            state = .idle
            return [.notifyReleased]

        case (.handsFree, .triggerUp):
            // Only meaningful after a non-isolated trigger-down, above. The
            // release with no keystroke in between is what proves it was a
            // deliberate tap rather than the opening of a chord.
            guard pendingStop else { return [] }
            pendingStop = false
            lastTapAt = nil
            state = .idle
            return [.notifyReleased]

        case let (.handsFree, .keyDown(keyCode, isBare)):
            // The chord resolved: this was ⇧⌥→ and not a stop. Hands-free
            // tolerates typing, so the dictation carries on.
            pendingStop = false
            // Unlike a hold, hands-free tolerates typing — the user is expected to
            // keep working. Only Escape means "bin it".
            guard keyCode == HotkeyBinding.escapeKeyCode, isBare else { return [] }
            state = .idle
            return [.notifyCancelled, .swallowEvent]

        default:
            // Includes: modifiers changing mid-recording (a stray ⇧ must not kill a
            // dictation in progress), auto-repeat, timers whose gesture is gone,
            // every `.toggleUp` (the push-to-talk key is a tap, so its release
            // means nothing), and the push key pressed during a hold — the hold is
            // the gesture in progress and it decides when it ends.
            return []
        }
    }
}
