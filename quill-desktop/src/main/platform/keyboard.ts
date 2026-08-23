/// The keystrokes Quill posts on the user's behalf.
///
/// # What this can and cannot do, said plainly
///
/// The macOS build synthesised arbitrary Unicode straight into the focused app
/// with `CGEvent.keyboardSetUnicodeString`, and used that both as its typing
/// fallback and for live typing. There is no cross-platform equivalent
/// reachable from Node without a native module built for the machine in front
/// of the user, so this layer offers exactly what libuiohook's post path
/// offers: **tap a key, with modifiers.** No arbitrary text.
///
/// Everything that needs text therefore goes through the clipboard and one
/// synthetic paste — which is what the macOS build already used as its PRIMARY
/// path, for the separate reason that it is the only method that behaves
/// identically in native, Electron and browser text fields. So the loss is the
/// fallback, not the main road, and `textInserter` says so when it has to use
/// it.
///
/// # Reading our own keystrokes back
///
/// Every event this posts is also seen by our own hook a few milliseconds
/// later. On macOS that was solved by stamping the event with a marker field;
/// libuiohook has no such field on any platform. So instead each post is
/// RECORDED as expected, and the hook drops the next matching event inside a
/// short window.
///
/// That is weaker than a marker and it is worth being honest about the gap: if
/// the user physically presses Ctrl+V in the same 250 ms as Quill's paste, one
/// of the two is swallowed by the filter. The consequence is one ignored
/// keystroke, never a wrong insertion, and the window is short enough that it
/// has to be a genuine coincidence.

import { isModifierCode } from '../../core/hotkey/binding';

interface UiohookModule {
  uIOhook: {
    start(): void;
    stop(): void;
    keyTap(key: number, modifiers?: number[]): void;
    keyToggle(key: number, toggle: 'down' | 'up'): void;
    on(event: string, listener: (event: never) => void): void;
    off(event: string, listener: (event: never) => void): void;
    removeAllListeners(event?: string): void;
  };
  UiohookKey: Record<string, number>;
  EventType: Record<string, number>;
}

let cached: UiohookModule | null | undefined;

/// `uiohook-napi` is an OPTIONAL dependency, and this is where that decision is
/// paid for.
///
/// It ships prebuilt binaries for the common platforms, but a musl Linux, a
/// BSD, or an architecture without a prebuild will fail to install it — and on
/// those machines an app that refuses to launch is a worse outcome than an app
/// that works from the tray and says push-to-talk is unavailable. Every caller
/// below tolerates null.
export function uiohook(): UiohookModule | null {
  if (cached !== undefined) return cached;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires, global-require
    cached = require('uiohook-napi') as UiohookModule;
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error('[quill] uiohook-napi is unavailable; push-to-talk and synthetic '
      + 'keystrokes are off. Text will be left on the clipboard instead.', error);
    cached = null;
  }
  return cached;
}

export function keyboardIsAvailable(): boolean {
  return uiohook() !== null;
}

/// The scancodes this layer needs, resolved once against the real table so a
/// drift between `core/hotkey/binding.ts` and libuiohook shows up here rather
/// than as a hotkey that silently never fires.
export interface Scancodes {
  ctrl: number;
  alt: number;
  shift: number;
  meta: number;
  v: number;
  c: number;
  a: number;
  z: number;
  backspace: number;
  escape: number;
  left: number;
  right: number;
}

let scancodes: Scancodes | null = null;

export function codes(): Scancodes {
  if (scancodes) return scancodes;
  const module = uiohook();
  const key = module?.UiohookKey ?? {};
  scancodes = {
    ctrl: key.Ctrl ?? 29,
    alt: key.Alt ?? 56,
    shift: key.Shift ?? 42,
    meta: key.Meta ?? 3675,
    v: key.V ?? 47,
    c: key.C ?? 46,
    a: key.A ?? 30,
    z: key.Z ?? 44,
    backspace: key.Backspace ?? 14,
    escape: key.Escape ?? 1,
    left: key.ArrowLeft ?? 57419,
    right: key.ArrowRight ?? 57421,
  };
  return scancodes;
}

/// The modifier that means "the editing one" on this platform: Command on
/// macOS, Control everywhere else. Every clipboard chord goes through this
/// rather than through a platform check at the call site, so a paste and a
/// select-all cannot disagree about which key they are pressing.
export function primaryModifier(): number {
  return process.platform === 'darwin' ? codes().meta : codes().ctrl;
}

// MARK: - Self-event filter

interface ExpectedEvent {
  code: number;
  expiresAt: number;
}

const expected: ExpectedEvent[] = [];

/// How long a posted event has to come back around before it is assumed lost.
///
/// Long enough for a busy machine to deliver it, short enough that a real
/// keystroke landing in the window is a coincidence rather than a habit.
const SELF_EVENT_WINDOW_MS = 250;

function expectSelfEvent(code: number): void {
  expected.push({ code, expiresAt: Date.now() + SELF_EVENT_WINDOW_MS });
}

/// Whether this key event is one we posted. Consuming, so a repeated key is
/// only excused as many times as it was posted.
export function isSelfPosted(code: number): boolean {
  const now = Date.now();
  while (expected.length > 0 && expected[0]!.expiresAt < now) expected.shift();
  const index = expected.findIndex((entry) => entry.code === code);
  if (index < 0) return false;
  expected.splice(index, 1);
  return true;
}

export function forgetSelfPostedEvents(): void {
  expected.length = 0;
}

// MARK: - Posting

function post(key: number, modifiers: number[]): boolean {
  const module = uiohook();
  if (!module) return false;
  try {
    expectSelfEvent(key);
    for (const modifier of modifiers) expectSelfEvent(modifier);
    module.uIOhook.keyTap(key, modifiers);
    return true;
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error('[quill] could not post a keystroke', error);
    return false;
  }
}

/// Posts a modified chord.
///
/// Returns false only when the event could not be constructed. A true here says
/// the event was posted, never that the focused app acted on it — there is no
/// API on any of the three platforms that tells you that, which is why the
/// caller has to be honest about the difference.
export function postChord(key: number, modifiers: number[] = []): boolean {
  return post(key, modifiers);
}

/// The paste chord for this platform.
export function postPaste(): boolean {
  return postChord(codes().v, [primaryModifier()]);
}

export function postCopy(): boolean {
  return postChord(codes().c, [primaryModifier()]);
}

export function postSelectAll(): boolean {
  return postChord(codes().a, [primaryModifier()]);
}

/// Posts `count` backspaces.
///
/// One event per character, because there is no "delete N" keystroke — and with
/// a gap between them, because a text view that coalesces input drops
/// backspaces that arrive in the same event-loop turn. Dropping one is not a
/// cosmetic bug: it leaves a stale character in the middle of the sentence and
/// every subsequent edit is off by one.
///
/// Asynchronous, unlike the macOS version's `usleep` loop, because this runs on
/// the main process's only thread and blocking it for 300 ms would freeze the
/// HUD, the tray and the dashboard at the exact moment the user is watching
/// text appear.
export async function postBackspaces(count: number, gapMs = 2): Promise<boolean> {
  if (count <= 0) return true;
  const module = uiohook();
  if (!module) return false;
  const backspace = codes().backspace;
  for (let index = 0; index < count; index += 1) {
    if (!post(backspace, [])) return false;
    if (gapMs > 0) await delay(gapMs);
  }
  return true;
}

/// Selects `count` characters to the left of the caret. Used by the transform
/// engine to re-select the last dictation before replacing it.
export async function postShiftLeft(count: number, gapMs = 1): Promise<boolean> {
  if (count <= 0) return true;
  const module = uiohook();
  if (!module) return false;
  const { left, shift } = codes();
  for (let index = 0; index < count; index += 1) {
    if (!post(left, [shift])) return false;
    if (gapMs > 0) await delay(gapMs);
  }
  return true;
}

/// Puts the caret back where it was. Right collapses a selection to its
/// right-hand end, which is exactly where the caret sat before the reselect.
export function collapseSelection(): boolean {
  return postChord(codes().right, []);
}

export function delay(ms: number): Promise<void> {
  return new Promise((resolve) => { setTimeout(resolve, ms); });
}

export { isModifierCode };
