import { dataFile, writeAtomic } from '../paths';
import { encodeJSON, fromISO, readStoreFile, toISO, uuid } from './storeFile';
import { trim, wordCount } from '../text/strings';

/// Scratchpad notes. The useful part is that dictation has somewhere to go that
/// is not another app's text field, so a thought can be captured without
/// choosing a destination first.
export interface Note {
  id: string;
  title: string;
  body: string;
  created: Date;
  modified: Date;
  isPinned: boolean;
}

export function makeNote(partial: Partial<Note> = {}): Note {
  const now = new Date();
  return {
    id: partial.id ?? uuid(),
    title: partial.title ?? '',
    body: partial.body ?? '',
    created: partial.created ?? now,
    modified: partial.modified ?? now,
    isPinned: partial.isPinned ?? false,
  };
}

/// A note dictated in one breath has no title, so the first line becomes one —
/// the user should not have to name a thought before they are allowed to have
/// it.
export function noteDisplayTitle(note: Note): string {
  if (note.title.length > 0) return note.title;
  const firstLine = note.body.split('\n')[0] ?? '';
  const trimmed = trim(firstLine);
  if (trimmed.length === 0) return 'Untitled';
  return trimmed.length > 60 ? `${trimmed.slice(0, 60)}…` : trimmed;
}

export function noteWordCount(note: Note): number {
  return wordCount(note.body);
}

function validate(value: unknown): Note[] | null {
  if (!Array.isArray(value)) return null;
  const out: Note[] = [];
  for (const raw of value as Record<string, unknown>[]) {
    if (!raw || typeof raw !== 'object') return null;
    if (typeof raw.body !== 'string') return null;
    out.push({
      id: typeof raw.id === 'string' ? raw.id : uuid(),
      title: typeof raw.title === 'string' ? raw.title : '',
      body: raw.body,
      created: fromISO(raw.created) ?? new Date(),
      modified: fromISO(raw.modified) ?? new Date(),
      isPinned: raw.isPinned === true,
    });
  }
  return out;
}

function encode(notes: Note[]): unknown {
  return notes.map((note) => ({
    id: note.id,
    title: note.title,
    body: note.body,
    created: toISO(note.created),
    modified: toISO(note.modified),
    isPinned: note.isPinned,
  }));
}

export class NoteStore {
  private readonly url: string | null;
  private notes: Note[] = [];
  /// Set when the file exists and could not be read. While it is true nothing
  /// is written, because the alternative is replacing notes that are probably
  /// still recoverable with the empty list we fell back to.
  private loadFailed = false;

  private static sharedStore: NoteStore | null = null;
  static shared(): NoteStore {
    if (!NoteStore.sharedStore) NoteStore.sharedStore = new NoteStore();
    return NoteStore.sharedStore;
  }

  static inMemory(notes: Note[]): NoteStore {
    const store = new NoteStore(null);
    store.notes = notes;
    return store;
  }

  constructor(url: string | null = dataFile('notes.json')) {
    this.url = url;
    if (!url) return;
    const outcome = readStoreFile(url, validate);
    switch (outcome.kind) {
      case 'missing': this.notes = []; break;
      case 'decoded': this.notes = outcome.value; break;
      case 'unreadable':
        this.notes = [];
        this.loadFailed = true;
        break;
    }
  }

  /// Pinned first, then most recently modified.
  get all(): Note[] {
    return [...this.notes].sort((a, b) => {
      if (a.isPinned !== b.isPinned) return a.isPinned ? -1 : 1;
      return b.modified.getTime() - a.modified.getTime();
    });
  }

  upsert(note: Note): Note {
    const updated: Note = { ...note, modified: new Date() };
    const index = this.notes.findIndex((existing) => existing.id === note.id);
    if (index >= 0) this.notes[index] = updated;
    else this.notes.push(updated);
    this.persist();
    return updated;
  }

  delete(id: string): void {
    this.notes = this.notes.filter((note) => note.id !== id);
    this.persist();
  }

  private persist(): void {
    if (this.loadFailed || !this.url) return;
    writeAtomic(this.url, encodeJSON(encode(this.notes)));
  }
}
