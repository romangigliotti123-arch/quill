import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HistoryStore, isLoopbackDevice, type DictationRecord } from '../src/core/stores/history';
import { NoteStore, makeNote, noteDisplayTitle } from '../src/core/stores/notes';
import { SnippetStore } from '../src/core/stores/snippets';
import { TransformStore, applyOfflineRecipe, transformSeed } from '../src/core/transforms/transforms';
import {
  VocabularyBook, contextualStrings, loadVocabularyOutcome, VOCABULARY_SEED,
} from '../src/core/stores/vocabulary';
import { QuillSettings, retentionCutoff, defaultSettings } from '../src/core/settings';
import { DATA_FILES } from '../src/core/paths';
import { harvestCandidate } from '../src/core/stores/vocabularyHarvest';
import { uuid } from '../src/core/stores/storeFile';

// The rule these exist to enforce, and the one every store in the original app
// got wrong at least once: a file that exists but will not decode is NOT an
// empty collection. Treating it as one and writing over it destroys everything
// the user has, silently, at the moment they next edit anything.

function scratch(): string {
  return mkdtempSync(join(tmpdir(), 'quill-test-'));
}

function record(date: Date, words = 5): DictationRecord {
  return {
    id: uuid(),
    date,
    rawText: 'raw',
    insertedText: 'inserted',
    wordCount: words,
    inputDevice: null,
    timings: {
      timeToFirstWordMs: null, finalToInsertedMs: null, endToEndMs: null,
      audioDurationMs: null, usedThoroughCleanup: false, releaseToInsertedMs: null,
      micOpenMs: null, speechOnsetMs: null, recogniserFirstWordMs: null,
    },
  };
}

// MARK: - Damage is not emptiness

test('an undecodable notes file is never overwritten', () => {
  const dir = scratch();
  const path = join(dir, 'notes.json');
  writeFileSync(path, '{ this is not json');

  const store = new NoteStore(path);
  assert.deepEqual(store.all, []);
  store.upsert(makeNote({ body: 'something new' }));

  // The damaged bytes are still there, and a copy was kept beside them.
  assert.equal(readFileSync(path, 'utf8'), '{ this is not json');
  assert.ok(readdirSync(dir).some((name) => name.includes('.unreadable-')),
    'no salvage copy was written');
});

test('a zero-byte file is a crash mid-write, not an empty collection', () => {
  const dir = scratch();
  const path = join(dir, 'snippets.json');
  writeFileSync(path, '');
  const store = new SnippetStore(path);
  // NOT the seed. Shipping starter snippets over the top of a damaged file
  // would look like a factory reset the user asked for, and would take their
  // own snippets with it.
  assert.deepEqual(store.all, []);
  store.upsert({
    id: uuid(), phrase: 'a', replacement: 'b', mode: 'anywhere',
    isEnabled: true, useCount: 0, lastUsed: null, created: new Date(),
  });
  assert.equal(readFileSync(path, 'utf8'), '');
});

test('a missing file is not damage — the seed is written on the first change', () => {
  const dir = scratch();
  const path = join(dir, 'snippets.json');
  const store = new SnippetStore(path);
  assert.ok(store.all.length > 0, 'a missing file should seed');
  store.recordUses([store.all[0]!.id]);
  assert.ok(existsSync(path));
});

test('a damaged transforms file keeps the built-ins in memory and writes nothing', () => {
  const dir = scratch();
  const path = join(dir, 'transforms.json');
  // Valid JSON, wrong shape — the case a hand edit actually produces, and the
  // one that silently substituted the eight built-ins and then wrote them over
  // every custom transform the user had.
  writeFileSync(path, '{"transforms": []}');
  const store = new TransformStore(path);
  assert.equal(store.all.length, transformSeed().length);
  store.recordUse(store.all[0]!.id);
  assert.equal(readFileSync(path, 'utf8'), '{"transforms": []}');
});

test('a damaged vocabulary file refuses to accept a new word', () => {
  // Adding one word must never be the act that replaces the whole file with the
  // shipped seed.
  const dir = scratch();
  const path = join(dir, 'vocabulary.json');
  writeFileSync(path, 'not json at all');
  const { isDamaged } = loadVocabularyOutcome(path);
  assert.equal(isDamaged, true);
  const book = new VocabularyBook(path);
  assert.equal(book.add('Netlify'), false);
  assert.equal(readFileSync(path, 'utf8'), 'not json at all');
});

// MARK: - The vocabulary is live

test('a word added on disk reaches the very next read', () => {
  // Reading the file once at launch meant a word added in the Dictionary went
  // to disk and then did nothing until the next launch — with the screen
  // reporting it as added the whole time.
  const dir = scratch();
  const path = join(dir, 'vocabulary.json');
  writeFileSync(path, JSON.stringify({ terms: ['Netlify'] }));
  const book = new VocabularyBook(path);
  assert.deepEqual(book.terms, ['Netlify']);

  // Edited by hand, behind the book's back, with a bumped modification time.
  writeFileSync(path, JSON.stringify({ terms: ['Netlify', 'graphify'] }));
  const future = new Date(Date.now() + 2000);
  // eslint-disable-next-line @typescript-eslint/no-var-requires, global-require
  require('node:fs').utimesSync(path, future, future);
  assert.deepEqual(book.terms, ['Netlify', 'graphify']);
});

test('the vocabulary refuses duplicates and blanks', () => {
  const dir = scratch();
  const path = join(dir, 'vocabulary.json');
  const book = new VocabularyBook(path);
  assert.equal(book.add('  '), false);
  assert.equal(book.add('Zzyzx'), true);
  assert.equal(book.add('zzyzx'), false, 'a case-different duplicate was accepted');
  assert.equal(book.remove('ZZYZX'), true);
});

test('the shipped seed is general vocabulary, not a person', () => {
  // It used to be the author's life: his suburb, his school, his family, and
  // eleven clients by full name — shipped in the binary, so every stranger who
  // installed Quill got a Dictionary of people they have never met.
  const text = contextualStrings(VOCABULARY_SEED).join(' ').toLowerCase();
  for (const personal of ['craigieburn', 'gigliotti', 'rosehill', 'noah', 'carlo', 'melbourne']) {
    assert.ok(!text.includes(personal), `the seed names ${personal}`);
  }
});

// MARK: - History retention

test('retention deletes what is past its date and nothing else', () => {
  const dir = scratch();
  const path = join(dir, 'history.json');
  const now = new Date();
  const old = new Date(now.getTime() - 40 * 86_400_000);
  const recent = new Date(now.getTime() - 2 * 86_400_000);

  const store = new HistoryStore(path, () => retentionCutoff('month', now));
  store.append(record(recent));
  store.append(record(old));
  assert.equal(store.all.length, 1, 'the expired record survived');
  store.dispose();
});

test('forever keeps everything', () => {
  const dir = scratch();
  const store = new HistoryStore(join(dir, 'history.json'), () => retentionCutoff('forever', new Date()));
  store.append(record(new Date(Date.now() - 400 * 86_400_000)));
  assert.equal(store.all.length, 1);
  store.dispose();
});

test('a month is measured in calendar days, not 86,400-second ones', () => {
  // "A month ago" has to mean the same wall-clock moment across the two days a
  // year when a day is not 24 hours long. Nobody would notice, which is exactly
  // why it should be right.
  const now = new Date('2026-04-05T09:30:00');
  const cutoff = retentionCutoff('month', now);
  assert.ok(cutoff);
  assert.equal(cutoff.getHours(), now.getHours());
  assert.equal(cutoff.getMinutes(), now.getMinutes());
});

test('a loopback device marks a record as a measurement', () => {
  // The eval rig writes to the same history file the app does. A dictation is
  // words a person spoke into a microphone; audio played into a loopback is a
  // measurement, and the two must not be added together on a screen whose only
  // job is to be trusted.
  assert.ok(isLoopbackDevice('BlackHole 2ch'));
  assert.ok(isLoopbackDevice('Monitor of Built-in Audio'));
  assert.ok(isLoopbackDevice('CABLE Output (VB-Audio Virtual Cable)'));
  assert.ok(!isLoopbackDevice('MacBook Air Microphone'));
  assert.ok(!isLoopbackDevice('Shure MV7'));
});

// MARK: - Settings

test('a settings file from an older build still loads', () => {
  // Every settings file written before a key existed decodes to the default,
  // which is the behaviour those files already had.
  const dir = scratch();
  const path = join(dir, 'settings.json');
  writeFileSync(path, JSON.stringify({ holdKey: 'CtrlRight', liveText: false }));
  const settings = new QuillSettings(path);
  assert.equal(settings.holdKey, 'CtrlRight');
  assert.equal(settings.liveText, false);
  assert.equal(settings.numberStyle, defaultSettings().numberStyle);
  assert.equal(settings.historyRetention, defaultSettings().historyRetention);
});

test('a value this build does not recognise falls back rather than throwing the file away', () => {
  // It matters most for retention — the consequence of losing that one is that
  // the app starts deleting on a schedule the user did not pick.
  const dir = scratch();
  const path = join(dir, 'settings.json');
  writeFileSync(path, JSON.stringify({ historyRetention: 'fortnight', numberStyle: 'shouty' }));
  const settings = new QuillSettings(path);
  assert.equal(settings.historyRetention, 'month');
  assert.equal(settings.numberStyle, 'spellOutSmall');
});

test('a corrupt settings file does not stop the app launching', () => {
  const dir = scratch();
  const path = join(dir, 'settings.json');
  writeFileSync(path, 'not json');
  const settings = new QuillSettings(path);
  assert.deepEqual(settings.current, defaultSettings());
});

test('settings changes are announced exactly once and only when something moved', () => {
  const dir = scratch();
  const settings = new QuillSettings(join(dir, 'settings.json'));
  let changes = 0;
  settings.on('changed', () => { changes += 1; });
  settings.set('liveText', false);
  settings.set('liveText', false);
  assert.equal(changes, 1);
});

// MARK: - Notes

test('a note takes its title from its first line', () => {
  // Nobody should have to name a thought before they are allowed to have it.
  assert.equal(noteDisplayTitle(makeNote({ body: 'Ask Carlo about the rails\nand the cloth' })),
    'Ask Carlo about the rails');
  assert.equal(noteDisplayTitle(makeNote({ title: 'Named', body: 'body' })), 'Named');
  assert.equal(noteDisplayTitle(makeNote({})), 'Untitled');
  assert.ok(noteDisplayTitle(makeNote({ body: 'x'.repeat(200) })).endsWith('…'));
});

// MARK: - Offline transform recipes

test('offline recipes do what they say and refuse when they cannot', () => {
  assert.equal(applyOfflineRecipe('none', 'anything'), null);
  assert.equal(applyOfflineRecipe('upperCase', 'hello'), 'HELLO');
  assert.equal(applyOfflineRecipe('titleCase', 'hello there'), 'Hello There');
  assert.equal(applyOfflineRecipe('bulletList', 'First thing. Second thing.'),
    '- First thing\n- Second thing');
  assert.equal(applyOfflineRecipe('numberedList', 'First thing. Second thing.'),
    '1. First thing\n2. Second thing');
});

test('re-bulleting a bullet list does not produce a double marker', () => {
  assert.equal(applyOfflineRecipe('bulletList', '- one\n- two'), '- one\n- two');
  assert.equal(applyOfflineRecipe('numberedList', '1. one\n2. two'), '1. one\n2. two');
});

test('expanding contractions also drops the filler', () => {
  // A transform that returns its input has told the user it ran. Found in a
  // live run: offline "More formal" on text with no contractions came back
  // character-identical and reported success.
  const out = applyOfflineRecipe('expandContractions', "so um we can't ship it");
  assert.ok(out !== null);
  assert.ok(out!.includes('cannot'));
  assert.ok(!out!.toLowerCase().includes(' um '));
});

// MARK: - The harvest

test('the harvest refuses names that would poison the dictionary', () => {
  // A dictionary stuffed with "src", "node-modules" and "test" is worse than an
  // empty one, because every junk entry is another chance for the corrector to
  // rewrite a word the user meant.
  for (const junk of ['src', 'node-modules', 'my-website', 'client work', 'v1.2.3', 'backup']) {
    assert.equal(harvestCandidate(junk), null, `accepted ${junk}`);
  }
  assert.equal(harvestCandidate('roman-design-co'), 'roman design co');
  assert.equal(harvestCandidate('blockcraft'), 'blockcraft');
});

// MARK: - Erase everything

test('every file the app writes is on the erase list', () => {
  // "Erase all my data" is a promise, and a promise kept by an `rm` written
  // from memory is one that quietly breaks the next time somebody adds a store.
  // This walks the source for `dataFile("…")` and fails when one is added and
  // not listed.
  const roots = ['src/core', 'src/main'];
  const named = new Set<string>();
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) { walk(path); continue; }
      if (!entry.name.endsWith('.ts')) continue;
      for (const match of readFileSync(path, 'utf8').matchAll(/dataFile\('([^']+)'\)/g)) {
        named.add(match[1]!);
      }
    }
  };
  for (const root of roots) walk(root);

  assert.ok(named.size > 0, 'the scan found no data files at all — it is not looking where it thinks');
  for (const name of named) {
    assert.ok((DATA_FILES as readonly string[]).includes(name),
      `${name} is written but is not on the erase list`);
  }
});
