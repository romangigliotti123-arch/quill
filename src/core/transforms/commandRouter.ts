import { alphanumericKey, splitWhitespace, trim } from '../text/strings';
import type { Transform } from './transforms';

/// Decides whether an utterance is something to type or something to do.
///
/// # Why this is the most conservative file in the app
///
/// The two failure modes are not symmetric, and nothing else about the design
/// makes sense until that is agreed.
///
/// Treating a command as content types "make that shorter" into a document. The
/// user sees it immediately, deletes five words, and is mildly annoyed.
///
/// Treating content as a command *deletes what they said*. The sentence never
/// arrives, a transform runs on some unrelated earlier text, and the user is
/// left looking at a document that changed in a way they did not ask for, with
/// no record of the words they lost. They may not even notice until later.
///
/// So this router is precision-first to the point of being obtuse. It fires
/// only when the *entire* utterance is an instruction, and it would rather miss
/// a real command ten times than eat one sentence. Every guard below exists
/// because of a specific sentence it must not swallow, and the sentence is
/// named.
///
/// # The three ways to run a transform, in order of how much they are trusted
///
/// 1. **A hotkey.** Unambiguous — the user pressed a key. The router is not
///    involved at all.
/// 2. **The wake word.** "Quill, make that shorter." A word nobody dictates by
///    accident, so everything after it is an instruction, including
///    instructions Quill has no transform for.
/// 3. **A bare spoken instruction.** "Make that shorter." This is the
///    convenient one and the dangerous one, and it is the only path the guards
///    apply to. It fires only for transforms that already exist — a bare
///    utterance is never allowed to become a free-form instruction.
///
/// # What the caller must still do
///
/// A routing decision is not permission to throw the words away. `Routing`
/// carries `spokenText` in every case, and the engine never destroys the target
/// text until it has a result in hand.

export type RouterMode = 'automatic' | 'explicit';

export type RoutingDecision =
  | { kind: 'content' }
  | { kind: 'transform'; transform: Transform }
  /// An instruction with no matching transform, reachable only from `explicit`.
  /// The engine runs it as a one-off with no offline recipe.
  | { kind: 'freeform'; instruction: string };

/// Why the router decided what it decided.
///
/// A case per rule rather than a string, so tests can assert on the *reason*
/// and not just the answer. A router that returns `content` for the wrong
/// reason is one edit away from returning `transform`.
export type RoutingReason =
  | { kind: 'empty' }
  | { kind: 'exactTrigger'; phrase: string }
  | { kind: 'wakeWord' }
  | { kind: 'explicitMode' }
  | { kind: 'containsQuotedOrLiteralText' }
  | { kind: 'moreThanOneSentence' }
  | { kind: 'compoundInstruction'; word: string }
  | { kind: 'narrativeMarker'; word: string }
  | { kind: 'tooLong'; words: number; limit: number }
  | { kind: 'noCommandVerb' }
  | { kind: 'noReferent' }
  | { kind: 'noMatchingTransform' }
  | { kind: 'leftoverContent'; words: string[] }
  | { kind: 'grammarMatch' };

export function describeReason(reason: RoutingReason): string {
  switch (reason.kind) {
    case 'empty': return 'nothing was said';
    case 'exactTrigger': return `the whole utterance is the trigger "${reason.phrase}"`;
    case 'wakeWord': return 'it started with the wake word';
    case 'explicitMode': return 'the command key was held';
    case 'containsQuotedOrLiteralText': return 'it contains quoted or literal text';
    case 'moreThanOneSentence': return 'it is more than one sentence';
    case 'compoundInstruction': return `it joins two clauses with "${reason.word}"`;
    case 'narrativeMarker': return `it reads as narration — "${reason.word}"`;
    case 'tooLong': return `${reason.words} words, over the ${reason.limit}-word limit for a command`;
    case 'noCommandVerb': return 'it does not start with a command verb';
    case 'noReferent': return 'it never refers to existing text';
    case 'noMatchingTransform': return 'no transform matches it';
    case 'leftoverContent': return `it carries content beyond the instruction — ${reason.words.join(' ')}`;
    case 'grammarMatch': return 'verb, referent and a matching transform, and nothing else';
  }
}

export interface Routing {
  decision: RoutingDecision;
  /// Always the utterance as spoken. The caller keeps this whatever the
  /// decision, so a wrong answer here is recoverable rather than lossy.
  spokenText: string;
  reason: RoutingReason;
}

export function routingIsCommand(routing: Routing): boolean {
  return routing.decision.kind !== 'content';
}

// MARK: - Lexicons

/// Verbs that can start an instruction.
///
/// Closed and short on purpose. Every entry is a word that, at the *front* of a
/// whole utterance and followed by a referent, is an order rather than a
/// statement. "Send", "add", "write" and "say" are all missing and all stay
/// missing — "send it to Carlo" and "add that to the invoice" are things people
/// dictate.
export const COMMAND_VERBS = new Set([
  'make', 'turn', 'change', 'convert', 'rewrite', 'reword', 'rephrase',
  'format', 'reformat', 'shorten', 'summarise', 'summarize', 'condense',
  'tidy', 'clean', 'fix', 'correct', 'proofread', 'polish', 'punctuate',
  'capitalise', 'capitalize', 'bullet', 'number', 'sum', 'trim', 'tighten',
  'formalise', 'formalize', 'expand',
]);

/// Words that point at text that already exists. Without one of these the
/// utterance is not about anything, which means it is content.
export const REFERENTS = new Set([
  'that', 'this', 'it', 'these', 'those', 'them', 'above', 'last', 'previous',
]);

/// Words that carry no content and so are not counted as leftovers.
///
/// This list is the *only* forgiveness the grammar path has, which is why it is
/// a list and not a threshold: every word in it is a word someone deliberately
/// decided cannot change what an instruction means. Adding a word here widens
/// what fires. "On", "at" and "from" are absent for that reason — they attach
/// an instruction to something else, and something else is content.
export const FUNCTION_WORDS = new Set([
  'a', 'an', 'the', 'to', 'into', 'as', 'of', 'more', 'less', 'much',
  'very', 'bit', 'lot', 'far', 'way', 'slightly', 'somewhat', 'little',
  'up', 'down', 'please', 'instead', 'one', 'sound', 'sounds', 'look',
  'looks', 'reads', 'be', 'all', 'just', 'my', 'me', 'its',
]);

/// Stripped from the front of an utterance before the verb check.
///
/// Only from the front, and only in a run. "You" is here so "can you make that
/// shorter" reaches the verb, and stripping it only at the front is what keeps
/// "you said make it shorter" as content — there the run stops at "said", which
/// is not a verb, so the utterance is typed.
export const POLITENESS = new Set([
  'please', 'can', 'could', 'would', 'will', 'you', 'hey', 'ok', 'okay',
  'now', 'just', 'quickly', 'actually', 'maybe', 'lets', 'let', 'us',
]);

// MARK: - Tokens

/// Lowercased words, punctuation discarded.
///
/// Punctuation is discarded rather than respected because the recogniser
/// invents it: the same spoken instruction arrives as "Make that shorter.",
/// "make that shorter" and "Make that, shorter" across three dictations, and a
/// router that treats those differently is a router that works intermittently.
export function tokeniseCommand(text: string): string[] {
  return splitWhitespace(text).map(alphanumericKey).filter((token) => token.length > 0);
}

export function stripPoliteness(tokens: string[]): string[] {
  let out = tokens;
  while (out.length > 1 && POLITENESS.has(out[0]!)) out = out.slice(1);
  return out;
}

export function stripWakeWord(wake: string, tokens: string[]): string[] | null {
  const word = alphanumericKey(wake);
  if (word.length === 0) return null;
  let index = 0;
  // "Hey Quill, …" as well as "Quill, …".
  if (tokens[0] === 'hey' && tokens.length > 1) index = 1;
  if (tokens[index] !== word) return null;
  return tokens.slice(index + 1);
}

/// A sentence terminator with a word after it. Abbreviations do not count —
/// "e.g." and "9 a.m." are not sentence breaks, and a naive scan for "." is
/// wrong often enough in dictation to matter.
export function hasInteriorSentenceBreak(text: string): boolean {
  const match = /[.!?]\s+\S/u.exec(text);
  if (!match) return false;
  const head = text.slice(0, match.index);
  const lastWord = splitWhitespace(head).pop() ?? '';
  return !lastWord.includes('.') || lastWord.length > 3;
}

/// Shapes that an instruction does not have.
export function contentGuard(spoken: string, tokens: string[]): RoutingReason | null {
  // Quoted text, an address or a link. Someone is dictating a literal.
  if (spoken.includes('"') || spoken.includes('“')
    || spoken.includes('@') || spoken.toLowerCase().includes('http')) {
    return { kind: 'containsQuotedOrLiteralText' };
  }

  // Two sentences. A spoken command is one clause; the moment there is a full
  // stop with words after it, something is being narrated.
  if (hasInteriorSentenceBreak(spoken)) return { kind: 'moreThanOneSentence' };

  // A conjunction joins the instruction to something else, and that something
  // else is content this router would throw away.
  for (const word of ['and', 'then', 'also', 'plus', 'but', 'because', 'so']) {
    if (tokens.includes(word)) return { kind: 'compoundInstruction', word };
  }

  // Reported speech. "Tell him to make it more formal" is a sentence about an
  // instruction, not an instruction.
  for (const word of ['said', 'says', 'told', 'asked', 'tell', 'ask', 'wrote', 'think', 'thinks']) {
    if (tokens.includes(word)) return { kind: 'narrativeMarker', word };
  }

  return null;
}

// MARK: - Matching

interface KeywordMatch {
  transform: Transform;
  /// The tokens this transform's keywords accounted for.
  matched: Set<string>;
}

/// The whole utterance, word for word, is one of the transform's triggers.
export function exactTriggerMatch(
  tokens: string[],
  transforms: Transform[],
): { transform: Transform; phrase: string } | null {
  if (tokens.length === 0) return null;
  for (const transform of transforms) {
    for (const phrase of transform.triggers) {
      const words = stripPoliteness(tokeniseCommand(phrase));
      if (words.length !== tokens.length) continue;
      if (words.every((word, i) => word === tokens[i])) return { transform, phrase };
    }
  }
  return null;
}

/// The transform whose keywords appear in the utterance.
///
/// Ordered by how much of the utterance each explains, then by how often the
/// transform is used, then by name — so the answer is stable across runs and a
/// test cannot pass by accident of ordering.
export function bestKeywordMatch(tokens: string[], transforms: Transform[]): KeywordMatch | null {
  const set = new Set(tokens);
  const scored: KeywordMatch[] = [];
  for (const transform of transforms) {
    const matched = new Set<string>();
    for (const keyword of transform.keywords) {
      const normalised = alphanumericKey(keyword);
      if (normalised.length > 0 && set.has(normalised)) matched.add(normalised);
    }
    if (matched.size === 0) continue;
    scored.push({ transform, matched });
  }
  if (scored.length === 0) return null;
  return scored.reduce((best, candidate) => {
    if (candidate.matched.size !== best.matched.size) {
      return candidate.matched.size > best.matched.size ? candidate : best;
    }
    if (candidate.transform.useCount !== best.transform.useCount) {
      return candidate.transform.useCount > best.transform.useCount ? candidate : best;
    }
    return candidate.transform.name < best.transform.name ? candidate : best;
  });
}

/// The instruction to send to the model, in the user's own words.
///
/// Rebuilt from the original string rather than from the tokens, because the
/// tokens have lost their punctuation and capitalisation and the model reads
/// better prose. The tokens are only used to find where the instruction starts.
export function rebuildInstruction(tokens: string[], spoken: string): string {
  const first = tokens[0];
  if (first === undefined) return spoken;
  const words = splitWhitespace(spoken);
  for (let index = 0; index < words.length; index += 1) {
    if (alphanumericKey(words[index]!) === first) return words.slice(index).join(' ');
  }
  return spoken;
}

export interface CommandRouterOptions {
  /// Above this, it is prose. Measured against the built-in triggers: the
  /// longest is "turn that into bullet points" at five words, and the longest
  /// plausible spoken instruction — "make that a numbered list instead" — is
  /// six. Twelve is double the real ceiling, which is the right kind of slack.
  wordLimit?: number;
  /// How much unaccounted-for content an utterance may carry and still be an
  /// instruction.
  ///
  /// Zero. Every word must be explained by the verb, a referent, a function
  /// word or the transform's own keywords, or the utterance is typed.
  ///
  /// One was tried and is wrong. "Make it the last one on the list" is a
  /// sentence a person dictates; it has the verb, the referent and the keyword
  /// "list", and only "on" is left over. At a limit of one it fires the bullet
  /// transform and the sentence is gone.
  leftoverLimit?: number;
  /// Said before an instruction to make it unambiguous.
  wakeWord?: string;
}

export class CommandRouter {
  readonly wordLimit: number;
  readonly leftoverLimit: number;
  readonly wakeWord: string;

  constructor(options: CommandRouterOptions = {}) {
    this.wordLimit = options.wordLimit ?? 12;
    this.leftoverLimit = options.leftoverLimit ?? 0;
    this.wakeWord = options.wakeWord ?? 'quill';
  }

  route(utterance: string, transforms: Transform[], mode: RouterMode = 'automatic'): Routing {
    const spoken = trim(utterance);
    if (spoken.length === 0) {
      return { decision: { kind: 'content' }, spokenText: utterance, reason: { kind: 'empty' } };
    }

    const usable = transforms.filter((t) => t.isEnabled && t.instruction.length > 0);
    let tokens = tokeniseCommand(spoken);
    let effectiveMode = mode;
    let wakeReason: RoutingReason | null = null;

    // 1. Wake word. Checked before anything else because it is the user
    //    explicitly overriding every heuristic below, and because it is the
    //    only way to reach a free-form instruction by voice.
    const stripped = stripWakeWord(this.wakeWord, tokens);
    if (stripped) {
      tokens = stripped;
      effectiveMode = 'explicit';
      wakeReason = { kind: 'wakeWord' };
      if (tokens.length === 0) {
        // "Quill." on its own. Nothing to do, and typing the word back would be
        // worse than doing nothing.
        return { decision: { kind: 'content' }, spokenText: spoken, reason: { kind: 'empty' } };
      }
    }

    // 2. An exact whole-utterance trigger, which is the strongest signal
    //    available and the only one that is trusted before the guards.
    //
    //    Trusted first because the trigger list is authored, not inferred: a
    //    built-in trigger was written to be unmistakable, and a user-defined one
    //    is a phrase they typed into a box specifically so that saying it would
    //    run this transform. Matching the *whole* utterance is what keeps it
    //    safe — "no wait, make that Carlo" contains "make that" and is not an
    //    exact match for anything.
    const polite = stripPoliteness(tokens);
    const hit = exactTriggerMatch(polite, usable);
    if (hit) {
      return {
        decision: { kind: 'transform', transform: hit.transform },
        spokenText: spoken,
        reason: wakeReason ?? { kind: 'exactTrigger', phrase: hit.phrase },
      };
    }

    // 3. Explicit mode skips the guards entirely — they answer a question the
    //    user has already answered.
    if (effectiveMode === 'explicit') {
      const match = bestKeywordMatch(polite, usable);
      if (match) {
        return {
          decision: { kind: 'transform', transform: match.transform },
          spokenText: spoken,
          reason: wakeReason ?? { kind: 'explicitMode' },
        };
      }
      return {
        decision: { kind: 'freeform', instruction: rebuildInstruction(polite, spoken) },
        spokenText: spoken,
        reason: wakeReason ?? { kind: 'explicitMode' },
      };
    }

    // 4. Hard content guards. Each one is a shape that an instruction never has
    //    and dictated prose regularly does.
    const guardReason = contentGuard(spoken, tokens);
    if (guardReason) {
      return { decision: { kind: 'content' }, spokenText: spoken, reason: guardReason };
    }

    if (tokens.length > this.wordLimit) {
      return {
        decision: { kind: 'content' },
        spokenText: spoken,
        reason: { kind: 'tooLong', words: tokens.length, limit: this.wordLimit },
      };
    }

    // 5. The grammar: a command verb at the front, and a referent to the text
    //    it acts on. Both are required, and the verb must be *first*.
    //
    //    Anchoring the verb is what separates "make that a bullet list" from
    //    "send it to Noah, no wait, make that Carlo" — the self-correction idiom
    //    and the command idiom are the same three words, and their position in
    //    the utterance is the only thing that tells them apart.
    const verb = polite[0];
    if (verb === undefined || !COMMAND_VERBS.has(verb)) {
      return { decision: { kind: 'content' }, spokenText: spoken, reason: { kind: 'noCommandVerb' } };
    }
    if (!polite.some((token) => REFERENTS.has(token))) {
      return { decision: { kind: 'content' }, spokenText: spoken, reason: { kind: 'noReferent' } };
    }

    const match = bestKeywordMatch(polite, usable);
    if (!match) {
      // An instruction Quill has no transform for. It does not become a
      // free-form request, because at this point the only evidence that it is an
      // instruction at all is the heuristic that just failed to find a match.
      return {
        decision: { kind: 'content' },
        spokenText: spoken,
        reason: { kind: 'noMatchingTransform' },
      };
    }

    // 6. Everything left over after the verb, the referent, the function words
    //    and the transform's own keywords have been accounted for.
    //
    //    This is the guard for "make it more formal and mention the deposit",
    //    where the instruction is real but is carrying content that would be
    //    silently dropped. Refusing costs the user a retry; accepting costs them
    //    the words "mention the deposit".
    const leftover = polite.filter((token) => token !== verb
      && !REFERENTS.has(token)
      && !FUNCTION_WORDS.has(token)
      && !match.matched.has(token));
    if (leftover.length > this.leftoverLimit) {
      return {
        decision: { kind: 'content' },
        spokenText: spoken,
        reason: { kind: 'leftoverContent', words: leftover },
      };
    }

    return {
      decision: { kind: 'transform', transform: match.transform },
      spokenText: spoken,
      reason: { kind: 'grammarMatch' },
    };
  }
}
