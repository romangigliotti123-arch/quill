import { dataFile, writeAtomic } from '../paths';
import { encodeJSON, fromISO, readStoreFile, toISO } from '../stores/storeFile';
import { escapeRegExp, escapeReplacement } from '../text/strings';
import { AIOutputGuard } from '../ai/outputGuard';
import { CLEANUP_SYSTEM_PROMPT } from '../ai/prompts';
import { SpellingConvention, toBritish } from './orthography';

// The learned writing profile: what has been observed about how this person
// writes, what it is confident enough to act on, and what it is allowed to do
// with that.

export type Formality = 'casual' | 'neutral' | 'formal';

export function formalityTitle(value: Formality): string {
  switch (value) {
    case 'casual': return 'Casual';
    case 'neutral': return 'Neutral';
    case 'formal': return 'Formal';
  }
}

export function spellingTitle(value: SpellingConvention): string {
  return value === 'british' ? 'British' : 'American';
}

export function spellingShortName(value: SpellingConvention): string {
  return value === 'british' ? 'British spelling' : 'American spelling';
}

/// "British/Australian" rather than "British": en-AU follows British convention,
/// and a model told "British" for an Australian has been told something
/// slightly false about who it is writing for.
function spellingPromptLine(value: SpellingConvention): string {
  return value === 'british' ? 'Use British/Australian spelling.' : 'Use American spelling.';
}

// MARK: - Presets

/// The four voices, pickable in one click.
///
/// These are the feature for the first month. Learning needs corrections and
/// corrections are rare, so anything that depends on them alone is a feature
/// that ships broken and gets good later — which is the same as shipping broken.
export type StylePreset = 'neutral' | 'casual' | 'professional' | 'technical';

export const STYLE_PRESETS: StylePreset[] = ['neutral', 'casual', 'professional', 'technical'];

export function presetTitle(preset: StylePreset): string {
  switch (preset) {
    case 'neutral': return 'Neutral';
    case 'casual': return 'Casual';
    case 'professional': return 'Professional';
    case 'technical': return 'Technical';
  }
}

export function presetSummary(preset: StylePreset): string {
  switch (preset) {
    case 'neutral': return 'Clean it up and change nothing else.';
    case 'casual': return "How you'd write to someone you know. Contractions, no sales voice.";
    case 'professional': return 'Client-ready. Complete sentences, still human.';
    case 'technical': return 'Precise. Keeps identifiers, paths and version numbers exactly as spoken.';
  }
}

/// One line, spent from the prompt budget, so it earns its length.
///
/// Every one of these describes **word choice**, and never a kind of document.
/// That distinction is the whole finding of the measurement below, and it is
/// not a stylistic preference — it decides whether the AI pass works at all.
///
/// # Benchmark — live against meta/llama-3.1-8b-instruct
///
/// Transcript: "Send it to Noah no wait send it to Carlo instead and tell him
/// the bed frames are ready". Variants interleaved round-robin so a slow patch
/// of network could not land on one of them.
///
///     style line                                        accepted   no rewrite
///     ────────────────────────────────────────────────────────────────────────
///     none (base cleanup prompt only)                    7/7        7/7
///     "write it the way one person messages another…"    2/7        0/7
///     "use everyday wording. no marketing…"              6/6        6/6
///     "write it as a clear, complete message to a        0/7        0/7
///      client; polished but not stiff"
///     "use precise, complete wording. no slang…"         9/9        9/9
///
/// The two persona lines did not adjust the tone of the sentence — they
/// replaced it. "Tell him the bed frames are ready" came back as "I've sent the
/// bed frames to Carlo, they're ready": a first-person report of an action
/// nobody performed, pasted without review. The professional line was worse
/// still at 0/7 accepted, because its rewrite was short enough to trip
/// `AIOutputGuard`'s floor — meaning a user who picked Professional would have
/// had the AI pass silently do nothing on every single dictation while still
/// paying its deadline.
function presetPromptLine(preset: StylePreset): string {
  switch (preset) {
    case 'neutral':
      return "Keep the speaker's own wording and register.";
    case 'casual':
      return 'Use everyday wording. No marketing, sales or AI-assistant phrasing.';
    case 'professional':
      return 'Use precise, complete wording. No slang and no marketing phrasing.';
    case 'technical':
      return 'Keep identifiers, file paths, commands and version numbers exactly as spoken; do not prettify them.';
  }
}

export function presetFormality(preset: StylePreset): Formality {
  switch (preset) {
    case 'neutral':
    case 'technical': return 'neutral';
    case 'casual': return 'casual';
    case 'professional': return 'formal';
  }
}

/// Sensible starting tone per destination app.
///
/// Not learned and not guessed at — this is the small set where the answer is
/// obvious to anyone. Everything else returns null and falls back to the user's
/// base preset. A shrug is the correct output for an app we know nothing about.
///
/// Keyed on the executable or window class the window watcher reports, because
/// bundle identifiers do not exist on Windows or Linux.
export function suggestedPreset(processOrClass: string): StylePreset | null {
  const name = processOrClass.toLowerCase();
  const has = (list: string[]): boolean => list.some((candidate) => name.includes(candidate));
  if (has(['slack', 'discord', 'whatsapp', 'telegram', 'signal', 'messages', 'element'])) return 'casual';
  if (has(['outlook', 'thunderbird', 'mail', 'evolution', 'geary', 'spark'])) return 'professional';
  if (has(['code', 'xcode', 'devenv', 'jetbrains', 'idea', 'pycharm', 'webstorm', 'rider',
    'terminal', 'iterm', 'ghostty', 'kitty', 'alacritty', 'konsole', 'powershell', 'cmd.exe',
    'wt.exe', 'nvim', 'vim', 'emacs', 'zed', 'cursor'])) return 'technical';
  return null;
}

// MARK: - Traits

/// One learned preference and the evidence for it.
///
/// A tally rather than a flag, for two reasons. A flag cannot express "I have
/// seen this once and am not sure", which is the state the profile spends most
/// of its life in. And a flag cannot be argued out of: people change, and a
/// preference learned in March should not need until December to unlearn.
export interface StyleTrait {
  /// Votes per value. The public shape is deliberate — this is what appears in
  /// style.json and it should read as an explanation, not as a checksum.
  votes: Record<string, number>;
  lastObserved: Date | null;
}

/// The most votes any one value can hold.
///
/// This is the "can change its mind" number. Each vote also takes one off every
/// rival, so a settled preference survives a stray correction but flips after
/// `VOTE_CEILING` consistent ones. Six is about a month of real corrections.
export const VOTE_CEILING = 6;

export function emptyTrait(): StyleTrait {
  return { votes: {}, lastObserved: null };
}

export function traitSupport(trait: StyleTrait): number {
  const values = Object.values(trait.votes);
  return values.length === 0 ? 0 : Math.max(...values);
}

export function traitTotal(trait: StyleTrait): number {
  return Object.values(trait.votes).reduce((total, count) => total + count, 0);
}

export function traitConfidence(trait: StyleTrait): number {
  const total = traitTotal(trait);
  return total === 0 ? 0 : traitSupport(trait) / total;
}

/// The winner, ignoring how sure we are. A genuine tie is unknown, not a coin
/// toss — silence is the safe output for a feature that rewrites text.
export function traitValue(trait: StyleTrait): string | null {
  const ranked = Object.entries(trait.votes)
    .filter(([, count]) => count > 0)
    .sort((a, b) => (a[1] === b[1] ? a[0].localeCompare(b[0]) : b[1] - a[1]));
  const top = ranked[0];
  if (!top) return null;
  if (ranked.length > 1 && ranked[1]![1] === top[1]) return null;
  return top[0];
}

/// One observation, one vote. Callers must not stuff the ballot by counting
/// every "colour" in a paragraph — see `styleLearner`, where each detector
/// returns at most one value per correction.
export function recordTrait(trait: StyleTrait, key: string, at: Date): void {
  for (const other of Object.keys(trait.votes)) {
    if (other === key) continue;
    const remaining = (trait.votes[other] ?? 0) - 1;
    // Dropped rather than left at zero: this file is meant to be read by a
    // human, and "american: 0" sitting under "british: 4" reads like a
    // half-held opinion instead of an absence of one.
    if (remaining > 0) trait.votes[other] = remaining;
    else delete trait.votes[other];
  }
  trait.votes[key] = Math.min(VOTE_CEILING, (trait.votes[key] ?? 0) + 1);
  trait.lastObserved = at;
}

/// A mean that forgets. Sentence length is a habit, not a constant, and an
/// average taken over every dictation since installation stops responding to
/// the writer some time in month two.
export interface RunningMean {
  total: number;
  count: number;
}

/// Beyond this the window slides instead of growing. Forty samples is enough
/// for the mean to be stable and few enough that a changed habit shows up
/// within a few weeks.
export const SAMPLE_CEILING = 40;
/// Below this the mean is noise, and a prompt rule built on noise is worse than
/// no rule.
export const MINIMUM_SAMPLES = 3;

export function emptyMean(): RunningMean {
  return { total: 0, count: 0 };
}

export function meanAverage(mean: RunningMean): number | null {
  if (mean.count < MINIMUM_SAMPLES) return null;
  return mean.total / mean.count;
}

export function addSample(mean: RunningMean, sample: number): void {
  if (mean.count >= SAMPLE_CEILING && mean.count > 0) {
    mean.total -= mean.total / mean.count;  // drop one sample's worth at the current mean
    mean.count -= 1;
  }
  mean.total += sample;
  mean.count += 1;
}

// MARK: - Phrasing

/// A rewrite the user has made more than once.
export interface StylePhrasing {
  /// What Quill wrote, lowercased — matching is case-insensitive.
  from: string;
  /// What they changed it to, verbatim. Casing is preserved because casing is
  /// often the entire edit.
  to: string;
  count: number;
  lastObserved: Date | null;
}

export function makePhrasing(from: string, to: string, count = 1, lastObserved: Date | null = null): StylePhrasing {
  return { from: from.toLowerCase(), to, count, lastObserved };
}

/// Stable without a UUID: the pair *is* the identity, and generating a new id
/// for a rewrite already in the list is how duplicates appear in a table.
export function phrasingID(phrasing: StylePhrasing): string {
  return `${phrasing.from}→${phrasing.to}`;
}

/// Whether this is allowed to rewrite text on its own.
///
/// Gated hard. Three sightings, and a trigger distinctive enough to be safe:
/// multi-word, or a single word long enough not to be grammar. The rule that is
/// missing here — "and a target that means the same thing" — is not checkable,
/// which is exactly why the count bar is where it is.
export function phrasingIsApplicable(phrasing: StylePhrasing): boolean {
  if (phrasing.count < MINIMUM_PHRASING_COUNT) return false;
  const words = phrasing.from.split(' ').filter((word) => word.length > 0).length;
  return words > 1 || phrasing.from.length >= 6;
}

// MARK: - Profile

export interface StyleProfile {
  preset: StylePreset;
  /// Per-destination overrides, keyed on the executable or window class.
  appTones: Record<string, StylePreset>;
  isLearningEnabled: boolean;
  spelling: StyleTrait;
  contractions: StyleTrait;
  formality: StyleTrait;
  oxfordComma: StyleTrait;
  exclamations: StyleTrait;
  sentenceLength: RunningMean;
  phrasings: StylePhrasing[];
  /// Counts corrections it actually learned something from, not corrections
  /// seen. "Learned from 12 edits" has to mean twelve edits moved a number.
  correctionCount: number;
  modelAccepted: number;
  modelReverted: number;
  lastLearned: Date | null;
}

/// A trait only counts once it clears both bars.
export const MINIMUM_SUPPORT = 2;
export const MINIMUM_CONFIDENCE = 0.6;
export const MINIMUM_PHRASING_COUNT = 3;
export const MAXIMUM_PHRASINGS = 24;

/// Prefill is on the critical path, so this is a budget, not a style guide. The
/// AI bench measured a 190ms p50 difference between two prompt variants that
/// differed only in length. Rules are emitted most-valuable first and the tail
/// is dropped when the budget runs out.
export const MAXIMUM_PROMPT_CHARACTERS = 420;

/// What a profile looks like before anything has been learned.
///
/// Nothing is seeded. It used to arrive pre-loaded with British spelling and
/// contractions at full vote weight — the two things known about the author —
/// which meant the Style screen told every other user that Quill had "learned"
/// two facts about them on the day they installed it. A screen whose only job
/// is to report what it has observed must not open by reporting somebody else's
/// habits as theirs.
export function freshProfile(preset: StylePreset = 'neutral'): StyleProfile {
  return {
    preset,
    appTones: {},
    isLearningEnabled: true,
    spelling: emptyTrait(),
    contractions: emptyTrait(),
    formality: emptyTrait(),
    oxfordComma: emptyTrait(),
    exclamations: emptyTrait(),
    sentenceLength: emptyMean(),
    phrasings: [],
    correctionCount: 0,
    modelAccepted: 0,
    modelReverted: 0,
    lastLearned: null,
  };
}

export function settled(profile: StyleProfile, trait: StyleTrait): string | null {
  if (traitSupport(trait) < MINIMUM_SUPPORT) return null;
  if (traitConfidence(trait) < MINIMUM_CONFIDENCE) return null;
  return traitValue(trait);
}

/// The voice to use for a given destination.
///
/// Explicit override first, then the built-in suggestion, then the base preset.
/// Unknown apps fall through to the base rather than being guessed at — a wrong
/// tone is worse than a generic one.
export function toneFor(profile: StyleProfile, processOrClass: string | null): StylePreset {
  if (!processOrClass) return profile.preset;
  const chosen = profile.appTones[processOrClass];
  if (chosen) return chosen;
  return suggestedPreset(processOrClass) ?? profile.preset;
}

/// The style rules, one per line, ready to append to the cleanup prompt. Empty
/// when there is nothing worth saying — which is a real outcome, and costs
/// nothing.
export function promptRules(profile: StyleProfile, processOrClass: string | null = null): string[] {
  const rules: string[] = [presetPromptLine(toneFor(profile, processOrClass))];

  const spelling = settled(profile, profile.spelling);
  if (spelling === 'british' || spelling === 'american') {
    rules.push(spellingPromptLine(spelling));
  }
  const contractions = settled(profile, profile.contractions);
  if (contractions !== null) {
    rules.push(contractions === 'yes'
      ? 'Use contractions.'
      : 'Do not contract words; write them out in full.');
  }
  // One direction only, and the asymmetry is measured.
  //
  // "Keep sentences short, around 6 words" asks the model to restructure, which
  // is the same shape as the two preset lines that had to be rewritten — and it
  // cost the same way: 19/20 kept all the content against 20/20 without it. One
  // dictation in twenty losing a clause is not a price worth paying for a rule
  // whose result cannot be checked afterwards.
  //
  // "Do not split them up" is the opposite instruction: it forbids
  // restructuring rather than requesting it, so it cannot cause that failure.
  const words = meanAverage(profile.sentenceLength);
  if (words !== null && words > 24) {
    rules.push('Long sentences are fine; do not split them up.');
  }
  const oxford = settled(profile, profile.oxfordComma);
  if (oxford !== null) {
    rules.push(oxford === 'yes'
      ? 'Put a comma before the final "and" in a list.'
      : 'No comma before the final "and" in a list.');
  }
  if (settled(profile, profile.exclamations) === 'no') {
    rules.push('No exclamation marks.');
  }

  // Trim from the bottom: the list is already in value order.
  const out: string[] = [];
  let budget = MAXIMUM_PROMPT_CHARACTERS;
  for (const rule of rules) {
    const cost = rule.length + 3;   // "- " and a newline
    if (cost > budget) break;
    budget -= cost;
    out.push(rule);
  }
  return out;
}

/// The full system prompt for a dictation: the cleanup rules, then the voice.
///
/// Note what is *not* here. Learned phrasings are applied deterministically
/// instead of being described to the model, and there is no list of words to
/// avoid, because both hazards were measured on this exact endpoint: a word
/// list in the prompt gets spent from, and a negative list was the worst
/// variant tested, dropping spoken self-correction from 20/20 to 0/20.
export function styleSystemPrompt(
  profile: StyleProfile,
  base: string = CLEANUP_SYSTEM_PROMPT,
  processOrClass: string | null = null,
): string {
  const rules = promptRules(profile, processOrClass);
  if (rules.length === 0) return base;
  return `${base}\nStyle:\n${rules.map((rule) => `- ${rule}`).join('\n')}`;
}

/// Literal, word-boundary substitutions for phrasings that have stuck.
export function applyPhrasings(profile: StyleProfile, text: string): string {
  let out = text;
  for (const phrasing of profile.phrasings) {
    if (!phrasingIsApplicable(phrasing)) continue;
    out = out.replace(
      new RegExp(`\\b${escapeRegExp(phrasing.from)}\\b`, 'giu'),
      // The replacement is escaped as a TEMPLATE, not as a pattern: a phrasing
      // taught by dictating a price — "$100" — would otherwise be read as
      // capture group 1 and vanish. They are different escapings and using one
      // for both is silent corruption.
      escapeReplacement(phrasing.to),
    );
  }
  return out;
}

/// The part of the profile that needs no network and no model.
///
/// People dictate on trains, so a style feature that only works online is a
/// style feature that does not work. Two things survive offline because both
/// are exact string operations rather than judgement calls: learned phrasings,
/// and spelling convention. Sentence length, formality and tone cannot be done
/// this way — enforcing them means paraphrasing, and a rule that paraphrases is
/// a rule that changes meaning.
export function applyDeterministically(profile: StyleProfile, text: string): string {
  let out = applyPhrasings(profile, text);
  if (settled(profile, profile.spelling) === 'british') out = toBritish(out);
  return out;
}

export function recordModelOutcome(profile: StyleProfile, accepted: boolean): void {
  if (accepted) profile.modelAccepted += 1;
  else profile.modelReverted += 1;
}

/// False when the user keeps undoing the model's rewrites. At that point the
/// model pass is costing a deadline per dictation to produce text that gets
/// thrown away. Requires a real sample first — two reverts on a Tuesday is not
/// a verdict.
export function trustsModel(profile: StyleProfile): boolean {
  const total = profile.modelAccepted + profile.modelReverted;
  if (total < 5) return true;
  return profile.modelReverted / total <= 0.5;
}

/// One line for the dashboard. Says what has been learned, or says plainly that
/// nothing has — never implies a personalisation that is not there.
export function styleSummaryLine(profile: StyleProfile): string {
  const parts: string[] = [presetTitle(profile.preset)];
  const spelling = settled(profile, profile.spelling);
  if (spelling === 'british' || spelling === 'american') parts.push(spellingShortName(spelling));
  const contractions = settled(profile, profile.contractions);
  if (contractions !== null) parts.push(contractions === 'yes' ? 'contractions' : 'no contractions');
  const words = meanAverage(profile.sentenceLength);
  if (words !== null) parts.push(`~${Math.round(words)} words/sentence`);
  const applicable = profile.phrasings.filter(phrasingIsApplicable).length;
  if (applicable > 0) parts.push(`${applicable} phrasing${applicable === 1 ? '' : 's'}`);
  const learned = parts.length > 1 ? parts.join(' · ') : `${parts[0]} · nothing learned yet`;
  if (profile.correctionCount === 0) return learned;
  return `${learned} · from ${profile.correctionCount} correction${profile.correctionCount === 1 ? '' : 's'}`;
}

// MARK: - Output guard

/// Phrases that mark text as written by an assistant rather than a person.
///
/// Short and boring on purpose. Each one is judged only when it appears in the
/// *output* and not in the input — a cleanup pass has no business introducing
/// any of them, and if the user actually said "delve" the check never fires.
/// That asymmetry is what keeps a list this blunt safe.
export const STYLE_TELLS = [
  'i hope this finds you well',
  'i hope this email finds you',
  'delve',
  'tapestry',
  "in today's fast-paced",
  "it's important to note",
  'it is important to note',
  'as an ai',
  'unlock the power',
  'elevate your',
  'rest assured',
  'we are excited to',
  "we're excited to",
  'cutting-edge',
  'game-changer',
  'seamlessly',
  // Added after a live run: asked to make "The site is live. Invoice attached,
  // due in 7 days." sound warm, the model produced "Hello and welcome to our
  // August newsletter! We're thrilled to…". The length ceiling caught that one,
  // but the tells should catch it first — a rewrite that stays the same length
  // would otherwise walk straight through.
  'thrilled',
  'delighted to',
  'welcome to our',
  'look no further',
];

/// Tells present in the output that were not in the input.
export function introducedTells(input: string, output: string): string[] {
  const inLower = input.toLowerCase();
  const outLower = output.toLowerCase();
  return STYLE_TELLS.filter((tell) => outLower.includes(tell) && !inLower.includes(tell));
}

/// The whole guard for the dictation path: length and vocabulary from
/// `AIOutputGuard`, then tone, then the profile's own deterministic pass.
///
/// Returns null when the model output cannot be trusted — which means "insert
/// the fast pass", not "show an error".
///
/// Order matters and is deliberate: the profile's own rewrites run *after* the
/// vocabulary check, not before. If a learned phrasing happens to remove one of
/// the user's vocabulary terms, that is them overruling themselves three times
/// over, which beats a rule written to protect them from a model.
export function styleSanitise(
  raw: string,
  input: string,
  profile: StyleProfile,
  vocabulary: string[] = [],
): string | null {
  const cleaned = AIOutputGuard.sanitise(raw, input, vocabulary);
  if (cleaned === null) return null;
  if (introducedTells(input, cleaned).length > 0) return null;
  return applyDeterministically(profile, cleaned);
}

// MARK: - Store

function decodeTrait(value: unknown): StyleTrait {
  const trait = emptyTrait();
  if (!value || typeof value !== 'object') return trait;
  const raw = value as { votes?: unknown; lastObserved?: unknown };
  if (raw.votes && typeof raw.votes === 'object') {
    for (const [key, count] of Object.entries(raw.votes as Record<string, unknown>)) {
      if (typeof count === 'number' && count > 0) trait.votes[key] = count;
    }
  }
  trait.lastObserved = fromISO(raw.lastObserved);
  return trait;
}

/// Hand-written and every field optional on the way in. A stricter decoder
/// throws on a missing key, and the store turns a throw into a fresh profile —
/// so adding one field in a later version would silently delete everything the
/// user had taught it. Learned state is not something you get to lose during a
/// refactor.
function decodeProfile(value: unknown): StyleProfile | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  const profile = freshProfile();
  if (STYLE_PRESETS.includes(raw.preset as StylePreset)) profile.preset = raw.preset as StylePreset;
  if (raw.appTones && typeof raw.appTones === 'object') {
    for (const [key, tone] of Object.entries(raw.appTones as Record<string, unknown>)) {
      if (STYLE_PRESETS.includes(tone as StylePreset)) profile.appTones[key] = tone as StylePreset;
    }
  }
  profile.isLearningEnabled = raw.isLearningEnabled !== false;
  profile.spelling = decodeTrait(raw.spelling);
  profile.contractions = decodeTrait(raw.contractions);
  profile.formality = decodeTrait(raw.formality);
  profile.oxfordComma = decodeTrait(raw.oxfordComma);
  profile.exclamations = decodeTrait(raw.exclamations);
  const mean = raw.sentenceLength as { total?: unknown; count?: unknown } | undefined;
  if (mean && typeof mean.total === 'number' && typeof mean.count === 'number') {
    profile.sentenceLength = { total: mean.total, count: mean.count };
  }
  if (Array.isArray(raw.phrasings)) {
    for (const entry of raw.phrasings as Record<string, unknown>[]) {
      if (typeof entry?.from !== 'string' || typeof entry?.to !== 'string') continue;
      profile.phrasings.push({
        from: entry.from,
        to: entry.to,
        count: typeof entry.count === 'number' ? entry.count : 1,
        lastObserved: fromISO(entry.lastObserved),
      });
    }
  }
  if (typeof raw.correctionCount === 'number') profile.correctionCount = raw.correctionCount;
  if (typeof raw.modelAccepted === 'number') profile.modelAccepted = raw.modelAccepted;
  if (typeof raw.modelReverted === 'number') profile.modelReverted = raw.modelReverted;
  profile.lastLearned = fromISO(raw.lastLearned);
  return profile;
}

function encodeProfile(profile: StyleProfile): unknown {
  const trait = (value: StyleTrait): unknown => ({
    votes: value.votes,
    lastObserved: toISO(value.lastObserved),
  });
  return {
    preset: profile.preset,
    appTones: profile.appTones,
    isLearningEnabled: profile.isLearningEnabled,
    spelling: trait(profile.spelling),
    contractions: trait(profile.contractions),
    formality: trait(profile.formality),
    oxfordComma: trait(profile.oxfordComma),
    exclamations: trait(profile.exclamations),
    sentenceLength: profile.sentenceLength,
    phrasings: profile.phrasings.map((phrasing) => ({
      from: phrasing.from,
      to: phrasing.to,
      count: phrasing.count,
      lastObserved: toISO(phrasing.lastObserved),
    })),
    correctionCount: profile.correctionCount,
    modelAccepted: profile.modelAccepted,
    modelReverted: profile.modelReverted,
    lastLearned: toISO(profile.lastLearned),
  };
}

/// The profile on disk.
///
/// Three states, not two. The fifth store to face the same question: "no file
/// yet" and "a file I could not read" call for opposite behaviour. Here the
/// fallback is a fresh profile, so damage would look like a factory reset
/// rather than a deletion — and the next preset change would write it over the
/// top.
export class StyleStore {
  private readonly url: string | null;
  private current: StyleProfile;
  private loadFailed = false;

  private static sharedStore: StyleStore | null = null;
  static shared(): StyleStore {
    if (!StyleStore.sharedStore) StyleStore.sharedStore = new StyleStore();
    return StyleStore.sharedStore;
  }

  static inMemory(profile: StyleProfile): StyleStore {
    const store = new StyleStore(null);
    store.current = profile;
    return store;
  }

  constructor(url: string | null = dataFile('style.json')) {
    this.url = url;
    this.current = freshProfile();
    if (!url) return;
    const outcome = readStoreFile(url, decodeProfile);
    switch (outcome.kind) {
      case 'missing': this.current = freshProfile(); break;
      case 'decoded': this.current = outcome.value; break;
      case 'unreadable':
        this.current = freshProfile();
        this.loadFailed = true;
        break;
    }
  }

  get profile(): StyleProfile {
    return structuredClone(this.current);
  }

  update(transform: (profile: StyleProfile) => void): void {
    transform(this.current);
    this.persist();
  }

  private persist(): void {
    if (this.loadFailed || !this.url) return;
    writeAtomic(this.url, encodeJSON(encodeProfile(this.current)));
  }
}
