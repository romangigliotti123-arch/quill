import { AIOutputGuard } from '../ai/outputGuard';
import { isLetter, isNumber, isUppercase, trim } from '../text/strings';
import { homophoneMayReplace, normaliseHomophone } from './homophonePairs';

/// Checks a homophone pass's output, and rebuilds the result from the INPUT.
///
/// The pattern is `cleanupProjection`'s: state the contract in the prompt, then
/// enforce it in code afterwards, because a prompt is a request and a check is
/// a guarantee. What differs is how little of the model's answer is kept.
///
/// `cleanupProjection` returns the model's own text once it has been proved to
/// be the input with words removed. This does not. It reads the model's answer
/// only to learn *which listed word it chose at each position*, and then
/// rebuilds the sentence from the input, substituting exactly those words and
/// nothing else. Punctuation, capitalisation, spacing, every unlisted word —
/// all come from the input verbatim and are not the model's to change.
///
/// That makes the blast radius exactly the pair list, by construction rather
/// than by inspection. A model that returns a beautifully rewritten sentence
/// gets the same treatment as one that returns the input: only its choices
/// between `flour` and `flower` survive.

interface ProjectionToken {
  word: string;      // letters, digits and apostrophes only
  trailing: string;  // punctuation and whitespace, kept verbatim
  leading: string;   // whitespace before, kept verbatim
}

/// Splits into words plus the exact characters around them, so the input can be
/// reassembled byte-for-byte when nothing is substituted.
export function tokeniseForProjection(text: string): ProjectionToken[] {
  const tokens: ProjectionToken[] = [];
  let leading = '';
  let word = '';
  let trailing = '';
  const flush = (): void => {
    if (word.length === 0) return;
    tokens.push({ word, trailing, leading });
    leading = '';
    word = '';
    trailing = '';
  };
  for (const ch of text) {
    const isWord = isLetter(ch) || isNumber(ch) || ch === "'" || ch === '’';
    if (isWord) {
      if (trailing.length > 0) {
        flush();
        leading = trailing;
        trailing = '';
      }
      word += ch;
    } else if (word.length === 0) {
      leading += ch;
    } else {
      trailing += ch;
    }
  }
  flush();
  if ((leading.length > 0 || trailing.length > 0) && tokens.length > 0) {
    const last = tokens[tokens.length - 1]!;
    last.trailing += trailing + leading;
  }
  return tokens;
}

export interface ProjectOptions {
  /// Whether a given substitution is allowed. The default is the hand-written
  /// pair list, which is what the offer-a-choice pass uses. `contextProjection`
  /// passes the generated pronunciation table instead, because there the model
  /// proposes freely and this is the only thing standing between a proposal and
  /// the user's document.
  mayReplace?: (original: string, proposed: string) => boolean;
  /// How many words may change at once. One is the honest answer for a
  /// mishearing; a model returning five swaps has started rewriting, and the
  /// fact that all five happen to be homophones does not make it the user's
  /// sentence any more.
  maximumSubstitutions?: number;
  /// Take the repairs that check out and revert the rest, rather than
  /// discarding a good fix because the model also tried a bad one.
  keepWhatIsAllowed?: boolean;
}

/// Returns the corrected text, or null meaning "keep the input".
///
/// Never throws and never reports an error: the caller already holds a good
/// answer, and this is only ever allowed to improve it.
export function projectHomophones(
  raw: string,
  input: string,
  options: ProjectOptions = {},
): string | null {
  const mayReplace = options.mayReplace ?? homophoneMayReplace;
  const maximumSubstitutions = options.maximumSubstitutions ?? Number.MAX_SAFE_INTEGER;
  const keepWhatIsAllowed = options.keepWhatIsAllowed ?? false;

  let out = trim(raw);
  if (out.length === 0) return null;

  // Same three shapes the other pass sees from this endpoint.
  out = AIOutputGuard.stripCodeFence(out);
  out = AIOutputGuard.stripLeadingLabel(out);
  out = AIOutputGuard.stripWrappingQuotes(out);
  out = trim(out);
  if (out.length === 0) return null;

  // A model that starts explaining has stopped choosing.
  if (out.includes('\n\n') && !input.includes('\n\n')) return null;

  const inTokens = tokeniseForProjection(input);
  const outTokens = tokeniseForProjection(out);
  if (inTokens.length === 0) return null;

  // This pass may not insert or delete a single word, so a length change is a
  // refusal on its own — no alignment, no repair, no benefit of the doubt. It
  // is the cheapest possible check and it catches a rewritten sentence outright.
  if (outTokens.length !== inTokens.length) return null;

  let substitutions = 0;
  for (let index = 0; index < inTokens.length; index += 1) {
    const original = inTokens[index]!.word;
    const proposed = outTokens[index]!.word;
    if (normaliseHomophone(original) === normaliseHomophone(proposed)) continue;
    // Different word. It survives only if the caller's rule permits it.
    if (!mayReplace(original, proposed)) {
      // Refusing the whole answer over one bad word throws away the good ones
      // with it. Measured: the model returned "I moved the whole front end to
      // type scripts" for "I move ... to type scoops" — the dropped ending
      // repaired, which is exactly what was asked for, and "scoops" turned into
      // "scripts", which is not. All-or-nothing lost both.
      //
      // Reverting just the disallowed word is not a weaker guarantee. Every
      // surviving change is still individually verified, the word count still
      // has to match exactly, so a rewritten sentence is still refused outright.
      if (!keepWhatIsAllowed) return null;
      continue;
    }
    inTokens[index]!.word = matchCase(original, proposed);
    substitutions += 1;
    // Refuse the whole answer rather than keeping the first N. A model that
    // changed too much was not doing this job, and taking half of its output
    // would be keeping the half we happened to look at first.
    if (substitutions > maximumSubstitutions) return null;
  }

  // Nothing changed: say so, rather than handing back an identical string the
  // caller would have to compare anyway.
  if (substitutions === 0) return null;

  return inTokens.map((token) => token.leading + token.word + token.trailing).join('');
}

/// "Flower" -> "Flour", "FLOWER" -> "FLOUR", "flower" -> "flour".
///
/// The model is told to preserve capitalisation and mostly does; relying on
/// that would still put a lowercase word at the start of a sentence the first
/// time it forgot. The input's casing is the input's to keep.
export function matchCase(original: string, replacement: string): string {
  const first = original[0];
  if (first === undefined) return replacement;
  if (original.length > 1 && Array.from(original).every((c) => !isLetter(c) || isUppercase(c))) {
    return replacement.toUpperCase();
  }
  if (isUppercase(first)) {
    return replacement.slice(0, 1).toUpperCase() + replacement.slice(1);
  }
  return replacement;
}
