import type { DictationRecord } from '../stores/history';
import { contextualStrings, loadVocabulary, type Vocabulary } from '../stores/vocabulary';
import { alphanumericKey } from '../text/strings';

// Everything the Insights screen shows, derived from `DictationRecord`s and
// nothing else.
//
// The rule this file exists to enforce: no number on that screen may be an
// estimate, a constant, or a percentile against a population we cannot see.
// Other dictation apps lead with "Top 6%" — a ranking against users we are not
// allowed to inspect, next to a words-per-minute figure it does not explain.
// Every field below is computable from this machine's own history, and anything
// that needs an assumption (typing speed) states the assumption on screen.

export type InsightsRange = 'week' | 'month' | 'all';

export const INSIGHTS_RANGES: InsightsRange[] = ['week', 'month', 'all'];

export function rangeTitle(range: InsightsRange): string {
  switch (range) {
    case 'week': return '7 days';
    case 'month': return '30 days';
    case 'all': return 'All time';
  }
}

export function rangeDays(range: InsightsRange): number | null {
  switch (range) {
    case 'week': return 7;
    case 'month': return 30;
    case 'all': return null;
  }
}

export function rangePhrase(range: InsightsRange): string {
  switch (range) {
    case 'week': return 'in the last 7 days';
    case 'month': return 'in the last 30 days';
    case 'all': return 'since Quill was installed';
  }
}

export function rangeComparisonPhrase(range: InsightsRange): string {
  switch (range) {
    case 'week': return 'vs the 7 days before';
    case 'month': return 'vs the 30 days before';
    case 'all': return 'vs the first half';
  }
}

/// One recogniser mistake Quill repaired, kept with the word it produced so the
/// screen can name it. "16 dictionary fixes" is a number; "neglify → Netlify,
/// seven times" is a reason to keep the dictionary.
export interface Fix {
  heard: string;
  written: string;
  count: number;
  isDictionary: boolean;
}

export interface InsightsDay {
  /// Start of that calendar day, as epoch milliseconds — a plain number so the
  /// whole metrics object survives the IPC hop to the renderer unchanged.
  date: number;
  words: number;
  sessions: number;
}

export interface InsightsMetrics {
  range: InsightsRange;
  generatedAt: number;

  // Volume
  sessions: number;
  totalWords: number;
  previousWords: number;
  /// Fraction, e.g. 0.18 for +18%. Null when there is no prior window to
  /// compare against — a delta against zero history is theatre.
  wordsDelta: number | null;
  dailyWords: InsightsDay[];

  // Pace, measured against the audio we actually recorded.
  medianWPM: number;
  wpmP10: number;
  wpmP90: number;
  speakingSeconds: number;
  typingSeconds: number;
  savedSeconds: number;

  // Latency — the measurement nobody else exposes.
  firstWordMs: number[];
  endToEndMs: number[];
  /// Key release → text on screen. The number a person actually waits through.
  /// Empty for history written before the release moment was stamped, which is
  /// deliberate: those records genuinely do not contain it, and filling the gap
  /// with end-to-end would report a figure that includes however long the
  /// person was speaking.
  releaseMs: number[];
  firstWordP50: number;
  endToEndP50: number;
  endToEndP90: number;
  endToEndP99: number;
  releaseP50: number;
  releaseP90: number;
  releaseP99: number;
  thoroughShare: number;
  hasReleaseLatency: boolean;

  // Corrections
  wordsCorrected: number;
  dictionaryFixes: number;
  totalFixes: number;
  topFixes: Fix[];

  // Consistency
  heat: InsightsDay[];
  currentStreak: number;
  longestStreak: number;
  busiestDay: InsightsDay | null;
  activeDays: number;
  /// Days the user has actually had Quill, not days the heatmap happens to
  /// draw. The denominator used to be the whole heatmap window — ten months of
  /// squares — so a new install read "3 days you dictated on, out of 308",
  /// counting 305 days before the app existed as days they failed to use it.
  observedDays: number;
  /// The date of the earliest dictation, for the card's "since" line.
  firstRecord: number | null;
}

/// The one stated assumption on the screen, held here so the caption and the
/// arithmetic can never drift apart.
export const TYPING_WPM = 40;

/// How far back the heatmap reaches. Ten months is the widest window that still
/// leaves a cell you can aim a cursor at inside the panel.
export const HEAT_WEEKS = 44;

/// Linear-interpolated percentile on a sorted array. Nearest-rank jumps in
/// visible steps on small samples, which makes a median look like it is
/// snapping to individual dictations.
export function percentile(sorted: number[], q: number): number {
  if (sorted.length === 0) return 0;
  if (sorted.length === 1) return sorted[0]!;
  const position = q * (sorted.length - 1);
  const lower = Math.floor(position);
  const upper = Math.min(lower + 1, sorted.length - 1);
  const t = position - lower;
  return sorted[lower]! + (sorted[upper]! - sorted[lower]!) * t;
}

function startOfDay(date: Date): Date {
  const out = new Date(date.getTime());
  out.setHours(0, 0, 0, 0);
  return out;
}

function addDays(date: Date, days: number): Date {
  const out = new Date(date.getTime());
  out.setDate(out.getDate() + days);
  return out;
}

function daysBetween(a: Date, b: Date): number {
  return Math.round((startOfDay(b).getTime() - startOfDay(a).getTime()) / 86_400_000);
}

/// The heatmap runs to the end of the current week so the grid is square.
/// Weeks start on Sunday, matching the calendar the macOS build used.
function endOfWeek(date: Date): Date {
  const start = startOfDay(date);
  return addDays(start, 6 - start.getDay());
}

/// One entry per calendar day, zeroes included. A sparkline that skips empty
/// days draws a flat line through a week off.
function densify(records: DictationRecord[], days: number, endingAt: Date): InsightsDay[] {
  const lastDay = startOfDay(endingAt);
  const words = new Map<number, number>();
  const counts = new Map<number, number>();
  for (const record of records) {
    const day = startOfDay(record.date).getTime();
    words.set(day, (words.get(day) ?? 0) + record.wordCount);
    counts.set(day, (counts.get(day) ?? 0) + 1);
  }
  const out: InsightsDay[] = [];
  for (let offset = days - 1; offset >= 0; offset -= 1) {
    const day = addDays(lastDay, -offset).getTime();
    out.push({ date: day, words: words.get(day) ?? 0, sessions: counts.get(day) ?? 0 });
  }
  return out;
}

/// Current streak counts back from today, and tolerates a today that has not
/// happened yet — at 9am a run of thirty days should not read as zero because
/// you have not dictated since breakfast.
function streakLengths(days: InsightsDay[], now: Date): { current: number; longest: number } {
  let longest = 0;
  let run = 0;
  for (const day of days) {
    run = day.sessions > 0 ? run + 1 : 0;
    longest = Math.max(longest, run);
  }

  const index = new Map(days.map((day) => [day.date, day.sessions]));
  const today = startOfDay(now);
  let cursor = today;
  if ((index.get(today.getTime()) ?? 0) === 0) cursor = addDays(today, -1);
  let current = 0;
  while ((index.get(cursor.getTime()) ?? 0) > 0) {
    current += 1;
    cursor = addDays(cursor, -1);
  }
  return { current, longest };
}

export function computeInsights(
  records: DictationRecord[],
  options: { vocabulary?: Vocabulary; range?: InsightsRange; now?: Date } = {},
): InsightsMetrics {
  const vocabulary = options.vocabulary ?? loadVocabulary();
  const range = options.range ?? 'month';
  const now = options.now ?? new Date();

  const days = rangeDays(range);
  const windowStart = days === null ? null : addDays(now, -days);
  const inRange = records.filter((record) => (windowStart === null
    ? record.date <= now
    : record.date > windowStart && record.date <= now));

  // The prior window of equal length. For "all time" that is the older half of
  // the history, which is the only honest analogue.
  let previous: DictationRecord[] = [];
  if (days !== null) {
    const priorStart = addDays(now, -days * 2);
    const priorEnd = addDays(now, -days);
    previous = records.filter((record) => record.date > priorStart && record.date <= priorEnd);
  } else if (records.length > 0) {
    const oldest = new Date(Math.min(...records.map((record) => record.date.getTime())));
    const midpoint = new Date(oldest.getTime() + (now.getTime() - oldest.getTime()) / 2);
    previous = records.filter((record) => record.date <= midpoint);
  }

  const totalWords = inRange.reduce((total, record) => total + record.wordCount, 0);
  const previousWords = previous.reduce((total, record) => total + record.wordCount, 0);
  const wordsDelta = previousWords > 0 ? (totalWords - previousWords) / previousWords : null;

  // Pace. Records with no audio duration cannot contribute a rate, and a
  // sub-second clip divides into nonsense — both are dropped rather than
  // clamped, because a clamped outlier still moves the median.
  const rates = inRange
    .filter((record) => (record.timings.audioDurationMs ?? 0) > 900 && record.wordCount > 2)
    .map((record) => record.wordCount / (record.timings.audioDurationMs! / 60_000))
    .sort((a, b) => a - b);
  const speakingSeconds = inRange.reduce(
    (total, record) => total + (record.timings.audioDurationMs ?? 0) / 1000,
    0,
  );

  const numbers = (pick: (record: DictationRecord) => number | null): number[] => inRange
    .map(pick)
    .filter((value): value is number => value !== null)
    .sort((a, b) => a - b);

  const firstWordMs = numbers((record) => record.timings.timeToFirstWordMs);
  const endToEndMs = numbers((record) => record.timings.endToEndMs);
  const releaseMs = numbers((record) => record.timings.releaseToInsertedMs);
  const thorough = inRange.filter((record) => record.timings.usedThoroughCleanup).length;
  const thoroughShare = inRange.length === 0 ? 0 : thorough / inRange.length;

  const corrections = tallyCorrections(inRange, vocabulary);

  const oldestDate = records.length > 0
    ? new Date(Math.min(...records.map((record) => record.date.getTime())))
    : now;
  const dailyWindow = days ?? Math.max(1, daysBetween(oldestDate, now));
  const dailyWords = densify(inRange, Math.min(dailyWindow, 120), now);

  // Heatmap window is deliberately independent of the range control: a streak
  // is a property of the whole history, not of the last 7 days.
  const heat = densify(records, HEAT_WEEKS * 7, endOfWeek(now));
  const streaks = streakLengths(heat, now);

  // Only the days since the first dictation count against the user. Bounded at
  // both ends: the heatmap runs to the end of the current week, which meant the
  // denominator also swept up days that have not happened yet.
  const firstRecord = records.length > 0 ? oldestDate : null;
  let observedDays = 0;
  if (firstRecord) {
    const from = startOfDay(firstRecord).getTime();
    const today = startOfDay(now).getTime();
    observedDays = Math.max(1, heat.filter((day) => day.date >= from && day.date <= today).length);
  }

  const busiest = heat.reduce<InsightsDay | null>(
    (best, day) => (best === null || day.words > best.words ? day : best),
    null,
  );

  const typingSeconds = (totalWords / TYPING_WPM) * 60;

  return {
    range,
    generatedAt: now.getTime(),
    sessions: inRange.length,
    totalWords,
    previousWords,
    wordsDelta,
    dailyWords,
    medianWPM: Math.round(percentile(rates, 0.5)),
    wpmP10: Math.round(percentile(rates, 0.1)),
    wpmP90: Math.round(percentile(rates, 0.9)),
    speakingSeconds,
    typingSeconds,
    savedSeconds: Math.max(0, typingSeconds - speakingSeconds),
    firstWordMs,
    endToEndMs,
    releaseMs,
    firstWordP50: percentile(firstWordMs, 0.5),
    endToEndP50: percentile(endToEndMs, 0.5),
    endToEndP90: percentile(endToEndMs, 0.9),
    endToEndP99: percentile(endToEndMs, 0.99),
    releaseP50: percentile(releaseMs, 0.5),
    releaseP90: percentile(releaseMs, 0.9),
    releaseP99: percentile(releaseMs, 0.99),
    thoroughShare,
    hasReleaseLatency: releaseMs.length > 0,
    wordsCorrected: corrections.words,
    dictionaryFixes: corrections.dictionary,
    totalFixes: corrections.words + corrections.dictionary,
    topFixes: corrections.top,
    heat,
    currentStreak: streaks.current,
    longestStreak: streaks.longest,
    busiestDay: busiest && busiest.words > 0 ? busiest : null,
    activeDays: heat.filter((day) => day.sessions > 0).length,
    observedDays,
    firstRecord: firstRecord ? firstRecord.getTime() : null,
  };
}

// MARK: - Corrections

/// What the cleanup pass changed, recovered by aligning the raw transcript
/// against what was inserted.
///
/// Storing raw and inserted separately is what makes this possible at all — the
/// same split the comparison rig needs to score accuracy and formatting apart.
/// A single "text" column would leave this screen with nothing to show but a
/// word count.

/// Multi-word entries have to match a single token too — the recogniser hears
/// "no acuss", cleanup writes "Noah Kass", and the fix that matters is the
/// surname. The stoplist keeps ordinary English inside those phrases ("next",
/// "co") from claiming credit for a fix it had nothing to do with.
const PHRASE_STOPLIST = new Set(['next', 'co', 'the', 'and', 'of', 'a']);

export function vocabularyTokens(vocabulary: Vocabulary): Set<string> {
  const terms = new Set<string>();
  for (const phrase of contextualStrings(vocabulary)) {
    const lower = phrase.toLowerCase();
    terms.add(lower);
    for (const word of lower.split(' ')) {
      if (word.length > 0 && !PHRASE_STOPLIST.has(word)) terms.add(word);
    }
  }
  return terms;
}

/// Case and punctuation are stripped for *matching* only. Quill adds a full
/// stop to almost every dictation; counting that as a correction would put the
/// fix count within a rounding error of the sentence count and mean nothing.
export function normaliseFixToken(token: string): string {
  return alphanumericKey(token);
}

/// Tokens with no letters or digits in them are dropped outright. Quill's
/// cleanup adds an em dash to roughly every second dictation, and counting a
/// dash as a corrected word would put the fix total within a rounding error of
/// the sentence count.
export function tokenizeForFixes(text: string): string[] {
  return text.split(/[ \n\t]+/u).filter((token) => normaliseFixToken(token).length > 0);
}

export type Change =
  | { kind: 'substitute'; from: string; to: string }
  | { kind: 'insert'; word: string }
  | { kind: 'delete'; word: string };

/// Classic LCS alignment. Runs of unmatched tokens on both sides are paired off
/// as substitutions; the remainder are insertions or deletions.
export function alignForFixes(before: string[], after: string[]): Change[] {
  const a = before.map(normaliseFixToken);
  const b = after.map(normaliseFixToken);
  const n = a.length;
  const m = b.length;

  const table: number[][] = [];
  for (let i = 0; i <= n; i += 1) table.push(new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      table[i]![j] = a[i] === b[j]
        ? table[i + 1]![j + 1]! + 1
        : Math.max(table[i + 1]![j]!, table[i]![j + 1]!);
    }
  }

  const changes: Change[] = [];
  let removed: string[] = [];
  let added: string[] = [];
  const flush = (): void => {
    const shared = Math.min(removed.length, added.length);
    for (let k = 0; k < shared; k += 1) {
      changes.push({ kind: 'substitute', from: removed[k]!, to: added[k]! });
    }
    for (let k = shared; k < removed.length; k += 1) changes.push({ kind: 'delete', word: removed[k]! });
    for (let k = shared; k < added.length; k += 1) changes.push({ kind: 'insert', word: added[k]! });
    removed = [];
    added = [];
  };

  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      flush();
      i += 1;
      j += 1;
    } else if (table[i + 1]![j]! >= table[i]![j + 1]!) {
      removed.push(before[i]!);
      i += 1;
    } else {
      added.push(after[j]!);
      j += 1;
    }
  }
  while (i < n) { removed.push(before[i]!); i += 1; }
  while (j < m) { added.push(after[j]!); j += 1; }
  flush();
  return changes;
}

export function tallyCorrections(
  records: DictationRecord[],
  vocabulary: Vocabulary,
): { words: number; dictionary: number; top: Fix[] } {
  const terms = vocabularyTokens(vocabulary);
  let words = 0;
  let dictionary = 0;
  const pairs = new Map<string, { heard: string; written: string; count: number; isDictionary: boolean }>();

  for (const record of records) {
    const before = tokenizeForFixes(record.rawText);
    const after = tokenizeForFixes(record.insertedText);
    if (before.length === 0 || after.length === 0) continue;

    for (const change of alignForFixes(before, after)) {
      if (change.kind === 'substitute') {
        const isDictionary = terms.has(normaliseFixToken(change.to));
        if (isDictionary) dictionary += 1;
        else words += 1;
        const key = `${normaliseFixToken(change.from)}→${normaliseFixToken(change.to)}`;
        const existing = pairs.get(key);
        pairs.set(key, {
          heard: change.from,
          written: change.to,
          count: (existing?.count ?? 0) + 1,
          isDictionary,
        });
      } else {
        words += 1;
      }
    }
  }

  const top = [...pairs.values()]
    .sort((a, b) => (a.count === b.count ? b.written.localeCompare(a.written) : b.count - a.count))
    .slice(0, 8)
    .map((entry) => ({
      heard: entry.heard,
      written: entry.written,
      count: entry.count,
      isDictionary: entry.isDictionary,
    }));

  return { words, dictionary, top };
}

export { InsightsFormat } from './insightsFormat';
