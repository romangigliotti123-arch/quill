import Testing
@testable import QuillKit

// The gesture grammar, driven directly. Every trap these cover is one that only
// shows up on real hardware at the worst moment: a stray keystroke aborting a
// dictation, Option+Space starting one, a double-tap that needed three taps.

private typealias SM = HotkeyStateMachine
private let escape = HotkeyBinding.escapeKeyCode

/// Drives a machine through inputs on a fake clock and collects everything it emitted.
private struct Driver {
    var machine = SM()
    var clock: Double = 100

    mutating func at(_ t: Double, _ input: SM.Input) -> [SM.Effect] {
        clock = t
        return machine.handle(input, at: t)
    }

    /// Hold long enough to arm, i.e. the ordinary push-to-talk start.
    mutating func beginHold(at t: Double) -> [SM.Effect] {
        let armed = at(t, .triggerDown(isolated: true))
        guard case let .startArmTimer(token, _)? = armed.first else { return armed }
        return at(t + machine.timing.armDelay, .armTimerFired(token: token))
    }
}

// MARK: - Push to talk

@Test func holdingPastTheArmDelayStartsAndReleasingEnds() {
    var d = Driver()
    #expect(d.beginHold(at: 1) == [.notifyPressed])
    #expect(d.machine.state == .holding)
    #expect(d.at(3, .triggerUp) == [.notifyReleased])
    #expect(d.machine.state == .idle)
}

@Test func armDelayIsNotPaidUntilItElapses() {
    var d = Driver()
    let effects = d.at(1, .triggerDown(isolated: true))
    #expect(effects == [.startArmTimer(token: 1, delay: d.machine.timing.armDelay)])
    #expect(!d.machine.isRecording)
}

@Test func aTapIsNotAHold() {
    var d = Driver()
    _ = d.at(1, .triggerDown(isolated: true))
    let effects = d.at(1.05, .triggerUp)
    #expect(effects == [.cancelArmTimer])
    #expect(d.machine.state == .idle)
}

@Test func triggerHeldAsPartOfAChordNeverArms() {
    // Option+Space. The single most common false trigger there is.
    var d = Driver()
    #expect(d.at(1, .triggerDown(isolated: false)).isEmpty)
    #expect(d.machine.state == .idle)
}

// MARK: - Double tap hands-free

@Test func doubleTapWithinTheWindowStartsHandsFree() {
    var d = Driver()
    _ = d.at(1, .triggerDown(isolated: true))
    _ = d.at(1.05, .triggerUp)
    _ = d.at(1.20, .triggerDown(isolated: true))
    let effects = d.at(1.25, .triggerUp)
    #expect(effects == [.cancelArmTimer, .notifyPressed])
    #expect(d.machine.state == .handsFree)
}

@Test func doubleTapOutsideTheWindowIsJustTwoTaps() {
    var d = Driver()
    _ = d.at(1, .triggerDown(isolated: true))
    _ = d.at(1.05, .triggerUp)
    _ = d.at(2.00, .triggerDown(isolated: true))
    #expect(d.at(2.05, .triggerUp) == [.cancelArmTimer])
    #expect(d.machine.state == .idle)
}

@Test func oneTapEndsHandsFreeAndItsReleaseDoesNotRearm() {
    var d = Driver()
    _ = d.at(1, .triggerDown(isolated: true))
    _ = d.at(1.05, .triggerUp)
    _ = d.at(1.20, .triggerDown(isolated: true))
    _ = d.at(1.25, .triggerUp)

    #expect(d.at(5.0, .triggerDown(isolated: true)) == [.notifyReleased])
    #expect(d.machine.state == .idle)
    #expect(d.at(5.05, .triggerUp).isEmpty)
    #expect(d.machine.state == .idle)
}

@Test func thirdTapDoesNotImmediatelyToggleAgain() {
    var d = Driver()
    _ = d.at(1, .triggerDown(isolated: true))
    _ = d.at(1.05, .triggerUp)
    _ = d.at(1.20, .triggerDown(isolated: true))
    _ = d.at(1.25, .triggerUp)          // hands-free on
    _ = d.at(1.40, .triggerDown(isolated: true))
    _ = d.at(1.45, .triggerUp)          // hands-free off

    _ = d.at(1.60, .triggerDown(isolated: true))
    #expect(d.at(1.65, .triggerUp) == [.cancelArmTimer])
    #expect(d.machine.state == .idle)
}

@Test func aHoldDoesNotCountAsTheFirstHalfOfADoubleTap() {
    var d = Driver()
    _ = d.beginHold(at: 1)
    _ = d.at(1.30, .triggerUp)           // a real hold, released
    _ = d.at(1.40, .triggerDown(isolated: true))
    #expect(d.at(1.45, .triggerUp) == [.cancelArmTimer])
    #expect(d.machine.state == .idle)
}

@Test func anAbortedChordDoesNotCountAsATap() {
    var d = Driver()
    _ = d.at(1, .triggerDown(isolated: true))
    _ = d.at(1.03, .keyDown(keyCode: 49, isBare: false))   // Option+Space
    _ = d.at(1.06, .triggerUp)
    _ = d.at(1.20, .triggerDown(isolated: true))
    #expect(d.at(1.25, .triggerUp) == [.cancelArmTimer])
    #expect(d.machine.state == .idle)
}

// MARK: - Aborts and cancels

@Test func typingWhileArmedAbandonsTheGestureSilently() {
    var d = Driver()
    _ = d.at(1, .triggerDown(isolated: true))
    #expect(d.at(1.05, .keyDown(keyCode: 0, isBare: false)) == [.cancelArmTimer])
    #expect(d.machine.state == .idle)
}

@Test func anotherModifierWhileArmedAbandonsTheGesture() {
    var d = Driver()
    _ = d.at(1, .triggerDown(isolated: true))
    #expect(d.at(1.05, .otherModifierChanged) == [.cancelArmTimer])
    #expect(d.machine.state == .idle)
}

@Test func typingMidHoldCancelsTheDictation() {
    var d = Driver()
    _ = d.beginHold(at: 1)
    #expect(d.at(2, .keyDown(keyCode: 0, isBare: true)) == [.notifyCancelled])
    #expect(d.machine.state == .idle)
}

@Test func escapeMidHoldCancelsAndIsSwallowed() {
    var d = Driver()
    _ = d.beginHold(at: 1)
    #expect(d.at(2, .keyDown(keyCode: escape, isBare: true)) == [.notifyCancelled, .swallowEvent])
}

@Test func escapeCancelsHandsFreeButTypingDoesNot() {
    var d = Driver()
    _ = d.at(1, .triggerDown(isolated: true))
    _ = d.at(1.05, .triggerUp)
    _ = d.at(1.20, .triggerDown(isolated: true))
    _ = d.at(1.25, .triggerUp)

    #expect(d.at(2, .keyDown(keyCode: 0, isBare: true)).isEmpty)
    #expect(d.machine.state == .handsFree)
    #expect(d.at(3, .keyDown(keyCode: escape, isBare: true)) == [.notifyCancelled, .swallowEvent])
    #expect(d.machine.state == .idle)
}

@Test func chordedEscapeIsLeftAloneSoForceQuitStillWorks() {
    var d = Driver()
    _ = d.beginHold(at: 1)
    // ⌘⌥Esc belongs to the system; swallowing it would be worse than a lost dictation.
    #expect(d.at(2, .keyDown(keyCode: escape, isBare: false)) == [.notifyCancelled])
}

@Test func strayModifierMidHoldDoesNotKillTheDictation() {
    var d = Driver()
    _ = d.beginHold(at: 1)
    #expect(d.at(2, .otherModifierChanged).isEmpty)
    #expect(d.machine.state == .holding)
}

// MARK: - Timer hygiene

@Test func aStaleArmTimerCannotStartAPhantomRecording() {
    var d = Driver()
    let first = d.at(1, .triggerDown(isolated: true))
    guard case let .startArmTimer(staleToken, _)? = first.first else {
        Issue.record("expected an arm timer")
        return
    }
    _ = d.at(1.05, .triggerUp)                       // gesture abandoned
    _ = d.at(1.20, .triggerDown(isolated: true))     // a new one begins
    #expect(d.at(1.21, .armTimerFired(token: staleToken)).isEmpty)
    #expect(!d.machine.isRecording)
}

@Test func armTimerFiringInIdleDoesNothing() {
    var d = Driver()
    #expect(d.at(1, .armTimerFired(token: 1)).isEmpty)
    #expect(d.machine.state == .idle)
}

@Test func triggerUpInIdleIsIgnored() {
    var d = Driver()
    #expect(d.at(1, .triggerUp).isEmpty)
    #expect(d.machine.state == .idle)
}

// MARK: - Tap interruption

@Test func aTapDisabledMidHoldEndsTheDictationRatherThanStrandingIt() {
    var d = Driver()
    _ = d.beginHold(at: 1)
    #expect(d.at(2, .tapInterrupted) == [.notifyReleased])
    #expect(d.machine.state == .idle)
}

@Test func aTapDisabledWhileArmedJustDropsTheGesture() {
    var d = Driver()
    _ = d.at(1, .triggerDown(isolated: true))
    #expect(d.at(1.05, .tapInterrupted) == [.cancelArmTimer])
    #expect(d.machine.state == .idle)
}

@Test func handsFreeSurvivesATapInterruption() {
    // Nothing was missed: hands-free ends on a fresh tap, which the re-enabled
    // tap will still see.
    var d = Driver()
    _ = d.at(1, .triggerDown(isolated: true))
    _ = d.at(1.05, .triggerUp)
    _ = d.at(1.20, .triggerDown(isolated: true))
    _ = d.at(1.25, .triggerUp)
    #expect(d.at(2, .tapInterrupted).isEmpty)
    #expect(d.machine.state == .handsFree)
}

// MARK: - Binding arithmetic

@Test func rightAndLeftOptionAreDistinguishable() {
    // Generic masks cannot tell the sides apart, which is how a release gets
    // missed when both Options are involved.
    #expect(HotkeyBinding.rightOption.presenceMask != HotkeyBinding(keyCode: 58).presenceMask)
    #expect(HotkeyBinding.rightOption.genericMask == HotkeyBinding(keyCode: 58).genericMask)
}

@Test func chordMaskExcludesFnSoArrowAndReturnComparisonsStillMatch() {
    #expect(!HotkeyBinding.chordMask.contains(.maskSecondaryFn))
    #expect(HotkeyBinding.isolationMask.contains(.maskSecondaryFn))
}
