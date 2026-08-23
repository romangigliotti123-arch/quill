import { isRealEnglishWord } from '../text/dictionary';
import { isPunctuationOrSymbol, lettersOnly, trimPunctuation } from '../text/strings';
import { AMBIGUOUS_SPLITS } from './corrections';
import type { VocabularyBook } from '../stores/vocabulary';

/// Repairs proper nouns the recogniser has never heard.
///
/// The recogniser does not merely mis-spell a word, it splits one word into
/// three. Matching therefore runs over sliding windows of one to three words,
/// comparing a letters-only normalisation by edit distance.
///
/// The danger is over-correction — silently rewriting a word the user meant is
/// worse than leaving a wrong one, because they will not notice it. Two guards:
/// single words must clear a high bar AND not be real English, and multi-word
/// spans must clear a higher bar still.

export interface Token {
  /// Punctuation that came before the word — an opening quote, a bracket, a
  /// bullet. It used to be left inside `word`, and a match rebuilt the token
  /// from the match alone, so it was silently deleted:
  ///
  ///     he said "Netlify" was down   ->   he said Netlify" was down
  leading: string;
  word: string;
  /// Punctuation that followed the word, preserved so correcting a term never
  /// eats the comma after it.
  trailing: string;
}

/// Near-exact, for spans where nothing looks misheard.
export const ORDINARY_PHRASE_THRESHOLD = 0.95;

/// How alike two strings must LOOK before their sounds are allowed to decide.
/// Set below every repair this route has ever made (the lowest is 0.57) and far
/// above the collisions it has caused (0.143).
export const PHONETIC_LETTERS_FLOOR = 0.45;

/// Distance is Damerau-Levenshtein rather than plain Levenshtein because
/// transposition is the characteristic speech error: "net a fly" against
/// "Netlify" is NTFL against NTLF, one swap apart and two substitutions apart
/// if you cannot see the swap.
export const PHONETIC_THRESHOLD = 0.72;

/// Below this, a sound key is too small to mean anything.
///
/// "quill" reduces to "kl" and so does "colour". A two-character skeleton
/// collides with half the language, and matching on one is not evidence of
/// anything — it is a coin flip that silently rewrites a word.
export const MINIMUM_PHONETIC_KEY_LENGTH = 4;

/// Words that can never be the first or last part of a name.
export const BOUNDARY_WORDS = new Set([
  'is', 'was', 'are', 'were', 'be', 'been', 'the', 'a', 'an', 'to', 'of',
  'and', 'or', 'but', 'if', 'in', 'on', 'at', 'it', 'its', 'this', 'that',
  'for', 'from', 'with', 'by', 'as', 'so', 'then', 'than', 'do', 'does',
  'did', 'has', 'have', 'had', 'will', 'would', 'can', 'could', 'not',
  // Pronouns, added after a real dictation lost one.
  //
  //     recogniser:  "The client found me on Air Tasker. He's been discreet"
  //     inserted:    "The client found me on Airtasker been discreet"
  //
  // "Air Tasker He's" is a three-word span, it did not end in any of the
  // closed-class words above, so the guard let it through and the match
  // collapsed all three into "Airtasker" — taking the pronoun with it.
  //
  // "I" is deliberately NOT here, and that is not an oversight. The canonical
  // repair this whole pass exists for is
  //
  //     "Push the graph if I build"  ->  "Push the graphify build"
  //
  // which is a three-word span ending in "I". Listing "i" blocks it. A pronoun
  // that turns up INSIDE a misheard name has to stay matchable, and "I" is the
  // only one that does.
  'he', 'she', 'we', 'they', 'you', 'him', 'her', 'them', 'us',
  'my', 'your', 'his', 'our', 'their',
]);

/// Letters only, lowercased. Spaces go too, which is the point — it is what
/// lets "graph if I" and "graphify" be compared at all.
export function normalise(text: string): string {
  return lettersOnly(text);
}

export function termWordCount(term: string): number {
  return term.split(/[ -]/).filter((piece) => piece.length > 0).length;
}

/// A multi-word term can only be spoken as that many words.
///
/// "Builda Bed" is two words. A three-word span collapsing into it is not the
/// recogniser mis-hearing a name, it is a sentence. Single-word terms are
/// exempt, because a name arriving as several words is the exact failure this
/// whole pass exists for: "graphify" comes back as "graph if I", "Firestore" as
/// "fire store", "blockcraft" as "block craft".
///
/// A single-word SPAN is the recogniser having GLUED the name together —
/// "Wispr Flow" heard as "Whisperflow" — which is the same failure as splitting
/// one, and must stay reachable.
export function spanCanBe(wordCount: number, spanCount: number): boolean {
  return wordCount <= 1 || spanCount === 1 || wordCount === spanCount;
}

export function isBoundaryWord(word: string | undefined): boolean {
  if (!word) return false;
  let lowered = word.toLowerCase();
  // A contraction is its pronoun for this purpose: "he's" ends a span just as
  // surely as "he" does, and listing every contracted form would go stale the
  // first time the recogniser picked a different apostrophe.
  const cut = Array.from(lowered).findIndex((c) => c === "'" || c === '’');
  if (cut >= 0) lowered = lowered.slice(0, cut);
  lowered = trimPunctuation(lowered);
  if (lowered.length === 0) return false;
  return BOUNDARY_WORDS.has(lowered);
}

/// 1.0 is identical. Levenshtein normalised by the longer string.
export function similarity(a: string, b: string): number {
  if (a === b) return 1;
  if (a.length === 0 || b.length === 0) return 0;
  const distance = levenshtein(Array.from(a), Array.from(b));
  return 1 - distance / Math.max(a.length, b.length);
}

export function levenshtein(a: string[], b: string[]): number {
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;
  let previous = new Array<number>(b.length + 1);
  let current = new Array<number>(b.length + 1);
  for (let j = 0; j <= b.length; j += 1) previous[j] = j;
  for (let i = 1; i <= a.length; i += 1) {
    current[0] = i;
    for (let j = 1; j <= b.length; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      current[j] = Math.min(current[j - 1]! + 1, previous[j]! + 1, previous[j - 1]! + cost);
    }
    const swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length]!;
}

/// Levenshtein plus transposition. A swap costs one, not two.
export function damerauLevenshtein(a: string[], b: string[]): number {
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;
  const d: number[][] = [];
  for (let i = 0; i <= a.length; i += 1) d.push(new Array<number>(b.length + 1).fill(0));
  for (let i = 0; i <= a.length; i += 1) d[i]![0] = i;
  for (let j = 0; j <= b.length; j += 1) d[0]![j] = j;
  for (let i = 1; i <= a.length; i += 1) {
    for (let j = 1; j <= b.length; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      d[i]![j] = Math.min(d[i - 1]![j]! + 1, d[i]![j - 1]! + 1, d[i - 1]![j - 1]! + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        d[i]![j] = Math.min(d[i]![j]!, d[i - 2]![j - 2]! + 1);
      }
    }
  }
  return d[a.length]![b.length]!;
}

/// Consonant skeleton with the sounds English confuses folded together.
///
/// Vowels go entirely after the first character: they are the least reliable
/// thing a recogniser produces and the first thing it gets wrong in an
/// unfamiliar word. What survives is the consonant frame, which is what makes
/// "graph if I", "grapify" and "graphify" the same key.
export function phoneticKey(text: string): string {
  const lower = Array.from(text.toLowerCase()).filter((c) => /\p{L}/u.test(c));
  if (lower.length === 0) return '';
  const out: string[] = [];
  let i = 0;
  while (i < lower.length) {
    const c = lower[i]!;
    // Digraphs first, or "ph" becomes P and F and never matches.
    if (i + 1 < lower.length) {
      const pair = c + lower[i + 1]!;
      let mapped: string | null = null;
      switch (pair) {
        case 'ph': mapped = 'f'; break;
        case 'gh': mapped = 'f'; break;   // "laugh"; silent in "night" but harmless here
        case 'ck': mapped = 'k'; break;
        case 'sh': case 'ch': mapped = 'x'; break;
        case 'th': mapped = '0'; break;
        case 'qu': mapped = 'k'; break;
        default: mapped = null;
      }
      if (mapped !== null) {
        if (out[out.length - 1] !== mapped) out.push(mapped);
        i += 2;
        continue;
      }
    }
    let folded: string | null;
    switch (c) {
      case 'a': case 'e': case 'i': case 'o': case 'u': case 'y': case 'h': case 'w':
        // Keep a leading vowel: "iOS" and "OS" must not collide.
        folded = out.length === 0 ? c : null;
        break;
      case 'b': case 'p': case 'v': case 'f': folded = 'f'; break;   // voiced/unvoiced pairs are
      case 'c': case 'k': case 'g': case 'q': case 'j': folded = 'k'; break;  // routinely swapped by ASR
      case 'd': case 't': folded = 't'; break;
      case 's': case 'z': case 'x': folded = 's'; break;
      case 'm': case 'n': folded = 'n'; break;
      case 'l': case 'r': folded = 'l'; break;
      default: folded = c;
    }
    if (folded !== null && out[out.length - 1] !== folded) out.push(folded);
    i += 1;
  }
  return out.join('');
}

export function phoneticSimilarity(a: string, b: string): number {
  const ka = phoneticKey(a);
  const kb = phoneticKey(b);
  if (ka.length < MINIMUM_PHONETIC_KEY_LENGTH || kb.length < MINIMUM_PHONETIC_KEY_LENGTH) return 0;
  if (ka === kb) return 1;
  const distance = damerauLevenshtein(Array.from(ka), Array.from(kb));
  return 1 - distance / Math.max(ka.length, kb.length);
}

export function tokenise(text: string): Token[] {
  // `split(' ')` and not `split(/\s+/)`: newlines belong inside a token here so
  // that the rebuild can put them back, which is what the ` \n` fixup at the
  // end of `correct` relies on.
  return text
    .split(' ')
    .filter((chunk) => chunk.length > 0)
    .map((chunk) => {
      // Trailing first, then leading off what is left. The other order makes a
      // chunk that is entirely punctuation — a lone quote, a dash — land in
      // both fields and get emitted twice.
      let trailingLength = 0;
      while (trailingLength < chunk.length
        && isPunctuationOrSymbol(chunk[chunk.length - 1 - trailingLength]!)) trailingLength += 1;
      const trailing = chunk.slice(chunk.length - trailingLength);
      const core = chunk.slice(0, chunk.length - trailingLength);
      let leadingLength = 0;
      while (leadingLength < core.length && isPunctuationOrSymbol(core[leadingLength]!)) leadingLength += 1;
      const leading = core.slice(0, leadingLength);
      return { leading, word: core.slice(leadingLength), trailing };
    })
    .filter((token) => token.word.length > 0 || token.trailing.length > 0 || token.leading.length > 0);
}

interface Prepared {
  term: string;
  normalised: string;
  wordCount: number;
}

interface MemoKey {
  candidate: string;
  spanCount: number;
  phoneticAllowed: boolean;
}

/// What each span matched last time, so a growing transcript is not re-decided
/// from scratch on every keystroke.
///
/// Live typing calls `cleanFast` on the WHOLE transcript so far, once per
/// partial. That is the right thing for correctness — the text on screen has to
/// agree with the text that will be inserted — but it means a dictation of N
/// characters runs the matcher over a growing prefix N/20-ish times, and the
/// matcher is the expensive part. Quadratic in the length of what you said.
///
/// The matcher is a pure function of (span, span length, whether sound is
/// allowed to decide) and the term list, so the second pass over a sentence can
/// only reach the same answers as the first. This remembers them.
export class MatchMemo {
  /// Past this the cache is dropped rather than grown. A long session has no
  /// business holding every span anyone ever said, and rebuilding it costs one
  /// slow sentence, not a slow app.
  private static readonly capacity = 20_000;

  private termsFingerprint = '';
  private prepared: Prepared[] = [];
  private entries = new Map<string, string | null>();
  private englishWords = new Map<string, boolean>();
  private missCount = 0;

  get misses(): number { return this.missCount; }
  resetCounters(): void { this.missCount = 0; }

  /// Returns the term list with its per-term work already done, dropping
  /// everything remembered if the list itself has changed — a word added in the
  /// Dictionary has to take effect on the next sentence.
  prepare(terms: string[]): Prepared[] {
    const fingerprint = terms.join(' ');
    if (fingerprint !== this.termsFingerprint) {
      this.termsFingerprint = fingerprint;
      this.prepared = terms.map((term) => ({
        term,
        normalised: normalise(term),
        wordCount: termWordCount(term),
      }));
      this.entries.clear();
    }
    return this.prepared;
  }

  private static encode(key: MemoKey): string {
    return `${key.spanCount} ${key.phoneticAllowed ? '1' : '0'} ${key.candidate}`;
  }

  /// `undefined` means "this span has not been decided yet"; `null` means
  /// "decided, and the answer was no match" — which is by far the commonest
  /// result and is worth remembering.
  cached(key: MemoKey): string | null | undefined {
    return this.entries.get(MatchMemo.encode(key));
  }

  remember(key: MemoKey, value: string | null): void {
    this.missCount += 1;
    if (this.entries.size >= MatchMemo.capacity) this.entries.clear();
    this.entries.set(MatchMemo.encode(key), value);
  }

  isEnglish(word: string, compute: (word: string) => boolean): boolean {
    const known = this.englishWords.get(word);
    if (known !== undefined) return known;
    const answer = compute(word);
    if (this.englishWords.size >= MatchMemo.capacity) this.englishWords.clear();
    this.englishWords.set(word, answer);
    return answer;
  }
}

export interface VocabularyCorrectorOptions {
  /// Fixed for tests and for anything scoring a corpus, where the list must not
  /// move underneath the run.
  terms?: string[];
  /// The shipping path: follows the vocabulary file as it changes.
  book?: VocabularyBook;
  /// Tuned against real failures rather than picked round: "craigeburn" vs
  /// "craigieburn" scores 0.91 and must pass; "graphifi" vs "graphify" scores
  /// 0.875 and must pass; ordinary English near-misses must not.
  singleWordThreshold?: number;
  multiWordThreshold?: number;
}

export class VocabularyCorrector {
  private readonly fixedTerms: string[] | null;
  private readonly book: VocabularyBook | null;
  private readonly singleWordThreshold: number;
  private readonly multiWordThreshold: number;
  private readonly memo = new MatchMemo();

  constructor(options: VocabularyCorrectorOptions = {}) {
    this.fixedTerms = options.terms ?? null;
    this.book = options.terms ? null : (options.book ?? null);
    this.singleWordThreshold = options.singleWordThreshold ?? 0.8;
    this.multiWordThreshold = options.multiWordThreshold ?? 0.85;
  }

  /// Read per call, not per instance.
  ///
  /// The cleaner is built once at launch and lives for the life of the process,
  /// so a corrector holding a snapshot meant a word added in the Dictionary did
  /// nothing at all until the app was relaunched — with the screen reporting it
  /// as added the whole time.
  get terms(): string[] {
    return this.fixedTerms ?? this.book?.terms ?? [];
  }

  /// Spans this corrector has actually had to match, as opposed to recognise.
  /// The incremental behaviour is asserted by counting this rather than by
  /// timing, because a clock on a shared machine measures the machine.
  get spansMatchedForTesting(): number { return this.memo.misses; }
  resetTestingCounters(): void { this.memo.resetCounters(); }

  private isRealEnglishWordMemoised(word: string): boolean {
    return this.memo.isEnglish(word, isRealEnglishWord);
  }

  everyWordIsOrdinaryEnglish(span: string): boolean {
    const words = span.split(/[ -]/).filter((piece) => piece.length > 0);
    if (words.length === 0) return false;
    return words.every((word) => this.isRealEnglishWordMemoised(word));
  }

  correct(text: string): string {
    // Once, at the top: the list must not change between two windows of the
    // same sentence.
    const terms = this.terms;
    if (terms.length === 0 || text.length === 0) return text;

    const tokens = tokenise(text);
    if (tokens.length === 0) return text;

    // Per-term work done once for the whole sentence rather than once per
    // candidate span, and dropped if the Dictionary changed under us.
    const prepared = this.memo.prepare(terms);

    let index = 0;
    while (index < tokens.length) {
      let replaced = false;
      // Longest span first: "next fulfilment" must win over "next" alone.
      const longest = Math.min(3, tokens.length - index);
      for (let span = longest; span >= 1; span -= 1) {
        const window = tokens.slice(index, index + span);
        // A name does not begin or end with a function word.
        //
        // Without this, "until Craig Eburn is done" matched the span "Craig
        // Eburn is" against "Craigieburn" — close enough by sound once the
        // trailing "is" is folded into the skeleton — and the replacement
        // swallowed the verb: "Until Craigieburn done".
        if (isBoundaryWord(window[0]?.word)) continue;
        if (isBoundaryWord(window[window.length - 1]?.word) && span !== 1) continue;
        // A name is split across adjacent WORDS, never across a clause boundary
        // or around a stray mark.
        //
        //     "Ship the code. Sign the release"  ->  "Ship the codesign the release"
        //     "pushed the code, sign off"        ->  "pushed the codesign off"
        //
        // `continue` rather than `break`, so the shorter span is still tried —
        // that is what keeps the legitimate repair in shapes like
        // "Air Tasker. He's".
        if (!window.slice(0, -1).every((t) => !Array.from(t.trailing).some((c) => '.,!?;:'.includes(c)))) continue;
        if (!window.every((t) => t.word.length > 0)) continue;
        const candidate = window.map((t) => t.word).join(' ');
        // An email address is not a misheard name. Its local part is whatever
        // the person chose to call themselves, and fuzzy-matching it against
        // the Dictionary would rewrite someone's address — which looks correct
        // and silently mails the wrong person.
        if (candidate.includes('@')) continue;
        const key: MemoKey = {
          candidate,
          spanCount: span,
          phoneticAllowed: this.allowsPhoneticMatch(window),
        };
        const remembered = this.memo.cached(key);
        let resolved: string | null;
        if (remembered !== undefined) {
          resolved = remembered;
        } else {
          resolved = this.bestMatch(candidate, span, key.phoneticAllowed, prepared);
          this.memo.remember(key, resolved);
        }
        if (resolved === null) continue;

        // Keep the trailing punctuation of the last token in the span. The
        // opening quote or bracket the user said comes back too.
        tokens[index] = {
          leading: window[0]!.leading,
          word: resolved,
          trailing: window[span - 1]!.trailing,
        };
        if (span > 1) tokens.splice(index + 1, span - 1);
        index += 1;
        replaced = true;
        break;
      }
      if (!replaced) index += 1;
    }

    return tokens
      .map((t) => t.leading + t.word + t.trailing)
      .join(' ')
      .split(' \n')
      .join('\n');
  }

  /// Whether the sound-based route may fire for this span at all.
  ///
  /// It may not, unless at least one word in the span is not English. This is
  /// the guard that keeps a useful feature from becoming a destructive one.
  ///
  /// Sound matching is powerful precisely because it ignores spelling, and that
  /// is also how it gets you killed: "net a fly" and "not a fly" have the same
  /// consonant skeleton, so the rule that rescues "Netlify" from the first
  /// would silently plant "Netlify" in the middle of the second. Nothing in the
  /// audio distinguishes them — only the surrounding sentence does, and this
  /// pass does not read the sentence.
  ///
  /// # Why there is no "ask a model about the near-misses" pass
  ///
  /// The tempting design: use this scorer as a cheap DETECTOR — flag any span
  /// that sounds like a term even when the guard refuses to act — and let a
  /// model decide. Measured before building it, and it does not work. The
  /// phonetic skeleton at a 0.70 floor flags 11 of 12 ordinary sentences
  /// against the shipped seed vocabulary:
  ///
  ///     "not leave"      -> Netlify          1.00
  ///     "Friday and"     -> Builda Bed       0.80
  ///     "colour looked"  -> Carlo Gigliotti  0.80
  ///     "caps for"       -> Vesper           0.80
  ///     "second"         -> subagent         0.80
  ///
  /// The real manglings score 0.75, 0.75 and 0.86. Ordinary English reaches
  /// 1.00. There is no threshold between them.
  private allowsPhoneticMatch(window: Token[]): boolean {
    return window.some((t) => t.word.length > 0 && !this.isRealEnglishWordMemoised(t.word));
  }

  private bestMatch(
    candidate: string,
    spanCount: number,
    phoneticAllowed: boolean,
    terms: Prepared[],
  ): string | null {
    const normalised = normalise(candidate);
    if (normalised.length < 3) return null;

    const threshold = spanCount === 1 ? this.singleWordThreshold : this.multiWordThreshold;

    // Depends on the candidate alone, so it is worked out at most once per span
    // instead of once per term. Still lazy: the guard that needs it is reached
    // for a minority of terms, and it is the expensive one.
    let ordinaryCandidate: boolean | null = null;
    const candidateIsOrdinaryEnglish = (): boolean => {
      if (ordinaryCandidate === null) ordinaryCandidate = this.everyWordIsOrdinaryEnglish(candidate);
      return ordinaryCandidate;
    };

    let best: { term: string; score: number } | null = null;
    for (const entry of terms) {
      const target = entry.normalised;
      if (target.length === 0) continue;
      // Cheap length prefilter: nothing this far apart can clear the bar.
      const ratio = Math.min(normalised.length, target.length) / Math.max(normalised.length, target.length);
      if (ratio < threshold - 0.15) continue;

      if (normalised === target) {
        // An exact letter match is normally the strongest evidence there is —
        // "fire store" IS "Firestore". But it used to return here before any
        // guard ran, and the letters of a name are not unique to that name.
        // "Builda Bed" normalises to "buildabed" and so does "build a bed", so
        // the shipping seed list turned
        //
        //     "I need to build a bed for the spare room"
        //
        // into "I need to Builda Bed for the spare room" — a sentence of
        // ordinary English, rewritten into a brand.
        if (!spanCanBe(entry.wordCount, spanCount)) continue;
        // And the split form must not be a pair that the literal table already
        // decided needs an anchor.
        if (spanCount > 1 && AMBIGUOUS_SPLITS.has(normalised)) continue;
        // One word, spelled correctly, whose letters equal a one-word term. The
        // only thing this branch can change about it is its case, and the
        // pass's own rule is that a correctly spelled English word is presumed
        // intentional — so "codesign" said as a word, or "sync", is left as the
        // user wrote it.
        //
        // Scoped to one-word terms so the glued-name repair stays reachable:
        // "whisperflow" → "Wispr Flow" has wordCount 2 and is untouched.
        // `continue`, not `return null`, so a longer term later in the list can
        // still match this span.
        if (spanCount === 1 && entry.wordCount === 1 && this.isRealEnglishWordMemoised(candidate)) continue;
        return candidate === entry.term ? null : entry.term;
      }

      // Letters first, then sound.
      //
      // Spelling distance is the wrong instrument for a speech error and
      // measurably so: "Netlify" came back as "net a fly" (0.57 by letters,
      // against a 0.85 bar) and as "Netterfly" (0.67, against 0.80). Both are
      // within a whisker of the target phonetically and nowhere near it
      // alphabetically, so the corrector sat on its hands for exactly the words
      // it exists to fix.
      const score = similarity(normalised, target);
      if (!spanCanBe(entry.wordCount, spanCount)) continue;
      // A span of entirely ordinary English matched against a multi-word term
      // has to be near-exact, not merely close.
      //
      // "Roman design cost" scores 0.867 against "Roman Design Co" and cleared
      // the 0.85 bar, so "the Roman design cost a lot more than I thought"
      // became "the Roman Design Co a lot more than I thought" — the verb
      // deleted, mid-sentence, silently.
      const ordinaryPhrase = spanCount > 1 && entry.wordCount > 1 && candidateIsOrdinaryEnglish();
      const bar = ordinaryPhrase ? ORDINARY_PHRASE_THRESHOLD : threshold;
      if (score >= bar && score > (best?.score ?? 0)) {
        best = { term: entry.term, score };
      } else if (phoneticAllowed && score >= PHONETIC_LETTERS_FLOOR) {
        // Sound is only evidence when the spelling is at least in the same
        // neighbourhood. "y t dlp" — the recogniser spelling out yt-dlp — was
        // being replaced by "Netlify". They share 0.143 of their letters. A
        // genuine mishearing of a name still LOOKS something like the name.
        const sound = phoneticSimilarity(normalised, target);
        if (sound >= PHONETIC_THRESHOLD && sound > (best?.score ?? 0)) {
          best = { term: entry.term, score: sound };
        }
      }
    }

    if (!best) return null;
    // A correctly spelled English word is presumed intentional.
    if (spanCount === 1 && this.isRealEnglishWordMemoised(candidate)) return null;
    return best.term;
  }
}
