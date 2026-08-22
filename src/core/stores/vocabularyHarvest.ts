import { openSync, readSync, closeSync, readdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { isRealEnglishWord } from '../text/dictionary';
import { contextualStrings, loadVocabulary, type Vocabulary } from './vocabulary';

/// Finds the proper nouns you actually use, by looking at your own machine.
///
/// The dictionary is the single highest-leverage thing in this app and the one
/// nobody maintains. Measured on a real voice: "Netlify" came back as
/// "Netterfly", "graphify" as "grapify", "Firestore" as "fire pay will fi" —
/// and every one of those was already in the seed list, which is the only
/// reason any of them were repaired. The words that are *not* in the list fail
/// silently and forever, and asking someone to sit down and type out their own
/// vocabulary is a task that never gets done.
///
/// So it reads the names off the machine instead. Folder names under the
/// projects directory, git remote names, the `name` field of package manifests:
/// these are exactly the words a developer says out loud all day and exactly
/// the ones a general speech model has never seen.
///
/// **It reads names, never contents.** Directory entries, a remote URL, and one
/// field from a manifest. It does not open source files, does not read
/// documents, and never leaves the machine — the whole point of an on-device
/// app is that this kind of thing is safe to do, and it is only safe if the
/// boundary is drawn tightly and kept there.
///
/// Suggestions are proposed, never auto-applied. A dictionary that adds words
/// by itself is one that starts rewriting your speech into terms you did not
/// choose.

export interface HarvestSuggestion {
  term: string;
  /// Where it was found, in the user's terms — shown so a suggestion can be
  /// judged rather than merely accepted.
  source: string;
}

/// Roots worth looking in, in order. Only directories that already exist are
/// visited; nothing is created and nothing is walked recursively beyond one
/// level.
///
/// The Windows entries are the ones its own tools create — Visual Studio makes
/// `source\repos`, and `git clone` in PowerShell lands wherever the user is,
/// which is usually the profile root or Documents.
export function defaultHarvestRoots(): string[] {
  const home = homedir();
  const common = [
    join(home, 'Documents', 'Work', 'Projects'),
    join(home, 'Projects'),
    join(home, 'Developer'),
    join(home, 'dev'),
    join(home, 'src'),
    join(home, 'code'),
    join(home, 'git'),
    join(home, 'repos'),
  ];
  if (process.platform === 'win32') {
    return [
      join(home, 'source', 'repos'),
      join(home, 'Documents', 'GitHub'),
      ...common,
    ];
  }
  return common;
}

/// Directory names that are structure rather than product.
export const BORING_NAMES = new Set([
  'src', 'lib', 'bin', 'dist', 'build', 'out', 'tmp', 'temp', 'test', 'tests',
  'node modules', 'nodemodules', 'public', 'assets', 'docs', 'doc', 'scripts',
  'backup', 'backups', 'old', 'new', 'archive', 'archives', 'untitled',
  'desktop', 'downloads', 'documents', 'projects', 'work', 'code', 'dev',
  'website', 'websites', 'app', 'apps', 'site', 'sites', 'project', 'misc',
]);

/// Deliberately small and deliberately not the bundled dictionary.
///
/// The dictionary would call "blockcraft" a non-word and also call "quill" a
/// word, which is the wrong way round for this job. What is wanted here is only
/// "is this so ordinary that the recogniser certainly knows it", and a short
/// list answers that.
export const COMMON_NAMES = new Set([
  'my', 'the', 'and', 'for', 'with', 'from', 'this', 'that', 'your', 'our',
  'home', 'page', 'pages', 'landing', 'portfolio', 'resume', 'blog', 'shop',
  'store', 'client', 'clients', 'final', 'copy', 'version', 'draft', 'demo',
  'sample', 'example', 'template', 'starter', 'boilerplate', 'playground',
  'sandbox', 'practice', 'learning', 'tutorial', 'course', 'school', 'notes',
  'site', 'work', 'works', 'web', 'website', 'app', 'apps', 'test',
  'old', 'new', 'main', 'dev', 'prod', 'live', 'temp', 'backup', 'personal',
]);

export function isCommonName(word: string): boolean {
  return word.length <= 2 || COMMON_NAMES.has(word);
}

/// Turns a folder or package name into a term, or rejects it.
///
/// The filter matters more than the finding. A dictionary stuffed with "src",
/// "node-modules" and "test" is worse than an empty one, because every junk
/// entry is another chance for the corrector to rewrite a word the user meant.
export function harvestCandidate(raw: string): string | null {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return null;

  // A hyphenated or underscored name is several words; the spoken form is the
  // words, not the slug. "roman-design-co" is said "Roman Design Co". Spaces
  // count as separators too — a folder called "client work" is two ordinary
  // words and must be rejected on the same grounds as "client-work", or the
  // hyphen becomes the only thing standing between the dictionary and a pile of
  // English.
  const parts = trimmed
    .replace(/_/g, '-')
    .replace(/ /g, '-')
    .split('-')
    .filter((piece) => piece.length > 0);
  if (parts.length === 0 || parts.length > 4) return null;

  const rejoined = parts.join(' ');
  if (rejoined.length < 3 || rejoined.length > 40) return null;
  // Names, not sentences or version strings.
  if (!/^[\p{L}\p{N} ]+$/u.test(rejoined)) return null;
  if (!/\p{L}/u.test(rejoined)) return null;
  // A pile of digits is a date or a version, not something anyone dictates.
  if ((rejoined.match(/\p{N}/gu) ?? []).length > 2) return null;

  const lowered = rejoined.toLowerCase();
  if (BORING_NAMES.has(lowered)) return null;
  // Every part being an ordinary English word means the recogniser already
  // knows it, and adding it only creates a chance to mis-correct. "blockcraft"
  // is worth having; "my website" is not.
  if (parts.every((part) => isCommonName(part.toLowerCase()))) return null;
  // A single ordinary English word is the worst possible dictionary entry: the
  // recogniser already knows it, so the term can never repair anything, and it
  // sits there as one more chance to rewrite a word the user meant. Measured on
  // a real machine, the harvest proposed "dashboard", "maze", "cortex" and
  // "orbital" — every one of them a folder named with a real word.
  //
  // Only single words. A multi-word name made of ordinary words is still worth
  // having, because the value is in the spacing and the casing.
  if (parts.length === 1 && isRealEnglishWord(rejoined)) return null;
  return rejoined;
}

/// Reads at most `bytes` from the front of a file. A manifest's name field is
/// near the top, and a cap means a pathological file cannot be pulled into
/// memory by something the user did not ask for.
function head(path: string, bytes: number): string | null {
  let handle: number | null = null;
  try {
    handle = openSync(path, 'r');
    const buffer = Buffer.alloc(bytes);
    const read = readSync(handle, buffer, 0, bytes, 0);
    return buffer.subarray(0, read).toString('utf8');
  } catch {
    return null;
  } finally {
    if (handle !== null) {
      try { closeSync(handle); } catch { /* already closed */ }
    }
  }
}

function firstMatch(text: string, pattern: RegExp): string | null {
  const match = pattern.exec(text);
  return match?.[1] ?? null;
}

/// The `name` field of a package manifest, and the last path component of a git
/// remote. Both are read as text and matched with a narrow pattern rather than
/// parsed — a JSON parser here would happily read the whole file, and this
/// should not be able to see more than it needs to.
function fromManifests(project: string, label: string): [string, string][] {
  const out: [string, string][] = [];

  const packageJSON = head(join(project, 'package.json'), 2_048);
  if (packageJSON) {
    const name = firstMatch(packageJSON, /"name"\s*:\s*"([^"]{2,40})"/);
    const term = name ? harvestCandidate(name.replace(/^@[^/]+\//, '')) : null;
    if (term) out.push([term, `package.json in ${label}`]);
  }

  for (const [file, pattern] of [
    ['Cargo.toml', /name\s*=\s*"([^"]{2,40})"/],
    ['pyproject.toml', /name\s*=\s*"([^"]{2,40})"/],
    ['Package.swift', /name\s*:\s*"([^"]{2,40})"/],
    ['go.mod', /module\s+(\S{2,60})/],
  ] as [string, RegExp][]) {
    const text = head(join(project, file), 2_048);
    if (!text) continue;
    const name = firstMatch(text, pattern);
    const term = name ? harvestCandidate(name.split('/').pop() ?? name) : null;
    if (term) out.push([term, `${file} in ${label}`]);
  }

  // .git/config holds the remote URL. The repository name is very often the
  // product name spoken aloud, and it is one line of a config file.
  const gitConfig = head(join(project, '.git', 'config'), 4_096);
  if (gitConfig) {
    const url = firstMatch(gitConfig, /url\s*=\s*(\S+)/);
    if (url) {
      const repo = (url.split('/').pop() ?? '').replace(/\.git$/, '');
      const term = harvestCandidate(repo);
      if (term) out.push([term, `git remote in ${label}`]);
    }
  }
  return out;
}

/// Everything worth suggesting, minus what is already known.
export function harvestSuggestions(options: {
  roots?: string[];
  existing?: Vocabulary;
} = {}): HarvestSuggestion[] {
  const roots = options.roots ?? defaultHarvestRoots();
  const existing = options.existing ?? loadVocabulary();
  const known = new Set(contextualStrings(existing).map((term) => term.toLowerCase()));
  // Key is the lowercased term, so duplicates across sources collapse; the
  // value keeps the casing that was actually on disk.
  const found = new Map<string, { display: string; source: string }>();

  for (const root of roots) {
    let entries: string[];
    try {
      if (!statSync(root).isDirectory()) continue;
      entries = readdirSync(root);
    } catch {
      continue;
    }

    for (const name of entries) {
      if (name.startsWith('.')) continue;
      const path = join(root, name);
      try {
        if (!statSync(path).isDirectory()) continue;
      } catch {
        continue;
      }
      const term = harvestCandidate(name);
      if (term && !found.has(term.toLowerCase())) {
        found.set(term.toLowerCase(), { display: term, source: `folder ${name}` });
      }
      for (const [manifestTerm, source] of fromManifests(path, name)) {
        const key = manifestTerm.toLowerCase();
        if (!found.has(key)) found.set(key, { display: manifestTerm, source });
      }
    }
  }

  return [...found.entries()]
    .filter(([key]) => !known.has(key))
    .map(([, value]) => ({ term: value.display, source: value.source }))
    .sort((a, b) => a.term.localeCompare(b.term, undefined, { sensitivity: 'base' }));
}
