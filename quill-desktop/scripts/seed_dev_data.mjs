#!/usr/bin/env node
// Fills a scratch data directory with plausible history, notes and a style
// profile, so the dashboard can be reviewed with content in it rather than ten
// empty states.
//
// Writes ONLY to $QUILL_DATA_DIR, and refuses to run without one. A seeding
// script that can reach the real folder is one bad shell history away from
// overwriting somebody's actual dictations.

import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.env.QUILL_DATA_DIR;
if (!dir) {
  console.error('Set QUILL_DATA_DIR to a scratch folder first. Refusing to touch the real one.');
  process.exit(1);
}
mkdirSync(dir, { recursive: true });

const SAMPLES = [
  ['send it to noah at kass barbers dot com dot au and tell him the frames are ready',
   'Send it to noah@kassbarbers.com.au and tell him the frames are ready.'],
  ['push the graph if I build to neglify tonight', 'Push the graphify build to Netlify tonight.'],
  ['the page loads in about one. 4 seconds on a cold cache',
   'The page loads in about 1.4 seconds on a cold cache.'],
  ['um so I think we should probably ship it on friday',
   'I think we should probably ship it on Friday.'],
  ['send it to noah no wait send it to carlo', 'Send it to Carlo.'],
  ['speaking of 4 men in the workshop this morning', 'Speaking of four men in the workshop this morning.'],
  ['every time cloudflare cashed something stale it broke the preview',
   'Every time Cloudflare cached something stale it broke the preview.'],
  ['can you check whether the deposit came through this morning',
   'Can you check whether the deposit came through this morning?'],
  ['the block craft replica needs a new chunk loader',
   'The blockcraft replica needs a new chunk loader.'],
  ['I move the whole front end over last night', 'I moved the whole front end over last night.'],
];

const DEVICES = ['MacBook Air Microphone', 'Shure MV7', null];
const now = Date.now();
const records = [];
// Not uniform: a real history is bursty, with days off. A seeded set that is
// evenly spread makes the streak card and the heatmap look like nothing they
// will ever look like on a real machine.
for (let day = 0; day < 60; day += 1) {
  if (day % 7 === 5 || day % 11 === 3) continue;
  const count = 1 + ((day * 7) % 5);
  for (let index = 0; index < count; index += 1) {
    const [raw, inserted] = SAMPLES[(day * 3 + index) % SAMPLES.length];
    const words = inserted.split(/\s+/).filter(Boolean).length;
    const audioMs = 900 + words * 340 + ((day * 37 + index * 91) % 700);
    const release = 240 + ((day * 53 + index * 29) % 900);
    records.push({
      id: `${day}-${index}-seed`,
      date: new Date(now - day * 86_400_000 - index * 3_600_000).toISOString(),
      rawText: raw,
      insertedText: inserted,
      wordCount: words,
      inputDevice: DEVICES[(day + index) % DEVICES.length],
      timings: {
        timeToFirstWordMs: 700 + ((day * 13) % 900),
        finalToInsertedMs: 20 + ((day * 7) % 60),
        endToEndMs: audioMs + release,
        audioDurationMs: audioMs,
        usedThoroughCleanup: (day + index) % 4 === 0,
        releaseToInsertedMs: release,
        micOpenMs: 90 + ((day * 3) % 120),
        speechOnsetMs: 400 + ((day * 17) % 800),
        recogniserFirstWordMs: 300 + ((day * 11) % 500),
      },
    });
  }
}
writeFileSync(join(dir, 'history.json'), JSON.stringify(records, null, 2));

writeFileSync(join(dir, 'notes.json'), JSON.stringify([
  {
    id: 'note-1', title: '', isPinned: true,
    body: 'Ask Carlo whether the reversible bedheads need a different rail for the king size, '
      + 'and whether the railroaded cloth comes in the same width.',
    created: new Date(now - 3_600_000).toISOString(),
    modified: new Date(now - 3_600_000).toISOString(),
  },
  {
    id: 'note-2', title: 'onboarding', isPinned: false,
    body: 'Stage 2 form still lets a client submit without a business name. Add the check before '
      + 'the write, not after.',
    created: new Date(now - 86_400_000).toISOString(),
    modified: new Date(now - 86_400_000).toISOString(),
  },
], null, 2));

writeFileSync(join(dir, 'style.json'), JSON.stringify({
  preset: 'casual',
  appTones: {},
  isLearningEnabled: true,
  spelling: { votes: { british: 4 }, lastObserved: new Date(now - 172_800_000).toISOString() },
  contractions: { votes: { yes: 3 }, lastObserved: new Date(now - 172_800_000).toISOString() },
  formality: { votes: {}, lastObserved: null },
  oxfordComma: { votes: { no: 2, yes: 1 }, lastObserved: new Date(now - 400_000_000).toISOString() },
  exclamations: { votes: { no: 3 }, lastObserved: new Date(now - 90_000_000).toISOString() },
  sentenceLength: { total: 268, count: 16 },
  phrasings: [
    { from: 'i would like', to: 'I want', count: 4, lastObserved: new Date(now - 200_000_000).toISOString() },
    { from: 'kind regards', to: 'Cheers', count: 3, lastObserved: new Date(now - 300_000_000).toISOString() },
    { from: 'reach out', to: 'get in touch', count: 2, lastObserved: new Date(now - 500_000_000).toISOString() },
  ],
  correctionCount: 12,
  modelAccepted: 9,
  modelReverted: 1,
  lastLearned: new Date(now - 90_000_000).toISOString(),
}, null, 2));

writeFileSync(join(dir, 'vocabulary.json'), JSON.stringify({
  terms: ['Firestore', 'Netlify', 'graphify', 'blockcraft', 'Craigieburn', 'Noah Kass',
    'nxt', 'Wispr Flow', 'TypeScript', 'SQLite', 'Cloudflare', 'Airtasker'],
}, null, 2));

console.log(`[quill] seeded ${records.length} dictations into ${dir}`);
