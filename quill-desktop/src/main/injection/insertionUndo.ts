import { graphemeCount } from '../../core/text/strings';
import { appContextOf } from '../../core/cleanup/appContext';
import {
  captureClipboard, readClipboardText, restoreClipboard, snapshotIsFaithful, writeClipboard,
} from './clipboardSnapshot';
import {
  codes, collapseSelection, delay, keyboardIsAvailable, postBackspaces, postChord, postCopy,
  postShiftLeft,
} from '../platform/keyboard';
import type { WindowWatcher } from '../platform/windowWatcher';

/// Takes back the last thing Quill inserted, in one keystroke.
///
/// The ask, in the user's own words: "when I'm transcribing something and I
/// decide to get rid of all of it, instead of having to delete a word or select
/// it all and then click delete, I should just be able to press delete plus
/// option."
///
/// The asymmetry is the whole design. Not firing costs the user one extra
/// gesture; firing wrongly deletes a sentence they wrote themselves, in a
/// document Quill cannot read back, and they find out later with nothing to
/// blame.
///
/// # Two things changed from the macOS build, and one of them is an improvement
///
/// **The chord no longer overrides anything.** There it was ⌥⌫, which already
/// means "delete the previous word" in every macOS text field, and the event
/// tap swallowed it and put it back when the undo declined. That is not
/// available here — the hook observes the keyboard rather than sitting in the
/// delivery path — so the chord is an Electron global accelerator instead,
/// Ctrl+Alt+Z by default, which nothing else claims. Nothing to swallow,
/// nothing to put back, and no standard binding taken away from the user.
///
/// **Verification got better, not worse.** macOS asked the Accessibility API
/// what was behind the caret, and measured, three of the four apps anyone
/// actually dictates into refused to say: a terminal reports a caret that never
/// leaves 0, a browser reports no caret, an Electron editor reports no focused
/// element. So the strict version did not make the feature careful, it made it
/// not exist. Here there is no AX to ask — but there is a way to ask the field
/// itself: select the last N characters and copy them. If what comes back is
/// exactly what Quill inserted, the sentence is provably still there, in any
/// app, with no per-app support needed.
///
/// That check is skipped in a terminal, and the reason is not subtle: Ctrl+C in
/// a terminal is SIGINT, and a verification step that kills the user's running
/// process is worse than any deletion this file could commit. Terminals fall
/// back to the trust path below.

interface PendingInsertion {
  text: string;
  /// Which window it went into, so a switch away invalidates it.
  identity: string | null;
  /// The process name, for the terminal check.
  process: string | null;
  at: number;
}

/// How long an insertion stays deletable when nothing can confirm it is still
/// there.
///
/// Only the unverified path uses it. A field that answers is checked against
/// the actual characters and needs no clock; a field that will not answer is
/// being taken on trust, and trust should not outlive the moment. A minute is
/// far longer than the gesture takes — you say a sentence, you see it is wrong,
/// you take it back — and far shorter than the time in which a document can
/// quietly become something else.
export const UNVERIFIED_WINDOW_MS = 60_000;

/// The longest insertion this will try to verify by reselecting.
///
/// Reselecting is one Shift+Left per character, and each keystroke is a real
/// event the focused app has to process. Three hundred keeps the worst case
/// around a third of a second; beyond that the trust path takes over, which is
/// the same trade the transform engine makes for the same reason.
export const MAXIMUM_VERIFY_CHARACTERS = 300;

export class InsertionUndo {
  private pending: PendingInsertion | null = null;

  constructor(private readonly windows: WindowWatcher | null = null) {}

  /// Whether there is an insertion the chord could take back.
  get isArmed(): boolean { return this.pending !== null; }

  get pendingText(): string | null { return this.pending?.text ?? null; }

  /// Called once an insertion has actually landed. Reads the destination now,
  /// not at delete time, for the same reason the live typer captures its target
  /// at `begin`: the app the words went into is the app that was focused when
  /// they went in.
  record(text: string): void {
    if (text.length === 0) {
      this.pending = null;
      return;
    }
    const active = this.windows?.active ?? null;
    this.pending = {
      text,
      identity: active?.identity ?? null,
      process: active?.process ?? null,
      at: Date.now(),
    };
  }

  /// Deliberately blunt. This is called from the keyboard hook on every real
  /// keystroke, from the mouse hook on every click, on every window change and
  /// at the start of every dictation, and in each case the cheapest correct
  /// answer is to stop believing the record rather than to reason about whether
  /// that particular event could have moved the caret.
  discard(reason = 'unspecified'): void {
    if (this.pending !== null && process.env.QUILL_LOG_UNDO === '1') {
      // eslint-disable-next-line no-console
      console.log(`[quill] undo record DISCARDED — ${reason}`);
    }
    this.pending = null;
  }

  /// Take the last insertion back.
  ///
  /// Returns whether the text was actually removed, and a reason when it was
  /// not — the HUD says it out loud rather than leaving the user to guess
  /// whether the chord did anything, which is the failure mode this whole path
  /// is prone to.
  async undoLastInsertion(): Promise<{ removed: boolean; reason: string | null }> {
    const record = this.pending;
    // Consumed either way. One chord, one attempt — a second press must not try
    // again against a field we have just failed to recognise.
    this.pending = null;

    if (!record) {
      return { removed: false, reason: 'There is nothing to take back.' };
    }
    if (!keyboardIsAvailable()) {
      return { removed: false, reason: 'Quill cannot synthesise keystrokes on this machine.' };
    }

    const active = this.windows?.active ?? null;
    // The record is dropped on window changes, but a change in the gap between
    // the accelerator firing and this line has not been seen yet.
    if (record.identity !== null && active !== null && active.identity !== record.identity) {
      return { removed: false, reason: 'You have moved to a different window since then.' };
    }

    const length = graphemeCount(record.text);
    const isTerminal = appContextOf(record.process) === 'terminal';
    const canVerify = !isTerminal && length <= MAXIMUM_VERIFY_CHARACTERS;

    if (canVerify) {
      const verdict = await this.verifyAndSelect(record.text, length);
      if (verdict === 'verified') {
        // The text is selected, so one Backspace removes exactly it.
        await postBackspaces(1);
        return { removed: true, reason: null };
      }
      if (verdict === 'selection') {
        return {
          removed: false,
          reason: 'Something is selected there — the delete would have eaten that instead.',
        };
      }
      return {
        removed: false,
        reason: 'What Quill inserted is not behind your cursor any more, so nothing was deleted.',
      };
    }

    // The trust path. Nothing can read this field back, so what is left to go on
    // is the record still being armed — which is not nothing: every keystroke,
    // every click, every window change and the start of every dictation all
    // throw it away. The gap those cannot see is an app that rewrites its own
    // text with no input, so there is also a clock.
    if (Date.now() - record.at > UNVERIFIED_WINDOW_MS) {
      return {
        removed: false,
        reason: 'That was more than a minute ago, and Quill cannot check it is still there.',
      };
    }
    await postBackspaces(length);
    return { removed: true, reason: null };
  }

  /// Selects the last `length` characters and reads them back.
  ///
  /// Leaves the selection in place on success, so the caller can delete it with
  /// one keystroke rather than `length` of them. Collapses it on every failure
  /// path, because leaving somebody's paragraph highlighted after a chord that
  /// did nothing is its own small betrayal.
  private async verifyAndSelect(text: string, length: number): Promise<'verified' | 'selection' | 'mismatch'> {
    const before = captureClipboard();
    const restore = (): void => {
      if (snapshotIsFaithful(before)) restoreClipboard(before);
    };

    // A live selection would be eaten by the delete instead of our text. There
    // is no API that reports one, so it is probed: put a sentinel on the
    // clipboard and copy. With nothing selected, a copy leaves the clipboard
    // alone in every app tested; with something selected, the sentinel is
    // replaced.
    const sentinel = ` quill-probe-${Date.now()}`;
    if (!writeClipboard(sentinel)) { restore(); return 'mismatch'; }
    postCopy();
    await delay(40);
    if (readClipboardText() !== sentinel) {
      restore();
      return 'selection';
    }

    if (!await postShiftLeft(length)) { collapseSelection(); restore(); return 'mismatch'; }
    postCopy();
    await delay(60);
    const selected = readClipboardText();
    restore();

    if (selected === text) return 'verified';
    collapseSelection();
    return 'mismatch';
  }

  /// The keys this needs, exposed so `main` can tell the hook what to ignore.
  static probeKeys(): number[] {
    const table = codes();
    return [table.c, table.left, table.right, table.backspace];
  }
}

export { postChord };
