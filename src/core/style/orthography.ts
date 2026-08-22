import { isLetter, isUppercase, isWhitespace } from '../text/strings';

export type SpellingConvention = 'british' | 'american';

/// American → British spelling, deterministically.
///
/// One direction only, and that is a decision rather than an omission. Going
/// the other way means turning "-ise" into "-ize", which needs an exception
/// list running to advertise, surprise, exercise, promise, revise, devise,
/// comprise, compromise, supervise, improvise, disguise, franchise, merchandise
/// and enterprise before it stops writing non-words into someone's email. The
/// payoff for the reverse direction is zero and the downside is a typo they did
/// not make. A profile set to `american` therefore changes the prompt and
/// nothing else, which is honest about what a rule can do.

const IZE_EXCEPTIONS = new Set(['maize', 'assize', 'baize', 'sizer', 'sizers']);

const IZE_SUFFIXES: [string, string][] = [
  ['izations', 'isations'], ['ization', 'isation'],
  ['izers', 'isers'], ['izer', 'iser'],
  ['izing', 'ising'], ['ized', 'ised'], ['izes', 'ises'], ['ize', 'ise'],
];

const YZE_SUFFIXES: [string, string][] = [
  ['yzing', 'ysing'], ['yzed', 'ysed'], ['yzes', 'yses'], ['yze', 'yse'],
];

const OUR_STEMS: [string, string][] = [
  ['color', 'colour'], ['favor', 'favour'], ['honor', 'honour'],
  ['labor', 'labour'], ['neighbor', 'neighbour'], ['behavior', 'behaviour'],
  ['flavor', 'flavour'], ['rumor', 'rumour'], ['harbor', 'harbour'],
  ['armor', 'armour'], ['vapor', 'vapour'], ['savor', 'savour'],
  ['endeavor', 'endeavour'], ['splendor', 'splendour'], ['valor', 'valour'],
  ['odor', 'odour'], ['tumor', 'tumour'], ['clamor', 'clamour'],
  ['demeanor', 'demeanour'], ['parlor', 'parlour'], ['humor', 'humour'],
  ['vigor', 'vigour'],
];

/// Endings that keep the "u". Deliberately excludes "ous" and "ary":
/// "humorous", "vigorous", "glamorous" and "honorary" are British spellings as
/// they stand, and a rule that "fixes" them is a rule that breaks them.
const OUR_ENDINGS = new Set(['', 's', 'ed', 'ing', 'ful', 'less', 'ite', 'ites', 'hood', 'al', 'ally']);

/// Everything with no rule behind it. A table rather than cleverness, because
/// the alternative is a heuristic that is wrong in public.
const TABLE: Record<string, string> = {
  center: 'centre', centers: 'centres', centered: 'centred', centering: 'centring',
  theater: 'theatre', theaters: 'theatres',
  liter: 'litre', liters: 'litres',
  fiber: 'fibre', fibers: 'fibres',
  caliber: 'calibre', somber: 'sombre', specter: 'spectre',
  meager: 'meagre', luster: 'lustre', maneuver: 'manoeuvre',
  defense: 'defence', defenses: 'defences',
  offense: 'offence', offenses: 'offences',
  pretense: 'pretence',
  traveled: 'travelled', traveling: 'travelling', traveler: 'traveller',
  canceled: 'cancelled', canceling: 'cancelling',
  modeled: 'modelled', modeling: 'modelling',
  labeled: 'labelled', labeling: 'labelling',
  marveled: 'marvelled', signaled: 'signalled',
  totaled: 'totalled', fueled: 'fuelled', fueling: 'fuelling',
  counselor: 'counsellor', jeweler: 'jeweller',
  gray: 'grey', plow: 'plough', mold: 'mould', smolder: 'smoulder',
  practicing: 'practising', practiced: 'practised',
};

/// Spellings that only exist in British English, used by `convention` so a
/// single "colour" is recognised without needing a rule to reverse it.
const BRITISH_ONLY = new Set<string>([
  ...Object.values(TABLE),
  ...OUR_STEMS.map(([, british]) => british),
]);

/// Words where "ize" is not a suffix at all.
///
/// Matched on the tail rather than the whole word, because the ones that matter
/// compound freely — resize, downsize, supersize, oversized — and an enumerated
/// list would be missing whichever one gets said first. No real "-ize" verb
/// ends in "size", "prize" or "seize", so the tail test is exact rather than
/// approximate.
function isIzeException(lower: string): boolean {
  if (IZE_EXCEPTIONS.has(lower)) return true;
  for (const stem of ['size', 'prize', 'seize']) {
    const inflections = [stem, `${stem}s`, `${stem}d`, `${stem.slice(0, -1)}ing`];
    if (inflections.some((form) => lower.endsWith(form))) return true;
  }
  return false;
}

/// Evidence of British spelling that cannot be anything else.
///
/// Three sources, all unambiguous: the explicit table ("centre", "defence",
/// "travelled"), the -our family and its endings, and the two suffixes with no
/// American-English homographs — "-isation" and "-yse". Notably absent is bare
/// "-ise", which would match "advise", "raise", "promise" and "exercise" and
/// turn every writer on earth British.
function isBritishMarker(lower: string): boolean {
  if (BRITISH_ONLY.has(lower)) return true;
  for (const [, british] of OUR_STEMS) {
    if (lower.startsWith(british) && OUR_ENDINGS.has(lower.slice(british.length))) return true;
  }
  if (lower.endsWith('isation') || lower.endsWith('isations')) return true;
  for (const [, british] of YZE_SUFFIXES) {
    if (lower.endsWith(british) && lower.length - british.length >= 3) return true;
  }
  return false;
}

/// The British spelling of an American word, or null if it is not one.
export function americanised(lower: string): string | null {
  const direct = TABLE[lower];
  if (direct) return direct;

  // -ize/-ization and friends. The stop list is the entire risk here: the
  // suffix is only a suffix in some words, and "seize" is not a verb anybody
  // spells "seise".
  if (!isIzeException(lower)) {
    for (const [american, british] of IZE_SUFFIXES) {
      if (!lower.endsWith(american)) continue;
      // Keep a stem worth the name — "size" must never reach this.
      if (lower.length - american.length < 3) continue;
      return lower.slice(0, -american.length) + british;
    }
  }
  for (const [american, british] of YZE_SUFFIXES) {
    if (!lower.endsWith(american)) continue;
    if (lower.length - american.length < 3) continue;
    return lower.slice(0, -american.length) + british;
  }

  // -or → -our, as a stem table with a whitelist of endings. A blanket rule
  // cannot be used: British keeps "humorous", "vigorous", "honorary" and
  // "laborious" with the American-looking -or-.
  for (const [stem, british] of OUR_STEMS) {
    if (!lower.startsWith(stem)) continue;
    const ending = lower.slice(stem.length);
    if (!OUR_ENDINGS.has(ending)) continue;
    return british + ending;
  }
  return null;
}

/// A token as leading punctuation, letters, trailing punctuation — so a
/// conversion can put back exactly what it took off.
export function splitToken(token: string): { prefix: string; core: string; suffix: string } {
  const characters = Array.from(token);
  let start = 0;
  while (start < characters.length && !isLetter(characters[start]!)) start += 1;
  let end = characters.length;
  while (end > start && !isLetter(characters[end - 1]!)) end -= 1;
  return {
    prefix: characters.slice(0, start).join(''),
    core: characters.slice(start, end).join(''),
    suffix: characters.slice(end).join(''),
  };
}

export function matchCaseTo(original: string, replacement: string): string {
  if (original === original.toUpperCase() && original.length > 1) return replacement.toUpperCase();
  const first = original[0];
  if (first && isUppercase(first)) {
    return replacement.slice(0, 1).toUpperCase() + replacement.slice(1);
  }
  return replacement;
}

/// Anything that is not plain prose is left alone: a URL, an email address, a
/// file name or an identifier that happens to contain "ize" is not a spelling
/// mistake, and "Normalization.ts" must survive intact.
///
/// The test is on the *core* — the token with its outer punctuation taken off —
/// and it is "letters only". Testing the whole token instead was the first
/// version and it was wrong in the most ordinary way possible: it refused to
/// convert any word at the end of a sentence, because "color." contains a full
/// stop.
function convertToken(token: string): string {
  const parts = splitToken(token);
  if (parts.core.length < 4) return token;
  if (!Array.from(parts.core).every(isLetter)) return token;
  const replacement = americanised(parts.core.toLowerCase());
  if (!replacement) return token;
  return parts.prefix + matchCaseTo(parts.core, replacement) + parts.suffix;
}

export function toBritish(text: string): string {
  // Whitespace is preserved exactly rather than normalised: this runs on text
  // that is about to be pasted, and a cleanup pass that quietly eats a blank
  // line between paragraphs is a cleanup pass nobody trusts.
  let out = '';
  let token = '';
  for (const character of text) {
    if (isWhitespace(character)) {
      if (token.length > 0) { out += convertToken(token); token = ''; }
      out += character;
    } else {
      token += character;
    }
  }
  if (token.length > 0) out += convertToken(token);
  return out;
}

/// Which convention a single word is written in, or null for the vast majority
/// of words that are spelled the same either way.
///
/// Only unambiguous markers count. "advise", "surprise" and "raise" are spelled
/// that way on both sides of the Atlantic, so a detector that reads any "-ise"
/// as British evidence would find British habits in every writer alive. Silence
/// beats a false reading — the vote it would cast is the same weight as a real
/// one.
export function spellingConvention(word: string): SpellingConvention | null {
  const core = splitToken(word).core.toLowerCase();
  if (core.length < 4 || !Array.from(core).every(isLetter)) return null;
  if (isBritishMarker(core)) return 'british';
  if (americanised(core) !== null) return 'american';
  return null;
}
