import type { NumberStyle } from '../settings';
import { isLetter, isNumber, trimCharacters } from '../text/strings';

// How a spoken number is written down.
//
// The recogniser is already good at this — "I'm 15 years old" and "6th of
// April, 1830" come back as digits, "one of you" and "the two parties" as
// words — so the job here is a light rule on top, not an override.
//
// The refusals are the substance. Checked against a real corpus, where "On 6
// April 1830, the church was organised" would otherwise have shipped as "On six
// April 1830", and where 20 of 299 recorded transcripts contain a bare small
// digit at all. A number touching a month, a colon, a dollar sign, a decimal
// point, an "@" or a hyphen is part of something, and the something is never
// prose.

const PUNCTUATION = ',.;:!?"\'()[]“”‘’';

export function bareWord(token: string): string {
  return trimCharacters(token, PUNCTUATION);
}

export function trailingPunctuation(token: string): string {
  let out = '';
  for (let index = token.length - 1; index >= 0; index -= 1) {
    const character = token[index]!;
    if (!',.;:!?"\')]'.includes(character)) break;
    out = character + out;
  }
  return out;
}

export const MONTH_NAMES = new Set([
  'january', 'february', 'march', 'april', 'may', 'june', 'july',
  'august', 'september', 'october', 'november', 'december',
  'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
]);

/// "5 years old" is an age and stays a numeral; "5 minutes" is a count and
/// does not.
export const AGE_WORDS = new Set(['years', 'year', 'yo', 'y/o']);

/// A numbered reference is a label, not a quantity. "See chapter 3", not
/// "see chapter three".
export const NUMBERED_REFERENCE_WORDS = new Set([
  'chapter', 'version', 'page', 'step', 'part', 'figure', 'table', 'number',
  'no', 'item', 'level', 'round', 'phase', 'question', 'task', 'line', 'row',
  'column', 'section', 'room', 'unit', 'model', 'size', 'grade', 'track',
  'episode', 'season', 'volume', 'issue', 'week', 'day', 'apartment', 'suite',
  'build', 'rev', 'revision', 'port', 'channel', 'tier',
]);

/// Anything carrying structure — an address, a version, a time, money, a URL,
/// an identifier. Never prose, so never restyled, in any mode.
function isStructural(token: string): boolean {
  if (token.includes('@') || token.includes('/') || token.includes(':')) return true;
  if (token.includes('$') || token.includes('%') || token.includes('_')) return true;
  // A hyphen between digits is a phone number or a range, not two words.
  if (token.includes('-') && Array.from(token).some(isNumber)) return true;
  // A dot with a digit on either side is a decimal or a version.
  return hasInternalDot(token);
}

function hasInternalDot(token: string): boolean {
  const chars = Array.from(token);
  for (let index = 0; index < chars.length; index += 1) {
    if (chars[index] !== '.') continue;
    const previous = index > 0 ? chars[index - 1]! : ' ';
    const next = index + 1 < chars.length ? chars[index + 1]! : ' ';
    if (isNumber(previous) || isNumber(next)) return true;
    if (isLetter(previous) && isLetter(next)) return true;
  }
  return false;
}

/// Whether the words either side say "this number is a date, an age, or a
/// numbered thing" — all of which keep their digits whatever the mode.
function numberKeepsItsDigits(before: string, after: string): boolean {
  if (MONTH_NAMES.has(before) || MONTH_NAMES.has(after)) return true;
  if (AGE_WORDS.has(after) || before === 'aged') return true;
  if (NUMBERED_REFERENCE_WORDS.has(before)) return true;
  return false;
}

/// Replaces the word inside a token, keeping whatever punctuation was attached.
function replacingWord(token: string, replacement: string): string {
  const word = bareWord(token);
  const at = token.indexOf(word);
  if (word.length === 0 || at < 0) return replacement;
  return token.slice(0, at) + replacement + token.slice(at + word.length);
}

const ONES = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven',
  'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen',
  'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen',
];
const TENS = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];

/// Spelled English for 0…9999. Beyond that a number is a year or an amount and
/// spelling it out helps nobody, so `applyNumberStyle` does not ask.
export function englishNumber(value: number): string {
  if (value < 20) return ONES[value]!;
  if (value < 100) {
    const unit = value % 10;
    return unit === 0 ? TENS[Math.floor(value / 10)]! : `${TENS[Math.floor(value / 10)]}-${ONES[unit]}`;
  }
  if (value < 1000) {
    const rest = value % 100;
    const head = `${ONES[Math.floor(value / 100)]} hundred`;
    return rest === 0 ? head : `${head} and ${englishNumber(rest)}`;
  }
  const rest = value % 1000;
  const head = `${englishNumber(Math.floor(value / 1000))} thousand`;
  return rest === 0 ? head : `${head} ${englishNumber(rest)}`;
}

const WORD_NUMBERS: Record<string, number> = {
  zero: 0, one: 1, two: 2, three: 3, four: 4, five: 5,
  six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11,
  twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15,
  sixteen: 16, seventeen: 17, eighteen: 18, nineteen: 19,
  twenty: 20, thirty: 30, forty: 40, fifty: 50, sixty: 60,
  seventy: 70, eighty: 80, ninety: 90,
};

/// The single words that mean a number, for the always-digits direction.
export function numberFromWords(word: string): number | null {
  const value = WORD_NUMBERS[word.toLowerCase()];
  return value === undefined ? null : value;
}

/** Whole-string integer, the way Swift's `Int(_:)` behaves — no partial parses. */
function wholeInt(text: string): number | null {
  if (!/^-?\d+$/.test(text)) return null;
  const value = Number.parseInt(text, 10);
  return Number.isFinite(value) ? value : null;
}

/// "20 5 people" back into "25 people", after always-digits turned each word of
/// "twenty five" into its own numeral. Only joins a round ten to a single unit,
/// which is the only pair that is one spoken number rather than two.
///
/// Requires BOTH halves to be ones this pass spelled out. An earlier version ran
/// `\b([2-9])0 ([1-9])\b` over the joined sentence, after the loop above had
/// carefully skipped every structural token — which put it outside the only
/// guard in this function. A word boundary sits after a colon and after a dot,
/// so "the 10:30 5 minutes early" became "the 10:35 minutes early", and
/// "1.20 5 times" became "1.25 times": times and version numbers, the exact
/// tokens `isStructural` exists to protect, silently rewritten one step after
/// being protected.
function collapseSpokenTens(tokens: string[], spelledOut: Set<number>): string[] {
  if (spelledOut.size === 0) return tokens;
  const out: string[] = [];
  let index = 0;
  while (index < tokens.length) {
    const next = index + 1;
    if (spelledOut.has(index) && spelledOut.has(next)) {
      const tens = wholeInt(tokens[index]!);
      const unit = wholeInt(bareWord(tokens[next]!));
      if (tens !== null && tens >= 20 && tens <= 90 && tens % 10 === 0
        && unit !== null && unit >= 1 && unit <= 9) {
        out.push(replacingWord(tokens[next]!, String(tens + unit)));
        index += 2;
        continue;
      }
    }
    out.push(tokens[index]!);
    index += 1;
  }
  return out;
}

/// Applies the chosen number style, and refuses on everything structural.
export function applyNumberStyle(text: string, style: NumberStyle): string {
  if (style === 'asHeard') return text;

  const tokens = text.split(' ');
  const out = [...tokens];
  const spelledOut = new Set<number>();

  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index]!;
    if (isStructural(token)) continue;
    // The style guards belong to the writing convention, so they apply to the
    // mode that IS the writing convention. "Always words" is the blunt mode by
    // definition — someone who picks it has asked for every number spelled out
    // and should get it.
    if (style === 'spellOutSmall') {
      const before = index > 0 ? bareWord(tokens[index - 1]!).toLowerCase() : '';
      const after = index + 1 < tokens.length ? bareWord(tokens[index + 1]!).toLowerCase() : '';
      if (numberKeepsItsDigits(before, after)) continue;
    }

    const word = bareWord(token);

    if (style === 'spellOutSmall') {
      // One to nine only. Ten and up read better as digits, which is also what
      // the recogniser already produces.
      const value = wholeInt(word);
      if (value === null || value < 1 || value > 9) continue;
      out[index] = replacingWord(token, englishNumber(value));
    } else if (style === 'alwaysWords') {
      const value = wholeInt(word);
      if (value === null || value < 0 || value > 9999) continue;
      out[index] = replacingWord(token, englishNumber(value));
    } else if (style === 'alwaysDigits') {
      const value = numberFromWords(word);
      if (value === null) continue;
      out[index] = replacingWord(token, String(value));
      spelledOut.add(index);
    }
  }

  const final = style === 'alwaysDigits' ? collapseSpokenTens(out, spelledOut) : out;
  return final.join(' ');
}
