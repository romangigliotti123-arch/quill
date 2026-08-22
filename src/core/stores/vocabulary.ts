import { statSync } from 'node:fs';
import { dataFile, expandTilde, writeAtomic } from '../paths';
import { encodeJSON, readStoreFile } from './storeFile';
import { equalsIgnoringCase, trim } from '../text/strings';

/// Words the recogniser has no reason to know.
///
/// A general model has never seen "graphify" or "Craigieburn", and a dictation
/// app that mangles the nouns you use every day is worse than useless — you
/// spend longer fixing it than typing would have taken.
///
/// On macOS these were also handed to Apple's recogniser as contextual strings.
/// Measured, that did nothing: the same audio with 0 biasing terms and with 25
/// produced byte-identical text. Whisper does have a real biasing channel — the
/// `initial_prompt` — and the speech renderer uses it, but the correction pass
/// below is still what actually repairs a mangled name, because biasing is a
/// hint and not a guarantee.
export interface Vocabulary {
  terms: string[];
}

/// Seeded from the names a general speech model reliably mishears.
///
/// This list used to be the author's life: his suburb, his school, his family,
/// and eleven clients by full name. It shipped in the binary, so every stranger
/// who installed Quill got a Dictionary of people they have never met — and
/// those people never agreed to be in it. A seed is a guess at what ANY user
/// says; anything narrower belongs in the file on their own machine, which is
/// what the Dictionary tab is for.
export const VOCABULARY_SEED: Vocabulary = {
  terms: [
    'Firebase', 'Firestore', 'Netlify', 'Supabase', 'SQLite', 'Postgres',
    'Redis', 'Docker', 'Kubernetes', 'nginx', 'GraphQL', 'OAuth', 'JWT',
    'SwiftUI', 'SwiftPM', 'Xcode', 'TypeScript', 'JavaScript', 'Playwright',
    'PyTorch', 'NumPy', 'pandas', 'pytest', 'venv', 'CPython', 'codesign',
    'npm', 'pnpm', 'webpack', 'Vite', 'ESLint', 'Prettier', 'Tailwind',
    'React', 'Next.js', 'Node.js', 'Deno', 'Rust', 'Kotlin', 'Golang',
    'tmux', 'xterm', 'ssh', 'sudo', 'cron', 'regex', 'stdout', 'stderr',
    'API', 'CLI', 'SDK', 'UUID', 'JSON', 'YAML', 'CSV', 'HTTP', 'HTTPS',
    'CI', 'CD', 'repo', 'monorepo', 'changelog', 'hotfix', 'linting',
    // Cross-platform additions. The macOS build could assume a Mac vocabulary;
    // this one runs where people say these instead.
    'PowerShell', 'WSL', 'systemd', 'Wayland', 'Xorg', 'GNOME', 'KDE',
    'Ubuntu', 'Debian', 'Fedora', 'Arch', 'NixOS', 'winget', 'Chocolatey',
    'Electron', 'Vulkan', 'CUDA', 'ONNX', 'Whisper',
  ],
};

export function vocabularyURL(): string {
  const override = process.env.QUILL_VOCABULARY_FILE;
  if (override && override.length > 0) return expandTilde(override);
  return dataFile('vocabulary.json');
}

function validateVocabulary(value: unknown): Vocabulary | null {
  if (!value || typeof value !== 'object') return null;
  const terms = (value as { terms?: unknown }).terms;
  if (!Array.isArray(terms)) return null;
  if (!terms.every((term) => typeof term === 'string')) return null;
  return { terms: terms as string[] };
}

/// Multi-word entries are kept whole. Splitting "Next Fulfilment" into two
/// tokens would bias toward the common word "next" rather than the company.
export function contextualStrings(vocabulary: Vocabulary): string[] {
  return vocabulary.terms.map(trim).filter((term) => term.length > 0);
}

/// The same read, with the one bit callers need before they write.
///
/// A plain `load` cannot distinguish "no file yet" from "a file I could not
/// read", and both would return the shipped seed. Every writer does load →
/// mutate → save, so one unreadable byte would mean the next word added to the
/// dictionary writes sixty stock terms over everything the user had put there.
export function loadVocabularyOutcome(url = vocabularyURL()): {
  vocabulary: Vocabulary;
  isDamaged: boolean;
} {
  const outcome = readStoreFile(url, validateVocabulary);
  switch (outcome.kind) {
    case 'missing': return { vocabulary: { terms: [...VOCABULARY_SEED.terms] }, isDamaged: false };
    case 'decoded': return { vocabulary: outcome.value, isDamaged: false };
    case 'unreadable': return { vocabulary: { terms: [...VOCABULARY_SEED.terms] }, isDamaged: true };
  }
}

export function loadVocabulary(url = vocabularyURL()): Vocabulary {
  return loadVocabularyOutcome(url).vocabulary;
}

export function saveVocabulary(vocabulary: Vocabulary, url = vocabularyURL()): boolean {
  return writeAtomic(url, encodeJSON(vocabulary));
}

/// The vocabulary, live.
///
/// Reading the file once at launch meant a word added in the Dictionary went to
/// disk and then did nothing — not to the next dictation, not to the one after
/// that, only to the next launch. The screen said the word was in the
/// dictionary and the dictionary behaved as though it were not, which is the
/// worst of the three possible outcomes: a silent failure that looks like a
/// success.
///
/// So reads go through here. The file's modification time is checked on access
/// and the cache is refreshed when it moves. One `stat` per dictation is free
/// against a gap measured in seconds, and it means the file stays what its own
/// documentation promises — the source of truth, editable by hand, without the
/// app needing to be told.
export class VocabularyBook {
  private readonly url: string;
  private cached: Vocabulary;
  private stamp: number | null;

  private static sharedBook: VocabularyBook | null = null;
  static shared(): VocabularyBook {
    if (!VocabularyBook.sharedBook) VocabularyBook.sharedBook = new VocabularyBook();
    return VocabularyBook.sharedBook;
  }

  constructor(url: string = vocabularyURL()) {
    this.url = url;
    this.cached = loadVocabulary(url);
    this.stamp = VocabularyBook.modified(url);
  }

  /// The vocabulary as it is on disk right now.
  get current(): Vocabulary {
    const latest = VocabularyBook.modified(this.url);
    // Both null (no file, still no file) counts as unchanged, so a machine with
    // no vocabulary file does not re-read on every single call.
    if (latest !== this.stamp) {
      this.cached = loadVocabulary(this.url);
      this.stamp = latest;
    }
    return this.cached;
  }

  get terms(): string[] {
    return contextualStrings(this.current);
  }

  /// Adds a term, refusing duplicates and blanks. Returns false when nothing
  /// changed, so a caller can say "already there" rather than pretending.
  add(term: string): boolean {
    const trimmed = trim(term);
    if (trimmed.length === 0) return false;
    // Re-read before writing: the Dictionary screen and a hand edit can both be
    // in flight, and a stale in-memory copy written back would silently delete
    // whatever the other one added.
    const { vocabulary, isDamaged } = loadVocabularyOutcome(this.url);
    // Adding one word must never be the act that replaces the whole file with
    // the shipped seed.
    if (isDamaged) return false;
    if (contextualStrings(vocabulary).some((existing) => equalsIgnoringCase(existing, trimmed))) return false;
    vocabulary.terms.push(trimmed);
    if (!saveVocabulary(vocabulary, this.url)) return false;
    this.cached = vocabulary;
    this.stamp = VocabularyBook.modified(this.url);
    return true;
  }

  remove(term: string): boolean {
    const { vocabulary, isDamaged } = loadVocabularyOutcome(this.url);
    if (isDamaged) return false;
    const before = vocabulary.terms.length;
    vocabulary.terms = vocabulary.terms.filter((existing) => !equalsIgnoringCase(existing, term));
    if (vocabulary.terms.length === before) return false;
    if (!saveVocabulary(vocabulary, this.url)) return false;
    this.cached = vocabulary;
    this.stamp = VocabularyBook.modified(this.url);
    return true;
  }

  private static modified(url: string): number | null {
    try {
      return statSync(url).mtimeMs;
    } catch {
      return null;
    }
  }
}
