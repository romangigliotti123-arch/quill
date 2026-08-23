import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  HotkeyEffect, HotkeyInput, HotkeyStateMachine,
} from '../src/core/hotkey/stateMachine';
import {
  ASSIGNABLE_BINDINGS, ESCAPE_CODE, bindingCapText, bindingDisplayName, bindingForCode,
  bindingIsBusy, bindingNamed, isModifierCode,
} from '../src/core/hotkey/binding';

// The gesture grammar, driven directly. Every trap these cover is one that only
// shows up on real hardware at the worst moment: a stray keystroke aborting a
// dictation, Alt+Space starting one, a double-tap that needed three taps.

/// Drives a machine through inputs on a fake clock and collects what it emitted.
class Driver {
  machine = new HotkeyStateMachine(undefined, ESCAPE_CODE);

  at(time: number, input: HotkeyInput): HotkeyEffect[] {
    return this.machine.handle(input, time);
  }

  /// Hold long enough to arm, i.e. the ordinary push-to-talk start.
  beginHold(time: number): HotkeyEffect[] {
    const armed = this.at(time, { kind: 'triggerDown', isolated: true });
    // Not `[0]`: key-down emits `beginPreroll` ahead of the arm timer.
    const timer = armed.find((effect) => effect.kind === 'startArmTimer');
    if (!timer || timer.kind !== 'startArmTimer') return armed;
    return this.at(time + this.machine.timing.armDelay, { kind: 'armTimerFired', token: timer.token });
  }
}

const kinds = (effects: HotkeyEffect[]): string[] => effects.map((effect) => effect.kind);

// MARK: - Push to talk

test('holding past the arm delay starts and releasing ends', () => {
  const d = new Driver();
  assert.deepEqual(kinds(d.beginHold(1)), ['notifyPressed']);
  assert.equal(d.machine.state.kind, 'holding');
  assert.deepEqual(kinds(d.at(3, { kind: 'triggerUp' })), ['notifyReleased']);
  assert.equal(d.machine.state.kind, 'idle');
});

test('the arm delay is not paid until it elapses', () => {
  const d = new Driver();
  const effects = d.at(1, { kind: 'triggerDown', isolated: true });
  assert.deepEqual(kinds(effects), ['beginPreroll', 'startArmTimer']);
  assert.equal(d.machine.isRecording, false);
});

test('a tap is not a hold', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  assert.deepEqual(kinds(d.at(1.05, { kind: 'triggerUp' })), ['cancelArmTimer', 'abortPreroll']);
  assert.equal(d.machine.state.kind, 'idle');
});

test('a trigger held as part of a chord never arms', () => {
  // Alt+Space. The single most common false trigger there is.
  const d = new Driver();
  assert.deepEqual(d.at(1, { kind: 'triggerDown', isolated: false }), []);
  assert.equal(d.machine.state.kind, 'idle');
});

// MARK: - Double tap hands-free

test('a double tap within the window starts hands-free', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  d.at(1.05, { kind: 'triggerUp' });
  d.at(1.20, { kind: 'triggerDown', isolated: true });
  assert.deepEqual(kinds(d.at(1.25, { kind: 'triggerUp' })), ['cancelArmTimer', 'notifyPressed']);
  assert.equal(d.machine.state.kind, 'handsFree');
});

test('a double tap outside the window is just two taps', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  d.at(1.05, { kind: 'triggerUp' });
  d.at(2.00, { kind: 'triggerDown', isolated: true });
  assert.deepEqual(kinds(d.at(2.05, { kind: 'triggerUp' })), ['cancelArmTimer', 'abortPreroll']);
  assert.equal(d.machine.state.kind, 'idle');
});

test('one tap ends hands-free and its release does not re-arm', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  d.at(1.05, { kind: 'triggerUp' });
  d.at(1.20, { kind: 'triggerDown', isolated: true });
  d.at(1.25, { kind: 'triggerUp' });

  assert.deepEqual(kinds(d.at(5.0, { kind: 'triggerDown', isolated: true })), ['notifyReleased']);
  assert.equal(d.machine.state.kind, 'idle');
  assert.deepEqual(d.at(5.05, { kind: 'triggerUp' }), []);
  assert.equal(d.machine.state.kind, 'idle');
});

test('a third tap does not immediately toggle again', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  d.at(1.05, { kind: 'triggerUp' });
  d.at(1.20, { kind: 'triggerDown', isolated: true });
  d.at(1.25, { kind: 'triggerUp' });          // hands-free on
  d.at(1.40, { kind: 'triggerDown', isolated: true });
  d.at(1.45, { kind: 'triggerUp' });          // hands-free off

  d.at(1.60, { kind: 'triggerDown', isolated: true });
  assert.deepEqual(kinds(d.at(1.65, { kind: 'triggerUp' })), ['cancelArmTimer', 'abortPreroll']);
  assert.equal(d.machine.state.kind, 'idle');
});

test('a hold does not count as the first half of a double tap', () => {
  const d = new Driver();
  d.beginHold(1);
  d.at(1.30, { kind: 'triggerUp' });           // a real hold, released
  d.at(1.40, { kind: 'triggerDown', isolated: true });
  assert.deepEqual(kinds(d.at(1.45, { kind: 'triggerUp' })), ['cancelArmTimer', 'abortPreroll']);
  assert.equal(d.machine.state.kind, 'idle');
});

test('an aborted chord does not count as a tap', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  d.at(1.03, { kind: 'keyDown', code: 57, isBare: false });   // Alt+Space
  d.at(1.06, { kind: 'triggerUp' });
  d.at(1.20, { kind: 'triggerDown', isolated: true });
  assert.deepEqual(kinds(d.at(1.25, { kind: 'triggerUp' })), ['cancelArmTimer', 'abortPreroll']);
  assert.equal(d.machine.state.kind, 'idle');
});

// MARK: - Aborts and cancels

test('typing while armed abandons the gesture silently', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  assert.deepEqual(kinds(d.at(1.05, { kind: 'keyDown', code: 30, isBare: false })),
    ['cancelArmTimer', 'abortPreroll']);
  assert.equal(d.machine.state.kind, 'idle');
});

test('another modifier while armed abandons the gesture', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  assert.deepEqual(kinds(d.at(1.05, { kind: 'otherModifierChanged' })),
    ['cancelArmTimer', 'abortPreroll']);
  assert.equal(d.machine.state.kind, 'idle');
});

test('typing mid-hold cancels the dictation', () => {
  const d = new Driver();
  d.beginHold(1);
  assert.deepEqual(kinds(d.at(2, { kind: 'keyDown', code: 30, isBare: true })), ['notifyCancelled']);
  assert.equal(d.machine.state.kind, 'idle');
});

test('escape mid-hold cancels', () => {
  const d = new Driver();
  d.beginHold(1);
  assert.deepEqual(kinds(d.at(2, { kind: 'keyDown', code: ESCAPE_CODE, isBare: true })),
    ['notifyCancelled']);
});

test('escape cancels hands-free but typing does not', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  d.at(1.05, { kind: 'triggerUp' });
  d.at(1.20, { kind: 'triggerDown', isolated: true });
  d.at(1.25, { kind: 'triggerUp' });

  assert.deepEqual(d.at(2, { kind: 'keyDown', code: 30, isBare: true }), []);
  assert.equal(d.machine.state.kind, 'handsFree');
  assert.deepEqual(kinds(d.at(3, { kind: 'keyDown', code: ESCAPE_CODE, isBare: true })),
    ['notifyCancelled']);
  assert.equal(d.machine.state.kind, 'idle');
});

test('a stray modifier mid-hold does not kill the dictation', () => {
  const d = new Driver();
  d.beginHold(1);
  assert.deepEqual(d.at(2, { kind: 'otherModifierChanged' }), []);
  assert.equal(d.machine.state.kind, 'holding');
});

// MARK: - Timer hygiene

test('a stale arm timer cannot start a phantom recording', () => {
  const d = new Driver();
  const first = d.at(1, { kind: 'triggerDown', isolated: true });
  const timer = first.find((effect) => effect.kind === 'startArmTimer');
  assert.ok(timer && timer.kind === 'startArmTimer', 'expected an arm timer');
  const staleToken = timer.token;

  d.at(1.05, { kind: 'triggerUp' });                       // gesture abandoned
  d.at(1.20, { kind: 'triggerDown', isolated: true });     // a new one begins
  assert.deepEqual(d.at(1.21, { kind: 'armTimerFired', token: staleToken }), []);
  assert.equal(d.machine.isRecording, false);
});

test('an arm timer firing in idle does nothing', () => {
  const d = new Driver();
  assert.deepEqual(d.at(1, { kind: 'armTimerFired', token: 1 }), []);
  assert.equal(d.machine.state.kind, 'idle');
});

test('a trigger up in idle is ignored', () => {
  const d = new Driver();
  assert.deepEqual(d.at(1, { kind: 'triggerUp' }), []);
  assert.equal(d.machine.state.kind, 'idle');
});

// MARK: - Hook interruption

test('a hook stopped mid-hold ends the dictation rather than stranding it', () => {
  const d = new Driver();
  d.beginHold(1);
  assert.deepEqual(kinds(d.at(2, { kind: 'hookInterrupted' })), ['notifyReleased']);
  assert.equal(d.machine.state.kind, 'idle');
});

test('a hook stopped while armed just drops the gesture', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  assert.deepEqual(kinds(d.at(1.05, { kind: 'hookInterrupted' })), ['cancelArmTimer', 'abortPreroll']);
  assert.equal(d.machine.state.kind, 'idle');
});

test('hands-free survives a hook interruption', () => {
  // Nothing was missed: hands-free ends on a fresh tap, which the restarted
  // hook will still see.
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  d.at(1.05, { kind: 'triggerUp' });
  d.at(1.20, { kind: 'triggerDown', isolated: true });
  d.at(1.25, { kind: 'triggerUp' });
  assert.deepEqual(d.at(2, { kind: 'hookInterrupted' }), []);
  assert.equal(d.machine.state.kind, 'handsFree');
});

// MARK: - Preroll
//
// The bug these exist for: recording used to start only once the arm delay had
// elapsed AND the audio pipeline had spun up, so the first word of every
// dictation was gone. Capture now begins on the key-down itself, before the
// gesture has resolved, and is thrown away if it turns out not to be dictation.

test('the microphone opens on key-down, before the gesture has resolved', () => {
  const d = new Driver();
  const effects = d.at(1, { kind: 'triggerDown', isolated: true });
  assert.equal(effects[0]?.kind, 'beginPreroll');
});

test('an abandoned gesture throws the speculative audio away', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  assert.ok(kinds(d.at(1.05, { kind: 'triggerUp' })).includes('abortPreroll'));

  const chord = new Driver();
  chord.at(1, { kind: 'triggerDown', isolated: true });
  assert.ok(kinds(chord.at(1.02, { kind: 'keyDown', code: 57, isBare: false })).includes('abortPreroll'));
});

test('a chord never opens the microphone at all', () => {
  const d = new Driver();
  assert.deepEqual(d.at(1, { kind: 'triggerDown', isolated: false }), []);
});

test('a double tap does not abort the preroll it is about to use', () => {
  const d = new Driver();
  d.at(1, { kind: 'triggerDown', isolated: true });
  d.at(1.05, { kind: 'triggerUp' });
  d.at(1.20, { kind: 'triggerDown', isolated: true });
  const effects = kinds(d.at(1.25, { kind: 'triggerUp' }));
  assert.ok(!effects.includes('abortPreroll'), 'the audio for the hands-free session was discarded');
});

// MARK: - Bindings

test('left and right modifiers are distinguishable', () => {
  // The macOS build had to reach for device-dependent flag bits to tell these
  // apart, and missed a key-up when both were held. Here they are separate
  // scancodes and separate events.
  assert.notEqual(bindingNamed('AltRight').code, bindingNamed('AltLeft').code);
  assert.equal(bindingForCode(bindingNamed('AltRight').code)?.name, 'AltRight');
});

test('every assignable binding resolves and has a name a person can read', () => {
  for (const name of ASSIGNABLE_BINDINGS) {
    const binding = bindingNamed(name);
    assert.equal(binding.name, name, `${name} did not resolve`);
    assert.ok(isModifierCode(binding.code), `${name} is not a modifier`);
    assert.ok(bindingDisplayName(binding).length > 3);
    assert.ok(bindingCapText(binding).length > 0);
  }
});

test('an unknown binding name falls back rather than producing a dead key', () => {
  // A settings file from a newer build, or one edited by hand. A binding that
  // resolves to nothing is a dictation key that silently stops working.
  assert.equal(bindingNamed('NoSuchKey').name, 'AltRight');
});

test('left-hand modifiers are flagged as busy', () => {
  // Bindable, but binding one means every Ctrl+C on the machine arms a
  // dictation for 120 ms first. The screen says so rather than hiding them.
  assert.ok(bindingIsBusy(bindingNamed('CtrlLeft')));
  assert.ok(!bindingIsBusy(bindingNamed('AltRight')));
});
