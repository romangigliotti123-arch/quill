import { AIOutputGuard } from '../ai/outputGuard';
import { SpeechToken, tokeniseSpeech } from '../text/speechToken';
import { trim } from '../text/strings';
import { similarity } from './vocabularyCorrector';
import { Cue, FILLERS, cues, isAbandonment } from './selfCorrection';

/// What comes back from the model, checked against what went in.
///
/// `AIOutputGuard` already does the shape checks — fences, labels, quotes,
/// runaway essays — and this uses them. What it adds is the check that matters
/// for self-correction and that a length ratio cannot express: the output must
/// be the *input with words deleted*, and every deletion must have a reason.
///
/// `AIOutputGuard`'s own 0.5 length floor is deliberately not applied. It was
/// sized for a long transcript, and the headline case of this feature breaks
/// it: "Send it to Noah no wait send it to Carlo" → "Send it to Carlo" keeps
/// 40% of its characters, which is a correct answer the guard would reject.
/// Deletion is the point here, so the ratio is replaced with a rule about
/// *what* may be deleted rather than *how much*.

/// How far past a retraction cue a deletion may reach: three words.
///
/// A retraction may eat unlimited material *before* the cue — that is the whole
/// point, and "send it to Noah and tell him the frames are ready and the
/// invoice is paid, no wait, send it to Carlo" correctly reduces to five words
/// out of twenty-one. What it may not do is eat the version the speaker settled
/// on. That asymmetry is the guard; a percentage of the whole sentence cannot
/// express it, which is what an earlier 35% floor got wrong.
///
/// It is not zero because a restart overlaps. Measured 5 times out of 5, "Send
/// the nxt invoice to Noah no wait send it to Carlo" comes back as "Send the
/// next invoice to Carlo" — the model merges, keeping the noun phrase from
/// before the cue and the recipient from after it, and drops the redundant
/// "send it". That is the right answer and it costs two words of the tail.
///
/// Three separates it from the failure it is aimed at with room to spare. The
/// worst summary in the corpus reaches seven words past the cue.
export const MAXIMUM_TAIL_OVERREACH = 3;

/// Words that only mean "I am starting to talk now" when they are the first
/// thing said. "Right", "now", "like" and "so" are ordinary content everywhere
/// else, which is why this is anchored to position zero rather than added to
/// `FILLERS`.
export const OPENERS = new Set([
  'ok', 'okay', 'right', 'now', 'alright', 'anyway', 'yeah', 'so', 'well', 'like', 'basically',
]);

/// Returns the checked text, or null to mean "use the deterministic answer".
/// Never an error: the caller has something good already.
export function projectCleanup(raw: string, input: string, terms: string[]): string | null {
  let out = trim(raw);
  if (out.length === 0) return null;

  // Shape first, and reuse rather than reimplement: these three were all
  // observed from real models on this endpoint.
  out = AIOutputGuard.stripCodeFence(out);
  out = AIOutputGuard.stripLeadingLabel(out);
  out = AIOutputGuard.stripWrappingQuotes(out);
  out = trim(out);
  if (out.length === 0) return null;

  // A model that starts explaining has stopped editing.
  if (out.includes('\n\n') && !input.includes('\n\n')) return null;
  // Deleting words cannot make the text longer. The slack is for punctuation
  // and apostrophes, which it is allowed to add.
  if (out.length > input.length + 24) return null;

  const inTokens = tokeniseSpeech(input);
  const outTokens = tokeniseSpeech(out);
  if (inTokens.length === 0 || outTokens.length === 0) return null;

  const protectedWords = new Set(
    terms.flatMap((term) => term.split(' ').map((word) => word.toLowerCase())),
  );

  const mapping = align(outTokens, inTokens, protectedWords);
  if (!mapping) return null;
  if (!deletionsAreJustified(mapping, inTokens)) return null;

  // Over-deletion is the one failure the alignment cannot see: a summary is
  // still a subsequence of what it summarises.
  if (mapping.length < Math.min(2, inTokens.length)) return null;
  const start = settledStart(mapping, inTokens);
  const kept = new Set(mapping);
  let overreach = 0;
  for (let index = start; index < inTokens.length; index += 1) if (!kept.has(index)) overreach += 1;
  if (overreach > MAXIMUM_TAIL_OVERREACH) return null;

  return rebuild(outTokens, mapping, inTokens, protectedWords, out);
}

/// Maps each output token to the input token it came from, or null if some
/// output token came from nowhere.
///
/// This is the whole "cleanup, not rewriting" contract expressed as a check. A
/// model that adds a pleasantry, invents a detail, reorders a clause or swaps a
/// word for a nicer one produces an output that is not a subsequence of its
/// input, and lands here rather than in the user's editor.
///
/// Matched from the right. Either direction answers "is this a subsequence"
/// identically, but the direction decides *which* copy a repeated phrase is
/// credited to, and that changes what the guards downstream see. "Send it to
/// Noah no wait send it to Carlo" → "Send it to Carlo" credits the surviving
/// words to the second "send it to" going right-to-left and to the first one
/// going left-to-right — and only the first reading matches what the speaker
/// did, which is finish the sentence the second time.
export function align(
  outTokens: SpeechToken[],
  inTokens: SpeechToken[],
  protectedWords: Set<string>,
): number[] | null {
  const reversed: number[] = [];
  let cursor = inTokens.length - 1;
  for (let position = outTokens.length - 1; position >= 0; position -= 1) {
    const out = outTokens[position]!;
    let matched: number | null = null;
    let index = cursor;
    while (index >= 0) {
      if (matches(out, inTokens[index]!, protectedWords)) {
        matched = index;
        break;
      }
      index -= 1;
    }
    if (matched === null) return null;
    reversed.push(matched);
    cursor = matched - 1;
  }
  return reversed.reverse();
}

/// Where the version the speaker settled on begins: just past the last
/// retraction cue that licensed a deletion. Zero when nothing was retracted,
/// which makes the floor above a whole-sentence one — correct, because without
/// a retraction the only licensed deletions are stutters and opening preamble,
/// and those are small by construction.
export function settledStart(mapping: number[], inTokens: SpeechToken[]): number {
  const kept = new Set(mapping);
  const deleted: number[] = [];
  for (let index = 0; index < inTokens.length; index += 1) if (!kept.has(index)) deleted.push(index);
  if (deleted.length === 0) return 0;
  const retractions = cues(inTokens).filter((cue) => cue.isRetraction);
  let best = 0;
  for (const cue of retractions) {
    if (!deleted.some((index) => index >= cue.start && index < cue.end)) continue;
    if (cue.end > best) best = cue.end;
  }
  return best;
}

/// Equal ignoring case, punctuation and apostrophes — so the model is free to
/// turn "lets" into "Let's", which is a spelling repair, and not free to turn
/// "want" into "would like", which is a rewrite.
///
/// The second clause is the vocabulary escape hatch. Measured 10 times out of
/// 10: the model turns "nxt" into "next". Rejecting the whole response for it
/// would mean self-correction never works in a sentence containing one of the
/// user's words, which is most of them. Instead the near-miss is allowed to
/// align and `rebuild` puts the original spelling back — and because the
/// substitution only ever reads from the input, this cannot introduce a word
/// they did not say. The 0.6 bar admits nxt→next (0.75) and rejects unrelated
/// words.
export function matches(out: SpeechToken, input: SpeechToken, protectedWords: Set<string>): boolean {
  if (out.normalised === input.normalised) return true;
  if (!protectedWords.has(input.normalised)) return false;
  return similarity(out.normalised, input.normalised) >= 0.6;
}

/// Every run of deleted input tokens has to be one of three things. Anything
/// else and the response is discarded.
///
/// This is what stops the model acting on a retraction phrase that was literal
/// content. The gate in `selfCorrection` already refuses to send a transcript
/// whose only cues are literal; this catches the mixed case, where one real
/// correction gets the transcript sent and the model then also eats the quoted
/// one.
export function deletionsAreJustified(mapping: number[], inTokens: SpeechToken[]): boolean {
  const kept = new Set(mapping);
  const retractions = cues(inTokens).filter((cue) => cue.isRetraction);

  let start = 0;
  while (start < inTokens.length) {
    if (kept.has(start)) { start += 1; continue; }
    let end = start;
    while (end < inTokens.length && !kept.has(end)) end += 1;

    const cue = retractions.find((candidate) => candidate.start < end && start < candidate.end);
    if (cue) {
      if (!retractionIsFullyApplied(start, end, cue, inTokens)) return false;
    } else if (!isRepetition(start, end, inTokens)
      && !isAllFiller(start, end, inTokens)
      && !isOpeningPreamble(start, end, inTokens)) {
      return false;
    }
    start = end;
  }
  return true;
}

/// A correction has to actually be applied, in the right direction.
///
/// Both halves of this came from the live suite, and both are the original
/// complaint wearing a disguise — the model touched the sentence and still left
/// the wrong words in it.
///
///   "call the plumber no wait ring the electrician instead"
///     → "Call the plumber ring the electrician instead"
///   The model deleted the cue and nothing else, so both versions survive and
///   the signal that one of them was wrong is gone. Worse than untouched.
///
///   "push the nxt build to Netlify no wait push it to Firestore"
///     → "Push the nxt build to Netlify."
///   The model applied the correction backwards: it kept what was retracted and
///   deleted what was settled on.
///
/// The rule that catches both: a *replacement* cue ("no wait", "actually", "I
/// mean") retracts what came before it, so the deletion must reach back past
/// the cue. Only an *abandonment* ("never mind", "forget it") retracts
/// forwards, and only at the very end of the utterance.
export function retractionIsFullyApplied(
  runStart: number,
  runEnd: number,
  cue: Cue,
  inTokens: SpeechToken[],
): boolean {
  if (runStart < cue.start) return true;
  return runEnd === inTokens.length && isAbandonment(cue, inTokens);
}

/// The deleted run is a stutter or a false start: the same words appear
/// immediately before or immediately after it.
export function isRepetition(start: number, end: number, tokens: SpeechToken[]): boolean {
  const length = end - start;
  const deleted = tokens.slice(start, end).map((t) => t.normalised);
  if (start >= length) {
    const before = tokens.slice(start - length, start).map((t) => t.normalised);
    if (before.every((word, i) => word === deleted[i])) return true;
  }
  if (end + length <= tokens.length) {
    const after = tokens.slice(end, end + length).map((t) => t.normalised);
    if (after.every((word, i) => word === deleted[i])) return true;
  }
  return false;
}

/// The deleted run is nothing but discourse noise — "um", "uh". Measured: the
/// model drops these and the result reads better for it, which is the one kind
/// of unprompted deletion worth allowing.
export function isAllFiller(start: number, end: number, tokens: SpeechToken[]): boolean {
  if (end <= start) return false;
  return tokens.slice(start, end).every((token) => FILLERS.has(token.normalised));
}

/// The deleted run is the throat-clearing at the very start of a dictation.
///
/// Measured: "Ok so for the barber site I want the booking form on the home
/// page no wait on its own page" comes back without the "Ok so", 5 times out of
/// 5. Refusing that response means refusing the correction with it, which
/// trades the headline feature for two words of preamble.
///
/// Confined to the run of opener words the utterance actually starts with,
/// rather than to index 0, because the model may drop "Ok so" or just the "so".
/// Either way the licence stops at the first real word, so "do it right now"
/// cannot lose its ending and "I like the blue one" cannot lose its verb.
export function isOpeningPreamble(start: number, end: number, tokens: SpeechToken[]): boolean {
  if (end <= start) return false;
  let preamble = 0;
  while (preamble < Math.min(3, tokens.length)
    && (OPENERS.has(tokens[preamble]!.normalised) || FILLERS.has(tokens[preamble]!.normalised))) {
    preamble += 1;
  }
  return end <= preamble;
}

/// Emits the model's text, with the user's spelling restored wherever the model
/// normalised one of their words.
///
/// When nothing needed restoring — the overwhelmingly common case — the model's
/// own string is returned byte for byte, so the join below can never introduce
/// a spacing artefact into text that was already fine.
export function rebuild(
  outTokens: SpeechToken[],
  mapping: number[],
  inTokens: SpeechToken[],
  protectedWords: Set<string>,
  verbatim: string,
): string {
  let restored = false;
  const pieces: string[] = [];
  for (let position = 0; position < outTokens.length; position += 1) {
    const out = outTokens[position]!;
    const input = inTokens[mapping[position]!]!;
    const useInputSpelling = protectedWords.has(input.normalised) && input.word !== out.word;
    if (useInputSpelling) restored = true;
    pieces.push(out.lead + (useInputSpelling ? input.word : out.word) + out.trail);
  }
  return restored ? pieces.join(' ') : verbatim;
}
