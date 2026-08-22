import { escapeRegExp, splitWhitespace, trim, trimCharacters } from '../text/strings';
import { similarity, normalise } from '../cleanup/vocabularyCorrector';
import { spellingConvention, toBritish, type SpellingConvention } from './orthography';
import {
  Formality, MAXIMUM_PHRASINGS, StyleProfile, StylePhrasing, addSample, makePhrasing,
  phrasingID, recordTrait,
} from './styleProfile';

/// Reading a style out of the difference between what Quill wrote and what the
/// user kept.
///
/// Every function here is pure: strings in, values out, no clock, no disk, no
/// model, no network. That is not tidiness — it is the only way this is
/// testable at all. The alternative shape, a learner that reaches into a store
/// and a model and a date, can only be checked by running the whole app and
/// reading the output, which is how a learning feature ends up shipping with a
/// detector that has never once fired.
///
/// # The rule every detector follows
///
/// **One correction, one vote per trait.** A paragraph containing "colour" four
/// times is one piece of evidence about spelling, not four. Without that rule a
/// single long email settles the entire profile, and the tally stops meaning
/// what it says.

export interface StyleObservation {
  spelling: SpellingConvention | null;
  contractions: boolean | null;
  formality: Formality | null;
  oxfordComma: boolean | null;
  exclamations: boolean | null;
  sentenceWords: number | null;
  phrasings: StylePhrasing[];
}

export const EMPTY_OBSERVATION: StyleObservation = {
  spelling: null,
  contractions: null,
  formality: null,
  oxfordComma: null,
  exclamations: null,
  sentenceWords: null,
  phrasings: [],
};

export function observationIsEmpty(observation: StyleObservation): boolean {
  return observation.spelling === null
    && observation.contractions === null
    && observation.formality === null
    && observation.oxfordComma === null
    && observation.exclamations === null
    && observation.sentenceWords === null
    && observation.phrasings.length === 0;
}

// MARK: - Diff

/// A run that differs. Either side may be empty: an insertion has no `from`, a
/// deletion has no `to`.
export interface DiffSegment {
  from: string[];
  to: string[];
}

/// O(n·m) in time and space, which is fine for a dictation — a long one is 200
/// words. Past this it bails to a single whole-text segment rather than
/// allocating a million-cell table for a pasted document; that segment is too
/// long to become a phrasing, so the effect is that a giant paste teaches
/// nothing rather than that it hangs.
export const MAXIMUM_DIFF_TOKENS = 400;

/// The form two tokens are considered equal by.
export function diffKey(token: string): string {
  return trimCharacters(normaliseApostrophes(token).toLowerCase(), nonWordCharacters(token));
}

function nonWordCharacters(token: string): string {
  // Everything in `token` that is not alphanumeric or an apostrophe, so the
  // trim can strip exactly those from both ends.
  let out = '';
  for (const c of token) {
    if (!/[\p{L}\p{N}']/u.test(c) && !out.includes(c)) out += c;
  }
  return out;
}

/// Longest common subsequence, backtracked into runs.
///
/// Tokens are matched on a normalised form — lowercased, outer punctuation
/// stripped — so "team," and "team" are the same word. That is what keeps the
/// diff reporting changes of *wording* rather than changes of typography;
/// punctuation habits are read off the whole text instead, where they belong.
export function diffSegments(before: string[], after: string[]): DiffSegment[] {
  if (before.length === after.length && before.every((word, i) => word === after[i])) return [];
  if (before.length > MAXIMUM_DIFF_TOKENS || after.length > MAXIMUM_DIFF_TOKENS) {
    return [{ from: before, to: after }];
  }

  const a = before.map(diffKey);
  const b = after.map(diffKey);
  const lengths: number[][] = [];
  for (let i = 0; i <= a.length; i += 1) lengths.push(new Array<number>(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i -= 1) {
    for (let j = b.length - 1; j >= 0; j -= 1) {
      lengths[i]![j] = a[i] === b[j]
        ? lengths[i + 1]![j + 1]! + 1
        : Math.max(lengths[i + 1]![j]!, lengths[i]![j + 1]!);
    }
  }

  const out: DiffSegment[] = [];
  let pendingFrom: string[] = [];
  let pendingTo: string[] = [];
  const flush = (): void => {
    if (pendingFrom.length > 0 || pendingTo.length > 0) {
      out.push({ from: pendingFrom, to: pendingTo });
      pendingFrom = [];
      pendingTo = [];
    }
  };

  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      flush();
      i += 1;
      j += 1;
    } else if (lengths[i + 1]![j]! >= lengths[i]![j + 1]!) {
      pendingFrom.push(before[i]!);
      i += 1;
    } else {
      pendingTo.push(after[j]!);
      j += 1;
    }
  }
  while (i < a.length) { pendingFrom.push(before[i]!); i += 1; }
  while (j < b.length) { pendingTo.push(after[j]!); j += 1; }
  flush();
  return out;
}

// MARK: - Lexicons

/// Contraction to expansion. Used three ways: to spot a contraction, to spot an
/// expansion, and to tell whether a diff segment is a contraction change rather
/// than a change of words.
export const CONTRACTION_EXPANSIONS: Record<string, string> = {
  "don't": 'do not', "doesn't": 'does not', "didn't": 'did not',
  "isn't": 'is not', "aren't": 'are not', "wasn't": 'was not',
  "weren't": 'were not', "won't": 'will not', "wouldn't": 'would not',
  "shouldn't": 'should not', "couldn't": 'could not', "can't": 'cannot',
  "haven't": 'have not', "hasn't": 'has not', "hadn't": 'had not',
  "it's": 'it is', "that's": 'that is', "there's": 'there is',
  "here's": 'here is', "what's": 'what is', "let's": 'let us',
  "i'm": 'i am', "i'll": 'i will', "i've": 'i have', "i'd": 'i would',
  "you're": 'you are', "you'll": 'you will', "you've": 'you have',
  "we're": 'we are', "we'll": 'we will', "we've": 'we have',
  "they're": 'they are', "they'll": 'they will', "they've": 'they have',
  "he's": 'he is', "she's": 'she is', "who's": 'who is',
};

const EXPANSION_FORMS = new Set(Object.values(CONTRACTION_EXPANSIONS));

/// Register markers. Short lists, and only ever consulted on both sides of an
/// actual swap — see `formality`.
const CASUAL_MARKERS = [
  'hey', 'hi', 'yeah', 'yep', 'nah', 'cheers', 'thanks', 'no worries',
  'cool', 'sure thing', 'catch you', 'talk soon',
];

const FORMAL_MARKERS = [
  'dear', 'hello', 'greetings', 'thank you', 'regards', 'kind regards',
  'sincerely', 'certainly', 'apologies', 'please find', 'best wishes',
  'yours faithfully',
];

// MARK: - Text helpers

export function tokensOf(text: string): string[] {
  return splitWhitespace(text);
}

/// Sentence-ish. Splits on terminal punctuation and on line breaks, which
/// matters more than it sounds: a bullet list has no full stops and is not one
/// forty-word sentence.
export function sentencesOf(text: string): string[] {
  return text
    .split(/[.!?\n]/u)
    .map((piece) => trim(piece))
    .filter((piece) => piece.length > 0);
}

/// Trims punctuation off the ends of a phrase and squeezes inner runs of
/// whitespace, so "hi team," and "hi team" are the same phrasing.
export function bare(text: string): string {
  return trim(text.replace(/^[\p{P}\s]+|[\p{P}\s]+$/gu, '')).replace(/\s+/gu, ' ');
}

/// Both apostrophes. The recogniser emits a straight quote and some systems
/// substitute a curly one as you type, so a correction routinely contains one
/// of each and a check that knows only about "'" sees no contractions at all in
/// half the text it is given.
export function normaliseApostrophes(text: string): string {
  return text.replace(/’/g, "'");
}

export function contractionCount(text: string): number {
  const lower = normaliseApostrophes(text).toLowerCase();
  return tokensOf(lower)
    .map((token) => trimCharacters(token, '.,;:!?"()[]-—…'))
    .filter((token) => CONTRACTION_EXPANSIONS[token] !== undefined)
    .length;
}

export function expansionCount(text: string): number {
  const lower = ` ${normaliseApostrophes(text).toLowerCase()} `;
  let total = 0;
  for (const form of EXPANSION_FORMS) {
    total += lower.split(` ${form} `).length - 1;
  }
  return total;
}

export function expandContractions(text: string): string {
  let out = normaliseApostrophes(text);
  for (const [contraction, expansion] of Object.entries(CONTRACTION_EXPANSIONS)) {
    out = out.replace(new RegExp(`\\b${escapeRegExp(contraction)}\\b`, 'giu'), expansion);
  }
  return out;
}

// MARK: - Detectors

/// Spelling convention, from the correction if it shows one and from the
/// approved text otherwise.
///
/// The diff is the stronger signal — "capitalization" corrected to
/// "capitalisation" is a statement of preference — but it only fires when Quill
/// got it wrong in the first place. Scanning the text they kept catches the far
/// commoner case where they wrote "colour" themselves and left it alone.
export function detectSpelling(segments: DiffSegment[], edited: string): SpellingConvention | null {
  for (const segment of segments) {
    if (segment.from.length !== 1 || segment.to.length !== 1) continue;
    const before = spellingConvention(segment.from[0]!);
    const after = spellingConvention(segment.to[0]!);
    if (!before || !after || before === after) continue;
    return after;
  }

  let british = 0;
  let american = 0;
  for (const token of tokensOf(edited)) {
    const convention = spellingConvention(token);
    if (convention === 'british') british += 1;
    else if (convention === 'american') american += 1;
  }
  if (british === american) return null;
  return british > american ? 'british' : 'american';
}

/// Whether they write "don't" or "do not".
export function detectContractions(segments: DiffSegment[], edited: string): boolean | null {
  const removed = segments.map((segment) => segment.from.join(' ')).join(' ');
  const added = segments.map((segment) => segment.to.join(' ')).join(' ');

  const contractionDelta = contractionCount(added) - contractionCount(removed);
  const expansionDelta = expansionCount(added) - expansionCount(removed);
  if (contractionDelta > 0 && expansionDelta <= 0) return true;
  if (contractionDelta < 0 && expansionDelta > 0) return false;

  // No signal in the edit. Fall back to the text they approved — but only when
  // it is one-sided. Two expanded forms and no contractions is a habit; one "it
  // is" in a paragraph is a sentence.
  const contractions = contractionCount(edited);
  const expansions = expansionCount(edited);
  if (contractions > 0 && expansions === 0) return true;
  if (expansions >= 2 && contractions === 0) return false;
  return null;
}

/// Register, from greeting and sign-off swaps only.
///
/// Deliberately narrow. Formality is the trait most tempting to infer from
/// vibes — word length, sentence structure, an exclamation mark — and the one
/// where being wrong is most obvious, because it changes how every dictation
/// sounds rather than how one word is spelled. So it is learned only from a
/// swap the user actually made.
export function detectFormality(segments: DiffSegment[]): Formality | null {
  for (const segment of segments) {
    const before = segment.from.join(' ').toLowerCase();
    const after = segment.to.join(' ').toLowerCase();
    const wasCasual = CASUAL_MARKERS.some((marker) => before.includes(marker));
    const wasFormal = FORMAL_MARKERS.some((marker) => before.includes(marker));
    const isCasual = CASUAL_MARKERS.some((marker) => after.includes(marker));
    const isFormal = FORMAL_MARKERS.some((marker) => after.includes(marker));
    if (wasCasual && isFormal && !isCasual) return 'formal';
    if (wasFormal && isCasual && !isFormal) return 'casual';
  }
  return null;
}

/// Serial comma, read off the text they kept.
///
/// Only lists are counted, and a list is recognised by there being a comma
/// somewhere before the "and" that is not the one under examination. That test
/// exists to keep "I called Noah, and he said yes" — a joined clause, not a
/// list — from voting. Returns null unless every list in the text agrees,
/// because someone who does both has no preference to learn.
export function detectOxfordComma(text: string): boolean | null {
  const verdicts = new Set<boolean>();
  for (const sentence of sentencesOf(text)) {
    const words = tokensOf(sentence);
    if (words.length < 4) continue;
    for (let index = 2; index < words.length - 1; index += 1) {
      const bareWord = trimCharacters(words[index]!.toLowerCase(), '.,;:!?"()[]');
      if (bareWord !== 'and' && bareWord !== 'or') continue;
      const preceding = words.slice(0, index);
      const commasBefore = preceding.filter((word) => word.endsWith(',')).length;
      if (words[index - 1]!.endsWith(',')) {
        // "a, b, and c" — needs a second comma to prove it is a list.
        if (commasBefore >= 2) verdicts.add(true);
      } else if (commasBefore >= 1) {
        verdicts.add(false);
      }
    }
  }
  return verdicts.size === 1 ? [...verdicts][0]! : null;
}

/// Exclamation marks, counted on whole texts rather than on the diff — deleting
/// a "!" changes no word, so it never shows up as a replacement.
export function detectExclamations(dictated: string, edited: string): boolean | null {
  const before = Array.from(dictated).filter((c) => c === '!').length;
  const after = Array.from(edited).filter((c) => c === '!').length;
  if (after > before) return true;
  if (after < before) return false;
  return null;
}

/// Mean words per sentence of the text they approved.
export function detectSentenceWords(text: string): number | null {
  const parts = sentencesOf(text).filter((sentence) => tokensOf(sentence).length > 0);
  if (parts.length === 0) return null;
  const words = parts.reduce((total, sentence) => total + tokensOf(sentence).length, 0);
  // Under five words there is no sentence-length habit to measure, only a
  // fragment: "yep", "on it", "sounds good".
  if (words < 5) return null;
  return words / parts.length;
}

/// Rewrites worth remembering: they replaced these words with those words.
///
/// Everything explained by another trait is filtered out — a spelling change, a
/// contraction, or a near-identical respelling of the same word (which is a
/// vocabulary repair). What is left is a genuine choice of words.
export function detectPhrasings(segments: DiffSegment[]): StylePhrasing[] {
  const out: StylePhrasing[] = [];
  for (const segment of segments) {
    if (segment.from.length === 0 || segment.to.length === 0) continue;
    if (segment.from.length > 4 || segment.to.length > 4) continue;

    const from = bare(segment.from.join(' '));
    const to = bare(segment.to.join(' '));
    if (from.length === 0 || to.length === 0) continue;
    if (from.toLowerCase() === to.toLowerCase()) continue;

    if (toBritish(from).toLowerCase() === toBritish(to).toLowerCase()) continue;
    if (expandContractions(from).toLowerCase() === expandContractions(to).toLowerCase()) continue;

    // A near-identical respelling is a typo fix, not a phrasing. 0.85 is the
    // corrector's multi-word bar, borrowed for the same reason: above it the
    // two strings are the same word.
    if (similarity(normalise(from), normalise(to)) >= 0.85) continue;

    out.push(makePhrasing(from, to));
    // Three per correction. One heavily rewritten paragraph should not be able
    // to fill the table on its own.
    if (out.length === 3) break;
  }
  return out;
}

// MARK: - Entry points

/// What one correction says about how the user writes.
///
/// `dictated` is the text Quill inserted; `edited` is what they changed it to.
/// Returns an observation with a field set only where the evidence is
/// unambiguous — most corrections say one or two things, and a detector that
/// always has an opinion is a detector that is usually wrong.
export function observeStyle(dictated: string, edited: string): StyleObservation {
  const before = trim(dictated);
  const after = trim(edited);
  if (after.length === 0 || before === after) return EMPTY_OBSERVATION;

  const segments = diffSegments(tokensOf(before), tokensOf(after));

  return {
    spelling: detectSpelling(segments, after),
    contractions: detectContractions(segments, after),
    formality: detectFormality(segments),
    oxfordComma: detectOxfordComma(after),
    exclamations: detectExclamations(before, after),
    sentenceWords: detectSentenceWords(after),
    phrasings: detectPhrasings(segments),
  };
}

/// Fold an observation into a profile. Pure — the date is passed in.
export function applyObservation(
  observation: StyleObservation,
  profile: StyleProfile,
  at: Date,
): StyleProfile {
  if (!profile.isLearningEnabled || observationIsEmpty(observation)) return profile;
  const updated = structuredClone(profile);

  if (observation.spelling !== null) recordTrait(updated.spelling, observation.spelling, at);
  if (observation.contractions !== null) {
    recordTrait(updated.contractions, observation.contractions ? 'yes' : 'no', at);
  }
  if (observation.formality !== null) recordTrait(updated.formality, observation.formality, at);
  if (observation.oxfordComma !== null) {
    recordTrait(updated.oxfordComma, observation.oxfordComma ? 'yes' : 'no', at);
  }
  if (observation.exclamations !== null) {
    recordTrait(updated.exclamations, observation.exclamations ? 'yes' : 'no', at);
  }
  if (observation.sentenceWords !== null) addSample(updated.sentenceLength, observation.sentenceWords);

  for (const phrasing of observation.phrasings) {
    const index = updated.phrasings.findIndex((existing) => phrasingID(existing) === phrasingID(phrasing));
    if (index >= 0) {
      updated.phrasings[index]!.count += 1;
      updated.phrasings[index]!.lastObserved = at;
    } else {
      updated.phrasings.push(makePhrasing(phrasing.from, phrasing.to, 1, at));
    }
  }
  // Strongest and most recent survive. The tail is one-off edits, and a list
  // that only grows is a file that only grows.
  if (updated.phrasings.length > MAXIMUM_PHRASINGS) {
    updated.phrasings.sort((a, b) => (a.count === b.count
      ? (b.lastObserved?.getTime() ?? 0) - (a.lastObserved?.getTime() ?? 0)
      : b.count - a.count));
    updated.phrasings.length = MAXIMUM_PHRASINGS;
  }

  updated.correctionCount += 1;
  updated.lastLearned = at;
  return updated;
}

export function learnStyle(
  dictated: string,
  edited: string,
  profile: StyleProfile,
  at: Date = new Date(),
): StyleProfile {
  return applyObservation(observeStyle(dictated, edited), profile, at);
}
