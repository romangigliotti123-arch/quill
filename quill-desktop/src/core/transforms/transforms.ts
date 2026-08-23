import { dataFile, writeAtomic } from '../paths';
import { encodeJSON, fromISO, readStoreFile, toISO, uuid } from '../stores/storeFile';
import { escapeRegExp, escapeReplacement, trim } from '../text/strings';
import {
  FastCleaner, capitaliseSentences, collapseWhitespace, stripStandaloneDisfluencies,
  tightenPunctuationSpacing,
} from '../cleanup/fastCleaner';
import { AIOutputGuard } from '../ai/outputGuard';

// Transforms reshape text that already exists. That is a different job from the
// cleanup pass, and the difference decides almost every choice in this file.
//
// Cleanup is invisible, automatic and bounded — it runs on every dictation, it
// must beat a deadline, and it is only ever allowed to make the text look more
// like what the user meant to say. A transform is the opposite on all four
// counts: the user asks for it explicitly, it may take a second, and it is
// *supposed* to change the shape ("make that an email" adds a greeting that
// nobody spoke). The guard bounds that protect cleanup — output between 0.5×
// and 1.6× the input — would reject almost every correct transform, so
// transforms carry their own bounds per transform.
//
// The offline story is the same as everywhere else in Quill. Every transform
// declares what it does with no network. Some can be done exactly and
// deterministically (a bullet list is a sentence split; "more formal" is
// largely contraction expansion); some genuinely cannot ("summarise this"). The
// ones that cannot say so and refuse, rather than silently returning the input
// unchanged and letting the user believe the transform ran.

// MARK: - Length bounds

/// How much a transform is allowed to change the length of its input.
///
/// This is the only automatic check that can tell "the model rewrote the text"
/// from "the model answered the text", and it has to be per transform because
/// the honest answer differs by an order of magnitude: a summary legitimately
/// keeps 8% of the characters, an email legitimately triples them. One shared
/// bound would have to be the union of both, which admits everything.
export interface LengthBounds {
  minRatio: number;
  maxRatio: number;
  /// Added to the ceiling only. Short inputs need absolute headroom — "- " on
  /// every line of a two-line list is a large ratio and a tiny edit — while a
  /// floor with slack in it collapses to zero for anything short.
  slack: number;
}

export function boundsAdmit(bounds: LengthBounds, input: number, output: number): boolean {
  return output >= input * bounds.minRatio && output <= input * bounds.maxRatio + bounds.slack;
}

/// For a transform that reshapes without adding or removing information.
export const RESHAPING_BOUNDS: LengthBounds = { minRatio: 0.6, maxRatio: 1.6, slack: 24 };

// MARK: - Offline recipes

/// What a transform does with no network.
///
/// Deliberately a closed set of named recipes rather than a function: it has to
/// survive a round trip through JSON, because a user-defined transform picks
/// one too. A recipe that cannot be written down cannot be persisted.
export type OfflineRecipe =
  | 'none' | 'bulletList' | 'numberedList' | 'expandContractions' | 'fastClean'
  | 'sentenceCase' | 'titleCase' | 'upperCase' | 'lowerCase';

export const OFFLINE_RECIPES: OfflineRecipe[] = [
  'none', 'bulletList', 'numberedList', 'expandContractions', 'fastClean',
  'sentenceCase', 'titleCase', 'upperCase', 'lowerCase',
];

export function recipeTitle(recipe: OfflineRecipe): string {
  switch (recipe) {
    case 'none': return 'Needs the network';
    case 'bulletList': return 'Split into bullets';
    case 'numberedList': return 'Split into a numbered list';
    case 'expandContractions': return 'Expand contractions';
    case 'fastClean': return 'Deterministic cleanup';
    case 'sentenceCase': return 'Sentence case';
    case 'titleCase': return 'Title Case';
    case 'upperCase': return 'UPPERCASE';
    case 'lowerCase': return 'lowercase';
  }
}

/// How far short of the full transform this recipe falls, in the user's terms.
/// Null when the recipe is the whole job — a bullet list split by sentence is
/// not an approximation of anything.
///
/// This exists so the user is never left thinking they got the full transform
/// when they did not, and so does not re-run it later on a connection that
/// would have done the real thing.
export function recipeLimitation(recipe: OfflineRecipe): string | null {
  switch (recipe) {
    case 'expandContractions': return 'contractions and filler only';
    case 'fastClean': return 'deterministic cleanup only';
    default: return null;
  }
}

/// What the overlay says when this recipe ran because there was no network.
export function recipeOfflineNote(recipe: OfflineRecipe): string | null {
  if (recipe === 'none') return null;
  const limitation = recipeLimitation(recipe);
  return limitation ? `offline — ${limitation}` : 'offline';
}

/// Ordered longest-first at use, so "wouldn't've" cannot be half-matched by
/// "wouldn't". Apostrophes are matched in both the ASCII and the typographic
/// form because the recogniser emits ’ and a user editing a transform types '.
const CONTRACTIONS: Record<string, string> = {
  "can't": 'cannot', "won't": 'will not', "shan't": 'shall not',
  "don't": 'do not', "doesn't": 'does not', "didn't": 'did not',
  "isn't": 'is not', "aren't": 'are not', "wasn't": 'was not',
  "weren't": 'were not', "haven't": 'have not', "hasn't": 'has not',
  "hadn't": 'had not', "wouldn't": 'would not', "couldn't": 'could not',
  "shouldn't": 'should not', "mustn't": 'must not', "mightn't": 'might not',
  "i'm": 'I am', "i've": 'I have', "i'll": 'I will', "i'd": 'I would',
  "you're": 'you are', "you've": 'you have', "you'll": 'you will', "you'd": 'you would',
  "we're": 'we are', "we've": 'we have', "we'll": 'we will', "we'd": 'we would',
  "they're": 'they are', "they've": 'they have', "they'll": 'they will', "they'd": 'they would',
  "he's": 'he is', "she's": 'she is', "it's": 'it is', "that's": 'that is',
  "there's": 'there is', "here's": 'here is', "what's": 'what is',
  "let's": 'let us', "who's": 'who is',
  "he'll": 'he will', "she'll": 'she will', "it'll": 'it will',
  gonna: 'going to', wanna: 'want to', gotta: 'have to',
  kinda: 'kind of', sorta: 'sort of', cos: 'because', cuz: 'because',
  yeah: 'yes', yep: 'yes', nope: 'no', ok: 'OK', okay: 'OK',
};

/// "- foo", "* foo", "1. foo", "1) foo" → "foo". Re-bulleting a bullet list
/// must not produce "- - foo".
export function stripExistingMarker(line: string): string {
  for (const pattern of [/^[-*•]\s+/u, /^\d+[.)]\s+/u]) {
    const match = pattern.exec(line);
    if (match) return line.slice(match[0].length);
  }
  return line;
}

/// Multi-line input is already a list of something; splitting its sentences as
/// well would shred a paragraph the user deliberately kept together.
export function existingLines(text: string): string[] | null {
  if (!text.includes('\n')) return null;
  const lines = text
    .split('\n')
    .map((line) => stripExistingMarker(trim(line)))
    .filter((line) => line.length > 0);
  return lines.length === 0 ? null : lines;
}

/// Sentence splitting that survives dictation.
///
/// Dictation is full of "e.g." and "9 a.m." and "roman@example.com", and a
/// naive split on ".!?" turns every one of those into two bullets. The macOS
/// build used ICU sentence breaking; `Intl.Segmenter` gives the same thing here
/// where it exists, and the regex below is the fallback for the rare build
/// without it.
export function sentencesOfText(text: string): string[] {
  const segmenter = typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function'
    ? new Intl.Segmenter(undefined, { granularity: 'sentence' })
    : null;
  const out: string[] = [];
  if (segmenter) {
    for (const piece of segmenter.segment(text)) {
      const sentence = trim(piece.segment);
      if (sentence.length > 0) out.push(sentence);
    }
  } else {
    for (const piece of text.split(/(?<=[.!?])\s+(?=[A-Z])/u)) {
      const sentence = trim(piece);
      if (sentence.length > 0) out.push(sentence);
    }
  }
  return out.length === 0 ? [text] : out;
}

/// The full stop at the end of a bullet is noise; anything else — a question
/// mark, an exclamation — carries meaning and stays.
export function stripTrailingStop(s: string): string {
  return s.endsWith('.') && !s.endsWith('..') ? s.slice(0, -1) : s;
}

function makeList(text: string, marker: (index: number) => string): string | null {
  const items = existingLines(text) ?? sentencesOfText(text);
  if (items.length <= 1 && text.includes('\n')) return null;
  if (items.length === 0) return null;
  return items.map((item, index) => marker(index) + stripTrailingStop(item)).join('\n');
}

/// Contractions out, and the spoken filler with them.
///
/// The filler pass was added after a live run: "so um we should probably…" came
/// back from the offline path character-identical to what went in, and a
/// transform that returns its input has told the user it ran.
export function expandContractionsOffline(text: string): string {
  let out = stripStandaloneDisfluencies(text);
  out = collapseWhitespace(out);
  out = tightenPunctuationSpacing(out);
  // Longest first: "wouldn't" must not be rewritten by a shorter key that
  // happens to be a prefix of it once ordering is arbitrary.
  for (const key of Object.keys(CONTRACTIONS).sort((a, b) => b.length - a.length)) {
    const replacement = CONTRACTIONS[key]!;
    for (const apostrophe of ["'", '’']) {
      const variant = key.replace(/'/g, apostrophe);
      out = out.replace(
        new RegExp(`\\b${escapeRegExp(variant)}\\b`, 'giu'),
        escapeReplacement(replacement),
      );
    }
  }
  // The expansions are lowercase by construction; a sentence that started with
  // one now starts lowercase.
  return capitaliseSentences(out);
}

function titleCase(text: string): string {
  return text.replace(/\p{L}[\p{L}\p{M}'’]*/gu, (word) =>
    word.slice(0, 1).toUpperCase() + word.slice(1).toLowerCase());
}

/// The deterministic implementations. Pure functions over a string, no state,
/// no network, microseconds. Returns null when the recipe cannot apply.
export function applyOfflineRecipe(recipe: OfflineRecipe, text: string): string | null {
  const trimmed = trim(text);
  if (trimmed.length === 0) return null;
  switch (recipe) {
    case 'none': return null;
    case 'bulletList': return makeList(trimmed, () => '- ');
    case 'numberedList': return makeList(trimmed, (index) => `${index + 1}. `);
    case 'expandContractions': return expandContractionsOffline(trimmed);
    case 'fastClean': return new FastCleaner().cleanFast(trimmed);
    case 'sentenceCase': return capitaliseSentences(trimmed.toLowerCase());
    case 'titleCase': return titleCase(trimmed);
    case 'upperCase': return trimmed.toUpperCase();
    case 'lowerCase': return trimmed.toLowerCase();
  }
}

// MARK: - Transform

/// What the transform reads.
export type TransformTarget = 'selection' | 'lastDictation' | 'automatic';

export function targetTitle(target: TransformTarget): string {
  switch (target) {
    case 'selection': return 'The current selection';
    case 'lastDictation': return 'The last dictation';
    case 'automatic': return 'Selection, or the last dictation';
  }
}

/// One named reshaping of text.
export interface Transform {
  id: string;
  name: string;
  /// Handed to the model as the system instruction. Written as an order, not a
  /// description — "Rewrite as a bullet list", not "this makes bullet lists".
  instruction: string;
  /// Whole-utterance phrases that invoke this transform in command mode. These
  /// are matched exactly, and that is what makes them safe; see `commandRouter`.
  triggers: string[];
  /// The distinctive words that identify this transform inside a spoken
  /// instruction that is not an exact trigger. "formal", "bullet", "email".
  /// Ordinary English that could appear in dictated content does not belong
  /// here — every keyword is a chance to eat a sentence.
  keywords: string[];
  /// An Electron accelerator, e.g. "Control+Alt+B". Registered as a global
  /// shortcut, which is what makes it CONSUMED rather than merely observed —
  /// see `hotkeyEngine.ts` for why a transform chord must never be a bare key.
  accelerator: string | null;
  target: TransformTarget;
  offline: OfflineRecipe;
  bounds: LengthBounds;
  /// Whether the user's vocabulary must survive the round trip.
  ///
  /// True for transforms that reshape without removing — a bullet list that
  /// turned "nxt" into "next" got it wrong. False for shortening and
  /// summarising, where dropping words is the entire point and rejecting on a
  /// missing term would reject every correct answer.
  preservesVocabulary: boolean;
  isEnabled: boolean;
  /// Shipped with the app. Only affects presentation — a built-in can be edited
  /// and deleted like any other.
  isBuiltIn: boolean;
  useCount: number;
  lastUsed: Date | null;
  created: Date;
}

export function transformWorksOffline(transform: Transform): boolean {
  return transform.offline !== 'none';
}

function decodeTransform(raw: Record<string, unknown>): Transform | null {
  if (typeof raw.name !== 'string' || typeof raw.instruction !== 'string') return null;
  const bounds = raw.bounds as Partial<LengthBounds> | undefined;
  return {
    id: typeof raw.id === 'string' ? raw.id : uuid(),
    name: raw.name,
    instruction: raw.instruction,
    triggers: Array.isArray(raw.triggers) ? (raw.triggers as string[]).filter((t) => typeof t === 'string') : [],
    keywords: Array.isArray(raw.keywords) ? (raw.keywords as string[]).filter((t) => typeof t === 'string') : [],
    accelerator: typeof raw.accelerator === 'string' && raw.accelerator.length > 0 ? raw.accelerator : null,
    target: raw.target === 'selection' || raw.target === 'lastDictation' ? raw.target : 'automatic',
    offline: OFFLINE_RECIPES.includes(raw.offline as OfflineRecipe) ? (raw.offline as OfflineRecipe) : 'none',
    bounds: bounds && typeof bounds.minRatio === 'number' && typeof bounds.maxRatio === 'number'
      ? { minRatio: bounds.minRatio, maxRatio: bounds.maxRatio, slack: bounds.slack ?? 24 }
      : { ...RESHAPING_BOUNDS },
    preservesVocabulary: raw.preservesVocabulary !== false,
    isEnabled: raw.isEnabled !== false,
    isBuiltIn: raw.isBuiltIn === true,
    useCount: typeof raw.useCount === 'number' ? raw.useCount : 0,
    lastUsed: fromISO(raw.lastUsed),
    created: fromISO(raw.created) ?? new Date(),
  };
}

/// Hand-written rather than derived, and the reason is durability of a user's
/// own data. This type will gain fields — a transform is exactly the kind of
/// thing that grows options — and with a strict decoder one new required field
/// makes every previously-saved file fail to decode, at which point the store
/// falls back to the seed and the user's transforms are gone. Only `name` and
/// `instruction` are required; everything else defaults.
function validate(value: unknown): Transform[] | null {
  if (!Array.isArray(value)) return null;
  const out: Transform[] = [];
  for (const entry of value) {
    if (!entry || typeof entry !== 'object') return null;
    const decoded = decodeTransform(entry as Record<string, unknown>);
    if (!decoded) return null;
    out.push(decoded);
  }
  return out;
}

function encode(transforms: Transform[]): unknown {
  return transforms.map((transform) => ({
    ...transform,
    lastUsed: toISO(transform.lastUsed),
    created: toISO(transform.created),
  }));
}

export function makeTransform(partial: Partial<Transform> & { name: string; instruction: string }): Transform {
  return {
    id: partial.id ?? uuid(),
    name: partial.name,
    instruction: partial.instruction,
    triggers: partial.triggers ?? [],
    keywords: partial.keywords ?? [],
    accelerator: partial.accelerator ?? null,
    target: partial.target ?? 'automatic',
    offline: partial.offline ?? 'none',
    bounds: partial.bounds ?? { ...RESHAPING_BOUNDS },
    preservesVocabulary: partial.preservesVocabulary ?? true,
    isEnabled: partial.isEnabled ?? true,
    isBuiltIn: partial.isBuiltIn ?? false,
    useCount: partial.useCount ?? 0,
    lastUsed: partial.lastUsed ?? null,
    created: partial.created ?? new Date(),
  };
}

// MARK: - Seed

/// First-run contents.
///
/// The trigger phrases are the safety-critical part of this list. Every one
/// contains a command verb *and* a referent ("that", "it", "this"), because the
/// router will only fire on a whole utterance and those two things together are
/// what make a whole utterance an instruction rather than a sentence someone
/// dictated. A trigger like "bullet points" is deliberately absent: it is a
/// phrase a person could plausibly dictate into a document, and eating it would
/// cost them their words.
export function transformSeed(): Transform[] {
  const now = new Date();
  return [
    makeTransform({
      name: 'Bullet points',
      instruction: 'Rewrite the text as a bullet list. One point per line, each line starting with "- ".\n'
        + 'Keep every fact and every name; do not add, merge or invent points. No heading, no preamble.',
      triggers: ['make that a bullet list', 'make it a bullet list',
        'turn that into bullet points', 'turn this into bullet points',
        'make that bullet points', 'format that as bullet points',
        'bullet point that'],
      // "list" is shared with the numbered transform on purpose: it is what
      // makes "make that a bullet list" score two keywords against the numbered
      // transform's one, so the tie-break never has to run.
      keywords: ['bullet', 'bullets', 'bulleted', 'list'],
      offline: 'bulletList',
      bounds: { minRatio: 0.6, maxRatio: 1.6, slack: 24 },
      isBuiltIn: true,
      created: now,
    }),
    makeTransform({
      name: 'Numbered list',
      instruction: 'Rewrite the text as a numbered list. One step per line, each line starting with "1. ", "2. " and so on.\n'
        + 'Keep every fact and every name; do not add or invent steps. No heading, no preamble.',
      triggers: ['make that a numbered list', 'make it a numbered list',
        'turn that into a numbered list', 'number that'],
      keywords: ['numbered', 'number', 'list'],
      offline: 'numberedList',
      bounds: { minRatio: 0.6, maxRatio: 1.7, slack: 24 },
      isBuiltIn: true,
      created: now,
    }),
    makeTransform({
      name: 'Shorter',
      instruction: 'Rewrite the text in fewer words. Keep every fact, name and number; cut only padding and repetition.\n'
        + 'Same voice, same person, same tense. Return only the rewritten text.',
      triggers: ['make that shorter', 'make it shorter', 'make this shorter',
        'shorten that', 'shorten it', 'tighten that up', 'trim that down'],
      keywords: ['shorter', 'shorten', 'tighten', 'trim', 'concise'],
      offline: 'none',
      bounds: { minRatio: 0.15, maxRatio: 1.0, slack: 8 },
      // Cutting words is the job. A vocabulary check here would reject every
      // correct answer that dropped a proper noun on purpose.
      preservesVocabulary: false,
      isBuiltIn: true,
      created: now,
    }),
    makeTransform({
      name: 'Summarise',
      instruction: 'Summarise the text in one or two sentences. State only what the text says; add nothing.\n'
        + 'Return only the summary, with no preamble and no heading.',
      // "give me the gist of that" was here and was removed: it has no command
      // verb, and a whole utterance of it is something a person says to another
      // person in a chat window.
      triggers: ['summarise that', 'summarize that', 'summarise this', 'summarize this', 'sum that up'],
      keywords: ['summarise', 'summarize', 'summary', 'gist'],
      offline: 'none',
      bounds: { minRatio: 0.08, maxRatio: 0.8, slack: 24 },
      preservesVocabulary: false,
      isBuiltIn: true,
      created: now,
    }),
    makeTransform({
      name: 'More formal',
      instruction: 'Rewrite the text in a more formal register. Expand contractions, drop slang and filler,\n'
        + 'and use complete sentences. Do not lengthen it, do not add pleasantries, and do not change any fact.',
      triggers: ['make that more formal', 'make it more formal', 'make this more formal',
        'formalise that', 'make that sound professional'],
      keywords: ['formal', 'formalise', 'formalize', 'professional'],
      offline: 'expandContractions',
      bounds: { minRatio: 0.7, maxRatio: 1.8, slack: 24 },
      isBuiltIn: true,
      created: now,
    }),
    makeTransform({
      name: 'More casual',
      instruction: 'Rewrite the text so it reads like one person talking to another they already know.\n'
        + 'Plain words, contractions allowed, no corporate phrasing, no exclamation marks. Change no fact.',
      triggers: ['make that more casual', 'make it more casual',
        'make that sound friendlier', 'make it less formal'],
      keywords: ['casual', 'friendlier', 'informal', 'relaxed'],
      offline: 'none',
      bounds: { minRatio: 0.5, maxRatio: 1.5, slack: 24 },
      isBuiltIn: true,
      created: now,
    }),
    makeTransform({
      name: 'Email',
      // "No subject line" is spelled out because a live run put one in unasked —
      // and a subject line pasted into a Slack message or a reply box is
      // invented scaffolding in the wrong place.
      instruction: 'Rewrite the text as a short email body: one greeting line, the body, and a sign-off.\n'
        + 'No subject line, no headers, no "Subject:".\n'
        + 'Keep the body to what the text actually says — do not invent context, deadlines, prices or names.\n'
        + 'If the recipient is not named in the text, open with "Hey —". Return only the email.',
      // "write that as an email" is absent because "write" is not a command verb
      // and is not going to become one — "write that in the notes" is dictation.
      triggers: ['make that an email', 'make it an email', 'turn that into an email',
        'turn this into an email'],
      keywords: ['email'],
      offline: 'none',
      // A greeting and a sign-off are roughly 40 characters of scaffolding that
      // were never in the input, so the ceiling is generous and the slack is
      // absolute rather than proportional.
      bounds: { minRatio: 0.8, maxRatio: 3.0, slack: 120 },
      isBuiltIn: true,
      created: now,
    }),
    makeTransform({
      name: 'Fix grammar',
      instruction: 'Correct grammar, spelling and punctuation. Change nothing else — not the wording, not the register,\n'
        + 'not the order. If a sentence is already correct, return it untouched.',
      // Every trigger names what it acts on. Bare "fix the grammar" was here and
      // was removed — with no referent it is an instruction to a person, and
      // people dictate those.
      triggers: ['fix the grammar in that', 'fix that up',
        'clean that up', 'clean up that', 'tidy that up', 'proofread that'],
      keywords: ['grammar', 'spelling', 'punctuation', 'proofread', 'tidy'],
      offline: 'fastClean',
      bounds: { minRatio: 0.8, maxRatio: 1.3, slack: 16 },
      isBuiltIn: true,
      created: now,
    }),
  ];
}

// MARK: - Store

export class TransformStore {
  private readonly url: string | null;
  private items: Transform[] = [];
  /// Set when transforms.json exists and will not decode. While it is set the
  /// store never writes, so a damaged file is never overwritten.
  private loadFailed = false;
  private listeners: (() => void)[] = [];

  private static sharedStore: TransformStore | null = null;
  static shared(): TransformStore {
    if (!TransformStore.sharedStore) TransformStore.sharedStore = new TransformStore();
    return TransformStore.sharedStore;
  }

  static inMemory(items: Transform[]): TransformStore {
    const store = new TransformStore(null);
    store.items = items;
    return store;
  }

  constructor(url: string | null = dataFile('transforms.json')) {
    this.url = url;
    if (!url) return;
    // Three states, not two. `try ?? seed` collapses "the file is not there"
    // and "the file is damaged" into the same answer, and they call for
    // opposite behaviour.
    //
    // What that cost: a partial write during a crash, a zero-byte file, or one
    // hand-edited object missing a required key — and this file is explicitly
    // meant to be hand-editable — silently substituted the eight built-ins. The
    // next time any transform ran, `recordUse` found its id (it came from the
    // seed) and the store wrote the seed over the file. Every custom transform
    // the user had written was gone, permanently, with no error.
    const outcome = readStoreFile(url, validate);
    switch (outcome.kind) {
      case 'missing': this.items = transformSeed(); break;
      case 'decoded': this.items = outcome.value; break;
      case 'unreadable':
        // The seed in memory so the feature still works this session; nothing
        // written, so the damaged file survives for the user to rescue.
        this.items = transformSeed();
        this.loadFailed = true;
        break;
    }
  }

  onChange(listener: () => void): void { this.listeners.push(listener); }

  get all(): Transform[] { return this.items.map((item) => ({ ...item })); }
  get enabled(): Transform[] { return this.all.filter((item) => item.isEnabled); }

  /// Most-used first. A transform list is a menu, and the one you reach for
  /// belongs at the top.
  get ordered(): Transform[] {
    return this.all.sort((a, b) => (a.useCount !== b.useCount
      ? b.useCount - a.useCount
      : a.name.localeCompare(b.name, undefined, { sensitivity: 'base' })));
  }

  /// Saves an edit without touching the usage statistics.
  ///
  /// The editor holds the transform as it was when it opened. If the transform
  /// fires while that editor is on screen — which is the normal case, since the
  /// reason to open it is usually that the last run came out wrong — then
  /// `recordUse` bumps the counter and the next Save writes the stale snapshot
  /// straight back over it. The count silently rolls backwards, the "most used
  /// first" ordering shuffles, and there is nothing on screen to explain it.
  upsert(transform: Transform): Transform {
    const index = this.items.findIndex((item) => item.id === transform.id);
    if (index >= 0) {
      const existing = this.items[index]!;
      this.items[index] = {
        ...transform,
        useCount: Math.max(existing.useCount, transform.useCount),
        lastUsed: [existing.lastUsed, transform.lastUsed]
          .filter((date): date is Date => date !== null)
          .sort((a, b) => b.getTime() - a.getTime())[0] ?? null,
      };
    } else {
      this.items.push({ ...transform });
    }
    this.persist();
    return { ...(this.items.find((item) => item.id === transform.id) ?? transform) };
  }

  remove(id: string): void {
    this.items = this.items.filter((item) => item.id !== id);
    this.persist();
  }

  transform(id: string): Transform | null {
    const found = this.items.find((item) => item.id === id);
    return found ? { ...found } : null;
  }

  /// Bumps the counter for one firing. Separate from `upsert` so running a
  /// transform never races an open editor into overwriting an edit.
  recordUse(id: string, at: Date = new Date()): void {
    const index = this.items.findIndex((item) => item.id === id);
    if (index < 0) return;
    this.items[index]!.useCount += 1;
    this.items[index]!.lastUsed = at;
    this.persist();
  }

  /// Every trigger phrase, offered to the recogniser alongside the dictionary.
  /// A trigger that never survives transcription can never fire.
  get phrases(): string[] {
    return this.enabled.flatMap((transform) => transform.triggers);
  }

  private persist(): void {
    for (const listener of this.listeners) listener();
    if (this.loadFailed || !this.url) return;
    writeAtomic(this.url, encodeJSON(encode(this.items)));
  }
}

// MARK: - Output guard

/// The guard between a language model and text the user is about to send.
///
/// `AIOutputGuard` already does this job for the cleanup pass, and its
/// stripping steps are reused verbatim — a model that wraps its answer in
/// quotes or prefixes it with "Here is the email:" does that regardless of what
/// it was asked. What is not reused is its length rule, which is calibrated for
/// a pass that must not change the text much, and its "\n\n means the model
/// started explaining" rule, which would reject every correct email.
export const TransformOutputGuard = {
  conversationalOpeners: [
    'sure', 'certainly', 'of course', 'here is', "here's", 'here are',
    "i've", 'i have', 'absolutely', 'no problem', 'got it', 'understood',
  ],

  opensConversationally(text: string): boolean {
    const firstLine = text.split('\n')[0] ?? text;
    const lowered = firstLine.toLowerCase();
    return TransformOutputGuard.conversationalOpeners.some((opener) => {
      if (!lowered.startsWith(opener)) return false;
      // "Here is the deposit schedule" is a real sentence someone could be
      // transforming; "Here is the rewritten text:" is not. Require the opener
      // to be followed by a boundary that reads like an aside.
      const rest = lowered.slice(opener.length);
      const next = rest[0];
      if (next === undefined) return true;
      return next === ',' || next === ':' || next === '!'
        || rest.startsWith(' the rewritten') || rest.startsWith(' the text')
        || rest.startsWith(' your') || rest.startsWith(' is the rewritten');
    });
  },

  /// Returns the text to insert, or null if the response cannot be trusted.
  /// Null means "fall back to the offline recipe, or tell the user it did not
  /// run" — never "paste it anyway".
  sanitise(raw: string, input: string, bounds: LengthBounds, terms: string[]): string | null {
    let out = trim(raw);
    if (out.length === 0) return null;

    out = AIOutputGuard.stripCodeFence(out);
    out = AIOutputGuard.stripLeadingLabel(out);
    out = AIOutputGuard.stripWrappingQuotes(out);
    out = trim(out);
    if (out.length === 0) return null;

    // A model that opens with "Sure, here you go" has answered the request
    // rather than performed it. `stripLeadingLabel` only catches the form that
    // ends in a colon; this catches the conversational form.
    if (TransformOutputGuard.opensConversationally(out)
      && !TransformOutputGuard.opensConversationally(input)) return null;

    if (!boundsAdmit(bounds, input.length, out.length)) return null;

    if (terms.length > 0 && AIOutputGuard.droppedVocabulary(input, out, terms).length > 0) {
      return null;
    }
    return out;
  },
};
