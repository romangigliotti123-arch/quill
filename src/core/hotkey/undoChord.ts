import type { HotkeyState } from './stateMachine';

/// "Take back what you just inserted" — as a decision rather than a keystroke.
///
/// Pure, and separated from the hook for the same reason the gesture grammar
/// is: this is the part that decides whether Quill deletes text out of somebody
/// else's document, and it has to be checkable without a keyboard.
///
/// # What changed from the macOS build, and why
///
/// There, the chord was ⌥⌫ and the event tap SWALLOWED it, because ⌥⌫ already
/// means "delete the previous word" in every macOS text field. Swallowing is
/// the part that cannot be done here: `uiohook` observes the keyboard, it does
/// not sit in the delivery path, so a key it sees has already reached the
/// focused app. Overriding a standard binding without being able to swallow it
/// would mean the app deletes a word AND Quill deletes its sentence — two
/// deletions for one keystroke, which is worse than not having the feature.
///
/// So on Windows and Linux the chord is an Electron **global accelerator**,
/// Ctrl+Alt+Z by default, which the OS does deliver exclusively to us. That
/// removes the swallow problem by removing the collision: Ctrl+Alt+Z is not
/// bound by default anywhere, so nothing is being overridden. On macOS the
/// default stays Alt+Backspace, registered the same way.
///
/// What survives unchanged is the interesting half — the rule about WHEN the
/// chord may fire, which is what stops it deleting the previous sentence
/// because a key happened to be pressed mid-dictation.

/// How long after the trigger went down a chord press can still be the other
/// half of a reach rather than a key pressed during a dictation.
///
/// A backstop, not the test.
///
/// The question in `holding` is "is the user speaking, or reaching for the
/// other half of a chord", and the honest answer to it is `heardSpeech` —
/// whether the microphone has picked anything up. A clock was tried first and
/// the measurement killed it: driving the real chord through the real hook,
/// with a 500 ms gap between the two keys, the second key arrived 1.075 s after
/// the trigger went down. A human reaching across a keyboard does not beat a
/// shell script. Any window a careful press falls outside of turns the feature
/// back into "sometimes".
///
/// So this only catches the case where the audio never reports at all — a dead
/// microphone, a device that went away — and it is set well beyond any reach
/// and well inside a real dictation.
export const CHORD_WINDOW_SECONDS = 5;

export interface UndoChordQuery {
  gesture: HotkeyState;
  /// Seconds since the trigger went down, or null when it is not down.
  triggerHeldFor: number | null;
  /// Whether the microphone has heard anything above the noise floor during the
  /// gesture currently in flight.
  heardSpeech: boolean;
  /// Whether there is an insertion to take back at all.
  hasInsertion: boolean;
}

/// Whether the chord should take back Quill's last insertion.
///
/// Every clause is a way of not firing, which is the point.
export function undoChordClaims(query: UndoChordQuery): boolean {
  if (!query.hasInsertion) return false;

  switch (query.gesture.kind) {
    case 'idle':
      return true;
    case 'armed':
      // The dictation key may itself be part of the reach. Nobody starts a
      // dictation and presses the undo chord inside the 120 ms arm delay, so
      // this is the chord and not a gesture.
      return true;
    case 'holding':
      // Same chord, slightly slower hand. The arm timer moved the machine on at
      // 120 ms whether or not the user was doing anything, so "we are in
      // holding" does not yet mean "the user is speaking" — for the first few
      // hundred milliseconds it means "the trigger is down".
      //
      // Once anything has been heard the original reading holds: the user is
      // speaking, and claiming the chord would delete the previous sentence as
      // well as binning the current one.
      if (query.heardSpeech) return false;
      if (query.triggerHeldFor === null) return false;
      return query.triggerHeldFor <= CHORD_WINDOW_SECONDS;
    case 'handsFree':
      // Nothing is held here, so there is no chord to be halfway through — and
      // unlike a hold, hands-free is expected to survive typing. A keystroke is
      // the user editing, in a field a live dictation is writing into.
      return false;
  }
}
