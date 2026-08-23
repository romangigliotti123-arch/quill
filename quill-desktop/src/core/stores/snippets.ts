import { dataFile, writeAtomic } from '../paths';
import { encodeJSON, fromISO, readStoreFile, toISO, uuid } from './storeFile';
import { expandSnippets } from '../cleanup/snippetExpander';
import { trim } from '../text/strings';

/// A spoken phrase that stands in for a block of text.
///
/// Kept in a separate file from the dictionary for one reason that matters: the
/// dictionary is a *bias* — it nudges what the recogniser hears and is harmless
/// when it is wrong — while a snippet is an *edit* that drops hundreds of
/// characters into a document someone is already typing in. Two things with
/// that different a blast radius should not share a table, a migration or an
/// editor.
export type SnippetMode = 'anywhere' | 'alone';

export function snippetModeTitle(mode: SnippetMode): string {
  return mode === 'anywhere' ? 'Anywhere in a sentence' : 'Only on its own';
}

export interface Snippet {
  id: string;
  /// What you say. Matched word-for-word after punctuation and case are
  /// discarded — never fuzzily. See `snippetExpander` for why.
  phrase: string;
  /// What gets typed. Newlines are preserved exactly as written.
  replacement: string;
  mode: SnippetMode;
  isEnabled: boolean;
  useCount: number;
  lastUsed: Date | null;
  created: Date;
}

export function makeSnippet(partial: Partial<Snippet> & { phrase: string; replacement: string }): Snippet {
  return {
    id: partial.id ?? uuid(),
    phrase: partial.phrase,
    replacement: partial.replacement,
    mode: partial.mode ?? 'anywhere',
    isEnabled: partial.isEnabled ?? true,
    useCount: partial.useCount ?? 0,
    lastUsed: partial.lastUsed ?? null,
    created: partial.created ?? new Date(),
  };
}

/// Characters this snippet has saved: every firing typed the replacement
/// instead of the phrase. The one honest measure of whether it earns its place
/// in the list.
export function charactersSaved(snippet: Snippet): number {
  return snippet.useCount * Math.max(0, snippet.replacement.length - snippet.phrase.length);
}

/// The replacement on one line, for a list row. A snippet whose value is three
/// paragraphs still has to be recognisable in 40 characters.
export function snippetPreviewLine(snippet: Snippet): string {
  return trim(snippet.replacement.replace(/\s+/gu, ' '));
}

export function snippetIsBlank(snippet: Snippet): boolean {
  return trim(snippet.phrase).length === 0 && trim(snippet.replacement).length === 0;
}

interface StoredSnippet {
  id?: string;
  phrase?: string;
  replacement?: string;
  mode?: string;
  isEnabled?: boolean;
  useCount?: number;
  lastUsed?: string | null;
  created?: string;
}

function validate(value: unknown): Snippet[] | null {
  if (!Array.isArray(value)) return null;
  const out: Snippet[] = [];
  for (const entry of value as StoredSnippet[]) {
    if (!entry || typeof entry !== 'object') return null;
    if (typeof entry.phrase !== 'string' || typeof entry.replacement !== 'string') return null;
    out.push({
      id: typeof entry.id === 'string' ? entry.id : uuid(),
      phrase: entry.phrase,
      replacement: entry.replacement,
      mode: entry.mode === 'alone' ? 'alone' : 'anywhere',
      isEnabled: entry.isEnabled ?? true,
      useCount: typeof entry.useCount === 'number' ? entry.useCount : 0,
      lastUsed: fromISO(entry.lastUsed),
      created: fromISO(entry.created) ?? new Date(),
    });
  }
  return out;
}

function encode(snippets: Snippet[]): unknown {
  return snippets.map((snippet) => ({
    id: snippet.id,
    phrase: snippet.phrase,
    replacement: snippet.replacement,
    mode: snippet.mode,
    isEnabled: snippet.isEnabled,
    useCount: snippet.useCount,
    lastUsed: toISO(snippet.lastUsed),
    created: toISO(snippet.created),
  }));
}

/// First-run contents.
///
/// Nothing. A new install has no snippets.
///
/// It shipped three examples, and examples are the wrong shape for this
/// feature. A snippet fires on words you say out loud — so a starter set is
/// three phrases that will expand into somebody else's text the first time you
/// happen to say "my email" or "sign off" in a sentence, before you have read
/// the screen that would have told you they exist. The demonstration value is
/// one glance; the cost is being surprised by your own keyboard.
///
/// Kept as a function rather than folded away, because `SnippetStore` still has
/// to tell "no file yet" from "a file I could not read" — those are different
/// facts and only one of them is allowed to write.
export function snippetSeed(): Snippet[] {
  return [];
}

/// Snippets on disk, plus the usage counters.
export class SnippetStore {
  private readonly url: string | null;
  private items: Snippet[] = [];
  /// See `readStoreFile`. A snippets file that will not decode is not zero
  /// snippets.
  private loadFailed = false;

  private static sharedStore: SnippetStore | null = null;
  static shared(): SnippetStore {
    if (!SnippetStore.sharedStore) SnippetStore.sharedStore = new SnippetStore();
    return SnippetStore.sharedStore;
  }

  static inMemory(items: Snippet[]): SnippetStore {
    const store = new SnippetStore(null);
    store.items = items;
    return store;
  }

  constructor(url: string | null = dataFile('snippets.json')) {
    this.url = url;
    if (!url) return;
    const outcome = readStoreFile(url, validate);
    switch (outcome.kind) {
      case 'missing':
        this.items = snippetSeed();
        break;
      case 'decoded':
        this.items = outcome.value;
        break;
      case 'unreadable':
        // Deliberately NOT the seed. Shipping starter snippets over the top of a
        // damaged file would look like a factory reset the user asked for, and
        // would take their own snippets with it.
        this.items = [];
        this.loadFailed = true;
        break;
    }
  }

  get all(): Snippet[] { return this.items.map((snippet) => ({ ...snippet })); }
  get isEmpty(): boolean { return this.items.length === 0; }

  /// Newest-used first, then most-used, then newest. What a list of snippets
  /// should be ordered by: the one you reach for is the one at the top.
  get ordered(): Snippet[] {
    return this.all.sort((a, b) => {
      const left = a.lastUsed?.getTime() ?? null;
      const right = b.lastUsed?.getTime() ?? null;
      if (left !== null && right !== null && left !== right) return right - left;
      if (left === null && right !== null) return 1;
      if (left !== null && right === null) return -1;
      if (a.useCount !== b.useCount) return b.useCount - a.useCount;
      return b.created.getTime() - a.created.getTime();
    });
  }

  upsert(snippet: Snippet): Snippet {
    const index = this.items.findIndex((item) => item.id === snippet.id);
    if (index >= 0) {
      // The editor's copy of the counters is a snapshot from whenever the row
      // was loaded, and a dictation may have fired the snippet since. Writing it
      // back whole rolls the count backwards — so the editor owns the text and
      // the store owns the counters.
      const existing = this.items[index]!;
      const merged: Snippet = {
        ...snippet,
        useCount: Math.max(existing.useCount, snippet.useCount),
        lastUsed: [existing.lastUsed, snippet.lastUsed]
          .filter((date): date is Date => date !== null)
          .sort((a, b) => b.getTime() - a.getTime())[0] ?? null,
      };
      this.items[index] = merged;
      this.persist();
      return { ...merged };
    }
    this.items.push({ ...snippet });
    this.persist();
    return { ...snippet };
  }

  remove(id: string): void {
    this.items = this.items.filter((item) => item.id !== id);
    this.persist();
  }

  snippet(id: string): Snippet | null {
    const found = this.items.find((item) => item.id === id);
    return found ? { ...found } : null;
  }

  /// Bumps the counters for everything that fired. Separate from `upsert` so a
  /// dictation never races an open editor into overwriting an edit.
  recordUses(ids: string[], at: Date = new Date()): void {
    if (ids.length === 0) return;
    for (const id of new Set(ids)) {
      const index = this.items.findIndex((item) => item.id === id);
      if (index < 0) continue;
      this.items[index]!.useCount += ids.filter((candidate) => candidate === id).length;
      this.items[index]!.lastUsed = at;
    }
    this.persist();
  }

  /// The dictation path's one entry point: expand, count what fired, return the
  /// text to insert.
  expand(text: string): string {
    const result = expandSnippets(text, this.all);
    if (!result.didFire) return text;
    this.recordUses(result.firings.map((firing) => firing.id));
    return result.text;
  }

  /// Every trigger phrase. Offered to the recogniser alongside the dictionary
  /// so an unusual trigger is at least *heard* — a phrase that never survives
  /// transcription can never fire.
  get phrases(): string[] {
    return this.items.filter((snippet) => snippet.isEnabled).map((snippet) => snippet.phrase);
  }

  get totalCharactersSaved(): number {
    return this.items.reduce((total, snippet) => total + charactersSaved(snippet), 0);
  }

  private persist(): void {
    if (this.loadFailed || !this.url) return;
    writeAtomic(this.url, encodeJSON(encode(this.items)));
  }
}
