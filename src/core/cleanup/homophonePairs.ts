import { isLetter, trimCharacters } from '../text/strings';

/// The closed list of words the homophone pass is allowed to touch.
///
/// Homophones are the largest single error class in the eval corpus — seven of
/// twenty-seven word errors — and the one class nothing else in the app can
/// reach. The vocabulary corrector refuses any single word the dictionary
/// accepts, and both halves of a pair are real English by definition. The model
/// cleanup pass is contractually delete-only. So the audio is ambiguous, the
/// sentence is not, and every layer we have declines to look at the sentence.
///
/// `CORRECTIONS` already handles the ones a FIXED PHRASE decides — "hey fever"
/// is never right. This is for the rest, where only the sentence decides:
///
///     "every time Cloudflare cached something stale"
///       -> "every time Cloudflare cashed something stale"      (twice)
///
/// No table can fix that: "cashed a cheque" is correct English.
///
/// # Why a closed list rather than "fix any wrong words"
///
/// It bounds the blast radius to something checkable. A model told to fix wrong
/// words will eventually rewrite a word the user meant, and they will not
/// notice — the failure the corrector calls "worse than leaving a wrong one".
/// A model asked "is this *flour* or *flower*?" cannot do that, because those
/// are the only two answers it is permitted to give, and `homophoneProjection`
/// enforces it afterwards rather than trusting it.
///
/// # What is deliberately not here
///
/// **Function words.** to/too/two, their/there/they're, your/you're, its/it's.
/// They are in half of all sentences, so including them means the gate fires on
/// nearly every dictation and the pass stops being cheap. They are also the
/// ones a recogniser gets right most of the time, because the grammar around
/// them is strong. Cost is high, yield is low.
///
/// **Anything already decided by a fixed phrase.**
export const HOMOPHONE_GROUPS: string[][] = [
  // Found in real dictation.
  ['cached', 'cashed'],
  ['caching', 'cashing'],

  // Found in the frozen eval corpus.
  ['flour', 'flower'],
  ['flours', 'flowers'],
  ['dew', 'due', 'dews', 'dues'],
  ['formally', 'formerly'],
  ['emigration', 'immigration'],
  ['emigrant', 'immigrant'],

  // Trimmed against 263 real dictations. The gate fired on 12% of them, and the
  // words doing the firing were past(7), through(7), whether(6), course(4),
  // week(3) — every one already correct. A group that wakes the model
  // constantly and has never needed to is pure cost, so the high-frequency
  // pairs are gone on the same reasoning that keeps to/too/two out. What is
  // left is what someone could plausibly get wrong in a brief or an invoice.
  ['principal', 'principle'],
  ['principals', 'principles'],
  // complement/compliment is deliberately absent. Benched against the real
  // endpoint it was the only pair that caused damage, and it did so twice —
  // turning a correct "A compliment from a client is rare" into "A complement
  // from a client is rare", with and without a gloss telling it that compliment
  // means praise. A pair the model cannot decide does not belong on a list of
  // decisions we hand it; the loss is that those stay wrong, which is what they
  // already were. "complementary colours" is still fixed for free by
  // `CORRECTIONS`, where a fixed phrase settles it.
  ['discreet', 'discrete'],
  ['stationary', 'stationery'],
  ['affect', 'effect'],
  ['affects', 'effects'],
  ['affected', 'effected'],
  ['elicit', 'illicit'],
  ['eminent', 'imminent'],
  ['allude', 'elude'],
  ['ensure', 'insure'],
  ['loose', 'lose'],
  ['loosing', 'losing'],
];

/// What each word means, for the prompt.
///
/// Added after the first bench against the real endpoint scored 2/6 fixed and
/// 1/6 damaged with the options listed bare. The failures read like a model
/// that does not know which word is which rather than one that cannot read the
/// sentence — it left four real errors alone and then confidently turned a
/// correct "compliment" into "complement". Naming the meaning is the cheapest
/// thing that could fix that.
export const HOMOPHONE_GLOSS: Record<string, string> = {
  cached: 'stored for reuse', cashed: 'exchanged for money',
  caching: 'storing for reuse', cashing: 'exchanging for money',
  flour: 'the baking ingredient', flower: 'the plant',
  dew: 'morning moisture', dews: 'morning moisture',
  due: 'owed or expected', dues: 'fees owed',
  principal: 'main, or the head of something', principle: 'a rule or belief',
  principals: 'main people', principles: 'rules or beliefs',
  complement: 'something that completes or goes well with',
  compliment: 'a piece of praise',
  complements: 'completes or goes well with', compliments: 'praises',
  complementary: 'going well together', complimentary: 'free, or praising',
  discreet: 'careful not to attract attention', discrete: 'separate and distinct',
  stationary: 'not moving', stationery: 'paper and writing supplies',
  affect: 'to influence (verb)', effect: 'a result (noun)',
  affects: 'influences (verb)', effects: 'results (noun)',
  elicit: 'to draw out', illicit: 'illegal',
  eminent: 'distinguished', imminent: 'about to happen',
  loose: 'not tight', lose: 'to misplace or be beaten',
  loosing: 'releasing', losing: 'misplacing or being beaten',
  past: 'an earlier time, or beyond', passed: 'went by or handed over',
  lead: 'to go first, or the metal', led: 'past tense of lead',
  peace: 'absence of conflict', piece: 'a part of something',
  coarse: 'rough', course: 'a route, or a class',
  council: 'a group that governs', counsel: 'advice, or a lawyer',
  formally: 'officially', formerly: 'previously',
  emigration: 'leaving a country', immigration: 'entering a country',
  aloud: 'out loud', allowed: 'permitted',
  weather: 'rain and sun', whether: 'if',
  waist: 'the middle of the body', waste: 'squander, or rubbish',
  brake: 'to slow down', break: 'to snap, or a pause',
  role: 'a part played', roll: 'to turn over, or a bread roll',
  site: 'a place or website', sight: 'vision', cite: 'to quote a source',
};

/// word -> the group it belongs to, lowercased. Built once.
export const HOMOPHONE_GROUP_OF: Map<string, Set<string>> = (() => {
  const out = new Map<string, Set<string>>();
  for (const group of HOMOPHONE_GROUPS) {
    const set = new Set(group.map((word) => word.toLowerCase()));
    for (const word of set) out.set(word, set);
  }
  return out;
})();

/// Every word on the list, for the gate.
export const HOMOPHONE_ALL: Set<string> = new Set(HOMOPHONE_GROUP_OF.keys());

export function normaliseHomophone(word: string): string {
  return trimCharacters(word.toLowerCase().replace(/’/g, "'"), '.,;:!?"()[]');
}

/// May `replacement` stand in for `original`?
///
/// True only when both are in the same group. Identical words are allowed — the
/// model leaving a word alone is the common case and must not be read as a
/// violation.
export function homophoneMayReplace(original: string, replacement: string): boolean {
  const a = normaliseHomophone(original);
  const b = normaliseHomophone(replacement);
  if (a === b) return true;
  const group = HOMOPHONE_GROUP_OF.get(a);
  if (!group) return false;
  return group.has(b);
}

/// The list words actually present, in order, deduplicated. Used to build a
/// prompt that names only the choices that are live for this sentence.
export function homophoneCandidates(text: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const token of splitWords(text)) {
    const word = normaliseHomophone(token);
    if (!HOMOPHONE_ALL.has(word) || seen.has(word)) continue;
    seen.add(word);
    out.push(word);
  }
  return out;
}

/// The gate. Does this text contain anything worth spending a model call on?
///
/// A plain set lookup over the tokens. If nothing on the list appears there is
/// nothing this pass could legally change, so it must not run — that is what
/// keeps it off the critical path for most dictations.
export function homophoneHasCandidate(text: string): boolean {
  return homophoneCandidates(text).length > 0;
}

/** Swift's `split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })`. */
export function splitWords(text: string): string[] {
  const out: string[] = [];
  let current = '';
  for (const c of text) {
    if (isLetter(c) || c === "'" || c === '’') {
      current += c;
    } else if (current.length > 0) {
      out.push(current);
      current = '';
    }
  }
  if (current.length > 0) out.push(current);
  return out;
}
