/// Which key means "dictate".
///
/// Only bare modifiers are supported, which is a deliberate constraint: a bare
/// modifier is the one trigger that never collides with normal typing.
///
/// # What changed from the macOS build
///
/// That one stored a CoreGraphics virtual key code and did flag arithmetic with
/// device-dependent bits out of IOLLEvent.h to tell left Option from right
/// Option. None of that exists on Windows or Linux. What does exist, on all
/// three, is libuiohook's scancode table — and it already distinguishes the
/// sides: Alt is 56, AltRight is 3640, and the two arrive as separate key-down
/// and key-up events. So the binding is a NAME, the name maps to a scancode,
/// and the "is this specific physical key still down" question that needed
/// presence masks on macOS is answered here by tracking the set of keys that
/// are down, which is exact rather than inferred.

export interface HotkeyBinding {
  /// Stable across platforms and across releases; this is what goes in
  /// settings.json.
  name: string;
  /// libuiohook scancode.
  code: number;
}

/// The scancodes, copied from `UiohookKey` rather than imported, so the pure
/// core never has to load a native module. `hotkeyEngine` asserts they agree.
const CODES: Record<string, number> = {
  AltRight: 3640,
  AltLeft: 56,
  CtrlRight: 3613,
  CtrlLeft: 29,
  ShiftRight: 54,
  ShiftLeft: 42,
  MetaRight: 3676,
  MetaLeft: 3675,
  CapsLock: 58,
  Escape: 1,
  Backspace: 14,
};

export const ESCAPE_CODE = CODES.Escape!;
export const BACKSPACE_CODE = CODES.Backspace!;

export function bindingNamed(name: string): HotkeyBinding {
  const code = CODES[name];
  if (code === undefined) return { name: 'AltRight', code: CODES.AltRight! };
  return { name, code };
}

export function bindingForCode(code: number): HotkeyBinding | null {
  for (const [name, candidate] of Object.entries(CODES)) {
    if (candidate === code) return { name, code };
  }
  return null;
}

/// Right Alt / Right Option: reachable by the right thumb, unused by every
/// editor, and on a Mac layout it only ever produces alternate glyphs when
/// combined.
///
/// One caveat that is real and is stated on the Settings screen rather than
/// hidden: on keyboard layouts that use AltGr — most of continental Europe —
/// right Alt IS AltGr and types characters. Those users should bind right
/// Control instead, which is why the picker offers it first among the
/// alternatives.
export const DEFAULT_BINDING: HotkeyBinding = bindingNamed('AltRight');

/// Every key a user is allowed to bind, in the order they are offered.
///
/// Right-hand modifiers lead because they are the ones no app has claimed —
/// left Ctrl and left Meta are bindable, but binding them means every Ctrl+C on
/// the machine now arms a dictation for 120 ms first. They are offered anyway
/// (the choice is the user's) and the screen says so rather than hiding them.
export const ASSIGNABLE_BINDINGS: string[] = [
  'AltRight', 'CtrlRight', 'ShiftRight', 'MetaRight',
  'AltLeft', 'CtrlLeft', 'ShiftLeft', 'MetaLeft',
];

const IS_MAC = process.platform === 'darwin';

/// What the key between Ctrl and Alt is called on this machine.
///
/// One physical key, three names, and using the wrong one makes the setting
/// read as though it is about a key the keyboard does not have. Linux calls it
/// Super — the distributions, the window managers and the keycap all agree —
/// and a Linux user told to press "Windows" has to translate.
const META_NAME = IS_MAC ? 'Command' : process.platform === 'win32' ? 'Windows' : 'Super';

export function bindingDisplayName(binding: HotkeyBinding): string {
  switch (binding.name) {
    case 'AltRight': return IS_MAC ? 'Right Option' : 'Right Alt';
    case 'AltLeft': return IS_MAC ? 'Left Option' : 'Left Alt';
    case 'CtrlRight': return 'Right Control';
    case 'CtrlLeft': return 'Left Control';
    case 'ShiftRight': return 'Right Shift';
    case 'ShiftLeft': return 'Left Shift';
    case 'MetaRight': return `Right ${META_NAME}`;
    case 'MetaLeft': return `Left ${META_NAME}`;
    default: return binding.name;
  }
}

/// The symbol a user actually reads a modifier as, beside the side — "⌥" alone
/// cannot say which of the two you mean. On Windows and Linux the words read
/// better than the Mac glyphs, so they are used instead.
export function bindingCapText(binding: HotkeyBinding): string {
  const side = binding.name.endsWith('Right') ? 'R' : 'L';
  if (IS_MAC) {
    const glyph = binding.name.startsWith('Alt') ? '⌥'
      : binding.name.startsWith('Ctrl') ? '⌃'
        : binding.name.startsWith('Shift') ? '⇧'
          : binding.name.startsWith('Meta') ? '⌘' : '?';
    return glyph + side;
  }
  const word = binding.name.startsWith('Alt') ? 'Alt'
    : binding.name.startsWith('Ctrl') ? 'Ctrl'
      : binding.name.startsWith('Shift') ? 'Shift'
        : binding.name.startsWith('Meta') ? (process.platform === 'win32' ? 'Win' : 'Super') : '?';
  return `${side} ${word}`;
}

/// Whether this key is one people type with constantly. Drives one line of
/// warning on the settings screen; does not prevent the choice.
export function bindingIsBusy(binding: HotkeyBinding): boolean {
  return binding.name.endsWith('Left');
}

/// Whether right Alt is likely to be AltGr on this machine.
///
/// There is no reliable way to ask the OS which layout is active from Electron
/// without a native module, so this is not detection — it is a prompt to check.
/// The Settings screen shows the note next to the binding rather than acting on
/// it, because guessing wrong in either direction is worse than asking.
export function bindingMayBeAltGr(binding: HotkeyBinding): boolean {
  return binding.name === 'AltRight' && process.platform !== 'darwin';
}

/// Every keycode that is a modifier. Used to decide whether a key-down during a
/// gesture is "the user is typing" or "another modifier joined the chord".
///
/// CapsLock is excluded on purpose: it is a latched state, not something a user
/// is holding, and someone with it on should still be able to dictate.
export const MODIFIER_CODES = new Set<number>([
  CODES.AltLeft!, CODES.AltRight!, CODES.CtrlLeft!, CODES.CtrlRight!,
  CODES.ShiftLeft!, CODES.ShiftRight!, CODES.MetaLeft!, CODES.MetaRight!,
]);

export function isModifierCode(code: number): boolean {
  return MODIFIER_CODES.has(code);
}
