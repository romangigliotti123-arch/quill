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

    public init(timing: Timing = .default) {
        self.timing = timing
    }

    public var isRecording: Bool {
        state == .holding || state == .handsFree
    }

    public mutating func reset() {
        state = .idle
        lastTapAt = nil
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
            return [.startArmTimer(token: token, delay: timing.armDelay)]

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
            return [.cancelArmTimer]

        case (.armed, .keyDown), (.armed, .otherModifierChanged):
            // It was the beginning of a chord. Abandon it, and refuse to let it
            // count as the first half of a double-tap.
            lastTapAt = nil
            state = .idle
            return [.cancelArmTimer]

        case (.armed, .tapInterrupted):
            lastTapAt = nil
            state = .idle
            return [.cancelArmTimer]

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
            guard isolated else { return [] }
            lastTapAt = nil
            state = .idle
            return [.notifyReleased]

        case let (.handsFree, .keyDown(keyCode, isBare)):
            // Unlike a hold, hands-free tolerates typing — the user is expected to
            // keep working. Only Escape means "bin it".
            guard keyCode == HotkeyBinding.escapeKeyCode, isBare else { return [] }
            state = .idle
            return [.notifyCancelled, .swallowEvent]

        default:
            // Includes: modifiers changing mid-recording (a stray ⇧ must not kill a
            // dictation in progress), auto-repeat, and timers whose gesture is gone.
            return []
        }
    }
}
