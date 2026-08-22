import { alphanumericKey, isAlphanumeric, isWhitespace, trim } from '../text/strings';
import type { Snippet } from '../stores/snippets';

/// Swaps trigger phrases for the blocks of text they stand for.
///
/// Runs *after* cleanup and *before* insertion. Both halves of that are
/// deliberate. After cleanup, because the cleaner capitalises sentences and
/// repairs vocabulary, and a replacement that has already been dropped in would
/// be rewritten by it — "romangigliotti123@gmail.com" is not a sentence and
/// must not be sentence-cased. Before insertion, because the alternative is
/// typing the phrase into someone's document and then mutating text they are
/// already reading.
///
/// MATCHING IS EXACT, AND THAT IS THE WHOLE DESIGN. The vocabulary corrector
/// next door matches fuzzily on purpose — the worst case there is one wrong
/// noun. Here the worst case is four hundred characters of a client quote
/// landing in the middle of a message to someone else, and the user does not
/// notice until after they hit send. So: words are compared after case and
/// punctuation are stripped, and nothing else. No edit distance, no stemming,
/// no "close enough".
///
/// What the comparison *does* forgive is everything the recogniser adds on its
/// own — capitalisation at a sentence start, a comma the user never said, a
/// hyphen in "e-mail". Those are transcription artefacts, not different words.

export interface Firing {
  id: string;
  phrase: string;
  /// Where the trigger sat in the input, in UTF-16 units.
  sourceStart: number;
  sourceLength: number;
  /// Where the replacement sits in the output, in UTF-16 units.
  outputStart: number;
  outputLength: number;
}

export interface ExpansionResult {
  text: string;
  firings: Firing[];
  didFire: boolean;
}

interface SnippetToken {
  normalised: string;
  /// The word's own range, with any surrounding punctuation excluded.
  start: number;
  end: number;
}

export function isWordCharacter(character: string): boolean {
  return isAlphanumeric(character);
}

/// Lowercased, letters and digits only. This is what forgives the comma the
/// recogniser invented and the capital it added at a sentence start, while
/// still refusing anything that is a genuinely different word.
export function normaliseSnippetWord(text: string): string {
  return alphanumericKey(text);
}

/// Splits on whitespace, then trims non-word characters off each end and
/// records where the word itself sits.
///
/// Whitespace rather than a locale word breaker on purpose, and the difference
/// is not academic: ICU's word breaker splits "e-mail" into two words, so a
/// phrase saved as "my e-mail" would be three tokens and could never match the
/// two the recogniser produces for the same spoken sound. What a person hears
/// as one word has to be one token here.
///
/// Chunks that are nothing but punctuation drop out entirely — an em dash the
/// recogniser inserted must not break a phrase in half, and must not count as a
/// word either.
export function tokeniseSnippets(text: string): SnippetToken[] {
  const tokens: SnippetToken[] = [];
  let index = 0;
  while (index < text.length) {
    while (index < text.length && isWhitespace(text[index]!)) index += 1;
    if (index >= text.length) break;

    const chunkStart = index;
    while (index < text.length && !isWhitespace(text[index]!)) index += 1;

    let start = chunkStart;
    while (start < index && !isWordCharacter(text[start]!)) start += 1;
    let end = index;
    while (end > start && !isWordCharacter(text[end - 1]!)) end -= 1;
    if (start >= end) continue;

    const normalised = normaliseSnippetWord(text.slice(start, end));
    if (normalised.length === 0) continue;
    tokens.push({ normalised, start, end });
  }
  return tokens;
}

export function snippetWords(phrase: string): string[] {
  return tokeniseSnippets(phrase).map((token) => token.normalised);
}

export function expandSnippets(text: string, snippets: Snippet[]): ExpansionResult {
  const usable = snippets.filter(
    (snippet) => snippet.isEnabled
      && trim(snippet.phrase).length > 0
      && snippet.replacement.length > 0,
  );
  const none: ExpansionResult = { text, firings: [], didFire: false };
  if (usable.length === 0 || text.length === 0) return none;

  const tokens = tokeniseSnippets(text);
  if (tokens.length === 0) return none;

  // Whole-utterance rules get first refusal: if the entire dictation is the
  // phrase, that is unambiguous and beats any partial match.
  const whole = tokens.map((token) => token.normalised);
  for (const snippet of usable) {
    if (snippet.mode !== 'alone') continue;
    const words = snippetWords(snippet.phrase);
    if (words.length !== whole.length || !words.every((word, i) => word === whole[i])) continue;
    return {
      text: snippet.replacement,
      firings: [{
        id: snippet.id,
        phrase: snippet.phrase,
        sourceStart: 0,
        sourceLength: text.length,
        outputStart: 0,
        outputLength: snippet.replacement.length,
      }],
      didFire: true,
    };
  }

  // Longest phrase first, so "my email address" wins over a hypothetical
  // "email" rather than losing to whichever was created first.
  const candidates = usable
    .filter((snippet) => snippet.mode === 'anywhere')
    .map((snippet) => ({ snippet, words: snippetWords(snippet.phrase) }))
    .filter((candidate) => candidate.words.length > 0)
    .sort((a, b) => b.words.length - a.words.length);
  if (candidates.length === 0) return none;

  const matches: { start: number; end: number; snippet: Snippet }[] = [];
  let index = 0;
  while (index < tokens.length) {
    let matched = false;
    for (const candidate of candidates) {
      const span = candidate.words.length;
      if (index + span > tokens.length) continue;
      const window = tokens.slice(index, index + span).map((token) => token.normalised);
      if (!window.every((word, i) => word === candidate.words[i])) continue;
      // The replaced range covers the *words* only. Trailing punctuation
      // belongs to the sentence, not to the trigger, and eating the comma after
      // a phrase is the kind of bug that makes a feature feel unfinished.
      matches.push({
        start: tokens[index]!.start,
        end: tokens[index + span - 1]!.end,
        snippet: candidate.snippet,
      });
      index += span;
      matched = true;
      break;
    }
    if (!matched) index += 1;
  }
  if (matches.length === 0) return none;

  // Rebuilt left to right, which hands us the output ranges for free.
  let output = '';
  const firings: Firing[] = [];
  let cursor = 0;
  for (const match of matches) {
    if (match.start > cursor) output += text.slice(cursor, match.start);
    const location = output.length;
    output += match.snippet.replacement;
    firings.push({
      id: match.snippet.id,
      phrase: match.snippet.phrase,
      sourceStart: match.start,
      sourceLength: match.end - match.start,
      outputStart: location,
      outputLength: output.length - location,
    });
    cursor = match.end;
  }
  if (cursor < text.length) output += text.slice(cursor);

  output = capitaliseAfterFirings(output, firings);
  return { text: output, firings, didFire: true };
}

/// Re-capitalises the word immediately after a replacement that ended a
/// sentence.
///
/// The cleaner has already run by this point — it must, or it would
/// sentence-case an email address — so a replacement ending in a full stop
/// leaves "…the rest on launch. and I'll follow up." behind it. This is the one
/// thing the ordering costs, and it is one character to fix.
///
/// Only ever changes case, so every range handed back stays valid.
function capitaliseAfterFirings(output: string, firings: Firing[]): string {
  const chars = output.split('');
  const sentenceEnders = new Set(['.', '!', '?']);
  for (const firing of firings) {
    const end = firing.outputStart + firing.outputLength;
    if (end <= 0 || end >= chars.length) continue;
    const last = output[end - 1];
    if (!last || !sentenceEnders.has(last)) continue;

    let index = end;
    while (index < chars.length && isWhitespace(chars[index]!)) index += 1;
    if (index >= chars.length) continue;
    const letter = chars[index]!;
    const upper = letter.toUpperCase();
    // "ß".toUpperCase() is "SS". A one-for-one swap keeps every range valid;
    // anything else would silently slide the highlights.
    if (upper === letter || upper.length !== 1) continue;
    chars[index] = upper;
  }
  return chars.join('');
}
