import {
  captureClipboard, restoreClipboard, restoreIsSafe, snapshotIsFaithful,
  writeClipboard, readClipboardText,
} from './clipboardSnapshot';
import { keyboardIsAvailable, postPaste, delay } from '../platform/keyboard';

/// What happened to a piece of text on its way into the focused app.
export type InsertionResult =
  | { kind: 'inserted' }
  /// Could not type into the focused app; text was put on the clipboard so the
  /// user does not lose it. Never fail silently.
  | { kind: 'fellBackToClipboard'; reason: string }
  | { kind: 'failed'; reason: string };

export interface TextInserting {
  insert(text: string): Promise<InsertionResult>;
}

/// Puts transcribed text into whatever app has focus.
///
/// One rule outranks every other decision in this file: **the text must never
/// vanish**. A dictation app that loses a sentence is worse than one that never
/// inserted it, because the user finds out later, somewhere else, with nothing
/// to blame. So every failure path here ends with the text on the clipboard and
/// a reason a human can read.
///
/// # Why paste, on every platform
///
/// On macOS the choice was between a synthetic ⌘V and the Accessibility API,
/// and AX lost: in Electron apps — VS Code, Slack, Discord, a large share of
/// where dictation actually gets used — it returns success and then inserts at
/// the wrong offset, or replaces the whole field. A silent wrong answer is the
/// worst failure shape available.
///
/// Here the choice is narrower still, and it is worth saying why rather than
/// leaving it as an implementation detail. Windows has `SendInput` with a
/// `KEYEVENTF_UNICODE` flag that can type arbitrary text; X11 has `XTEST`;
/// Wayland has neither without a compositor protocol. None of the three is
/// reachable from Node without a native module built for the exact machine in
/// front of the user, and this app deliberately ships without one it cannot
/// guarantee. Clipboard-and-paste needs one keystroke, works in every text
/// field on all three platforms, and was already the primary path.
///
/// The cost is real and is stated on the Help screen: for the ~250 ms between
/// the write and the restore, the user's clipboard holds the dictation. A
/// clipboard manager will record it. That is the trade.
export class TextInserter implements TextInserting {
  /// How long our text sits on the clipboard before the user's own contents go
  /// back. See `scheduleRestore` for why this number cannot be made correct.
  restoreDelayMs = 250;

  async insert(text: string): Promise<InsertionResult> {
    if (text.length === 0) {
      return { kind: 'failed', reason: 'There was nothing to insert.' };
    }
    const blocked = this.blockingReason();
    if (blocked) return this.park(text, blocked);
    return this.insertByPasting(text);
  }

  /// The state that turns every synthetic keystroke into a no-op.
  ///
  /// On macOS this also covered Secure Input, which silently discards
  /// synthetic events. There is no equivalent flag to read on Windows or Linux
  /// — a UAC-elevated window on Windows will simply ignore events posted by a
  /// non-elevated process, with no error and nothing to detect. That case is
  /// therefore handled after the fact rather than before it: the text is on the
  /// clipboard either way, and the HUD says so.
  private blockingReason(): string | null {
    if (!keyboardIsAvailable()) {
      return 'Quill cannot synthesise keystrokes on this machine, because the '
        + 'input library did not install.';
    }
    return null;
  }

  private async insertByPasting(text: string): Promise<InsertionResult> {
    const previous = captureClipboard();

    if (!snapshotIsFaithful(previous)) {
      // The clipboard holds something we could not copy out — a file promise, a
      // custom application format. Pasting means clearing it, and we would have
      // nothing to put back.
      return this.park(text,
        'Your clipboard holds something Quill cannot copy out and put back, so it '
        + 'did not touch it.');
    }

    if (!writeClipboard(text)) {
      // Another process is holding the clipboard, or the write did not stick.
      // Put the user's contents back before walking away: losing someone's
      // clipboard as a side effect of a dictation that then failed is a bad
      // trade for them and an invisible one for us.
      restoreClipboard(previous);
      return {
        kind: 'failed',
        reason: 'Quill could not put the text on the clipboard, so it has not been inserted.',
      };
    }

    if (!postPaste()) {
      // Our text is already on the clipboard, and it stays there: restoring the
      // old contents to be tidy would trade away the only copy of what the user
      // just said.
      return {
        kind: 'fellBackToClipboard',
        reason: `Quill could not synthesise ${pasteChordName()}. The text is on your clipboard.`,
      };
    }

    this.scheduleRestore(previous, text);

    // Optimistic, and openly so. The platform reports that the event was
    // posted, never that the focused app consumed it. Confirming would mean
    // reading the target's contents back, and a retry on a false negative
    // inserts the sentence twice.
    return { kind: 'inserted' };
  }

  /// Leaves the text on the clipboard and says why.
  ///
  /// Deliberately does not restore anything: at this point the clipboard holds
  /// the only copy of the dictation, and the user has been told to paste it.
  private park(text: string, reason: string): InsertionResult {
    if (!writeClipboard(text)) {
      // Everything failed, including the fallback. Say that plainly rather than
      // reporting a clipboard the user will trust and find empty.
      return {
        kind: 'failed',
        reason: `${reason} Writing it to the clipboard also failed, so the text is gone.`,
      };
    }
    return {
      kind: 'fellBackToClipboard',
      reason: `${reason} The text is on your clipboard — press ${pasteChordName()}.`,
    };
  }

  private scheduleRestore(previous: ReturnType<typeof captureClipboard>, ourText: string): void {
    void (async () => {
      // Honest about the race, because it cannot be closed: no app tells you it
      // has finished reading the clipboard. The delay is a guess. Too short and
      // a busy machine, or an app that reads the clipboard lazily, pastes the
      // user's *old* clipboard instead of their dictation. Too long and their
      // clipboard is wrong for longer than they expect.
      await delay(this.restoreDelayMs);
      if (!restoreIsSafe(ourText, readClipboardText())) return;
      restoreClipboard(previous);
    })();
  }
}

export function pasteChordName(): string {
  return process.platform === 'darwin' ? '⌘V' : 'Ctrl+V';
}
