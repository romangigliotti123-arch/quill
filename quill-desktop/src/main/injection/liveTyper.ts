import { graphemeCount } from '../../core/text/strings';
import { smallestEdit } from '../../core/text/edit';
import {
  captureClipboard, restoreClipboard, restoreIsSafe, snapshotIsFaithful, writeClipboard,
  readClipboardText, type ClipboardSnapshot,
} from './clipboardSnapshot';
import { keyboardIsAvailable, postBackspaces, postPaste, delay } from '../platform/keyboard';
import type { WindowWatcher } from '../platform/windowWatcher';
import type { InsertionResult } from './textInserter';

/// Types words into the focused app while you are still speaking, and keeps
/// them honest as the recogniser changes its mind.
///
/// The whole design rests on one fact: the transcriber hands back the *entire*
/// best-so-far text on every update, not a delta, and it freely revises words
/// it already gave you. So this cannot simply append. It keeps a record of what
/// it believes is on screen, and on each update finds the longest prefix the
/// two still agree on, deletes back to it, and types the rest. In practice the
/// agreement point is near the end and the edit is a couple of characters — the
/// expensive case is a mid-sentence revision, which is exactly the case where
/// appending would have been wrong.
///
/// What it deliberately does not do is verify. There is no API that reports
/// what the focused app actually did with a synthetic keystroke, so `typed` is
/// a belief, not a reading. Everything below is built so that a wrong belief is
/// recoverable rather than destructive: it never deletes more than it typed, it
/// stops the moment focus moves, and it refuses to start at all when the
/// conditions that silently swallow keystrokes are present.
///
/// # The one thing that is genuinely different from the macOS build
///
/// There, an insertion was `CGEvent.keyboardSetUnicodeString` — arbitrary text,
/// no clipboard involved, a few microseconds. Here it is a clipboard write and
/// a synthetic paste, because that is what is reachable without a native module
/// on all three platforms (see `textInserter` for the full argument).
///
/// Two consequences follow, and both are handled rather than hidden:
///
///  1. **The update rate has to come down.** macOS ran at ~15 updates a second.
///     A clipboard write plus a paste is an order of magnitude more expensive,
///     so this runs at ~5, which is still faster than anyone reads.
///  2. **The user's clipboard is held for the whole dictation, not 250 ms.** It
///     is captured once at `begin`, kept aside, and put back at `finish` or
///     `retract`. Restoring between partials would mean twice as many clipboard
///     writes for no benefit, and would guarantee that the *next* partial's
///     paste raced the restore.
export class LiveTyper {
  /// Minimum gap between screen updates.
  ///
  /// Partials arrive faster than anyone can read, and every one of them costs
  /// real keystrokes in someone else's app.
  minimumIntervalMs = process.platform === 'darwin' ? 120 : 200;

  /// What we believe is on screen in the target app.
  private typedText = '';

  /// Which dictation owns the belief in `typed`.
  ///
  /// `begin()` used to reset the state with no identity attached, so a second
  /// dictation started while the first was still finalising silently overwrote
  /// the state that first one's pending `finish()` still depended on. When it
  /// resumed, its guards all passed — same app, same field, freshly captured by
  /// the NEW session — and it computed its edit from the new session's state.
  /// With nothing typed yet that is a clean insertion of the previous sentence
  /// into the middle of the one being spoken.
  ///
  /// A token makes that physically impossible rather than merely unlikely.
  private generationCounter = 0;

  /// Set when focus moved away mid-dictation. From then on this types nothing
  /// and deletes nothing — see `focusHeld` for why that is the only safe move.
  private abandoned = false;

  private targetIdentity: string | null = null;
  private lastUpdate = 0;
  private pendingText: string | null = null;
  private pendingTimer: NodeJS.Timeout | null = null;
  private clipboardBefore: ClipboardSnapshot | null = null;
  private lastPasted = '';
  /// Serialises the posting path. Two overlapping `apply` calls would interleave
  /// backspaces and pastes, which is not something a diff can recover from.
  private busy: Promise<void> = Promise.resolve();

  constructor(private readonly windows: WindowWatcher | null = null) {}

  get typed(): string { return this.typedText; }
  get generation(): number { return this.generationCounter; }
  get isAbandoned(): boolean { return this.abandoned; }
  /// Whether anything is on screen that this dictation put there.
  get hasTypedAnything(): boolean { return this.typedText.length > 0; }

  /// Returns false when live typing cannot work, in which case the caller
  /// should use the ordinary paste-on-release path.
  begin(): { ok: boolean; generation: number } {
    this.cancelPending();
    this.generationCounter += 1;
    this.typedText = '';
    this.abandoned = false;
    this.lastUpdate = 0;
    this.lastPasted = '';
    this.clipboardBefore = null;

    if (!keyboardIsAvailable()) {
      this.targetIdentity = null;
      return { ok: false, generation: this.generationCounter };
    }
    const snapshot = captureClipboard();
    if (!snapshotIsFaithful(snapshot)) {
      // The clipboard holds something we cannot put back. Live typing would
      // destroy it; the release-and-paste path notices the same thing and parks
      // the text instead.
      this.targetIdentity = null;
      return { ok: false, generation: this.generationCounter };
    }
    this.clipboardBefore = snapshot;
    this.targetIdentity = this.windows?.active?.identity ?? null;
    // A null identity is "this platform cannot tell", not "there is no target".
    // Live typing still runs; `focusHeld` degrades to always-true, exactly as
    // the macOS build did when the Accessibility API declined to answer.
    return { ok: true, generation: this.generationCounter };
  }

  /// Throttled. Safe to call on every partial.
  update(text: string, token: number): void {
    if (token !== this.generationCounter) return;
    if (this.abandoned) return;
    const now = Date.now();
    if (now - this.lastUpdate >= this.minimumIntervalMs) {
      this.cancelPending();
      this.enqueue(text, false);
      return;
    }
    // Schedule the tail rather than dropping it. Dropping is fine while speech
    // continues — the next partial carries the same text — but the last partial
    // before a pause has nothing behind it, and dropping that one is precisely
    // the "it only appears when I stop" behaviour this exists to fix.
    this.pendingText = text;
    if (this.pendingTimer) return;
    this.pendingTimer = setTimeout(() => {
      this.pendingTimer = null;
      const queued = this.pendingText;
      this.pendingText = null;
      if (queued !== null) this.enqueue(queued, false);
    }, this.minimumIntervalMs - (now - this.lastUpdate));
  }

  /// Unthrottled, for the final text. Returns what the caller should report.
  async finish(text: string, token: number): Promise<InsertionResult> {
    // The fence. A dictation that was superseded while it was finalising must
    // not type its sentence into the one that replaced it.
    if (token !== this.generationCounter) {
      return { kind: 'failed', reason: 'A newer dictation took over before this one finished.' };
    }
    this.cancelPending();
    if (this.abandoned) {
      await this.restoreClipboardIfOurs();
      return { kind: 'failed', reason: 'Focus moved while Quill was still typing.' };
    }
    if (!this.focusHeld()) {
      this.abandoned = true;
      await this.restoreClipboardIfOurs();
      return { kind: 'failed', reason: 'Focus moved while Quill was still typing.' };
    }
    await this.enqueue(text, true);
    await this.restoreClipboardIfOurs();
    // Report what actually happened, not what was attempted.
    //
    // This returned `inserted` unconditionally once, so an apply that aborted
    // mid-edit — after the backspaces had already gone out — still told the
    // coordinator the text was on screen. The paste fallback then never fired,
    // and the user was left with a hole where their sentence had been and
    // nothing on the clipboard to put back.
    if (this.abandoned || this.typedText !== text) {
      return { kind: 'failed', reason: 'Live typing stopped before the text was complete.' };
    }
    return { kind: 'inserted' };
  }

  /// Takes back everything typed during this dictation. For Escape, and for a
  /// transcript that turned out to be empty.
  ///
  /// `restoring` is text that arrived AFTER ours and is not ours to delete —
  /// the keystroke that cancelled the dictation, when it was passed through to
  /// the app rather than swallowed.
  ///
  /// That text is deleted and retyped rather than spared, because it cannot be
  /// spared. Backspaces delete from the caret backwards and the user's
  /// character is the last thing on screen, so deleting one fewer than we typed
  /// removes THEIR character first and leaves one of OURS behind.
  ///
  /// On this platform "retyped" means pasted, so a cancelling keystroke that
  /// produced a character comes back through the clipboard like everything
  /// else. A cancelling key that produced NO character — Escape, an arrow —
  /// costs nothing, and that is the overwhelmingly common case.
  async retract(token: number, restoring = ''): Promise<void> {
    if (token !== this.generationCounter) return;
    this.cancelPending();
    if (this.abandoned || this.typedText.length === 0 || !this.focusHeld()) {
      this.typedText = '';
      await this.restoreClipboardIfOurs();
      return;
    }
    const ours = graphemeCount(this.typedText);
    this.typedText = '';
    await this.run(async () => {
      await postBackspaces(ours + graphemeCount(restoring));
      if (restoring.length > 0) await this.paste(restoring);
    });
    await this.restoreClipboardIfOurs();
  }

  async reset(): Promise<void> {
    this.cancelPending();
    this.typedText = '';
    this.abandoned = false;
    this.targetIdentity = null;
    await this.restoreClipboardIfOurs();
  }

  // MARK: - The diff

  /// Re-exported so callers and tests have one name for it. The rule itself
  /// lives in `core/text/edit.ts`, which imports no Electron and can therefore
  /// be driven from a plain `node --test`.
  static edit = smallestEdit;

  private enqueue(text: string, force: boolean): Promise<void> {
    return this.run(() => this.apply(text, force));
  }

  private run(work: () => Promise<void>): Promise<void> {
    this.busy = this.busy.then(work, work);
    return this.busy;
  }

  private async apply(text: string, force: boolean): Promise<void> {
    if (this.abandoned) return;
    if (!this.focusHeld()) {
      // Everything already typed stays where it is, and nothing more is typed
      // or deleted.
      //
      // Deleting would be worse than useless: the backspaces would land in
      // whatever the user switched to and eat *their* text, which is the one
      // outcome a dictation app must never produce. Continuing to type would
      // scatter half a sentence across two apps. So this stops, the caller
      // falls back to pasting the whole thing into wherever focus now is, and
      // the user is left with a duplicate rather than a deletion.
      this.abandoned = true;
      return;
    }
    if (!force && text === this.typedText) return;

    const edit = smallestEdit(this.typedText, text);

    if (edit.deletions > 0) {
      if (!await postBackspaces(edit.deletions)) { this.abandoned = true; return; }
    }
    if (edit.insertion.length > 0) {
      if (!await this.paste(edit.insertion)) { this.abandoned = true; return; }
    }

    this.typedText = text;
    this.lastUpdate = Date.now();
  }

  /// One clipboard write and one paste.
  ///
  /// The clipboard is left holding our fragment on purpose — see the note on
  /// the class. `lastPasted` records what we put there so the restore at the
  /// end can tell "still ours, safe to put the user's back" from "the user
  /// copied something during the dictation, leave it alone".
  private async paste(fragment: string): Promise<boolean> {
    if (!writeClipboard(fragment)) return false;
    this.lastPasted = fragment;
    if (!postPaste()) return false;
    // A short settle before the next edit. The paste is asynchronous inside the
    // target app, and a backspace that overtakes it deletes the wrong thing.
    await delay(12);
    return true;
  }

  private async restoreClipboardIfOurs(): Promise<void> {
    const before = this.clipboardBefore;
    this.clipboardBefore = null;
    if (!before) return;
    if (this.lastPasted.length === 0) return;
    // Give the target a moment to finish reading before taking it back.
    await delay(60);
    if (!restoreIsSafe(this.lastPasted, readClipboardText())) return;
    restoreClipboard(before);
  }

  /// Whether the text is still going where it was going.
  ///
  /// When the platform cannot answer — a Wayland compositor with no focus
  /// protocol, a Linux box without xprop — this returns true rather than
  /// abandoning a perfectly good dictation. The failure mode of being too
  /// strict is losing text; of being too loose, a duplicate the user can see
  /// and delete. That is the same trade the macOS build made when the
  /// Accessibility API declined to answer, and it is the right way round.
  private focusHeld(): boolean {
    if (this.targetIdentity === null) return true;
    const now = this.windows?.active?.identity ?? null;
    if (now === null) return true;
    return now === this.targetIdentity;
  }

  private cancelPending(): void {
    if (this.pendingTimer) clearTimeout(this.pendingTimer);
    this.pendingTimer = null;
    this.pendingText = null;
  }
}
