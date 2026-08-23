import { alphanumericKey, isLetter, isNumber, isUppercase, splitWhitespace } from './strings';

/// A word with its punctuation kept beside it rather than glued to it.
///
/// Every rule in `selfCorrection` and in `cleanupProjection` reasons about
/// words; every rule also has to put the commas back afterwards. Splitting them
/// once, here, is what stops "send it to Noah, no wait, send it to Carlo." from
/// losing its full stop.
export interface SpeechToken {
  lead: string;
  word: string;
  trail: string;
  /// Lowercased, letters and digits only. Apostrophes go too, which is what
  /// lets "lets" and "Let's" compare equal — the model is allowed to add the
  /// apostrophe, and that must not read as a changed word.
  readonly normalised: string;
}

export function makeSpeechToken(lead: string, word: string, trail: string): SpeechToken {
  return { lead, word, trail, normalised: alphanumericKey(word) };
}

const SPELLED_NUMBERS = new Set([
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
  'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
  'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty', 'thirty',
  'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety', 'hundred', 'thousand',
]);

export function tokenIsNumber(token: SpeechToken): boolean {
  const n = token.normalised;
  if (n.length > 0 && Array.from(n).every(isNumber)) return true;
  return SPELLED_NUMBERS.has(n);
}

export function tokenIsCapitalised(token: SpeechToken): boolean {
  const first = token.word[0];
  return first !== undefined && isUppercase(first) && token.normalised !== 'i';
}

export function tokenEndsSentence(token: SpeechToken): boolean {
  return Array.from(token.trail).some((c) => '.!?'.includes(c));
}

export function tokeniseSpeech(text: string): SpeechToken[] {
  const tokens: SpeechToken[] = [];
  for (const chunk of splitWhitespace(text)) {
    const s = chunk;
    let leadEnd = 0;
    while (leadEnd < s.length && !isLetter(s[leadEnd]!) && !isNumber(s[leadEnd]!)) leadEnd += 1;
    const lead = s.slice(0, leadEnd);
    let rest = s.slice(leadEnd);
    let trail = '';
    while (rest.length > 0) {
      const last = rest[rest.length - 1]!;
      if (isLetter(last) || isNumber(last)) break;
      trail = last + trail;
      rest = rest.slice(0, -1);
    }
    const word = rest;
    if (word.length === 0) {
      // Stray punctuation. Glue it to whatever came before rather than carrying
      // an empty token that every rule would have to skip.
      if (tokens.length > 0) {
        tokens[tokens.length - 1]!.trail += lead + trail;
      } else if (s.length > 0) {
        tokens.push(makeSpeechToken('', '', s));
      }
      continue;
    }
    tokens.push(makeSpeechToken(lead, word, trail));
  }
  return tokens;
}

export function joinSpeech(tokens: SpeechToken[]): string {
  return tokens.map((t) => t.lead + t.word + t.trail).join(' ');
}
