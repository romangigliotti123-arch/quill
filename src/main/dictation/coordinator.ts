import {
  DictationTimeline, OverlayPresenting, Transcriber, TranscriberDelegate, Transcript,
} from '../../core/contracts';
import type { TranscriptCleaning } from '../../core/cleanup/fastCleaner';
import { AppContext, appContextOf, applyAppContext } from '../../core/cleanup/appContext';
import { withDeadline, RECOMMENDED_CLEANUP_DEADLINE_MS } from '../../core/ai/nimClient';
import { HistoryStore, isLoopbackDevice, type DictationRecord } from '../../core/stores/history';
import { SnippetStore } from '../../core/stores/snippets';
import { QuillSettings } from '../../core/settings';
import { uuid } from '../../core/stores/storeFile';
import { wordCount, trim } from '../../core/text/strings';
import type { HotkeyDelegate, HotkeyEngine } from '../hotkey/hotkeyEngine';
import type { InsertionResult, TextInserting } from '../injection/textInserter';
import { LiveTyper } from '../injection/liveTyper';
import type { InsertionUndo } from '../injection/insertionUndo';
import { writeClipboard } from '../injection/clipboardSnapshot';
import type { WindowWatcher } from '../platform/windowWatcher';
import type { CommandRouter } from '../../core/transforms/commandRouter';
import type { TransformEngine } from '../transforms/transformEngine';
import { TransformStore } from '../../core/transforms/transforms';

/// One dictation, start to finish: key down, listen, transcribe, clean, insert.
///
/// Deliberately narrow. It owns the lifecycle and delegates the rest; anything
/// that is not "what happens between key-down and text-inserted" belongs
/// somewhere else.

export interface CoordinatorOptions {
  hotkey: HotkeyEngine;
  transcriber: Transcriber;
  inserter: TextInserting;
  overlay: OverlayPresenting;
  cleaner: TranscriptCleaning;
  history?: HistoryStore;
  snippets?: SnippetStore;
  settings?: QuillSettings;
  liveTyper?: LiveTyper;
  undo?: InsertionUndo | null;
  windows?: WindowWatcher | null;
  /// Turns a finished utterance into a transform, or leaves it as content.
  /// Null means the feature is off and every utterance is content.
  transforms?: { router: CommandRouter; engine: TransformEngine } | null;
  /// How the destination is decided, injected so it can be pinned.
  ///
  /// Reading the focused window is process-wide state that a unit test does not
  /// own. Three tests of the dictation path once started passing or failing
  /// depending on which window happened to be focused on the machine running
  /// them. A test whose result depends on where the mouse was last clicked is
  /// not a test.
  context?: () => AppContext;
}

export interface LastDictation {
  text: string;
  insertedAt: number;
}

/// How long the key can be down and still count as a tap rather than an
/// utterance.
///
/// 400ms. The shortest real dictation in the corpus is "On my way." at 855ms,
/// and the shortest thing anyone can say and mean is a good deal longer than a
/// key bounce.
export const TAP_DURATION_SECONDS = 0.4;

/// Below this the input is not quiet, it is not connected to anything.
///
/// Ordinary room tone on a built-in microphone sits around 0.01–0.03 even with
/// nobody speaking; a loopback device with no app playing into it returns exact
/// zeros. The floor is set under the quietest real room and well above digital
/// silence, so the specific message only appears when the device genuinely
/// delivered nothing.
export const SILENCE_FLOOR = 0.005;

/// The whole change-of-mind decision, as a function of three numbers.
///
/// Pulled out so it can be tested without a clock. The integration version of
/// this test passed alone and failed in the suite, because the press and the
/// release are wall-clock timestamps and the gap between them grows when the
/// machine is busy. A flaky test is worse than no test; a pure one asks the
/// same question and always gets the same answer.
export function isChangeOfMind(heldFor: number, sawLevels: boolean, peak: number): boolean {
  return sawLevels && peak < SILENCE_FLOOR && heldFor < TAP_DURATION_SECONDS;
}

export class DictationCoordinator implements HotkeyDelegate, TranscriberDelegate {
  private readonly hotkey: HotkeyEngine;
  private readonly transcriber: Transcriber;
  private readonly inserter: TextInserting;
  private readonly overlay: OverlayPresenting;
  private readonly cleaner: TranscriptCleaning;
  private readonly history: HistoryStore;
  private readonly snippets: SnippetStore;
  private readonly settings: QuillSettings;
  private readonly liveTyper: LiveTyper;
  private readonly undo: InsertionUndo | null;
  private readonly windows: WindowWatcher | null;
  private readonly transforms: { router: CommandRouter; engine: TransformEngine } | null;
  private readonly context: () => AppContext;

  /// Loudest input level seen during the current dictation.
  private peakLevel = 0;
  /// Whether ANY level arrived, as distinct from levels that were all silent.
  ///
  /// The difference decides whether a quick tap is binned. A peak of zero can
  /// mean the microphone heard nothing — bin it — or that no buffer ever
  /// reached us, which is a different failure and one the user needs told
  /// about.
  private sawLevels = false;
  private timeline = new DictationTimeline();
  private isDictating = false;
  /// Capturing, but not yet committed: the key is down and the gesture has not
  /// resolved. Audio recorded in this window is kept if the gesture becomes a
  /// dictation and thrown away if it does not.
  private isSpeculating = false;
  /// True from the moment a dictation stops recording until its text has landed.
  ///
  /// A dictation started while another is still finishing does not live-type at
  /// all — it falls back to paste-on-release, which lands in one piece after
  /// the older one is done. Two sentences interleaving character by character
  /// in somebody's document is not something a fence can tidy up afterwards.
  private isFinalising = false;
  private isLive = false;
  private liveGeneration = 0;
  private capturedInputDevice: string | null = null;
  /// Where the words are going, decided at key-down.
  ///
  /// Captured with the focus rather than read at insertion time: the app you
  /// were in when you started speaking is the one you meant, and formatting
  /// decided against whatever happens to be frontmost a second later would be
  /// formatting for an app the user never chose.
  private capturedContext: AppContext = 'prose';
  private capturedProcess: string | null = null;
  /// Guards against a late result from a previous dictation landing in this one.
  private sessionID = 0;
  /// Which CONFIRMED dictation owns the caret, as distinct from which capture
  /// session is installed.
  ///
  /// `sessionID` moves on every speculative key-down, because that is what the
  /// transcriber's start/stop has to be fenced against. Fencing the INSERTION
  /// on it too meant that any abandoned gesture — a stray isolated tap, a chord
  /// that arms and aborts — superseded a dictation that was still finalising
  /// and pushed its sentence to the clipboard instead of into the document.
  ///
  /// The shape that made this routine: hands-free is taught as a double-tap and
  /// nothing says stopping is a single tap, so people double-tap to stop. Tap
  /// one stops it and starts the finalise; tap two, 150 ms later, opens a
  /// speculation — enough to invalidate the sentence they were in the middle of
  /// dictating. They get "You started again before that finished", for a
  /// gesture they made to STOP.
  private insertionEpoch = 0;
  /// The microphone disappeared during this dictation.
  private inputLost = false;

  /// What Quill last inserted, so "make that shorter" has something to act on.
  lastInsertion: LastDictation | null = null;
  /// Told to the UI so the dashboard can show what is happening.
  onActivity: ((activity: 'idle' | 'listening' | 'transcribing') => void) | null = null;

  constructor(options: CoordinatorOptions) {
    this.hotkey = options.hotkey;
    this.transcriber = options.transcriber;
    this.inserter = options.inserter;
    this.overlay = options.overlay;
    this.cleaner = options.cleaner;
    this.history = options.history ?? HistoryStore.shared();
    this.snippets = options.snippets ?? SnippetStore.shared();
    this.settings = options.settings ?? QuillSettings.instance();
    this.windows = options.windows ?? null;
    this.liveTyper = options.liveTyper ?? new LiveTyper(this.windows);
    this.undo = options.undo ?? null;
    this.transforms = options.transforms ?? null;
    this.context = options.context
      ?? (() => appContextOf(this.windows?.active?.process ?? null));
    this.hotkey.delegate = this;
    this.transcriber.delegate = this;
  }

  start(): boolean { return this.hotkey.start(); }

  // MARK: - Hotkey delegate

  hotkeyMayBegin(): void { this.speculativelyBegin(); }
  hotkeyAborted(): void { this.abandonSpeculation(); }
  hotkeyPressed(): void { this.beginDictation(); }
  hotkeyReleased(): void { void this.endDictation(); }
  hotkeyCancelled(userKeystroke: string): void { void this.cancelDictation(userKeystroke); }
  hotkeyDisturbance(reason: string): void { this.undo?.discard(reason); }
  hotkeyEngineUnavailable(reason: string): void {
    this.overlay.show({ kind: 'error', message: reason });
  }

  // MARK: - Transcriber delegate

  didHearLevel(level: number): void {
    // The first level is the first buffer off the microphone, so this is where
    // audio actually began. Stamped before the isDictating guard: audio starts
    // during speculation, which is the whole point of speculation.
    if (this.timeline.audioFirstBuffer === null && (this.isDictating || this.isSpeculating)) {
      this.timeline.audioFirstBuffer = Date.now();
    }
    this.sawLevels = true;
    // Told to the hotkey engine, not just kept here. It is what lets the undo
    // chord tell a reach from a dictation: the gesture machine says holding
    // 130 ms after the trigger goes down whether or not the user is speaking,
    // and only the audio knows which.
    if (level >= SILENCE_FLOOR) this.hotkey.noteSpeechHeard();
    this.peakLevel = Math.max(this.peakLevel, level);
    // The moment speech actually starts, as distinct from the moment the
    // microphone opened. Uses the same floor that decides "that device sent no
    // sound at all", so the two cannot disagree about what counts as audible.
    if (this.timeline.firstAudibleBuffer === null
      && level >= SILENCE_FLOOR
      && (this.isDictating || this.isSpeculating)) {
      this.timeline.firstAudibleBuffer = Date.now();
    }
    if (!this.isDictating) return;
    this.overlay.show({ kind: 'listening', level });
  }

  didProduce(transcript: Transcript): void {
    if (this.timeline.firstPartial === null && transcript.text.length > 0) {
      this.timeline.firstPartial = Date.now();
    }
    if (!this.isLive || !this.isDictating) return;
    // Cleaned, not raw. Typing the raw hypothesis would mean the final pass
    // capitalises the first letter and re-punctuates — a change at character
    // zero, which is a delete-and-retype of the entire sentence at the exact
    // moment the user is waiting for it to finish.
    //
    // Formatted for the destination here too, not only at the end. The live
    // stream and the final text have to agree, or the last edit becomes a
    // visible flicker as a capital letter or a full stop is taken back.
    this.liveTyper.update(
      applyAppContext(
        this.cleaner.cleanFast(transcript.text),
        this.capturedContext,
        this.settings.numberStyle,
      ),
      this.liveGeneration,
    );
    // Here rather than at `beginDictation`: this is the first moment anything
    // is actually at the caret, and until it happens the previous insertion is
    // still the last thing there and still safe to take back.
    if (this.liveTyper.hasTypedAnything) this.undo?.discard('live typing started');
  }

  didFail(error: string): void { this.fail(error); }

  /// The device went away mid-sentence. End the dictation now rather than wait
  /// for a key release that will arrive against a dead microphone.
  ///
  /// Deliberately not `fail`: that tears the session down and shows an error,
  /// which would throw away words the user actually said. Everything heard up
  /// to the disconnect is a real transcript and goes in exactly as it would
  /// have — the only thing that changes is that the user is told why it stops
  /// where it does.
  didLoseInput(): void {
    if (!this.isDictating) {
      // Still speculating: nothing has been shown and nothing was said, so
      // there is nothing to tell anyone about. Bin it quietly.
      this.abandonSpeculation();
      return;
    }
    this.inputLost = true;
    void this.endDictation();
  }

  // MARK: - Lifecycle

  /// Called the instant the key goes down. Everything expensive happens here —
  /// model warm-up and opening the microphone — because by the time the gesture
  /// has been recognised, whatever was said in the meantime is already gone.
  private speculativelyBegin(): void {
    if (this.isDictating || this.isSpeculating) return;
    this.isSpeculating = true;
    this.sessionID += 1;
    const session = this.sessionID;

    this.timeline = new DictationTimeline();
    // The honest start of the dictation, not the moment we worked out it was one.
    this.timeline.hotkeyDown = Date.now();
    this.capturedInputDevice = this.settings.current.inputDeviceLabel;
    // Per dictation, not per launch: last time's loud sentence must not vouch
    // for this time's dead microphone.
    this.peakLevel = 0;
    this.sawLevels = false;
    this.inputLost = false;

    void (async () => {
      await this.transcriber.prepare();
      if (session !== this.sessionID) return;
      if (!this.isSpeculating && !this.isDictating) return;
      try {
        await this.transcriber.start();
      } catch (error) {
        this.fail(`Could not start listening: ${String(error)}`);
      }
    })();
  }

  /// The gesture was a chord or a stray tap. Bin the audio without a trace — no
  /// overlay was ever shown, so nothing needs undoing on screen.
  private abandonSpeculation(): void {
    if (!this.isSpeculating || this.isDictating) return;
    this.isSpeculating = false;
    this.sessionID += 1;
    void this.transcriber.cancel();
  }

  /// The gesture is confirmed as dictation. Audio has been recording since
  /// key-down, so there is nothing to start here — only something to show.
  private beginDictation(): void {
    if (this.isDictating) return;

    if (!this.isSpeculating) {
      // Defensive: a confirmation with no speculation behind it. Start now and
      // accept the lost milliseconds rather than record nothing at all.
      //
      // BEFORE `isDictating = true`, which is the whole of it. This ran after
      // once, and `speculativelyBegin`'s first guard is `!isDictating` — so the
      // recovery this comment describes could never have run. The path is real:
      // the speculation's `start()` throws (the chosen microphone was
      // unplugged, a headset changed profile), `fail()` clears
      // `isSpeculating`, and 120 ms later the arm timer confirms the gesture.
      // The user then speaks a paragraph into a coordinator that believes it is
      // dictating and has no capture session at all.
      this.speculativelyBegin();
    }
    this.isDictating = true;
    this.inputLost = false;
    this.isSpeculating = false;
    // Here and nowhere else on the way in: this is the moment a gesture stops
    // being speculative and becomes something that will write to the caret.
    this.insertionEpoch += 1;
    // Decided here, once, rather than per partial: the focused app is whatever
    // the user was in when they pressed the key, and it is the only window it
    // is ever safe to type into during this dictation.
    this.capturedContext = this.context();
    this.capturedProcess = this.windows?.active?.process ?? null;
    // The undo record is NOT thrown away here.
    //
    // It used to be, on the reasoning that live typing is about to write into
    // the same field — true, but not yet true at this instant, and this instant
    // is 120 ms after the trigger went down. It is discarded the moment text
    // actually lands instead — the first live-typed character, or the insert
    // path, which either replaces the record with the new sentence or discards
    // it.
    //
    // Not while the previous dictation is still landing its text. This one
    // pastes on release instead, which arrives whole rather than interleaved.
    const live = this.liveTyper.begin();
    this.liveGeneration = live.generation;
    this.isLive = this.settings.liveText && live.ok && !this.isFinalising;
    this.overlay.show({ kind: 'listening', level: 0 });
    this.onActivity?.('listening');
  }

  private async endDictation(): Promise<void> {
    if (!this.isDictating) return;
    this.isDictating = false;
    this.isSpeculating = false;
    // Stamped first, before anything else in this method can cost time. This is
    // the moment the user stopped talking, and everything after it is latency
    // they sit through.
    this.timeline.hotkeyUp = Date.now();
    const epoch = this.insertionEpoch;

    // A tap, not a dictation.
    //
    // Both halves of the test matter. Short alone would bin a fast "Yes." —
    // measured at 855ms. Silent alone would show the error for a long hold at a
    // dead microphone, which is exactly when the user needs to be told. Only
    // short AND silent is a change of mind, and the right answer to a change of
    // mind is to leave no trace.
    //
    // Not when the microphone was pulled out from under it, though. A short,
    // silent recording is a change of mind when the user made it one and a
    // truncation when the device decided.
    const held = this.timeline.hotkeyDown === null
      ? 0
      : ((this.timeline.hotkeyUp ?? Date.now()) - this.timeline.hotkeyDown) / 1000;
    if (!this.inputLost && isChangeOfMind(held, this.sawLevels, this.peakLevel)) {
      this.sessionID += 1;
      if (this.isLive) await this.liveTyper.retract(this.liveGeneration);
      this.isLive = false;
      this.overlay.hide();
      this.onActivity?.('idle');
      void this.transcriber.cancel();
      return;
    }

    this.overlay.show({ kind: 'transcribing' });
    this.onActivity?.('transcribing');
    this.isFinalising = true;
    try {
      await this.finalise(epoch);
    } finally {
      // Cleared on every exit, including the early returns inside. A flag that
      // leaks true would silently disable live typing for the rest of the
      // session.
      this.isFinalising = false;
      this.onActivity?.('idle');
    }
  }

  private async finalise(epoch: number): Promise<void> {
    const raw = await this.transcriber.stop();

    if (epoch !== this.insertionEpoch) {
      // A newer DICTATION was confirmed while this one was finalising.
      //
      // Not inserting is right: pasting a sentence from thirty seconds ago into
      // whatever the user is typing in NOW is the failure this fence exists to
      // prevent. Throwing the sentence away is not — it was said, it was
      // transcribed, and losing words is the one thing this app may never do.
      const rescued = trim(raw);
      if (rescued.length > 0) {
        const cleaned = this.cleaner.cleanFast(rescued);
        this.history.append(this.record(rescued, '', wordCount(cleaned), {
          finalToInsertedMs: null, releaseToInsertedMs: null, usedThoroughCleanup: false,
        }));
        // Only when there is something to put there. Cleanup can reduce an
        // utterance to nothing — a dictation that was entirely filler — and
        // clearing the clipboard, writing "", and telling the user their words
        // are on it loses whatever they had copied AND gives them nothing back.
        if (cleaned.length > 0) {
          writeClipboard(cleaned);
          this.overlay.show({
            kind: 'error',
            message: 'You started again before that finished — it is on your clipboard.',
          });
          await sleep(1_800);
        }
      }
      // Repaint regardless. An aborted speculation leaves nothing else to clear
      // the HUD, and it would sit on "Transcribing" forever.
      if (!this.isDictating) this.overlay.hide();
      return;
    }

    this.timeline.finalTranscript = Date.now();

    if (trim(raw).length === 0) {
      // Nothing was said, but something may already be on screen: a volatile
      // hypothesis the recogniser later withdrew. Take it back, or the user is
      // left with words they never spoke.
      if (this.isLive) await this.liveTyper.retract(this.liveGeneration);
      this.isLive = false;

      // Say so. This used to hide the overlay and return, which means the user
      // held a key, spoke a sentence, let go, and watched absolutely nothing
      // happen — indistinguishable from the app being broken, from the key not
      // registering, and from the microphone being dead.
      const device = this.capturedInputDevice ?? 'Your microphone';
      if (this.inputLost) {
        this.overlay.show({ kind: 'error', message: `${device} disconnected — nothing was captured.` });
      } else {
        // Two very different failures wear the same face here, and only one of
        // them is the user's to fix. If the microphone delivered buffers that
        // never rose off the floor, the recogniser did not mishear anything —
        // nothing reached it. Telling someone to try again, when trying again
        // cannot work, is worse than saying nothing.
        this.overlay.show({
          kind: 'error',
          message: this.peakLevel < SILENCE_FLOOR
            ? `${device} sent no sound at all. Pick a different microphone in Settings.`
            : 'Nothing was heard — try again, or check the microphone in Settings.',
        });
      }
      await sleep(1_600);
      this.overlay.hide();
      return;
    }

    // Race the thorough pass against the deadline. Whatever is ready wins; the
    // fast pass is always ready.
    const fast = this.cleaner.cleanFast(raw);
    let final = fast;
    let usedThorough = false;

    // What live typing has actually put on screen so far, captured while it is
    // still ours. After the await below, a newer dictation's `begin()` may have
    // reset it — so this is the only moment a superseded session can still find
    // out what it left behind.
    const liveOnScreen = this.isLive ? this.liveTyper.typed : '';

    // One budget, not two.
    //
    // It used to be 250ms unless a self-correction gate said otherwise — but
    // self-correction is not the only pass behind this deadline. Context
    // recovery and homophone repair are gated inside the cleaner on their own
    // conditions, and on those dictations the request went out, was waited on,
    // and was thrown away unread at 250ms: only 11% of calls land inside it.
    // The deadline is an upper bound, and `cleanThorough` returns in
    // microseconds when no gate fires, so a smaller bound buys nothing on the
    // fast path.
    const budget = RECOMMENDED_CLEANUP_DEADLINE_MS;
    const better = await withDeadline(budget, () => this.cleaner.cleanThorough(raw, budget));
    if (better !== null && better !== fast) {
      final = better;
      usedThorough = true;
    }

    // Snippet expansion goes here and nowhere else: after cleanup, so the
    // cleaner never sentence-cases an email address or "repairs" a URL, and
    // before insertion, so nothing is typed and then rewritten inside an app we
    // do not control.
    final = this.snippets.expand(final);

    // Last, because it is the only step that knows where the text is going. A
    // shell command does not want the full stop the cleanup just added.
    final = applyAppContext(final, this.capturedContext, this.settings.numberStyle);

    // The fence, re-checked. The cleanup await above suspends for the whole
    // budget in the overwhelming majority of cases — so by here the user may
    // well have pressed the key again, armed a new dictation and started typing
    // into it. Everything below writes into the CURRENT dictation's world.
    if (epoch !== this.insertionEpoch) {
      // The sentence is not thrown away, but it is NOT re-inserted either, and
      // this is where that differs from the earlier rescue. There, nothing had
      // been typed. Here live typing may already have put a prefix into the
      // document, and the record of how long it was has been destroyed by the
      // newer dictation's `begin()`. So retracting is impossible (backspaces
      // would eat the new session's characters) and offering a clipboard copy
      // would invite the user to paste a third copy of a sentence that is
      // already half on screen.
      const rescued = trim(raw);
      if (rescued.length > 0) {
        this.history.append(this.record(rescued, liveOnScreen, wordCount(final), {
          finalToInsertedMs: null, releaseToInsertedMs: null, usedThoroughCleanup: usedThorough,
        }));
        if (liveOnScreen.length === 0) {
          writeClipboard(final);
          this.overlay.show({
            kind: 'error',
            message: 'You started again before that finished — it is on your clipboard.',
          });
          await sleep(1_800);
        }
      }
      return;
    }

    // Is this something to type, or something to DO?
    //
    // Asked here, after cleanup and before insertion, because the router reads
    // a finished sentence and the transform has to happen instead of the
    // insertion rather than after it.
    if (this.transforms) {
      const routing = this.transforms.router.route(final, TransformStore.shared().ordered);
      if (routing.decision.kind !== 'content') {
        // Take the command itself back off the screen first. Live typing has
        // been writing "make that shorter" since the first partial, and it must
        // not be left behind next to the result.
        if (this.isLive) await this.liveTyper.retract(this.liveGeneration);
        this.isLive = false;
        this.undo?.discard('a transform replaced the insertion');

        this.overlay.show({ kind: 'transcribing' });
        const outcome = await this.transforms.engine.run(routing);
        if (outcome.kind === 'done') {
          this.overlay.show({ kind: 'inserted', words: wordCount(outcome.success.text) });
        } else {
          // The engine does not touch the target until it has a result, so a
          // refusal leaves the document as it was — but the user asked for
          // something and has to be told it did not happen.
          this.overlay.show({ kind: 'error', message: outcome.reason });
        }
        this.timeline.textInserted = Date.now();
        await sleep(1_400);
        this.overlay.hide();
        return;
      }
    }

    // Two ways in, and the difference is whether the text is already there.
    // Live typing has been writing this sentence since the first partial, so
    // finishing it means reconciling the last edit — usually nothing, sometimes
    // the sentence the model rewrote. Pasting the whole thing here instead
    // would insert it twice.
    let result: InsertionResult;
    if (this.isLive && !this.liveTyper.isAbandoned) {
      const live = await this.liveTyper.finish(final, this.liveGeneration);
      // The one failure mode: focus moved mid-sentence. The partial text stays
      // where it was typed and the finished text goes wherever the user is now
      // — a duplicate, which they can see and delete, rather than a silent loss.
      result = live.kind === 'inserted' ? live : await this.inserter.insert(final);
    } else {
      if (this.isLive) await this.liveTyper.reset();
      result = await this.inserter.insert(final);
    }
    this.isLive = false;
    this.timeline.textInserted = Date.now();

    switch (result.kind) {
      case 'inserted':
        // Recorded here and only here: this is the one branch where text is
        // believed to be on screen, and the undo chord may not fire against a
        // sentence that never landed.
        this.undo?.record(final);
        this.lastInsertion = { text: final, insertedAt: Date.now() };
        if (this.inputLost) {
          // Say it plainly. The text is real and it is inserted, but it is only
          // as much of the sentence as reached the app before the device
          // disappeared — and a half-thought that reads as a whole one is the
          // failure mode this message exists to break.
          this.overlay.show({
            kind: 'error',
            message: `${this.capturedInputDevice ?? 'The microphone'} disconnected — kept what was heard.`,
          });
        } else {
          this.overlay.show({ kind: 'inserted', words: wordCount(final) });
        }
        break;
      case 'fellBackToClipboard':
        this.undo?.discard('the text went to the clipboard');
        this.overlay.show({ kind: 'error', message: result.reason });
        break;
      case 'failed':
        this.undo?.discard('the insertion failed');
        this.overlay.show({ kind: 'error', message: result.reason });
        break;
    }

    this.history.append(this.record(raw, final, wordCount(final), {
      finalToInsertedMs: this.timeline.finalToInsertedMs,
      releaseToInsertedMs: this.timeline.releaseToInsertedMs,
      usedThoroughCleanup: usedThorough,
    }));

    // eslint-disable-next-line no-console
    console.log(`[quill] ${this.timeline.logLine}`);

    await sleep(900);
    this.overlay.hide();
  }

  private async cancelDictation(userTyped: string): Promise<void> {
    // `isSpeculating` too, and this is not defensive tidying — it was a
    // permanent deadlock.
    //
    // Capture starts at key-down, but `isDictating` only becomes true when the
    // gesture is confirmed ~120ms later. A cancel landing in that window hit
    // the old `guard isDictating` and returned early, leaving `isSpeculating`
    // true forever — and `speculativelyBegin` refuses to start while it is. The
    // app then stops dictating silently, with no error and no overlay, until it
    // is relaunched.
    if (!this.isDictating && !this.isSpeculating) return;
    this.isDictating = false;
    this.isSpeculating = false;
    this.sessionID += 1;
    // Escape means "pretend this never happened", and with live typing on, part
    // of it already did. Take every character back before anything else. The
    // cancelling keystroke, if it reached the app, is sitting at the end of the
    // text we are about to take back — deleting our own character count would
    // eat it and leave one of ours in its place.
    if (this.isLive) await this.liveTyper.retract(this.liveGeneration, userTyped);
    this.isLive = false;
    await this.transcriber.cancel();
    this.overlay.hide();
    this.onActivity?.('idle');
  }

  private fail(message: string): void {
    // Only for a dictation that never began.
    //
    // Failures reach here from two very different places. One is `start()`
    // throwing, where there is no audio, no transcript and no history row, and
    // the user is owed the error. The other is the model being rebuilt in the
    // background, and those arrive with no session attached.
    //
    // The second kind used to run this whole method. So a warm-up that failed
    // while the NEXT dictation was already live and typing would retract and
    // delete every word the user was watching appear in their own document,
    // then set `isDictating` false so the key release did nothing. A background
    // maintenance task, silently eating a sentence.
    const began = this.timeline.audioFirstBuffer !== null || this.liveTyper.hasTypedAnything;
    if (began && this.isDictating) {
      // eslint-disable-next-line no-console
      console.log(`[quill] ignoring a failure that arrived mid-dictation: ${message}`);
      return;
    }
    // eslint-disable-next-line no-console
    console.log(`[quill] dictation FAILED to start: ${message}`);
    this.isDictating = false;
    this.isSpeculating = false;
    if (this.isLive) void this.liveTyper.retract(this.liveGeneration);
    this.isLive = false;
    this.overlay.show({ kind: 'error', message });
    this.onActivity?.('idle');
  }

  private record(
    rawText: string,
    insertedText: string,
    words: number,
    extra: {
      finalToInsertedMs: number | null;
      releaseToInsertedMs: number | null;
      usedThoroughCleanup: boolean;
    },
  ): DictationRecord {
    return {
      id: uuid(),
      date: new Date(),
      rawText,
      insertedText,
      wordCount: words,
      inputDevice: this.capturedInputDevice,
      timings: {
        timeToFirstWordMs: this.timeline.timeToFirstWordMs,
        finalToInsertedMs: extra.finalToInsertedMs,
        endToEndMs: this.timeline.endToEndMs,
        audioDurationMs: this.timeline.audioDurationMs,
        usedThoroughCleanup: extra.usedThoroughCleanup,
        releaseToInsertedMs: extra.releaseToInsertedMs,
        micOpenMs: this.timeline.micOpenMs,
        speechOnsetMs: this.timeline.speechOnsetMs,
        recogniserFirstWordMs: this.timeline.recogniserFirstWordMs,
      },
    };
  }

  /// Whether a dictation starting right now would live-type.
  ///
  /// Exposed because the rule is a decision, not an implementation detail: a
  /// dictation begun while the previous one is still landing its text must
  /// paste on release instead, so the two sentences cannot interleave in the
  /// same field.
  static wouldLiveType(
    liveTextEnabled: boolean,
    typerAvailable: boolean,
    previousStillFinalising: boolean,
  ): boolean {
    return liveTextEnabled && typerAvailable && !previousStillFinalising;
  }

  /// Whether the app is currently recording, for the tray icon and the
  /// dashboard.
  get isBusy(): boolean {
    return this.isDictating || this.isSpeculating || this.isFinalising;
  }

  /// The undo chord's entry point. Kept here rather than on `InsertionUndo` so
  /// the gesture guards can see the coordinator's state.
  async requestUndo(): Promise<void> {
    if (!this.undo) return;
    const { undoChordClaims } = await import('../../core/hotkey/undoChord');
    const allowed = undoChordClaims({
      gesture: this.hotkey.state,
      triggerHeldFor: this.hotkey.triggerHeldFor,
      heardSpeech: this.hotkey.heardSpeech,
      hasInsertion: this.undo.isArmed,
    });
    if (!allowed) {
      this.overlay.show({ kind: 'error', message: 'There is nothing to take back right now.' });
      await sleep(1_200);
      this.overlay.hide();
      return;
    }
    const outcome = await this.undo.undoLastInsertion();
    if (outcome.removed) {
      this.lastInsertion = null;
      this.overlay.show({ kind: 'inserted', words: 0 });
      await sleep(700);
      this.overlay.hide();
      return;
    }
    this.overlay.show({ kind: 'error', message: outcome.reason ?? 'Nothing was taken back.' });
    await sleep(1_800);
    this.overlay.hide();
  }

  /// Starts or stops hands-free from a menu item or a global shortcut, for the
  /// machines where the keyboard hook could not load.
  toggleHandsFree(): void {
    if (this.isDictating) {
      void this.endDictation();
      return;
    }
    this.speculativelyBegin();
    this.beginDictation();
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => { setTimeout(resolve, ms); });
}
