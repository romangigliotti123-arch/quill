import {
  DEFAULT_TIMING, HotkeyEffect, HotkeyStateMachine, HotkeyTiming,
} from '../../core/hotkey/stateMachine';
import {
  ESCAPE_CODE, HotkeyBinding, bindingNamed, isModifierCode,
} from '../../core/hotkey/binding';
import { isSelfPosted, uiohook, forgetSelfPostedEvents } from '../platform/keyboard';
import type { QuillSettings } from '../../core/settings';

/// What the hotkey engine reports.
///
/// Push-to-talk is a *hold*, so down and up are separate events rather than one
/// toggle.
export interface HotkeyDelegate {
  /// The trigger went down, but it is not yet known whether this is dictation.
  /// Start capturing audio now and discard it later if this turns out to be a
  /// chord or a stray tap — the alternative is losing whatever was said during
  /// the arm delay and the audio pipeline's spin-up.
  hotkeyMayBegin(): void;
  /// The gesture resolved to something other than dictation. Throw the
  /// speculative capture away.
  hotkeyAborted(): void;
  hotkeyPressed(): void;
  hotkeyReleased(): void;
  /// Escape, or any keystroke that means "throw this dictation away".
  ///
  /// `userKeystroke` is the text the cancelling key actually inserted into the
  /// focused app.
  ///
  /// It has to be the text and not a boolean. Backspaces delete from the caret
  /// backwards and that character is the LAST thing on screen, so there is no
  /// number of backspaces that removes what Quill typed and spares it: deleting
  /// one fewer takes the user's character first and leaves one of Quill's in
  /// its place. The only correct move is to take everything back and put their
  /// character in again, which needs the character.
  ///
  /// On this platform it is almost always empty, and that is not a shortcut —
  /// it is a consequence of the hook being an observer. Quill cannot swallow
  /// the cancelling key, so whatever it typed is genuinely in the document and
  /// the retract has to account for it. What Quill DOES know is the scancode,
  /// and the only keys that reach this path are Escape and other non-printing
  /// keys, which contribute nothing.
  hotkeyCancelled(userKeystroke: string): void;
  /// Something happened that could have moved the caret. Used to invalidate the
  /// undo record.
  hotkeyDisturbance(reason: string): void;
  /// The hook died or could not be started. Carries something a human can act on.
  hotkeyEngineUnavailable(reason: string): void;
}

interface UiohookEvent {
  keycode: number;
  altKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  shiftKey: boolean;
}

/// Where the engine gets its keys from.
///
/// An interface rather than a direct reference to the settings singleton so the
/// engine can be driven from a test with fixed bindings. Read on every
/// keystroke: a cached binding is a binding that needs a relaunch to change.
export interface HotkeyBindingProviding {
  /// Held down while speaking.
  readonly hold: HotkeyBinding;
  /// Tapped once to start and once to stop. May be the same key as `hold`, in
  /// which case it is reached by double-tapping instead.
  readonly toggle: HotkeyBinding;
  /// True while a settings screen is recording a new binding, during which the
  /// engine must ignore every key — otherwise assigning a key also fires it.
  readonly isCapturingHotkey: boolean;
}

export class SettingsBindings implements HotkeyBindingProviding {
  constructor(private readonly settings: QuillSettings) {}
  get hold(): HotkeyBinding { return bindingNamed(this.settings.holdKey); }
  get toggle(): HotkeyBinding { return bindingNamed(this.settings.toggleKey); }
  get isCapturingHotkey(): boolean { return this.settings.isCapturingHotkey; }
}

/// Fixed bindings, for tests and for anything that must not touch the disk.
export class StaticBindings implements HotkeyBindingProviding {
  constructor(
    readonly hold: HotkeyBinding = bindingNamed('AltRight'),
    readonly toggle: HotkeyBinding = bindingNamed('AltRight'),
  ) {}
  readonly isCapturingHotkey = false;
}

export class HotkeyEngine {
  delegate: HotkeyDelegate | null = null;

  private readonly machine: HotkeyStateMachine;
  private readonly bindings: HotkeyBindingProviding;
  /// Every key currently down, by scancode. This is what answers "is the
  /// trigger isolated" exactly, where macOS had to infer it from
  /// device-dependent flag bits.
  private readonly down = new Set<number>();
  private armTimer: NodeJS.Timeout | null = null;
  private running = false;
  private speechHeard = false;
  private triggerDownAt: number | null = null;
  private listeners: { event: string; fn: (event: never) => void }[] = [];

  constructor(bindings: HotkeyBindingProviding, timing: HotkeyTiming = DEFAULT_TIMING) {
    this.bindings = bindings;
    this.machine = new HotkeyStateMachine(timing, ESCAPE_CODE);
  }

  get state() { return this.machine.state; }
  get isRecording(): boolean { return this.machine.isRecording; }
  /// Seconds the trigger has been down, or null when it is not.
  get triggerHeldFor(): number | null {
    return this.triggerDownAt === null ? null : (Date.now() - this.triggerDownAt) / 1000;
  }
  get heardSpeech(): boolean { return this.speechHeard; }

  /// The microphone has heard something above the noise floor during the
  /// gesture currently in flight.
  ///
  /// This is what tells a chord from a dictation. The gesture machine cannot
  /// answer it — 130 ms after the trigger goes down it reports holding whether
  /// or not the user is speaking — and a clock cannot answer it either: a
  /// two-key reach measured over a second, well inside the time a short
  /// dictation takes. Only the audio knows.
  noteSpeechHeard(): void { this.speechHeard = true; }

  start(): boolean {
    if (this.running) return true;
    const module = uiohook();
    if (!module) {
      this.delegate?.hotkeyEngineUnavailable(
        'Push-to-talk is unavailable: the keyboard hook could not be loaded on this machine. '
        + 'Dictation can still be started from the tray or the dashboard.',
      );
      return false;
    }
    try {
      const onKeyDown = (event: UiohookEvent): void => this.handleKey(event, true);
      const onKeyUp = (event: UiohookEvent): void => this.handleKey(event, false);
      const onMouseDown = (): void => {
        // The keyboard hook is keyboard-only by design, so a click — the
        // ordinary way to move a caret — would otherwise be invisible.
        this.delegate?.hotkeyDisturbance('a mouse click');
      };
      module.uIOhook.on('keydown', onKeyDown as (event: never) => void);
      module.uIOhook.on('keyup', onKeyUp as (event: never) => void);
      module.uIOhook.on('mousedown', onMouseDown as (event: never) => void);
      this.listeners = [
        { event: 'keydown', fn: onKeyDown as (event: never) => void },
        { event: 'keyup', fn: onKeyUp as (event: never) => void },
        { event: 'mousedown', fn: onMouseDown as (event: never) => void },
      ];
      module.uIOhook.start();
      this.running = true;
      return true;
    } catch (error) {
      this.delegate?.hotkeyEngineUnavailable(this.startFailureMessage(error));
      return false;
    }
  }

  /// The one failure worth explaining in the user's terms rather than the
  /// library's.
  ///
  /// On X11 the hook needs no permission at all. On Wayland it reads
  /// `/dev/input/event*`, which is root-or-`input`-group by default, and the
  /// error that comes back is an errno nobody can act on. On macOS it needs
  /// Accessibility, which the OS grants per-binary and silently drops when the
  /// binary changes.
  private startFailureMessage(error: unknown): string {
    const detail = error instanceof Error ? error.message : String(error);
    if (process.platform === 'linux' && (process.env.XDG_SESSION_TYPE ?? '').toLowerCase() === 'wayland') {
      return 'Push-to-talk could not start. On Wayland, Quill reads the keyboard through '
        + '/dev/input, which usually means adding your user to the "input" group '
        + '(sudo usermod -aG input $USER) and logging back in. '
        + `The system said: ${detail}`;
    }
    if (process.platform === 'darwin') {
      return 'Push-to-talk could not start. macOS needs Quill in System Settings ▸ Privacy & '
        + 'Security ▸ Accessibility — and if it is already listed, remove it and add it again: '
        + 'the permission is tied to the exact binary, and a rebuild invalidates it. '
        + `The system said: ${detail}`;
    }
    return `Push-to-talk could not start. The system said: ${detail}`;
  }

  stop(): void {
    if (!this.running) return;
    const module = uiohook();
    try {
      for (const listener of this.listeners) module?.uIOhook.off(listener.event, listener.fn);
      module?.uIOhook.stop();
    } catch {
      /* stopping a hook that is already gone is not an error worth reporting */
    }
    this.listeners = [];
    this.running = false;
    this.down.clear();
    forgetSelfPostedEvents();
    this.cancelArmTimer();
    // The key-up will never arrive now, so tell the machine rather than
    // stranding whatever gesture was in flight.
    this.dispatch(this.machine.handle({ kind: 'hookInterrupted' }, now()));
  }

  private handleKey(event: UiohookEvent, isDown: boolean): void {
    const code = event.keycode;

    // Our own paste, our own backspaces, our own probe. Dropped before anything
    // else looks at them — a synthetic Ctrl+V read as the user typing would
    // cancel the dictation that produced it, which is not something anyone
    // would guess from the outside.
    if (isSelfPosted(code)) return;

    if (isDown) this.down.add(code);
    else this.down.delete(code);

    // A settings screen is listening for a new binding. Every key belongs to it
    // until it says otherwise, or assigning a key also fires it.
    if (this.bindings.isCapturingHotkey) return;

    const hold = this.bindings.hold;
    const toggle = this.bindings.toggle;
    const sharesKey = hold.code === toggle.code;

    // Any real keystroke could have moved the caret. Reported before the
    // gesture logic, because a key that abandons a gesture is still a key.
    if (isDown) this.delegate?.hotkeyDisturbance('a keystroke');

    if (code === hold.code) {
      if (isDown) {
        this.triggerDownAt = Date.now();
        this.speechHeard = false;
        this.dispatch(this.machine.handle(
          { kind: 'triggerDown', isolated: this.isIsolated(code) }, now(),
        ));
      } else {
        this.triggerDownAt = null;
        this.dispatch(this.machine.handle({ kind: 'triggerUp' }, now()));
      }
      return;
    }

    if (!sharesKey && code === toggle.code) {
      if (isDown) {
        this.dispatch(this.machine.handle(
          { kind: 'toggleDown', isolated: this.isIsolated(code) }, now(),
        ));
      } else {
        this.dispatch(this.machine.handle({ kind: 'toggleUp' }, now()));
      }
      return;
    }

    if (!isDown) return;

    if (isModifierCode(code)) {
      this.dispatch(this.machine.handle({ kind: 'otherModifierChanged' }, now()));
      return;
    }

    this.dispatch(this.machine.handle(
      { kind: 'keyDown', code, isBare: this.isIsolated(code) }, now(),
    ));
  }

  /// Whether the given key is the only modifier down.
  ///
  /// Exact, because the set of pressed keys is tracked directly. Caps Lock is
  /// not in `MODIFIER_CODES` on purpose: it is a latched state, not something a
  /// user is holding, and someone with it on should still be able to dictate.
  private isIsolated(code: number): boolean {
    for (const other of this.down) {
      if (other === code) continue;
      if (isModifierCode(other)) return false;
    }
    return true;
  }

  private dispatch(effects: HotkeyEffect[]): void {
    for (const effect of effects) {
      switch (effect.kind) {
        case 'beginPreroll': this.delegate?.hotkeyMayBegin(); break;
        case 'abortPreroll': this.delegate?.hotkeyAborted(); break;
        case 'notifyPressed': this.delegate?.hotkeyPressed(); break;
        case 'notifyReleased': this.delegate?.hotkeyReleased(); break;
        case 'notifyCancelled': this.delegate?.hotkeyCancelled(''); break;
        case 'startArmTimer': this.startArmTimer(effect.token, effect.delay); break;
        case 'cancelArmTimer': this.cancelArmTimer(); break;
      }
    }
  }

  private startArmTimer(token: number, delaySeconds: number): void {
    this.cancelArmTimer();
    this.armTimer = setTimeout(() => {
      this.armTimer = null;
      this.dispatch(this.machine.handle({ kind: 'armTimerFired', token }, now()));
    }, delaySeconds * 1000);
  }

  private cancelArmTimer(): void {
    if (this.armTimer) clearTimeout(this.armTimer);
    this.armTimer = null;
  }
}

function now(): number {
  return Date.now() / 1000;
}
