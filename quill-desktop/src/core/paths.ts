import { homedir } from 'node:os';
import { join } from 'node:path';
import {
  existsSync, mkdirSync, readdirSync, statSync, unlinkSync, writeFileSync, renameSync,
} from 'node:fs';

/// Where Quill keeps everything it has ever written about you.
///
/// One directory per platform, chosen to be the one a person would look in:
///
///   Windows   %APPDATA%\Quill
///   Linux     $XDG_CONFIG_HOME/quill, or ~/.config/quill
///   macOS     ~/Library/Application Support/Quill
///
/// Deliberately not `app.getPath('userData')`, even though this app is an
/// Electron app. That call is unavailable in a test and in the eval rig, it
/// changes with the product name, and — the part that matters — it is the same
/// folder Electron writes its own cache into, so "erase everything" would
/// either miss files or delete Chromium's.
export function dataDirectory(): string {
  const override = process.env.QUILL_DATA_DIR;
  if (override && override.length > 0) return expandTilde(override);
  switch (process.platform) {
    case 'win32': {
      const appData = process.env.APPDATA ?? join(homedir(), 'AppData', 'Roaming');
      return join(appData, 'Quill');
    }
    case 'darwin':
      return join(homedir(), 'Library', 'Application Support', 'Quill');
    default: {
      const xdg = process.env.XDG_CONFIG_HOME;
      return join(xdg && xdg.length > 0 ? xdg : join(homedir(), '.config'), 'quill');
    }
  }
}

export function expandTilde(path: string): string {
  if (path === '~') return homedir();
  if (path.startsWith('~/') || path.startsWith('~\\')) return join(homedir(), path.slice(2));
  return path;
}

export function dataFile(name: string): string {
  return join(dataDirectory(), name);
}

export function ensureDataDirectory(): string {
  const directory = dataDirectory();
  mkdirSync(directory, { recursive: true });
  return directory;
}

/// Everything Quill has ever written about you, in one list.
///
/// The list exists because "erase all my data" is a promise, and a promise kept
/// by an `rm` written from memory is one that quietly breaks the next time
/// somebody adds a store. Every file the app writes is named here, and
/// `tests/data.test.ts` walks the source for `dataFile("…")` and fails when one
/// is added and not listed — so forgetting is a test failure rather than a
/// leftover transcript nobody knew about.
///
/// Deliberately a list and not "delete the directory". On a development machine
/// the same folder can hold a downloaded speech model, and a feature that
/// re-downloads 150 MB out from under you is not the feature that was asked for.
export const DATA_FILES = [
  'history.json',      // every dictation
  'settings.json',     // hotkeys, microphone, preferences
  'vocabulary.json',   // the Dictionary
  'transforms.json',   // saved transforms and their chords
  'snippets.json',
  'notes.json',        // the Scratchpad
  'style.json',        // the learned writing profile
  'nim-key.txt',       // the API key
] as const;

export function dataFiles(): string[] {
  return DATA_FILES.map((name) => dataFile(name));
}

/// Copies the stores made of files they refused to overwrite, plus the traces
/// the debug switches write. Not data anybody chose to keep, but all of it is
/// still the user's words and it goes when they ask for everything to go.
export function incidentalFiles(): string[] {
  const directory = dataDirectory();
  let listed: string[];
  try {
    listed = readdirSync(directory);
  } catch {
    return [];
  }
  return listed
    .filter((name) => name.includes('.unreadable-') || name.endsWith('.log') || name === 'caret-probe.txt')
    .map((name) => join(directory, name));
}

/// What `eraseEverything()` is about to remove, so a confirmation can say it out
/// loud rather than asking someone to trust the word "everything".
export function dataSummary(): { name: string; bytes: number }[] {
  const out: { name: string; bytes: number }[] = [];
  for (const path of [...dataFiles(), ...incidentalFiles()]) {
    try {
      const stats = statSync(path);
      out.push({ name: path.split(/[\\/]/).pop() ?? path, bytes: stats.size });
    } catch {
      continue;
    }
  }
  return out.sort((a, b) => b.bytes - a.bytes);
}

/// Delete the lot. Returns what actually went.
///
/// Nothing in memory is touched, and that is on purpose rather than an
/// omission: every store in this app holds its records in memory and writes the
/// whole file on the next change, so a running Quill would put its history back
/// within a dictation. The only honest way to finish this is to relaunch, which
/// is what the caller does — and which is also what makes the result genuinely
/// indistinguishable from a fresh install.
export function eraseEverything(): string[] {
  const removed: string[] = [];
  for (const path of [...dataFiles(), ...incidentalFiles()]) {
    if (!existsSync(path)) continue;
    try {
      unlinkSync(path);
      removed.push(path.split(/[\\/]/).pop() ?? path);
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error(`[quill] erase: could not remove ${path}`, error);
    }
  }
  return removed;
}

/// An atomic write. Every store in the app goes through this.
///
/// A half-written history file read mid-save loses the lot, and on Windows a
/// plain `writeFileSync` over an open file can fail part-way and leave exactly
/// that. Write beside it, then rename — rename is atomic on all three
/// platforms when both paths are on the same filesystem, which they are by
/// construction here.
export function writeAtomic(path: string, contents: string): boolean {
  try {
    mkdirSync(join(path, '..'), { recursive: true });
    const temporary = `${path}.tmp`;
    writeFileSync(temporary, contents, 'utf8');
    renameSync(temporary, path);
    return true;
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error(`[quill] could not write ${path}`, error);
    return false;
  }
}

/// Electron sets `process.resourcesPath`; Node does not, and the core is meant
/// to be runnable under plain Node for tests and for the eval rig. Read
/// defensively in one place rather than declared globally, so nothing else in
/// `core` has to know this app is an Electron app.
export function resourcesPath(): string | null {
  const value = (process as NodeJS.Process & { resourcesPath?: string }).resourcesPath;
  return typeof value === 'string' && value.length > 0 ? value : null;
}
