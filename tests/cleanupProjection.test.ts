import { test } from 'node:test';
import assert from 'node:assert/strict';
import { projectCleanup } from '../src/core/cleanup/cleanupProjection';
import { resolveSelfCorrection } from '../src/core/cleanup/selfCorrection';
import { FastCleaner } from '../src/core/cleanup/fastCleaner';
import { VocabularyCorrector } from '../src/core/cleanup/vocabularyCorrector';
import { AICleaner } from '../src/core/ai/aiCleaner';
import { CLEANUP_PROMPT } from '../src/core/ai/prompts';
import type { AICompleting } from '../src/core/ai/nimClient';
import { FIXTURE_TERMS } from './fixtures';

// What comes back from the model, checked against what went in.
//
// The interesting tests here are the miserable ones — the model hangs, returns
// an essay, or quietly rewrites a sentence to the same length — and none of
// those can be provoked against a real endpoint on demand. So the client is a
// fake, and every one of these is a refusal that keeps a sentence the user did
// not say out of a document Quill cannot read back.

const vocabulary = FIXTURE_TERMS;
const project = (raw: string, input: string) => projectCleanup(raw, input, vocabulary);
const bare = () => new FastCleaner(new VocabularyCorrector({ terms: [] }));

// MARK: - A bad answer is refused

test('refuses a model that answered the dictation instead of editing it', () => {
  const input = 'Send it to Noah no wait send it to Carlo.';
  const essay = "Sure! Here is what I'd send: Hi Carlo, just letting you know the bed frames "
    + 'are ready for collection whenever suits you. Cheers.';
  assert.equal(project(essay, input), null);
});

test('refuses a model that improved the prose', () => {
  // Same length, same meaning, not their words. A length ratio cannot see this;
  // the delete-only alignment can. Observed from llama-3.1-8b on a real
  // transcript: "I want" became "I'd like" and "barber site" became "barber
  // shop".
  const input = 'Ok so for the barber site I want the booking form on the home page, no wait, on its own page.';
  const polished = "For the barber shop I'd like the booking form to be on its own separate page.";
  assert.equal(project(polished, input), null);
});

test('refuses a summary', () => {
  const input = 'Send it to Noah no wait send it to Carlo and tell him the bed frames are ready.';
  assert.equal(project('Bed frames ready.', input), null);
});

test('refuses a pleasantry the speaker never said', () => {
  const input = 'Send it to Noah no wait send it to Carlo.';
  assert.equal(project('Please send it to Carlo.', input), null);
  assert.equal(project('Send it to Carlo, thanks!', input), null);
});

test('refuses reordered words', () => {
  const input = 'Send it to Noah no wait send it to Carlo.';
  assert.equal(project('Carlo, send it to him.', input), null);
});

test('refuses a deletion with no reason behind it', () => {
  // The clause has no cue in it, is not a repeat, and is not filler. Dropping it
  // is the model deciding what matters, which is not its job.
  const input = 'Send it to Carlo and tell him the bed frames are ready.';
  assert.equal(project('Send it to Carlo.', input), null);
});

test('refuses to act on a cue that was literal content', () => {
  // The mixed case: one real correction gets the transcript past the gate, and
  // the model then also eats the quoted one. The gate cannot catch this; the
  // deletion check can.
  const input = 'He said no wait and then he left, sorry, and then he called.';
  assert.equal(project('He and then he called.', input), null);
});

test('refuses runaway length', () => {
  const input = 'Send it to Carlo.';
  assert.equal(project('Send it to Carlo. '.repeat(20), input), null);
});

test('refuses commentary around the answer', () => {
  const input = 'Send it to Noah no wait send it to Carlo.';
  assert.equal(project('Here you go.\n\nSend it to Carlo.', input), null);
});

// MARK: - Shape repairs it does accept

test('unwraps quotes, labels and fences the way real models emit them', () => {
  const input = 'Send it to Noah no wait send it to Carlo.';
  for (const wrapped of [
    '"Send it to Carlo."',
    'Cleaned text: Send it to Carlo.',
    '```\nSend it to Carlo.\n```',
  ]) {
    assert.equal(project(wrapped, input), 'Send it to Carlo.', `failed on ${wrapped}`);
  }
});

test('allows the model to add an apostrophe', () => {
  // "lets" → "Let's" is a spelling repair, not a changed word.
  const input = 'Lets meet at 3 actually make that 4.';
  assert.equal(project("Let's meet at 4.", input), "Let's meet at 4.");
});

test('allows the opening throat-clearing to go', () => {
  const input = 'Ok so send it to Noah no wait send it to Carlo.';
  assert.equal(project('Ok send it to Carlo.', input), 'Ok send it to Carlo.');
  assert.equal(project('Send it to Carlo.', input), 'Send it to Carlo.');
});

test('refuses to delete a discourse word from inside a sentence', () => {
  // "like", "so" and "right" open a sentence and mean nothing; in the middle of
  // one they are ordinary words. Licensing their deletion anywhere licenses it
  // there, so the licence stops at the first real word.
  const input = 'Book it for Tuesday no wait for Wednesday because I like that day.';
  assert.equal(project('Book it for Wednesday because I that day.', input), null);
  const other = 'Do it right now no wait do it tomorrow.';
  assert.equal(project('Do it now do it tomorrow.', other), null);
});

test('accepts the merge the model actually makes', () => {
  // Measured 5 times out of 5. Only "to Noah" was retracted, so the noun phrase
  // from before the cue and the recipient from after it are both kept and the
  // redundant "send it" goes. Two words of the settled half disappear, which is
  // why the tail guard is an overreach cap and not a percentage.
  const input = 'Send the nxt invoice to Noah no wait send it to Carlo.';
  assert.equal(project('Send the next invoice to Carlo.', input), 'Send the nxt invoice to Carlo.');
});

test('refuses a summary that eats the settled half', () => {
  // The shape a fraction-of-the-whole-sentence floor could not tell apart from
  // a legitimate retraction: both delete most of the input. This one reaches
  // seven words past the cue; the merge above reaches two.
  const input = 'Send it to Noah no wait send it to Carlo and tell him the bed frames are ready.';
  assert.equal(project('The bed frames are ready.', input), null);
});

// MARK: - Vocabulary

test('puts the user’s spelling back when the model normalised it', () => {
  // Measured 10 times out of 10 on the live endpoint: the model turns "nxt"
  // into "next". Rejecting the whole response for it would mean self-correction
  // never works in a sentence containing one of their words.
  const input = 'Ship the nxt build on Monday I mean on Tuesday.';
  assert.equal(project('Ship the next build on Tuesday.', input), 'Ship the nxt build on Tuesday.');
  // And the casing of a term is the term: "Graphify" is not "graphify".
  const cased = 'Push the graphify build no wait push the Netlify build.';
  assert.equal(project('Push the Netlify build.', cased), 'Push the Netlify build.');
});

test('a term that was never said is never introduced', () => {
  // The measured prompt failure this whole design exists to prevent: an earlier
  // variant lifted "Builda Bed" out of the prompt into a sentence that never
  // mentioned it. There is no word list in the prompt now, and even if there
  // were, a word not in the input cannot align.
  const input = 'Send it to Noah no wait send it to Carlo, the frames are ready.';
  assert.equal(project('Carlo, the Builda Bed frames are ready.', input), null);
});

test('the cleanup prompt still carries no word list', () => {
  for (const term of ['Builda Bed', 'Craigieburn', 'graphify', 'Firestore', 'nxt', 'Netlify']) {
    assert.ok(!CLEANUP_PROMPT.system.includes(term), `the prompt names ${term}`);
  }
});

test('the prompt is versioned', () => {
  // The version travels with the output so a complaint about quality can be
  // traced to the text that produced it.
  assert.equal(CLEANUP_PROMPT.version, 1);
  assert.ok(CLEANUP_PROMPT.system.length > 0);
});

// MARK: - The cleaner around it

class FakeClient implements AICompleting {
  readonly isConfigured: boolean;
  readonly isReadyToTry: boolean;
  calls = 0;

  constructor(
    private readonly behaviour: { kind: 'hangs' } | { kind: 'returns'; text: string },
    options: { configured?: boolean; ready?: boolean } = {},
  ) {
    this.isConfigured = options.configured ?? true;
    this.isReadyToTry = options.ready ?? true;
  }

  async complete(): Promise<string> {
    this.calls += 1;
    if (this.behaviour.kind === 'hangs') {
      // Longer than any deadline the app uses. The point is that the CALLER
      // does not wait for it — and `unref` so an abandoned racer cannot hold
      // the test process open, which is the same reason the real deadline
      // abandons its loser rather than awaiting it.
      await new Promise((resolve) => { setTimeout(resolve, 3_000).unref?.(); });
      return '';
    }
    return this.behaviour.text;
  }
}

const cleanerWith = (client: AICompleting): AICleaner => new AICleaner({
  client,
  fast: bare(),
  vocabulary,
  style: () => ({
    preset: 'neutral', appTones: {}, isLearningEnabled: false,
    spelling: { votes: {}, lastObserved: null },
    contractions: { votes: {}, lastObserved: null },
    formality: { votes: {}, lastObserved: null },
    oxfordComma: { votes: {}, lastObserved: null },
    exclamations: { votes: {}, lastObserved: null },
    sentenceLength: { total: 0, count: 0 },
    phrasings: [], correctionCount: 0, modelAccepted: 0, modelReverted: 0, lastLearned: null,
  }),
  contextRecovery: () => false,
});

const DEADLINE = 450;

test('a model that hangs does not hang the dictation', async () => {
  const started = Date.now();
  const out = await cleanerWith(new FakeClient({ kind: 'hangs' }))
    .cleanThorough('send it to Noah no wait send it to Carlo', DEADLINE);
  const elapsed = Date.now() - started;
  // The deterministic answer ships, and it ships on time.
  // No trailing full stop in the input, so none in the output — the cleaner
  // adds punctuation it can justify and nothing else.
  assert.equal(out, 'Send it to Carlo');
  assert.ok(elapsed < DEADLINE + 400, `waited ${elapsed}ms`);
});

test('a deadline too short to be worth asking skips the network entirely', async () => {
  const client = new FakeClient({ kind: 'returns', text: 'Ring the electrician instead.' });
  const out = await cleanerWith(client)
    .cleanThorough('call the plumber no wait ring the electrician instead', 60);
  assert.equal(client.calls, 0, 'spent a request it could not possibly finish');
  // The offline resolver has nothing to anchor on here, so nothing comes back.
  assert.equal(out, null);
});

test('no key is not an error and not a wait', async () => {
  const client = new FakeClient({ kind: 'hangs' }, { configured: false });
  const out = await cleanerWith(client)
    .cleanThorough('send it to Noah no wait send it to Carlo', DEADLINE);
  assert.equal(client.calls, 0);
  assert.equal(out, 'Send it to Carlo');
});

test('an open circuit breaker is honoured without calling the model', async () => {
  const client = new FakeClient({ kind: 'hangs' }, { ready: false });
  await cleanerWith(client).cleanThorough('send it to Noah no wait send it to Carlo', DEADLINE);
  assert.equal(client.calls, 0);
});

test('ordinary dictation never reaches the model', async () => {
  const client = new FakeClient({ kind: 'returns', text: 'anything at all' });
  const out = await cleanerWith(client)
    .cleanThorough('push the build to Netlify tonight', DEADLINE);
  assert.equal(client.calls, 0);
  assert.equal(out, null);
});

test('literal cue language never reaches the model either', async () => {
  const client = new FakeClient({ kind: 'returns', text: 'He walked off.' });
  await cleanerWith(client).cleanThorough('he said no wait and then walked off', DEADLINE);
  assert.equal(client.calls, 0);
});

test('a clean model answer is preferred over the offline one', async () => {
  // Something the rules cannot do: a correction with no repeated run and no
  // type-compatible swap to anchor on.
  const raw = 'call the plumber no wait ring the electrician instead';
  assert.equal(resolveSelfCorrection(bare().cleanFast(raw)), null);
  const out = await cleanerWith(new FakeClient({ kind: 'returns', text: 'Ring the electrician instead.' }))
    .cleanThorough(raw, DEADLINE);
  assert.equal(out, 'Ring the electrician instead.');
});

test('a model answer identical to the input is no answer at all', async () => {
  const raw = 'call the plumber no wait ring the electrician instead';
  const tidy = bare().cleanFast(raw);
  const out = await cleanerWith(new FakeClient({ kind: 'returns', text: tidy }))
    .cleanThorough(raw, DEADLINE);
  assert.equal(out, null);
});

test('cleanFast is unchanged from the deterministic cleaner', () => {
  // The AI cleaner replaces the fast one in the coordinator, so the fast path it
  // exposes has to be the same fast path, byte for byte.
  const raw = 'um so push the graph if I build to neglify';
  assert.equal(
    cleanerWith(new FakeClient({ kind: 'hangs' })).cleanFast(raw),
    bare().cleanFast(raw),
  );
});
