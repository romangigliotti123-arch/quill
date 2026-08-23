import type { TranscriptCleaning } from '../cleanup/fastCleaner';
import { FastCleaner } from '../cleanup/fastCleaner';
import { projectCleanup } from '../cleanup/cleanupProjection';
import { contextHasCandidate, projectContext } from '../cleanup/contextProjection';
import { homophoneHasCandidate } from '../cleanup/homophonePairs';
import { projectHomophones } from '../cleanup/homophoneProjection';
import { needsModelPass, resolveSelfCorrection } from '../cleanup/selfCorrection';
import { VocabularyBook } from '../stores/vocabulary';
import { QuillSettings } from '../settings';
import {
  MAXIMUM_PROMPT_CHARACTERS, StyleProfile, StyleStore, freshProfile, promptRules,
} from '../style/styleProfile';
import { CLEANUP_PROMPT, CONTEXT_PROMPT, VersionedPrompt, makeHomophonePrompt } from './prompts';
import { AICompleting, withDeadline } from './nimClient';
import { trim } from '../text/strings';

/// `cleanThorough` for the real app: the fast pass, then spoken
/// self-correction.
///
/// The order of operations is the design, and each step exists because the one
/// before it cannot do the job:
///
///   1. **FastCleaner** — punctuation, disfluency, the user's vocabulary. Under
///      2ms, offline, and better at proper nouns than any model measured. Its
///      output, not the raw transcript, is what everything downstream sees.
///   2. **The gate** — no retraction cue and no stutter means there is nothing
///      a model can add, so no request is made. Most dictations stop here and
///      pay nothing. This is also a safety property: a sentence that was
///      already right is never handed to something that might improve it.
///   3. **The offline resolver** — repairs the unambiguous corrections with no
///      network, in microseconds. People dictate on trains. It is also the
///      answer whenever the model misses its deadline.
///   4. **The model** — the general case, on the remaining budget minus a
///      safety margin, so this method always answers before the coordinator
///      stops waiting. Its answer is checked, not trusted.
///
/// Every failure at every step falls through to the step before it. There is no
/// path out of `cleanThorough` that throws, blocks past the deadline, or
/// returns text that is not either the model's checked output or a
/// deterministic result.
export interface AICleanerOptions {
  client: AICompleting;
  fast?: FastCleaner;
  prompt?: VersionedPrompt;
  /// Read at call time, not captured at launch. The Style screen writes
  /// style.json on a click and the profile is meant to affect the very next
  /// dictation — a snapshot taken in the constructor would apply the tone the
  /// app started with, forever.
  style?: () => StyleProfile;
  /// Set only by tests, which inject a fixed list.
  vocabulary?: string[];
  book?: VocabularyBook;
  /// Taken off the caller's deadline before the request is made, so the
  /// deterministic answer is returned *inside* the race rather than arriving
  /// after the coordinator has already given up. 30ms covers response decoding,
  /// the guard, and the hop back to the main thread.
  safetyMarginMs?: number;
  /// Below this there is no point asking. The floor for a completion on this
  /// endpoint is a measured 195–223ms of pure network on a warm connection, so
  /// anything under 120ms is guaranteed to be a wasted wait.
  minimumBudgetMs?: number;
  /// Whether to spend a request choosing between listed homophones. On by
  /// default, which it had to earn twice.
  ///
  /// Benched against the real endpoint with half the corpus deliberately
  /// correct: 3 of 6 fixed, 0 of 6 damaged. Zero damage was the bar.
  ///
  /// Then measured for cost against 263 real dictations. The first list woke
  /// the model on 12% of them, almost entirely on past, through, whether,
  /// course and week — words that were already right every time. Trimming those
  /// left 21 groups that fire on **1%**, and the words still triggering it are
  /// the ones that were actually wrong: cashed, principle, effect, discreet,
  /// losing.
  homophones?: boolean;
  /// Propose-then-verify instead of choose-from-a-list. Asked, not remembered:
  /// the switch in Settings had no effect until relaunch when this was a
  /// boolean captured at construction. Read once at the top of a pass so one
  /// dictation cannot see it flip halfway through.
  contextRecovery?: () => boolean;
}

export class AICleaner implements TranscriptCleaning {
  private readonly client: AICompleting;
  private readonly fast: FastCleaner;
  private readonly prompt: VersionedPrompt;
  private readonly style: () => StyleProfile;
  private readonly fixedVocabulary: string[] | null;
  private readonly book: VocabularyBook | null;
  private readonly safetyMarginMs: number;
  private readonly minimumBudgetMs: number;
  private readonly homophones: boolean;
  private readonly contextRecovery: () => boolean;

  constructor(options: AICleanerOptions) {
    this.client = options.client;
    this.fast = options.fast ?? new FastCleaner();
    this.prompt = options.prompt ?? CLEANUP_PROMPT;
    this.style = options.style ?? (() => StyleStore.shared().profile);
    this.fixedVocabulary = options.vocabulary ?? null;
    this.book = options.vocabulary ? null : (options.book ?? VocabularyBook.shared());
    this.safetyMarginMs = options.safetyMarginMs ?? 30;
    this.minimumBudgetMs = options.minimumBudgetMs ?? 120;
    this.homophones = options.homophones ?? process.env.QUILL_HOMOPHONES !== '0';
    this.contextRecovery = options.contextRecovery
      ?? (() => QuillSettings.instance().contextRecovery);
  }

  /// Read once per call, never captured.
  ///
  /// This used to be evaluated at construction, and the cleaner is built once
  /// at launch — so every word added to the Dictionary after that was invisible
  /// to the AI pass for the rest of the session. It is the list that protects
  /// the user's own terms from being rewritten, so a fresh word was not merely
  /// unprotected, it was the one most likely to be "corrected" into something
  /// else.
  private get vocabulary(): string[] {
    return this.fixedVocabulary ?? this.book?.terms ?? [];
  }

  cleanFast(raw: string): string {
    return this.fast.cleanFast(raw);
  }

  /// The cleanup prompt with the user's style rules appended.
  ///
  /// Appended rather than woven in, and capped, because the base prompt is the
  /// part that was measured to 10/10 and must not be diluted: every rule is
  /// additive, and the tail is dropped when the budget runs out.
  static systemPrompt(base: VersionedPrompt, profile: StyleProfile): string {
    const rules = promptRules(profile);
    if (rules.length === 0) return base.system;
    let appended = '';
    for (const rule of rules) {
      const next = appended.length === 0 ? rule : `${appended}\n${rule}`;
      if (next.length > MAXIMUM_PROMPT_CHARACTERS) break;
      appended = next;
    }
    if (appended.length === 0) return base.system;
    return `${base.system}\n\nHow this person writes:\n${appended}`;
  }

  async cleanThorough(raw: string, deadlineMs: number): Promise<string | null> {
    const tidy = this.fast.cleanFast(raw);
    if (tidy.length === 0) return null;

    const vocabulary = this.vocabulary;
    // Computed before anything can go wrong, so there is always an answer to
    // fall back to — including the case where the model returns garbage after
    // 200ms and there is no budget left to think about it.
    const offline = resolveSelfCorrection(tidy, vocabulary);

    const needsSelfCorrection = needsModelPass(tidy);
    // `offline` is the deterministic answer and may be null when there was
    // nothing to resolve; the text to correct is then the tidied input.
    const base = offline ?? tidy;
    // A long dictation almost always contains a stumble, and a stumble sets
    // `needsSelfCorrection` — so "one or the other" quietly meant homophones
    // never ran on the longest dictations. Measured on a real one: a phone call
    // in the tail contained "mum told me mum told me", the repetition gate
    // fired, and "cashing" stayed wrong all the way into the document.
    //
    // But the offline resolver handles repetitions deterministically, for free,
    // before any of this. When it has already changed the text the retraction
    // is dealt with and the model pass is only a refinement — so the request is
    // better spent on the homophone, which nothing else can reach.
    const offlineHandledIt = offline !== null && offline !== tidy;
    // Each pass gets the gate that matches its reach. The closed-list pass can
    // only fix a word on its short list, so asking about anything else is a
    // request spent on a question it cannot answer. The context pass verifies
    // against 2,281 words.
    //
    // Once, at the top, so the two branches below cannot disagree about it
    // within a single pass.
    const usesContext = this.contextRecovery();
    const hasCandidate = usesContext
      ? contextHasCandidate(base)
      : homophoneHasCandidate(base);
    const needsHomophones = this.homophones
      && (!needsSelfCorrection || offlineHandledIt)
      && hasCandidate;
    if (!needsSelfCorrection && !needsHomophones) return offline;
    if (!this.client.isConfigured || !this.client.isReadyToTry) return offline;

    const budget = deadlineMs - this.safetyMarginMs;
    if (budget < this.minimumBudgetMs) return offline;

    // Deliberately one request or the other, never both. They are both on the
    // critical path and the budget is one round trip wide.
    if (needsHomophones) {
      // Two shapes of the same request, and only one is sent. The context pass
      // lets the model propose freely and refuses anything that is not a
      // same-sounding swap; the older pass hands it a closed list to choose
      // from. The first covers 2,281 words against 44 and is the default; the
      // second stays reachable because its list carries pairs CMUdict does not
      // know this recogniser confuses.
      if (usesContext) {
        return (await this.recoverFromContext(base, budget)) ?? offline;
      }
      return (await this.correctHomophones(base, budget)) ?? offline;
    }

    const completion = await withDeadline(budget, () => this.client.complete(
      AICleaner.systemPrompt(this.prompt, this.style()),
      tidy,
      null,
      budget,
    ));
    if (completion === null) return offline;
    const checked = projectCleanup(completion, tidy, vocabulary);
    if (checked === null || checked === tidy) return offline;
    return checked;
  }

  /// One request, then the projection. Returns null for every failure — no key,
  /// no network, a rewritten sentence, a refused swap — because the caller
  /// already holds the deterministic answer and this may only improve it.
  private async correctHomophones(text: string, budgetMs: number): Promise<string | null> {
    const prompt = makeHomophonePrompt(text);
    if (!prompt) return null;
    const completion = await withDeadline(
      budgetMs,
      () => this.client.complete(prompt.system, text, null, budgetMs),
    );
    if (completion === null) return null;
    return projectHomophones(completion, text);
  }

  /// The context pass: the model reads the sentence and proposes a fix of its
  /// own, and `projectContext` refuses anything that is not a same-sounding
  /// word swapped for the one that was heard.
  private async recoverFromContext(text: string, budgetMs: number): Promise<string | null> {
    const completion = await withDeadline(
      budgetMs,
      () => this.client.complete(CONTEXT_PROMPT.system, text, null, budgetMs),
    );
    if (completion === null) return null;
    return projectContext(completion, text);
  }
}

/// A cleaner with no model behind it, for tests and for the offline default.
export function offlineCleaner(): TranscriptCleaning {
  return new FastCleaner();
}

export function emptyStyleProfile(): StyleProfile {
  return freshProfile();
}

export { trim };
