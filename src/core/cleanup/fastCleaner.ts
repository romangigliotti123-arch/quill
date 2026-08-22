import { escapeRegExp, escapeReplacement, isLetter, isLowercase, isNumber, isWhitespace, trim } from '../text/strings';
import { CORRECTIONS } from './corrections';
import { formatSpokenEmails } from './spokenEmail';
import { VocabularyCorrector } from './vocabularyCorrector';
import { VocabularyBook } from '../stores/vocabulary';

/// Turning raw speech into text someone would have typed.
///
/// The design is deliberate: a deterministic pass that is effectively free
/// always runs, and a model pass runs only if it can beat a deadline. Whatever
/// is ready when the deadline expires is what gets inserted.
///
/// The alternative designs were both worse. Waiting for the model would put
/// seconds between releasing the key and seeing text. Inserting raw text and
/// rewriting it afterwards means visibly mutating text the user is already
/// looking at, in an app we do not control.
export interface TranscriptCleaning {
  /** Must be fast enough to be invisible. Called on every dictation. */
  cleanFast(raw: string): string;
  /** May be slow and may return null if it could not finish in time. */
  cleanThorough(raw: string, deadlineMs: number): Promise<string | null>;
}

/// Words people say while thinking. Removed only when they stand alone — "um"
/// as a whole word goes, "umbrella" obviously does not.
const DISFLUENCIES = ['um', 'uh', 'erm', 'uhm', 'ah', 'eh', 'mm', 'hmm'];

/// Only the numbers anyone says before a decimal point. A version is "one point
/// two", a load time is "one point four" — nobody dictates "seventeen point
/// three" often enough to justify the extra surface for a wrong match.
export const NUMBER_WORDS: Record<string, string> = {
  zero: '0', one: '1', two: '2', three: '3', four: '4',
  five: '5', six: '6', seven: '7', eight: '8', nine: '9',
  ten: '10', eleven: '11', twelve: '12',
};

export class FastCleaner implements TranscriptCleaning {
  private readonly vocabulary: VocabularyCorrector;

  constructor(vocabulary?: VocabularyCorrector) {
    this.vocabulary = vocabulary ?? new VocabularyCorrector({ book: VocabularyBook.shared() });
  }

  cleanFast(raw: string): string {
    let text = trim(raw);
    if (text.length === 0) return text;

    // Before anything that treats a full stop as a sentence boundary.
    text = joinSpokenDecimals(text);
    text = applyCorrections(text);
    // Fuzzy pass second: the literal table above handles known phrasings
    // cheaply, this catches the ones where the recogniser split a word.
    text = this.vocabulary.correct(text);
    text = stripStandaloneDisfluencies(text);
    text = collapseWhitespace(text);
    text = tightenPunctuationSpacing(text);
    // After the spacing rules, so a domain the recogniser dotted correctly has
    // survived them; before the sentence casing, which knows to leave an
    // address lowercase.
    //
    // The number style is deliberately NOT here. It is a presentation choice
    // and the destination gets a vote, so it lives in `appContextFormatter`
    // alongside the other two — a terminal keeps its digits.
    text = formatSpokenEmails(text);
    text = capitaliseSentences(text);
    return text;
  }

  /// No model here. Callers race this against the real one.
  async cleanThorough(raw: string, _deadlineMs: number): Promise<string | null> {
    return this.cleanFast(raw);
  }
}

// MARK: - Steps, each independently testable

/// Turns "one. 4 seconds" back into "1.4 seconds".
///
/// The recogniser writes the spoken word "point" as a full stop. So "the page
/// loads in about one point four seconds" arrives as "one. 4 seconds", and then
/// sentence-casing sees a full stop and produces:
///
///     The page loads in about one. 4 Seconds on a cold cache.
///
/// Two errors and a capital letter in the middle of a sentence, from one spoken
/// decimal.
///
/// Deliberately narrow. It only fires when the thing before the full stop is a
/// spelled-out number word, because that is what the recogniser actually
/// produces here, and because a DIGIT before a full stop is far more likely to
/// be a real sentence ending — "it shipped in 2020. 3 people worked on it" must
/// not become "2020.3". Whatever follows may itself be dotted, so "one. 2.7"
/// comes out "1.2.7" rather than "1.2" with an orphan.
export function joinSpokenDecimals(text: string): string {
  const pattern = new RegExp(`\\b(${Object.keys(NUMBER_WORDS).join('|')})\\.\\s+(\\d+(?:\\.\\d+)*)`, 'i');
  let out = text;
  let from = 0;
  for (;;) {
    const searched = out.slice(from);
    const match = pattern.exec(searched);
    if (!match) break;
    const leading = NUMBER_WORDS[match[1]!.toLowerCase()];
    if (leading === undefined) break;
    const replacement = `${leading}.${match[2]}`;
    const start = from + match.index;
    out = out.slice(0, start) + replacement + out.slice(start + match[0].length);
    from = start + replacement.length;
  }
  return out;
}

export function applyCorrections(text: string): string {
  let out = text;
  for (const [wrong, right] of Object.entries(CORRECTIONS)) {
    out = out.replace(
      new RegExp(`\\b${escapeRegExp(wrong)}\\b`, 'giu'),
      escapeReplacement(right),
    );
  }
  return out;
}

export function stripStandaloneDisfluencies(text: string): string {
  const pattern = new RegExp(`\\b(${DISFLUENCIES.join('|')})\\b[,.]?`, 'giu');
  return text.replace(pattern, '');
}

export function collapseWhitespace(text: string): string {
  return text.replace(/\s+/gu, ' ').replace(/^ +| +$/g, '');
}

/// " ,"  ->  ","   and   "word.Next"  ->  "word. Next"
export function tightenPunctuationSpacing(text: string): string {
  let out = text.replace(/\s+([,.;:!?])/gu, '$1');
  // "word.Next" -> "word. Next", but not "node.js" -> "node. js".
  //
  // The recogniser writes node.js, three.js and roman-design-co.web.app
  // correctly, and this rule was pulling them apart — after which sentence
  // casing capitalised the fragment, so a correct "node.js" reached the
  // document as "node. Js".
  //
  // The test is the shape around the dot rather than a list of known suffixes:
  // a LOWERCASE letter directly after it. A dotted name is lowercase on both
  // sides; a sentence break is followed by a capital, because the recogniser
  // capitalises the sentences it emits. A suffix list was tried first and
  // immediately missed "web.app".
  out = out.replace(/([.!?])([A-Z])/g, '$1 $2');
  return out;
}

/// Sentence casing that knows a decimal point is not a full stop.
///
/// Every full stop used to arm the next capital, and the "next capital" was
/// simply the next letter — however far away, and across any number of digits.
/// So a decimal armed it and the digits could not absorb it, and the capital
/// landed on the following word:
///
///     The page loads in about 1.4 Seconds on a cold cache.
///     We cut version 2.0 Last night.
///     It shipped in 2020. 3 People worked on it.
///
/// Two rules fix all three. A full stop between two digits is a decimal and
/// ends nothing. And a pending capital expires when it meets a digit — after a
/// genuine sentence break the number itself opens the sentence, and a number
/// cannot be capitalised, so nothing further should be.
export function capitaliseSentences(text: string): string {
  const chars = Array.from(text);
  let capitaliseNext = true;
  for (let i = 0; i < chars.length; i += 1) {
    const c = chars[i]!;
    if (capitaliseNext && isLetter(c) && startsAnEmailAddress(chars, i)) {
      // "roman@gmail.com is the address" must not open with a capital R. An
      // address is case-insensitive but it is written lowercase, and a
      // capitalised one reads as a mistake because it is one.
      capitaliseNext = false;
    } else if (capitaliseNext && isLetter(c)) {
      chars[i] = c.toUpperCase();
      capitaliseNext = false;
    } else if (capitaliseNext && isNumber(c)) {
      // The sentence has started; it just started with a number.
      capitaliseNext = false;
    } else if (c === '.' || c === '!' || c === '?') {
      const previous = i > 0 ? chars[i - 1]! : ' ';
      const next = i + 1 < chars.length ? chars[i + 1]! : ' ';
      const isDecimalPoint = c === '.' && isNumber(previous) && isNumber(next);
      // A dot inside a name is not a sentence break either. Same bug as the
      // decimal, found the same way: "the node.js version bump" reached the
      // document as "the node.Js version bump". The test is the shape around
      // the dot — letter, dot, lowercase letter, with no space.
      const isInsideAName = c === '.' && isLetter(previous) && isLowercase(next);
      if (!isDecimalPoint && !isInsideAName) capitaliseNext = true;
    }
  }
  return chars.join('');
}

/// Whether the word beginning at `i` is an email address.
function startsAnEmailAddress(chars: string[], i: number): boolean {
  let j = i;
  while (j < chars.length && !isWhitespace(chars[j]!)) {
    if (chars[j] === '@') return true;
    j += 1;
  }
  return false;
}
