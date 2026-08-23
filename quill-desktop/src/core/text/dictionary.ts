import { gunzipSync } from 'node:zlib';
import { readFileSync } from 'node:fs';
import { isLetter, trimPunctuation } from './strings';
import { resourcesPath } from '../paths';

// "Is this an ordinary English word?", cross-platform.
//
// # Why this is not the operating system's spell checker
//
// The macOS build asked `NSSpellChecker`, once per English variant, over an
// XPC connection. There is no equivalent present on all three platforms:
// Windows exposes spell-check only through the Windows Runtime and only for
// installed languages, and on Linux there is nothing at all unless hunspell
// happens to be installed with an en_* dictionary — which on a fresh install it
// is not.
//
// Falling back to "assume every word is real" is not an option, because this
// answer is load-bearing for safety in two places:
//
//   * `VocabularyCorrector` presumes a correctly spelled English word is
//     intentional and refuses to touch it. Too permissive means fewer repairs
//     (a miss); too strict means it starts rewriting words the user meant
//     (damage).
//   * `allowsPhoneticMatch` requires a NON-word in the span before sound is
//     allowed to decide anything. That restriction is the only thing separating
//     signal from noise — see the measurement in `vocabularyCorrector.ts`.
//
// So the list ships with the app. That is a change in behaviour and worth being
// explicit about: the answer is now IDENTICAL on Windows, Linux and macOS,
// where before it varied with the machine's installed dictionaries. For an app
// whose corrections are tuned against a measured corpus, deterministic is the
// better property — the macOS build shipped a bug where asking "en" alone (US
// English) reported "colour", "realise" and "metre" as non-words on an
// Australian user's machine, and turned the guard inside out.
//
// # Why it is not a Set
//
// The built list is 1.2 million entries. A JavaScript `Set<string>` of that
// size costs somewhere north of 90 MB of heap — on a menu-bar app that is
// meant to sit there all day, for a lookup table. Instead the decompressed
// list is kept as ONE sorted string plus an `Int32Array` of line offsets, and
// looked up by binary search: about 18 MB, and around twenty comparisons per
// word. The comparisons are memoised a layer up (see `MatchMemo`), so the same
// word inside a growing transcript is only ever looked up once.

interface Wordlist {
  /** The whole list, sorted, newline separated. */
  readonly text: string;
  /** Start offset of each line. */
  readonly starts: Int32Array;
}

let list: Wordlist | null = null;
let loadAttempted = false;
let overrideWords: Set<string> | null = null;

/** Points the dictionary at a fixed set. For tests, and for the eval rig. */
export function useDictionary(set: Set<string> | null): void {
  overrideWords = set;
}

function load(): Wordlist | null {
  if (list || loadAttempted) return list;
  loadAttempted = true;
  try {
    const raw = gunzipSync(readFileSync(resolveWordlistPath())).toString('utf8');
    const starts: number[] = [];
    let index = 0;
    while (index < raw.length) {
      starts.push(index);
      const next = raw.indexOf('\n', index);
      if (next < 0) break;
      index = next + 1;
    }
    list = { text: raw, starts: Int32Array.from(starts) };
  } catch (error) {
    // A missing list must not crash a dictation. It degrades to "nothing is a
    // word", which makes the corrector MORE willing to act — so it is announced
    // loudly rather than swallowed, and `dictionaryIsLoaded` says so on the
    // Help screen.
    // eslint-disable-next-line no-console
    console.error('[quill] word list could not be read; vocabulary guards are degraded', error);
    list = null;
  }
  return list;
}

/** Where the list lives, in a build and in a package. */
function resolveWordlistPath(): string {
  const candidates = [
    resourcesPath() ? `${resourcesPath()}/data/words.txt.gz` : '',
    `${__dirname}/../data/words.txt.gz`,
    `${__dirname}/../../data/words.txt.gz`,
    `${__dirname}/../../../src/data/words.txt.gz`,
    `${process.cwd()}/src/data/words.txt.gz`,
    `${process.cwd()}/dist/data/words.txt.gz`,
  ].filter((path) => path.length > 0);
  for (const path of candidates) {
    try {
      readFileSync(path);
      return path;
    } catch {
      continue;
    }
  }
  throw new Error(`no word list found; looked in ${candidates.join(', ')}`);
}

function contains(word: string): boolean {
  if (overrideWords) return overrideWords.has(word);
  const loaded = load();
  if (!loaded) return false;
  const { text, starts } = loaded;
  let low = 0;
  let high = starts.length - 1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    const start = starts[middle]!;
    const end = middle + 1 < starts.length ? starts[middle + 1]! - 1 : text.length;
    const candidate = text.slice(start, end);
    if (candidate === word) return true;
    if (candidate < word) low = middle + 1;
    else high = middle - 1;
  }
  return false;
}

/** Whether the list actually loaded. Shown on the Help screen, because a
 *  degraded guard is not something a user should have to infer from behaviour. */
export function dictionaryIsLoaded(): boolean {
  if (overrideWords) return overrideWords.size > 0;
  return (load()?.starts.length ?? 0) > 1000;
}

export function dictionarySize(): number {
  if (overrideWords) return overrideWords.size;
  return load()?.starts.length ?? 0;
}

/// A word in ANY English this user might write, not just American.
///
/// The Australian-spelling bug the macOS build shipped is designed out rather
/// than patched: the list carries -our, -ise, -re and -ce spellings alongside
/// the American ones, so there is no "preferred variant" left to get wrong.
export function isRealEnglishWord(word: string): boolean {
  const trimmed = trimPunctuation(word);
  if (trimmed.length === 0) return false;
  const lower = trimmed.toLowerCase();
  if (contains(lower)) return true;
  // A possessive is the word plus an apostrophe. "Roman's" being absent is not
  // evidence that "Roman" is unknown.
  if (lower.endsWith("'s") || lower.endsWith('’s')) {
    return contains(lower.slice(0, -2));
  }
  // A hyphenated compound is real when both halves are. "well-known" is in no
  // list and is not a mishearing either.
  if (lower.includes('-')) {
    const parts = lower.split('-').filter((piece) => piece.length > 0);
    if (parts.length > 1 && parts.every((piece) => piece.length >= 2 && contains(piece))) return true;
  }
  // A single letter is a letter, not a misheard name — "a", "I", and the ones
  // people spell out. Anything of length one has nothing to correct to anyway.
  if (lower.length === 1 && isLetter(lower)) return true;
  return false;
}
