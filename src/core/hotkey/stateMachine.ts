/// The whole gesture grammar of the dictation key, with no keyboard hook
/// anywhere in sight.
///
/// Everything time-dependent arrives either as the `now` parameter or as an
/// explicit `armTimerFired` input, so tap-vs-hold-vs-double-tap can be driven
/// from a test in microseconds. The alternative — the way this was written the
/// first time — is a state machine welded to the hook, which can only be
/// checked by a human pressing a key and believing what they see.

export interface HotkeyTiming {
  /// How long the trigger must stay down before a hold counts as a hold.
  ///
  /// This is a real, perceptible floor on start-of-recording latency: every
  /// push-to-talk dictation starts 120 ms after the finger lands, and no amount
  /// of model pre-warming wins that back. What it buys is the ability to tell a
  /// tap from a hold at all, which is the only reason double-tap hands-free can
  /// coexist with push-to-talk on one key. Lower it and taps start being heard
  /// as holds; raise it and the app feels lazy.
  armDelay: number;
  /// Maximum gap between the two taps of a double-tap. Above a comfortable
  /// double-tap, below the rate at which two *separate* deliberate taps get
  /// glued into one gesture.
  doubleTapWindow: number;
}

export const DEFAULT_TIMING: HotkeyTiming = { armDelay: 0.12, doubleTapWindow: 0.42 };

/// Physical facts, already stripped of any platform detail. `isolated` and
/// `isBare` are decided by the caller because deciding them needs the set of
/// keys currently down; what happens as a result is decided here because that
/// is the part with rules.
export type HotkeyInput =
  /// The bound trigger modifier went down. `isolated` is false when any other
  /// modifier is also held — i.e. this is a chord, not a gesture.
  | { kind: 'triggerDown'; isolated: boolean }
  | { kind: 'triggerUp' }
  /// The *push-to-talk* key went down: a key whose single tap starts and stops
  /// hands-free dictation, with nothing to hold. Only ever produced when it is
  /// a different physical key from the hold trigger.
  | { kind: 'toggleDown'; isolated: boolean }
  | { kind: 'toggleUp' }
  /// Some *other* modifier changed while a gesture was in flight.
  | { kind: 'otherModifierChanged' }
  /// `isBare` means no other modifier held.
  | { kind: 'keyDown'; code: number; isBare: boolean }
  | { kind: 'armTimerFired'; token: number }
  /// The hook was stopped out from under us, so any key-up we were waiting on
  /// has already been missed.
  | { kind: 'hookInterrupted' };

export type HotkeyEffect =
  /// Start capturing audio the instant the key goes down, BEFORE we know
  /// whether this is a hold, a tap or the start of a chord.
  ///
  /// Without this, the microphone does not open until the arm delay has elapsed
  /// and the audio pipeline has spun up — measured together at a few hundred
  /// milliseconds — and anything said in that window is gone. It is the
  /// difference between "it dropped my first word" and not. The cost is that a
  /// discarded gesture briefly opened the microphone; the recording is thrown
  /// away and never transcribed.
  | { kind: 'beginPreroll' }
  /// The gesture turned out not to be dictation. Throw the audio away.
  | { kind: 'abortPreroll' }
  | { kind: 'notifyPressed' }
  | { kind: 'notifyReleased' }
  | { kind: 'notifyCancelled' }
  | { kind: 'startArmTimer'; token: number; delay: number }
  | { kind: 'cancelArmTimer' };

export type HotkeyState =
  | { kind: 'idle' }
  /// Trigger is down but the arm delay has not elapsed; still could be a tap.
  | { kind: 'armed'; token: number }
  /// Push-to-talk: recording, and it ends when the trigger comes back up.
  | { kind: 'holding' }
  /// Double-tapped: recording, and the trigger is no longer held.
  | { kind: 'handsFree' };

export class HotkeyStateMachine {
  state: HotkeyState = { kind: 'idle' };
  timing: HotkeyTiming;

  /// Monotonic so a stale arm timer that fires after its gesture was abandoned
  /// can be recognised and dropped, rather than starting a phantom recording.
  private nextToken = 1;
  private lastTapAt: number | null = null;
  /// A trigger-down arrived during hands-free with another modifier held, and
  /// we are waiting to find out whether it was a stop or the start of a chord.
  private pendingStop = false;
  /// The scancode of the cancel key. Injected so a test does not have to know
  /// libuiohook's table.
  private readonly escapeCode: number;

  constructor(timing: HotkeyTiming = DEFAULT_TIMING, escapeCode = 1) {
    this.timing = { ...timing };
    this.escapeCode = escapeCode;
  }

  get isRecording(): boolean {
    return this.state.kind === 'holding' || this.state.kind === 'handsFree';
  }

  reset(): void {
    this.state = { kind: 'idle' };
    this.lastTapAt = null;
    this.pendingStop = false;
  }

  handle(input: HotkeyInput, now: number): HotkeyEffect[] {
    const state = this.state;

    if (state.kind === 'idle' && input.kind === 'triggerDown') {
      // The Alt+Space guard. A trigger pressed as part of a chord is the user
      // typing, and must not so much as arm.
      if (!input.isolated) return [];
      const token = this.nextToken;
      this.nextToken += 1;
      this.state = { kind: 'armed', token };
      return [
        { kind: 'beginPreroll' },
        { kind: 'startArmTimer', token, delay: this.timing.armDelay },
      ];
    }

    if (state.kind === 'armed' && input.kind === 'armTimerFired') {
      if (input.token !== state.token) return [];
      this.state = { kind: 'holding' };
      return [{ kind: 'notifyPressed' }];
    }

    if (state.kind === 'armed' && input.kind === 'triggerUp') {
      if (this.lastTapAt !== null && now - this.lastTapAt <= this.timing.doubleTapWindow) {
        // Consumed, so a third tap starts a fresh pair instead of immediately
        // toggling again.
        this.lastTapAt = null;
        this.state = { kind: 'handsFree' };
        return [{ kind: 'cancelArmTimer' }, { kind: 'notifyPressed' }];
      }
      this.lastTapAt = now;
      this.state = { kind: 'idle' };
      return [{ kind: 'cancelArmTimer' }, { kind: 'abortPreroll' }];
    }

    if (state.kind === 'idle' && input.kind === 'toggleDown') {
      // No arm delay and no preroll window to protect: there is no
      // tap-vs-hold ambiguity on a key that only ever toggles, so recording
      // starts on the press itself. `beginPreroll` still comes first because it
      // is what opens the microphone, and `notifyPressed` is what puts the HUD
      // up.
      if (!input.isolated) return [];
      this.lastTapAt = null;
      this.state = { kind: 'handsFree' };
      return [{ kind: 'beginPreroll' }, { kind: 'notifyPressed' }];
    }

    if (state.kind === 'handsFree' && input.kind === 'toggleDown') {
      // Either bound key ends hands-free. Isolation is not required to stop:
      // refusing to stop because a stray Shift was also down would strand a
      // recording the user has plainly asked to end.
      this.lastTapAt = null;
      this.state = { kind: 'idle' };
      return [{ kind: 'notifyReleased' }];
    }

    if (state.kind === 'armed'
      && (input.kind === 'keyDown' || input.kind === 'otherModifierChanged' || input.kind === 'toggleDown')) {
      // It was the beginning of a chord. Abandon it, and refuse to let it count
      // as the first half of a double-tap.
      this.lastTapAt = null;
      this.state = { kind: 'idle' };
      return [{ kind: 'cancelArmTimer' }, { kind: 'abortPreroll' }];
    }

    if (state.kind === 'armed' && input.kind === 'hookInterrupted') {
      this.lastTapAt = null;
      this.state = { kind: 'idle' };
      return [{ kind: 'cancelArmTimer' }, { kind: 'abortPreroll' }];
    }

    if (state.kind === 'holding' && input.kind === 'triggerUp') {
      // A hold is not a tap; it must not seed a double-tap.
      this.lastTapAt = null;
      this.state = { kind: 'idle' };
      return [{ kind: 'notifyReleased' }];
    }

    if (state.kind === 'holding' && input.kind === 'keyDown') {
      this.state = { kind: 'idle' };
      if (input.code === this.escapeCode && input.isBare) {
        return [{ kind: 'notifyCancelled' }];
      }
      // Any other key mid-hold means the user was typing a combination, not
      // dictating. Throw the audio away rather than inserting a surprise.
      return [{ kind: 'notifyCancelled' }];
    }

    if (state.kind === 'holding' && input.kind === 'hookInterrupted') {
      // The key-up will never arrive now, so end the dictation rather than
      // stranding it — the user said words and deserves them.
      this.state = { kind: 'idle' };
      return [{ kind: 'notifyReleased' }];
    }

    if (state.kind === 'handsFree' && input.kind === 'triggerDown') {
      // One isolated tap ends hands-free. The matching triggerUp lands in idle,
      // where it is ignored, so the release cannot re-arm.
      if (!input.isolated) {
        // A stray Shift or Ctrl held while the user taps the trigger to stop.
        //
        // Refusing outright — which is what this used to do — strands the
        // recording: the microphone stays open, the HUD stays up, and the
        // deliberate "stop" the user just made does nothing.
        //
        // But stopping here would be worse than stranding. Unlike a dedicated
        // toggle key, the trigger IS a chord modifier, and in Shift+Alt+Right
        // the other modifier lands first — so an unguarded stop would fire on
        // the Alt of a chord the user is typing, ending the dictation and
        // pasting the transcript over their own selection. Wrong text inserted
        // beats an ignored stop, in the wrong direction.
        //
        // So neither: remember it, and let the next event say which it was. A
        // key-down means it was a chord; a release with nothing in between
        // means it was a tap.
        this.pendingStop = true;
        return [];
      }
      this.lastTapAt = null;
      this.pendingStop = false;
      this.state = { kind: 'idle' };
      return [{ kind: 'notifyReleased' }];
    }

    if (state.kind === 'handsFree' && input.kind === 'triggerUp') {
      // Only meaningful after a non-isolated trigger-down, above. The release
      // with no keystroke in between is what proves it was a deliberate tap
      // rather than the opening of a chord.
      if (!this.pendingStop) return [];
      this.pendingStop = false;
      this.lastTapAt = null;
      this.state = { kind: 'idle' };
      return [{ kind: 'notifyReleased' }];
    }

    if (state.kind === 'handsFree' && input.kind === 'keyDown') {
      // The chord resolved: this was Shift+Alt+Right and not a stop. Hands-free
      // tolerates typing, so the dictation carries on.
      this.pendingStop = false;
      // Only Escape means "bin it".
      if (input.code !== this.escapeCode || !input.isBare) return [];
      this.state = { kind: 'idle' };
      return [{ kind: 'notifyCancelled' }];
    }

    // Everything else. Includes: modifiers changing mid-recording (a stray
    // Shift must not kill a dictation in progress), auto-repeat, timers whose
    // gesture is gone, every `toggleUp` (the push-to-talk key is a tap, so its
    // release means nothing), and the push key pressed during a hold — the hold
    // is the gesture in progress and it decides when it ends.
    return [];
  }
}
