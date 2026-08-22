import { homophoneGroupOf, homophoneTableRaw } from './homophoneTable';
import { HOMOPHONE_GROUP_OF, homophoneMayReplace, normaliseHomophone, splitWords } from './homophonePairs';
import { projectHomophones } from './homophoneProjection';

/// The check that makes free-form word recovery safe.
///
/// The request, in the user's own words: "if it can't really understand a word
/// that I said, read the context of what I just said and figure out what word
/// makes the most sense". The obvious way to build it — ask a model to fix any
/// wrong word — is the trade the prompt bench already measured and lost,
/// because a model handed a sentence will eventually improve one the user meant.
///
/// Three other ways of bounding it were measured and all three failed:
///
///  - **Ask the recogniser what it was unsure about.** The alternatives it
///    returns are punctuation variants — " peppered flour" against " peppered,
///    flour" — and never a different word. There is no lexical n-best to lean
///    on. (Whisper's own token logprobs have the same shape.)
///  - **"The replacement must sound similar."** Under Quill's own `phoneticKey`,
///    85% of English words have a neighbour and "flour" has 1140 of them,
///    including "baffle". That key is lossy on purpose, for matching mis-split
///    proper nouns against a small dictionary; it bounds nothing here.
///  - **Offer the model every true homophone in the sentence.** Generated from
///    CMUdict that fires on 98% of real transcripts with a median of ten
///    decisions each. Ten decisions is ten chances to damage a correct word.
///
/// So this inverts the shape the homophone pass uses. That one hands the model
/// a closed list and asks it to choose. This one lets it propose whatever it
/// likes and then refuses the proposal unless the replacement is pronounced
/// identically to the word that was heard, checked against the generated table.
/// The model is free; the acceptance is not.

/// How many words may change at once.
///
/// Was one, when the only permitted swap was a homophone: a mishearing is one
/// word, and a model returning several had started rewriting. Dropped endings
/// are different — a 200-word dictation spoken fast can genuinely lose three of
/// them, so a cap of one would refuse the whole answer over the second repair.
///
/// Three rather than unlimited because the cap is the last line: every change
/// is individually verified as a homophone or an inflection, and a model that
/// wants four of them in one sentence is doing something this pass is not for.
export const MAXIMUM_SUBSTITUTIONS = 3;

/// Below this, do not spend a request.
///
/// "Push the build to Netlify tonight" trips the word gate, because build and
/// billed are homophones and the table is right about that. It is also six
/// words that need nothing, and paying most of a second on it is the tax that
/// quietly ends the habit of dictating at all.
///
/// Twelve is where a real corpus separates. The errors people complain about —
/// dropped endings, murmured words, a sentence they restarted — accumulate with
/// length; a six-word command either came out right or is obviously wrong.
/// Measured over 292 real dictations, the gate fires on 24% with no floor and
/// 18% at twelve words, and the median dictation is eighteen.
export const MINIMUM_WORDS = 12;

/// Endings that make the same word rather than a different one. Deliberately
/// short: every entry here is a swap the projection will permit without ever
/// consulting a dictionary, so a wrong one is a hole rather than a miss.
export const INFLECTIONS = new Set([
  's', 'es', 'd', 'ed', 'ing', 'n', 'en',
  'ly', 'er', 'est', 'ers', 'ings',
]);

/// Short function words that are prefixes of other real words.
///
/// These are the most common words anyone says, so a swap between two of them
/// is both the likeliest to fire and the most damaging when it does — "the"
/// becoming "they" changes the sentence and reads as though the user said it.
export const SHORT_NON_STEMS = new Set([
  'the', 'then', 'they', 'her', 'hers', 'his', 'she', 'our', 'ours',
  'him', 'its', 'for', 'not', 'was', 'are', 'out', 'you', 'who',
]);

/// Words too common, or too structural, for a swap to ever be worth offering.
export const FUNCTION_WORDS = new Set([
  'about', 'after', 'again', 'their', 'there', 'these', 'those', 'would',
  'could', 'should', 'which', 'while', 'where', 'whose', 'being', 'doing',
  'having', 'shall', 'might', 'must', "there's", "they're", 'your', 'yours',
  'here', 'hear', 'been', 'some', 'sum', 'four', 'for', 'one', 'won', 'two',
  'too', 'to', 'the', 'thee', 'and', 'but', 'not', 'you', 'him', 'her',
  'them', 'this', 'that', 'with', 'from', 'into', 'over', 'under', 'than',
  'then', 'when', 'what', 'were', 'was', 'are', 'its', "it's",
]);

/// The same word, spelled for a different country.
///
/// Caught by the bench on the first run: "I cashed the cheque on Friday" came
/// back as "I cashed the check on Friday". Both are true homophones and the
/// table is right about that, but the user is in Melbourne and "cheque" was
/// never the wrong word — no amount of context makes it one. A model asked to
/// pick the word that fits will quietly Americanise a document, and that is
/// damage the projection can refuse in code rather than argue about in a prompt.
///
/// Pairs, not a rule: -our/-or and -ise/-ize are not homophone pairs at all, so
/// they never reach this check. Only the ones that genuinely sound identical
/// need listing.
const REGIONAL_PAIRS: string[][] = [
  ['cheque', 'check'],
  ['defence', 'defense'],
  ['offence', 'offense'],
  ['licence', 'license'],
  ['practice', 'practise'],
  ['storey', 'story'],
  ['grey', 'gray'],
  ['kerb', 'curb'],
  ['metre', 'meter'],
  ['litre', 'liter'],
  ['theatre', 'theater'],
  ['fibre', 'fiber'],
  ['draught', 'draft'],
  ['plough', 'plow'],
  ['mould', 'mold'],
  ['smoulder', 'smolder'],
  ['programme', 'program'],
  ['tonne', 'ton'],
];

const REGIONAL_KEYS = new Set(REGIONAL_PAIRS.map((pair) => [...pair].sort().join('|')));

export function isRegionalRespelling(a: string, b: string): boolean {
  return REGIONAL_KEYS.has([a, b].sort().join('|'));
}

/// Whether two words are pronounced identically.
///
/// The generated table first, then the hand-written pairs as a supplement —
/// not a fallback. The hand-written list carries entries CMUdict does not,
/// because they came from watching this recogniser fail on this voice: "cached"
/// and "cashed" are one of them.
export function sameSound(original: string, proposed: string): boolean {
  const a = normaliseHomophone(original);
  const b = normaliseHomophone(proposed);
  if (a.length === 0 || b.length === 0 || a === b) return false;
  if (isRegionalRespelling(a, b)) return false;
  const group = homophoneGroupOf().get(a);
  if (group && group.has(b)) return true;
  return homophoneMayReplace(original, proposed);
}

/// The same word with a different ending.
///
/// This is the one that matters for how people actually speak. Measured:
///
///     said     "I move the whole front end to type scoops last night"
///     model    "I moved the whole front end to TypeScoop last night"
///
/// "moved" was said; the recogniser dropped the ending because it was spoken
/// fast. That is a real repair and the delete-only contract refused it,
/// correctly, because it has no way to tell it apart from the model rewriting
/// "Here are the following bugs I've been experiencing" into "I've been
/// experiencing bugs with the app" — which it also did, on the next sentence.
///
/// So the rule is spelled out instead of trusted: same stem, and the only thing
/// that may differ is an ending English actually uses.
///
/// The stem floor is three characters, and the pairs that would otherwise sail
/// through on length alone — "the"/"they", "he"/"her", "our"/"ours" — are shut
/// out by name in `SHORT_NON_STEMS`. A four-character floor would also close
/// them and would take "use"/"used" and "fix"/"fixed" with it, which is the
/// repair this pass exists to make.
export function sameStem(original: string, proposed: string): boolean {
  const a = normaliseHomophone(original);
  const b = normaliseHomophone(proposed);
  if (a === b) return false;
  if (a.length < 4 && b.length < 4) return false;
  const [shorter, longer] = a.length <= b.length ? [a, b] : [b, a];
  if (shorter.length < 3) return false;
  if (longer.length - shorter.length > 3) return false;
  if (SHORT_NON_STEMS.has(shorter) || SHORT_NON_STEMS.has(longer)) return false;

  // "moved" from "move", "sites" from "site", "running" from "run".
  if (longer.startsWith(shorter)) {
    return INFLECTIONS.has(longer.slice(shorter.length));
  }
  // "carries" from "carry", "studied" from "study" — the y is swapped for i
  // before the ending, which is a spelling rule rather than a new word.
  if (shorter.endsWith('y')) {
    const stem = shorter.slice(0, -1);
    if (!longer.startsWith(`${stem}i`)) return false;
    return INFLECTIONS.has(longer.slice(stem.length + 1));
  }
  return false;
}

/// The whole permission, in one place: delete it, swap it for a word that
/// sounds the same, or swap it for the same word with a different ending.
/// Anything else is the model writing rather than transcribing.
export function contextMayReplace(original: string, proposed: string): boolean {
  return sameSound(original, proposed) || sameStem(original, proposed);
}

let gateWords: Set<string> | null = null;

/// The words that are worth waking the model for.
///
/// The table has 2,281 words in it, but gating on all of them fires on 95% of
/// real transcripts with a median of six candidates — a round trip on nearly
/// every dictation, for a class of error that is not on nearly every dictation.
///
/// Two filters bring it down, and both are about which pairs are real:
///
///  - **A group where any member is a common function word is dropped.**
///    the/thee, but/butt, would/wood, your/yore. Nobody says "thee", so the
///    pair is all risk and no reward, and "the" alone appears 586 times in the
///    corpus.
///  - **A group where any member is under five letters is dropped.** Short
///    words are where the archaic halves cluster — wen, soss, hatt, haff — and
///    where a wrong swap is least likely to be noticed.
///
/// Measured on 376 real transcripts: 961 words, fires on 31%, median one
/// candidate, worst nine. Against the hand-written list's 44 words and 11%.
export function contextGateWords(): Set<string> {
  if (gateWords) return gateWords;
  const out = new Set<string>();
  for (const line of homophoneTableRaw().split('\n')) {
    const group = line.split(' ').filter((word) => word.length > 0);
    if (group.length === 0) continue;
    if (!group.every((word) => word.length >= 5 && !FUNCTION_WORDS.has(word))) continue;
    for (const word of group) out.add(word);
  }
  // The hand-written pairs are in regardless of length: they are short
  // precisely because they came from watching this recogniser fail, and "dew",
  // "due", "hay" earn their place by evidence rather than by rule.
  for (const word of HOMOPHONE_GROUP_OF.keys()) out.add(word);
  gateWords = out;
  return out;
}

/// Whether this sentence is worth a request at all. Free and local, and it runs
/// before anything is sent.
export function contextHasCandidate(text: string): boolean {
  const tokens = splitWords(text.toLowerCase());
  if (tokens.length < MINIMUM_WORDS) return false;
  const words = contextGateWords();
  return tokens.some((token) => words.has(token));
}

/// Returns the corrected text, or null meaning "keep the input".
export function projectContext(raw: string, input: string): string | null {
  return projectHomophones(raw, input, {
    mayReplace: contextMayReplace,
    maximumSubstitutions: MAXIMUM_SUBSTITUTIONS,
    // Take the repairs that check out and revert the rest, rather than
    // discarding a good fix because the model also tried a bad one.
    keepWhatIsAllowed: true,
  });
}
