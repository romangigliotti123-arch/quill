import {
  SpeechToken, joinSpeech, tokeniseSpeech, tokenEndsSentence, tokenIsCapitalised, tokenIsNumber,
} from '../text/speechToken';
import { trimPunctuation } from '../text/strings';
import { capitaliseSentences, collapseWhitespace, tightenPunctuationSpacing } from './fastCleaner';

/// Spoken self-correction.
///
/// The complaint: "Sometimes it doesn't pick up what I say if I make a
/// mistake." What happens is that both halves survive — "send it to Noah no
/// wait send it to Carlo" arrives with Noah still in it, and the first half has
/// to be deleted by hand, which is the exact work dictation was supposed to
/// save.
///
/// This file is the deterministic half of the answer. It does three jobs, and
/// they are deliberately different jobs:
///
///  1. `cues` finds retraction phrases and, critically, decides which ones are
///     *retractions* and which are ordinary English. "no wait" in "he said no
///     wait and then walked off" is content, not a correction, and anything
///     that cannot tell those apart will quietly eat words said on purpose.
///  2. `needsModelPass` is the gate. A transcript with no retraction cue and no
///     stutter has nothing for a language model to contribute, so it never pays
///     the network round trip. Measured on the live endpoint, that call costs
///     p50 284ms — more than the entire dictation budget — so not making it is
///     worth more than making it fast.
///  3. `resolveSelfCorrection` repairs the clear cases with no network at all.
///     People dictate on trains. Without this, the headline feature is a
///     feature that works at a desk.
///
/// Everything here is conservative in the same direction as the vocabulary
/// corrector: when the evidence is weak it does nothing and lets the untouched
/// fast text ship. A missed correction costs one manual edit. A wrong deletion
/// silently removes something that was said, into an app we do not control.

/// Phrases people say when they are taking something back.
///
/// Ordered longest-first because the longer phrase is the more specific signal:
/// "no wait" must win over a bare "no", and "or rather" over "rather".
///
/// Bare "no" and bare "rather" are deliberately absent. Both are far more often
/// ordinary speech than retraction, and a cue that fires on ordinary speech
/// does not merely miss — it hands the model licence to delete a clause.
const CUE_PHRASES: string[][] = [
  ['you', 'know', 'what'],
  ['let', 'me', 'rephrase'],
  ['no', 'wait'], ['wait', 'no'], ['no', 'sorry'], ['sorry', 'no'],
  ['i', 'mean'], ['i', 'meant'], ['make', 'that'], ['scratch', 'that'],
  ['strike', 'that'], ['never', 'mind'], ['or', 'rather'],
  ['forget', 'it'], ['forget', 'that'], ['hang', 'on'], ['hold', 'on'],
  ['actually'], ['sorry'], ['nevermind'], ['correction'],
].sort((a, b) => b.length - a.length);

/// Verbs of reported speech. A cue that follows one is being quoted, not used:
/// "he said no wait", "she said sorry", "I told him actually".
///
/// Measured, and the reason this list exists: on the live endpoint,
/// llama-3.1-8b turned "He said no wait and then walked off" into "He walked
/// off." 10 times out of 10, on every prompt variant tried. The model cannot be
/// talked out of it, so it never gets asked.
const REPORTING_VERBS = new Set([
  'said', 'says', 'say', 'saying', 'told', 'tell', 'tells', 'telling',
  'asked', 'asks', 'ask', 'asking', 'replied', 'replies', 'reply',
  'wrote', 'writes', 'goes', 'went', 'yelled', 'shouted', 'screamed',
  'whispered', 'answered', 'answers', 'mentioned', 'mentions', 'added',
]);

/// Words that turn the cue in front of them into the subject of a sentence:
/// "actually IS spelled with two Ls" is a sentence *about* the word.
///
/// Also measured: the same model returned "Actually, I'm not going to do that."
/// for that transcript, 6 times out of 10 — it stopped cleaning and started
/// replying.
const SUBJECT_MARKERS = new Set([
  'is', 'isnt', 'was', 'wasnt', 'are', 'arent', 'were', 'means', 'meant',
  'spells', 'spelled', 'spelt', 'has', 'had', 'sounds', 'looks', 'starts',
  'ends', 'comes', 'would', 'should',
]);

/// Nouns that quote the next word rather than use it: "the word sorry".
const QUOTING_NOUNS = new Set(['word', 'words', 'phrase', 'spelling', 'term']);

/// Cues that throw away what is *still to come* rather than what was just said.
/// "Never mind" ends an utterance; "no wait" turns one around. The distinction
/// decides which side of the cue a deletion is allowed to eat.
const ABANDONMENT_PHRASES: string[][] = [
  ['never', 'mind'], ['nevermind'], ['forget', 'it'], ['forget', 'that'],
  ['scratch', 'that'], ['strike', 'that'],
];

/// Noises, not words. Deliberately short: this set is what licenses the model
/// to delete something with no retraction behind it, so every entry has to be a
/// sound nobody ever means.
///
/// "like", "so", "well" and "basically" were in here and came out. Each is an
/// ordinary word in the middle of a sentence — "I like the blue one", "so it
/// works" — and licensing their deletion anywhere means licensing it there. As
/// sentence openers they are still deletable, via `isOpeningPreamble`, which is
/// anchored to the first word and cannot reach into a sentence.
///
/// Note what is also not here: "yeah" and "nah". Those carry tone, and
/// stripping them is the "model improved my prose" bug in miniature.
export const FILLERS = new Set(['um', 'uh', 'er', 'erm', 'uhm', 'mm', 'hmm']);

/// Words that repeat legitimately in English. "had had" is a tense, "very very"
/// is emphasis; collapsing them would be a correction nobody asked for.
const LEGITIMATE_DOUBLES = new Set(['had', 'that', 'very', 'really', 'no']);

/// One retraction phrase, located in the token stream.
export interface Cue {
  /// Half-open token range covering the phrase.
  start: number;
  end: number;
  /// False when the phrase is being used as ordinary content.
  isRetraction: boolean;
}

export function firstIndexOf(needle: string[], haystack: string[]): number | null {
  if (needle.length === 0 || needle.length > haystack.length) return null;
  for (let start = 0; start + needle.length <= haystack.length; start += 1) {
    if (haystack.slice(start, start + needle.length).every((word, i) => word === needle[i])) return start;
  }
  return null;
}

/// Where a restart actually begins.
///
/// Separate from `firstIndexOf` rather than replacing it: that one is also used
/// by `isAbandonment`, where first-match is correct.
export function lastIndexOf(needle: string[], haystack: string[]): number | null {
  if (needle.length === 0 || needle.length > haystack.length) return null;
  for (let start = haystack.length - needle.length; start >= 0; start -= 1) {
    if (haystack.slice(start, start + needle.length).every((word, i) => word === needle[i])) return start;
  }
  return null;
}

/// Whether a cue span is an abandonment. Takes a span rather than a phrase
/// because adjacent cues are merged — "you know what never mind" arrives as one
/// range, and only the tail of it identifies the kind.
export function isAbandonment(cue: Cue, tokens: SpeechToken[]): boolean {
  const words = tokens.slice(cue.start, cue.end).map((t) => t.normalised);
  return ABANDONMENT_PHRASES.some((phrase) => firstIndexOf(phrase, words) !== null);
}

/// Every cue phrase in the token stream, longest match first, non-overlapping,
/// with adjacent phrases merged.
///
/// Merging matters for "at 3 actually make that 4": "actually" and "make that"
/// are two cues back to back, and treating them separately puts "actually"
/// between the number being replaced and the number replacing it, so neither
/// rule below can see the swap.
export function cues(tokens: SpeechToken[]): Cue[] {
  const found: { start: number; end: number }[] = [];
  let index = 0;
  outer: while (index < tokens.length) {
    for (const phrase of CUE_PHRASES) {
      if (index + phrase.length > tokens.length) continue;
      const window = tokens.slice(index, index + phrase.length).map((t) => t.normalised);
      if (window.every((word, i) => word === phrase[i])) {
        found.push({ start: index, end: index + phrase.length });
        index += phrase.length;
        continue outer;
      }
    }
    index += 1;
  }

  const merged: { start: number; end: number }[] = [];
  for (const range of found) {
    const last = merged[merged.length - 1];
    if (last && last.end === range.start) last.end = range.end;
    else merged.push({ ...range });
  }

  return merged.map((range) => ({
    ...range,
    isRetraction: isRetraction(range, tokens),
  }));
}

/// The whole difficulty of this feature in one function.
function isRetraction(range: { start: number; end: number }, tokens: SpeechToken[]): boolean {
  if (range.start > 0) {
    const before = tokens[range.start - 1]!.normalised;
    if (REPORTING_VERBS.has(before) || QUOTING_NOUNS.has(before)) return false;
  }
  if (range.end < tokens.length) {
    if (SUBJECT_MARKERS.has(tokens[range.end]!.normalised)) return false;
  }
  // A cue with nothing after it can only be an abandonment ("...never mind"),
  // and a cue with nothing before it cannot be taking anything back — there is
  // nothing behind it to take back.
  if (range.start === 0) return false;
  return true;
}

/// A run of tokens immediately repeated: "the the", "we should we should".
export function firstRepetition(tokens: SpeechToken[]): { start: number; length: number } | null {
  let index = 0;
  while (index < tokens.length) {
    // Longest run first: "we should we should" is one 2-token repeat, not two
    // coincidental 1-token ones.
    const longest = Math.min(3, Math.floor((tokens.length - index) / 2));
    for (let length = longest; length >= 1; length -= 1) {
      const a = tokens.slice(index, index + length).map((t) => t.normalised);
      const b = tokens.slice(index + length, index + 2 * length).map((t) => t.normalised);
      if (a.length !== b.length || !a.every((word, i) => word === b[i])) continue;
      if (a.some((word) => word.length === 0)) continue;
      if (length === 1 && LEGITIMATE_DOUBLES.has(a[0]!)) continue;
      return { start: index, length };
    }
    index += 1;
  }
  return null;
}

/// Whether a language model has anything to add to this transcript.
///
/// This is a latency decision and a safety decision at once. The fast pass
/// already handles punctuation, disfluency and vocabulary offline in under 2ms;
/// the only thing it cannot do is self-correction. So unless the transcript
/// shows a retraction or a stutter, the model pass is skipped entirely — no
/// round trip, and no opportunity for the model to "improve" a sentence that
/// was already right.
export function needsModelPass(text: string): boolean {
  const tokens = tokeniseSpeech(text);
  if (tokens.length <= 1) return false;
  if (cues(tokens).some((cue) => cue.isRetraction)) return true;
  return firstRepetition(tokens) !== null;
}

/// "The the build is is failing" → "The build is failing".
export function collapseRepetitions(tokens: SpeechToken[]): { tokens: SpeechToken[]; changed: boolean } {
  let changed = false;
  const out = [...tokens];
  // Bounded rather than `while (true)`: a rule that can loop is a rule that can
  // hang the dictation path, and this one runs inside a deadline.
  for (let round = 0; round < 8; round += 1) {
    const repetition = firstRepetition(out);
    if (!repetition) break;
    // Drop the first copy and keep the second, so the punctuation that followed
    // the phrase the speaker actually finished survives.
    out.splice(repetition.start, repetition.length);
    changed = true;
  }
  return { tokens: out, changed };
}

/// "send it to Noah no wait send it to Carlo" → "send it to Carlo".
///
/// The evidence is the repeat: the words after the cue restart a run of words
/// from before it. Without that repeat this rule does nothing, which is exactly
/// why "he said no wait and then walked off" is safe — "and then walked off"
/// restarts nothing.
export function resolveParallelRestarts(tokens: SpeechToken[]): boolean {
  const all = cues(tokens).filter((cue) => cue.isRetraction).reverse();
  for (const cue of all) {
    const after = tokens.slice(cue.end).map((t) => t.normalised);
    if (after.length === 0) continue;
    const before = tokens.slice(0, cue.start).map((t) => t.normalised);

    // Longest restart wins: matching three words is strong evidence, matching
    // one is weak.
    const longest = Math.min(4, after.length);
    for (let length = longest; length >= 1; length -= 1) {
      const head = after.slice(0, length);
      // The LAST occurrence, not the first. The restart point is the most
      // recent place those words were said, and taking the first ate every
      // clause between them:
      //
      // "Send it to Noah and then send it to Sam no wait send it to Carlo."
      // The head is [send, it, to]; its first occurrence is token 0, so the
      // deletion ran from the very start of the utterance and produced "Send it
      // to Carlo." — losing the "send it to Noah" instruction, which was never
      // retracted.
      const start = lastIndexOf(head, before);
      if (start === null) continue;
      // One word only counts when it restarts the whole utterance — "I was
      // going to the I mean I went to the shop". Anywhere else a single shared
      // word is coincidence, not a restart.
      if (length < 2 && start !== 0) continue;
      tokens.splice(start, cue.end - start);
      return true;
    }
  }
  return false;
}

/// "at 3 actually make that 4" → "at 4"; "for 500 sorry 1500 dollars" →
/// "for 1500 dollars".
///
/// The evidence is that the token before the cue and the token after it are the
/// same *kind* of thing — two numbers, or two mid-sentence proper nouns. A swap
/// between things of different kinds is not a swap, it is a sentence.
export function resolveSwaps(tokens: SpeechToken[]): boolean {
  const all = cues(tokens).filter((cue) => cue.isRetraction).reverse();
  for (const cue of all) {
    const replacedIndex = cue.start - 1;
    const replacementIndex = cue.end;
    if (replacedIndex < 0 || replacementIndex >= tokens.length) continue;
    if (!areSwapCompatible(tokens, replacedIndex, replacementIndex)) continue;
    // Carry the replaced token's leading punctuation forward so "(500 sorry
    // 1500" does not lose its bracket.
    const lead = tokens[replacedIndex]!.lead;
    tokens.splice(replacedIndex, replacementIndex - replacedIndex);
    if (lead.length > 0) tokens[replacedIndex]!.lead = lead + tokens[replacedIndex]!.lead;
    return true;
  }
  return false;
}

function areSwapCompatible(tokens: SpeechToken[], a: number, b: number): boolean {
  const left = tokens[a]!;
  const right = tokens[b]!;
  if (tokenIsNumber(left) && tokenIsNumber(right)) return true;
  // Mid-sentence capitals only. A capital in first position is just the start
  // of a sentence and says nothing about the word.
  const leftIsName = a > 0 && tokenIsCapitalised(left) && !tokenEndsSentence(tokens[a - 1]!);
  const rightIsName = tokenIsCapitalised(right);
  return leftIsName && rightIsName && left.normalised !== right.normalised;
}

/// "send Carlo the invoice you know what never mind" → "send Carlo the invoice".
///
/// Strips the abandonment, not the sentence. Deleting what was actually said
/// would be the literal reading, and it would insert nothing at all after a
/// dictation — indistinguishable from the app being broken.
export function stripTrailingAbandonment(tokens: SpeechToken[]): boolean {
  const endings: string[][] = [
    ['you', 'know', 'what', 'never', 'mind'], ['you', 'know', 'what', 'forget', 'it'],
    ['never', 'mind'], ['nevermind'], ['forget', 'it'], ['forget', 'that'],
    ['scratch', 'that'], ['actually', 'never', 'mind'],
  ].sort((a, b) => b.length - a.length);

  for (const phrase of endings) {
    if (tokens.length <= phrase.length) continue;
    const tail = tokens.slice(tokens.length - phrase.length).map((t) => t.normalised);
    if (!tail.every((word, i) => word === phrase[i])) continue;
    // Never strip down to a fragment; two surviving words is the floor.
    if (tokens.length - phrase.length < 2) continue;
    const punctuation = tokens[tokens.length - 1]!.trail;
    tokens.splice(tokens.length - phrase.length, phrase.length);
    const last = tokens[tokens.length - 1]!;
    if (last.trail.length === 0) last.trail = punctuation;
    return true;
  }
  return false;
}

/// Repairs the unambiguous cases with no network. Returns null when it is not
/// confident, which means the untouched fast text ships.
///
/// Only four rules, each requiring evidence beyond the cue word itself. The cue
/// alone is never enough — that is what makes "he said no wait and then walked
/// off" survive intact.
export function resolveSelfCorrection(text: string, terms: string[] = []): string | null {
  let tokens = tokeniseSpeech(text);
  if (tokens.length <= 1) return null;

  const collapsed = collapseRepetitions(tokens);
  tokens = collapsed.tokens;
  let changed = collapsed.changed;
  // Bounded rather than "until nothing changes": one utterance can carry two
  // corrections, but this runs on the dictation path inside a deadline and a
  // rule engine that can spin is a rule engine that can hang it.
  for (let round = 0; round < 4; round += 1) {
    if (resolveParallelRestarts(tokens)) { changed = true; continue; }
    if (resolveSwaps(tokens)) { changed = true; continue; }
    break;
  }
  if (stripTrailingAbandonment(tokens)) changed = true;
  if (!changed || tokens.length === 0) return null;

  const rebuilt = joinSpeech(tokens);
  const tidied = tightenPunctuationSpacing(collapseWhitespace(rebuilt));
  const out = capitaliseUnlessProtected(tidied, terms);
  return out === text ? null : out;
}

/// Sentence-cases the result, except when the first word is one of the user's
/// terms. Deleting a false start can promote "graphify" to the front of the
/// sentence, and "Graphify" is a different word — `AIOutputGuard` rejects an AI
/// response for exactly that, so doing it here would be the offline path
/// committing the sin the online path guards against.
function capitaliseUnlessProtected(text: string, terms: string[]): string {
  const protectedWords = new Set(terms.flatMap((term) => term.split(' ')));
  const first = text.split(' ')[0] ?? '';
  const bare = trimPunctuation(first);
  if (protectedWords.has(bare)) return text;
  return capitaliseSentences(text);
}
