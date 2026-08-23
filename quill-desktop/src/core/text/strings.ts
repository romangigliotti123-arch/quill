// String primitives the rest of the app is built on.
//
// Swift's `String` iterates GRAPHEME CLUSTERS and JavaScript's iterates UTF-16
// code units, and the difference is not academic here: `LiveTyper` turns a
// character count into that many backspaces, and one backspace deletes one
// visible character. Counting UTF-16 units takes half an emoji off and leaves a
// fragment behind — silent corruption of text the user spoke, which is the
// failure the whole injection subsystem exists to prevent.
//
// So anything that counts characters for the keyboard goes through
// `graphemes()`. Everything else — regex work, JSON, comparisons — stays on
// ordinary strings, because converting there would cost time and buy nothing.

const segmenter: Intl.Segmenter | null =
  typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function'
    ? new Intl.Segmenter(undefined, { granularity: 'grapheme' })
    : null;

/** Visible characters, in order. */
export function graphemes(text: string): string[] {
  if (!text) return [];
  if (!segmenter) return Array.from(text);
  const out: string[] = [];
  for (const piece of segmenter.segment(text)) out.push(piece.segment);
  return out;
}

/** How many backspaces it takes to delete `text`. */
export function graphemeCount(text: string): number {
  if (!text) return 0;
  if (!segmenter) return Array.from(text).length;
  let n = 0;
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  for (const _ of segmenter.segment(text)) n += 1;
  return n;
}

// MARK: - Character classes
//
// Swift's `Character.isLetter` and friends are Unicode-aware. The JavaScript
// equivalents are regexes with the `u` flag; they are built once here rather
// than inline, because a regex literal inside a hot loop is recompiled on some
// engines and the vocabulary matcher runs these per character per partial.

const RE_LETTER = /\p{L}/u;
const RE_NUMBER = /\p{N}/u;
const RE_ALNUM = /[\p{L}\p{N}]/u;
const RE_UPPER = /\p{Lu}/u;
const RE_LOWER = /\p{Ll}/u;
const RE_WHITESPACE = /\s/u;
const RE_PUNCT_OR_SYMBOL = /[\p{P}\p{S}]/u;

export const isLetter = (c: string): boolean => RE_LETTER.test(c);
export const isNumber = (c: string): boolean => RE_NUMBER.test(c);
export const isAlphanumeric = (c: string): boolean => RE_ALNUM.test(c);
export const isUppercase = (c: string): boolean => RE_UPPER.test(c);
export const isLowercase = (c: string): boolean => RE_LOWER.test(c);
export const isWhitespace = (c: string): boolean => RE_WHITESPACE.test(c);
export const isPunctuationOrSymbol = (c: string): boolean => RE_PUNCT_OR_SYMBOL.test(c);

/** Swift's `CharacterSet.punctuationCharacters` — punctuation only, not symbols. */
const RE_PUNCT = /\p{P}/u;
export const isPunctuation = (c: string): boolean => RE_PUNCT.test(c);

/** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
export function trim(text: string): string {
  return text.replace(/^\s+|\s+$/gu, '');
}

/** `trimmingCharacters(in: .punctuationCharacters)` — both ends, punctuation only. */
export function trimPunctuation(text: string): string {
  let start = 0;
  let end = text.length;
  while (start < end && isPunctuation(text[start]!)) start += 1;
  while (end > start && isPunctuation(text[end - 1]!)) end -= 1;
  return text.slice(start, end);
}

/** Trim any character in `set` off both ends. */
export function trimCharacters(text: string, set: string): string {
  let start = 0;
  let end = text.length;
  while (start < end && set.includes(text[start]!)) start += 1;
  while (end > start && set.includes(text[end - 1]!)) end -= 1;
  return text.slice(start, end);
}

/** Split on whitespace, dropping empty pieces. Swift's `split(whereSeparator: \.isWhitespace)`. */
export function splitWhitespace(text: string): string[] {
  return text.split(/\s+/u).filter((piece) => piece.length > 0);
}

/** Words, for a word count. Matches `split(whereSeparator: \.isWhitespace).count`. */
export function wordCount(text: string): number {
  return splitWhitespace(text).length;
}

/** Lowercased, letters and digits only. */
export function alphanumericKey(text: string): string {
  let out = '';
  for (const c of text.toLowerCase()) if (isAlphanumeric(c)) out += c;
  return out;
}

/** Lowercased, letters only. Spaces go too — that is what lets "graph if I" and
 *  "graphify" be compared at all. */
export function lettersOnly(text: string): string {
  let out = '';
  for (const c of text.toLowerCase()) if (isLetter(c)) out += c;
  return out;
}

/** Escapes a literal for use inside a `RegExp`. Swift's `NSRegularExpression.escapedPattern`. */
export function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Escapes a literal for use as a `String.replace` REPLACEMENT.
 *
 *  `$1` in a replacement string is a capture group, so a phrasing the user
 *  taught by dictating a price — "$100" — would be read as group 1 and vanish.
 *  Swift's `NSRegularExpression.escapedTemplate` exists for exactly this, and
 *  using the pattern escaper for both is silent corruption. */
export function escapeReplacement(text: string): string {
  return text.replace(/\$/g, '$$$$');
}

/** Every `\b<literal>\b` occurrence replaced, case-insensitively. */
export function replaceWord(text: string, wrong: string, right: string): string {
  return text.replace(
    new RegExp(`\\b${escapeRegExp(wrong)}\\b`, 'giu'),
    escapeReplacement(right),
  );
}

/** Case-insensitive equality, the way Swift's `compare(_:options:.caseInsensitive)` is used here. */
export function equalsIgnoringCase(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}
