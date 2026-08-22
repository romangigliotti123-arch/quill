import { readFileSync, writeFileSync } from 'node:fs';

/// Reading a store's file without mistaking damage for emptiness.
///
/// Every store in this app made the same mistake once: a file that exists but
/// will not decode was treated as an empty collection, and the next write
/// atomically replaced it with `[]`. One partial write during a crash, one
/// field a newer build does not understand, and every note, every snippet,
/// every word in the dictionary is gone — in response to a single unreadable
/// byte, silently, at the moment the user next edited anything.
///
/// The distinction that matters is between three states, not two:
///
///   `missing`     — no file yet. Defaults are correct, writing is correct.
///   `decoded`     — read it.
///   `unreadable`  — a file exists and could not be read. Whatever is in memory
///                   is NOT the user's data, and writing it destroys what is.
///
/// A store that cannot tell the third from the first will eventually delete
/// everything its user has, and will report success while doing it.
export type StoreOutcome<T> =
  | { kind: 'missing' }
  | { kind: 'decoded'; value: T }
  | { kind: 'unreadable' };

export function readStoreFile<T>(path: string, validate: (value: unknown) => T | null): StoreOutcome<T> {
  let raw: string;
  try {
    raw = readFileSync(path, 'utf8');
  } catch {
    return { kind: 'missing' };
  }
  // A zero-byte file is a crash mid-write, not an empty collection.
  if (raw.length === 0) {
    salvage(raw, path, 'empty');
    return { kind: 'unreadable' };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    salvage(raw, path, 'undecodable');
    return { kind: 'unreadable' };
  }
  const value = validate(parsed);
  if (value === null) {
    salvage(raw, path, 'undecodable');
    return { kind: 'unreadable' };
  }
  return { kind: 'decoded', value };
}

/// Keeps a copy of what could not be read, and says so.
///
/// The user's data outranks the app's convenience every time, and a file the
/// app refuses to touch is one a person can still open in a text editor and
/// rescue by hand.
function salvage(contents: string, path: string, note: string): void {
  const copy = `${path}.unreadable-${Math.floor(Date.now() / 1000)}`;
  try {
    writeFileSync(copy, contents, 'utf8');
  } catch {
    /* best effort; the log line below is the real message */
  }
  // eslint-disable-next-line no-console
  console.error(`[quill] ${path} is ${note} — refusing to overwrite it. Copy at ${copy}`);
}

/// Dates go to disk as ISO 8601 and come back as `Date`.
export function toISO(date: Date | null | undefined): string | null {
  return date ? date.toISOString() : null;
}

export function fromISO(value: unknown): Date | null {
  if (typeof value !== 'string') return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

/// A stable, pretty JSON encoding with sorted keys — so a hand edit produces a
/// small diff rather than a reshuffled file.
export function encodeJSON(value: unknown): string {
  return `${JSON.stringify(value, sortedKeysReplacer, 2)}\n`;
}

function sortedKeysReplacer(this: unknown, _key: string, value: unknown): unknown {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      sorted[key] = (value as Record<string, unknown>)[key];
    }
    return sorted;
  }
  return value;
}

/// A v4 UUID without pulling in a dependency. `crypto.randomUUID` is present in
/// every Node and Electron this app supports.
export function uuid(): string {
  return globalThis.crypto.randomUUID();
}
