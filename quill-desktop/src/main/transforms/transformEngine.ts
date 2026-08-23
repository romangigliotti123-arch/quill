import { graphemeCount, trim } from '../../core/text/strings';
import {
  OfflineRecipe, Transform, TransformOutputGuard, TransformStore, applyOfflineRecipe,
  makeTransform, recipeLimitation, recipeOfflineNote, recipeTitle,
} from '../../core/transforms/transforms';
import type { Routing } from '../../core/transforms/commandRouter';
import { TRANSFORM_SYSTEM_PREAMBLE } from '../../core/ai/prompts';
import { writeClipboard } from '../injection/clipboardSnapshot';
import { collapseSelection, delay, postShiftLeft } from '../platform/keyboard';
import type { InsertionResult, TextInserting } from '../injection/textInserter';
import type { SelectionReading_ } from './selectionReader';

/// Runs a transform end to end: find the text, reshape it, put it back.
///
/// Three rules shape everything here, and they are the same three that govern
/// the inserter and the snippet expander next door.
///
/// **Nothing is destroyed before there is a replacement in hand.** The
/// selection is read, the transform runs, and only then is anything typed. A
/// model that hangs, refuses or returns rubbish leaves the document exactly as
/// it was.
///
/// **Offline is a first-class outcome, not an error.** People dictate on
/// trains. Every transform declares what it can do deterministically; those
/// that can do something do it and say so, and those that cannot say *that*
/// rather than silently returning the input unchanged.
///
/// **When the result cannot be placed safely, it goes on the clipboard.** Never
/// dropped, never typed into a position we are not sure about.

export type Applied =
  | { kind: 'model' }
  /// The model was never reached — no key, no network, breaker open.
  | { kind: 'offline'; recipe: OfflineRecipe }
  /// The model answered and the guard refused the answer, so the deterministic
  /// recipe shipped instead.
  ///
  /// Separate from `offline` because saying "offline" here is a lie, and the
  /// two have different fixes. Measured, live, three runs out of three: asked
  /// to formalise text containing "nxt", the model returns "next" every time.
  /// The guard is right to refuse it, but a user told "offline" while on wifi
  /// will go looking for the wrong problem.
  | { kind: 'guardedFallback'; recipe: OfflineRecipe };

export function appliedNote(applied: Applied): string | null {
  switch (applied.kind) {
    case 'model': return null;
    case 'offline': return recipeOfflineNote(applied.recipe);
    case 'guardedFallback': {
      const head = 'the AI answer was refused';
      const limitation = recipeLimitation(applied.recipe);
      return limitation ? `${head} — ${limitation}` : head;
    }
  }
}

export type Placement =
  | { kind: 'replacedSelection' }
  | { kind: 'replacedLastDictation' }
  /// Could not be typed where it belonged. It is on the clipboard and the
  /// reason says why.
  | { kind: 'parkedOnClipboard'; reason: string };

export interface TransformSuccess {
  transformName: string;
  original: string;
  text: string;
  via: Applied;
  placement: Placement;
}

export function successHeadline(success: TransformSuccess): string {
  let line = success.transformName;
  const note = appliedNote(success.via);
  if (note) line += ` — ${note}`;
  if (success.placement.kind === 'parkedOnClipboard') line += ' — on your clipboard, press paste';
  return line;
}

export type TransformOutcome =
  | { kind: 'done'; success: TransformSuccess }
  | { kind: 'failed'; reason: string };

/// The one thing the engine needs from the network.
///
/// Deliberately not the client itself: the engine's whole job is deciding what
/// to do when the model is unavailable, wrong or slow, and that is only
/// testable against a seam that can be all three on demand. Returns null for
/// every failure, because a null here means "use the deterministic answer", not
/// "show an error".
export interface TransformCompleting {
  completeTransform(system: string, user: string, deadlineMs: number): Promise<string | null>;
}

export interface LastDictationSource {
  (): { text: string; insertedAt: number } | null;
}

export interface TransformEngineOptions {
  store?: TransformStore;
  completer: TransformCompleting | null;
  selection: SelectionReading_;
  inserter: TextInserting;
  vocabulary?: () => string[];
  lastDictation?: LastDictationSource;
}

export class TransformEngine {
  /// How long a transform may take.
  ///
  /// Twenty-four times the dictation deadline, and that is not an oversight.
  /// The tight budget in the coordinator exists because the user has released
  /// the key and is waiting mid-sentence for their own words; every millisecond
  /// there is a millisecond of nothing happening. A transform is asked for
  /// deliberately, with an overlay up, in the way one waits for a menu command.
  deadlineMs = 6_000;

  /// How long after an insertion Quill will still offer to replace it.
  ///
  /// Past this the caret has almost certainly moved and a replacement would
  /// delete something else. Thirty seconds is long enough to read what was
  /// inserted and decide it is too long, which is when this gets used.
  replacementWindowMs = 30_000;

  /// The longest last-dictation Quill will try to reselect.
  ///
  /// Reselecting is one Shift+Left per character, and each keystroke is a real
  /// event the focused app has to process. Three hundred keeps the worst case
  /// around a third of a second; beyond that the result goes to the clipboard,
  /// which is instant and cannot go wrong.
  maxReselectCharacters = 300;

  private readonly store: TransformStore;
  private readonly completer: TransformCompleting | null;
  private readonly selection: SelectionReading_;
  private readonly inserter: TextInserting;
  private readonly vocabulary: () => string[];
  private readonly lastDictation: LastDictationSource;

  constructor(options: TransformEngineOptions) {
    this.store = options.store ?? TransformStore.shared();
    this.completer = options.completer;
    this.selection = options.selection;
    this.inserter = options.inserter;
    this.vocabulary = options.vocabulary ?? (() => []);
    this.lastDictation = options.lastDictation ?? (() => null);
  }

  /// A routed utterance. `content` is not this type's business and returns a
  /// failure saying so rather than quietly doing nothing.
  async run(routing: Routing): Promise<TransformOutcome> {
    switch (routing.decision.kind) {
      case 'content':
        return { kind: 'failed', reason: 'That was dictation, not a command.' };
      case 'transform':
        return this.runTransform(routing.decision.transform);
      case 'freeform':
        return this.runTransform(freeformTransform(routing.decision.instruction));
    }
  }

  async runTransform(transform: Transform): Promise<TransformOutcome> {
    const located = await this.locate(transform.target);
    if (located.kind === 'failed') return located;

    const produced = await this.produce(transform, located.text);
    if (produced.kind === 'failed') return produced;

    const placement = await this.place(produced.text, located);
    this.store.recordUse(transform.id);
    return {
      kind: 'done',
      success: {
        transformName: transform.name,
        original: located.text,
        text: produced.text,
        via: produced.via,
        placement,
      },
    };
  }

  /// The reshaping step on its own: no selection, no insertion, no clipboard.
  ///
  /// Public because this is the part worth testing, and it is testable with a
  /// fake completer and no network at all.
  async produce(
    transform: Transform,
    input: string,
  ): Promise<{ kind: 'produced'; text: string; via: Applied } | { kind: 'failed'; reason: string }> {
    const source = trim(input);
    if (source.length === 0) {
      return { kind: 'failed', reason: 'There was no text to transform.' };
    }

    // Three outcomes, kept apart all the way to the overlay: never asked, asked
    // and refused, asked and used. Collapsing the first two into "offline"
    // tells a user on wifi to go and check their wifi.
    let modelWasRefused = false;
    if (this.completer) {
      const raw = await this.completer.completeTransform(
        transformSystemPrompt(transform), source, this.deadlineMs,
      );
      if (raw !== null) {
        const clean = TransformOutputGuard.sanitise(
          raw, source, transform.bounds,
          transform.preservesVocabulary ? this.vocabulary() : [],
        );
        if (clean !== null) return { kind: 'produced', text: clean, via: { kind: 'model' } };
        modelWasRefused = true;
      }
    }

    const offline = applyOfflineRecipe(transform.offline, source);
    if (offline !== null) {
      // A recipe that returns its input has not transformed anything, and
      // pasting it would tell the user the transform ran. Found in a live run:
      // offline "More formal" on text with no contractions came back
      // character-identical and reported success.
      if (offline === source) {
        return { kind: 'failed', reason: noChangeReason(transform, modelWasRefused) };
      }
      return {
        kind: 'produced',
        text: offline,
        via: modelWasRefused
          ? { kind: 'guardedFallback', recipe: transform.offline }
          : { kind: 'offline', recipe: transform.offline },
      };
    }

    return {
      kind: 'failed',
      reason: unavailableReason(transform, this.completer !== null, modelWasRefused),
    };
  }

  // MARK: - Finding the text

  private async locate(target: Transform['target']): Promise<
    { kind: 'selection'; text: string } | { kind: 'lastDictation'; text: string; insertedAt: number }
    | { kind: 'failed'; reason: string }
  > {
    const fromSelection = async (): Promise<
      { kind: 'selection'; text: string } | { kind: 'failed'; reason: string } | null
    > => {
      const reading = await this.selection.readSelection();
      switch (reading.kind) {
        case 'selected': return { kind: 'selection', text: reading.text };
        case 'empty': return null;
        case 'unavailable': return { kind: 'failed', reason: reading.reason };
      }
    };

    const fromHistory = (): { kind: 'lastDictation'; text: string; insertedAt: number } | null => {
      const last = this.lastDictation();
      if (!last || trim(last.text).length === 0) return null;
      return { kind: 'lastDictation', text: last.text, insertedAt: last.insertedAt };
    };

    switch (target) {
      case 'selection':
        return (await fromSelection()) ?? { kind: 'failed', reason: 'Nothing is selected.' };
      case 'lastDictation':
        return fromHistory() ?? { kind: 'failed', reason: 'There is no recent dictation to transform.' };
      case 'automatic': {
        // Selection first, because a user who has selected something has told
        // us what they mean far more precisely than history can. An
        // `unavailable` selection is not a failure here, though — in a terminal
        // the reader refuses on purpose, and falling through to the last
        // dictation is exactly what should happen.
        const selection = await fromSelection();
        if (selection && selection.kind === 'selection') return selection;
        const history = fromHistory();
        if (history) return history;
        if (selection && selection.kind === 'failed') return selection;
        return {
          kind: 'failed',
          reason: 'Nothing is selected, and there is no recent dictation to transform.',
        };
      }
    }
  }

  // MARK: - Putting it back

  private async place(
    text: string,
    located: { kind: 'selection'; text: string } | { kind: 'lastDictation'; text: string; insertedAt: number },
  ): Promise<Placement> {
    if (located.kind === 'selection') {
      // The selection survived the read: the copy probe does not disturb it, so
      // pasting replaces exactly what was read.
      return this.report(await this.inserter.insert(text), { kind: 'replacedSelection' });
    }

    const refusal = this.reselectRefusal(located.text, located.insertedAt);
    if (refusal) return this.park(text, refusal);
    if (!await this.reselectLastDictation(located.text)) {
      return this.park(text,
        'Quill could not confirm the caret is still where it left it, so it did not type over anything.');
    }
    return this.report(await this.inserter.insert(text), { kind: 'replacedLastDictation' });
  }

  private report(result: InsertionResult, success: Placement): Placement {
    switch (result.kind) {
      case 'inserted': return success;
      case 'fellBackToClipboard': return { kind: 'parkedOnClipboard', reason: result.reason };
      case 'failed': return { kind: 'parkedOnClipboard', reason: result.reason };
    }
  }

  private park(text: string, reason: string): Placement {
    if (!writeClipboard(text)) {
      return { kind: 'parkedOnClipboard', reason: `${reason} Writing it to the clipboard also failed.` };
    }
    return { kind: 'parkedOnClipboard', reason };
  }

  /// Why this last dictation must not be reselected, or null if it may be.
  reselectRefusal(text: string, insertedAt: number, now: number = Date.now()): string | null {
    if (now - insertedAt > this.replacementWindowMs) {
      return `That dictation is more than ${Math.round(this.replacementWindowMs / 1000)} seconds old, `
        + 'so Quill will not assume the caret is still after it.';
    }
    if (text.length > this.maxReselectCharacters) {
      return `That dictation is ${text.length} characters, too long for Quill to reselect safely.`;
    }
    // Shift+Left moves by whatever the focused app calls a character. For plain
    // text every app agrees; for an emoji or a combining sequence they do not,
    // and a selection that is off by one deletes a character the user typed.
    if (/[\u{10000}-\u{10FFFF}]/u.test(text)) {
      return 'That dictation contains characters Quill cannot reselect reliably.';
    }
    return null;
  }

  /// Selects the last dictation and proves it selected the right thing.
  ///
  /// The proof is the whole point. Counting Shift+Left presses against a
  /// character count is a guess — the app may count graphemes differently, the
  /// user may have clicked elsewhere, an autocomplete may have rewritten the
  /// line. So the selection is read back and compared, and a mismatch collapses
  /// the selection and gives up rather than typing over text nobody asked
  /// about.
  async reselectLastDictation(text: string): Promise<boolean> {
    if (text.length === 0) return false;
    if (!await postShiftLeft(graphemeCount(text))) {
      collapseSelection();
      return false;
    }
    await delay(30);
    const reading = await this.selection.readSelection();
    if (reading.kind !== 'selected' || reading.text !== text) {
      collapseSelection();
      return false;
    }
    return true;
  }
}

/// Public so a settings pane can show exactly what Quill sends, rather than a
/// paraphrase of it.
export function transformSystemPrompt(transform: Transform): string {
  return `${TRANSFORM_SYSTEM_PREAMBLE}\n\nInstruction: ${transform.instruction}`;
}

/// A one-off transform built from a spoken instruction. No offline recipe —
/// there is no way to know what an arbitrary instruction means without a model
/// — and bounds wide enough not to reject something the user asked for in their
/// own words, since here the instruction is theirs and the length check has
/// nothing to measure against.
export function freeformTransform(instruction: string): Transform {
  return makeTransform({
    name: instruction,
    instruction,
    target: 'automatic',
    offline: 'none',
    bounds: { minRatio: 0.05, maxRatio: 4.0, slack: 200 },
    preservesVocabulary: true,
    isBuiltIn: false,
  });
}

export function unavailableReason(
  transform: Transform,
  hadCompleter: boolean,
  modelWasRefused: boolean,
): string {
  if (modelWasRefused) {
    return `"${transform.name}" got an answer Quill would not paste — it changed a word it was `
      + 'told to keep, or was the wrong length for this transform — and there is no offline '
      + 'version of this one. Your text has not been changed.';
  }
  if (!hadCompleter) {
    return `"${transform.name}" needs the AI layer, and no API key is configured. `
      + 'Your text has not been changed.';
  }
  return `"${transform.name}" needs the network and there is none — `
    + 'and there is no offline version of this one. Your text has not been changed.';
}

export function noChangeReason(transform: Transform, modelWasRefused: boolean): string {
  const why = modelWasRefused
    ? `the AI answer was refused and ${recipeTitle(transform.offline).toLowerCase()}`
    : `it ran offline — ${recipeTitle(transform.offline).toLowerCase()} — and`;
  return `"${transform.name}": ${why} found nothing it could change. Your text has not been changed.`;
}
