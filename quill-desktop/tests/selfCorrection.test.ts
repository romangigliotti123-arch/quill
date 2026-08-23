import { test } from 'node:test';
import assert from 'node:assert/strict';
import { joinSpeech, tokeniseSpeech } from '../src/core/text/speechToken';
import {
  cues, needsModelPass, resolveSelfCorrection,
} from '../src/core/cleanup/selfCorrection';
import { FIXTURE_TERMS } from './fixtures';

// The deterministic half of spoken self-correction. Offline, no network, no
// model — which is also how it runs on a train, so these are not a stand-in for
// the live tests, they are the behaviour a user gets most of the time.

// MARK: - Tokens

test('tokenisation keeps punctuation beside the word rather than inside it', () => {
  const tokens = tokeniseSpeech('Send it to Noah, no wait, send it to Carlo.');
  assert.deepEqual(tokens.map((t) => t.normalised),
    ['send', 'it', 'to', 'noah', 'no', 'wait', 'send', 'it', 'to', 'carlo']);
  assert.equal(tokens[3]!.trail, ',');
  assert.equal(tokens[9]!.trail, '.');
  assert.equal(joinSpeech(tokens), 'Send it to Noah, no wait, send it to Carlo.');
});

test('normalisation ignores apostrophes so lets and Let’s compare equal', () => {
  // The model is allowed to add the apostrophe in "Let's"; that is a spelling
  // repair, not a changed word, and every check downstream depends on it.
  assert.equal(tokeniseSpeech('lets')[0]!.normalised, tokeniseSpeech("Let's")[0]!.normalised);
});

test('stray punctuation does not become a wordless token', () => {
  const tokens = tokeniseSpeech('hello — world');
  assert.deepEqual(tokens.map((t) => t.word), ['hello', 'world']);
});

// MARK: - Telling a retraction from a quotation

test('a cue after a reporting verb is quoted, not retracted', () => {
  // The whole reason this feature is not just a find-and-replace on "no wait".
  const found = cues(tokeniseSpeech('He said no wait and then walked off.'));
  assert.equal(found.length, 1);
  assert.equal(found[0]!.isRetraction, false);
});

test('a cue that is the subject of the next verb is content', () => {
  const found = cues(tokeniseSpeech('Tell them actually is spelled with two Ls.'));
  assert.ok(found.every((cue) => !cue.isRetraction));
});

test('an ordinary retraction is recognised', () => {
  const found = cues(tokeniseSpeech('Send it to Noah no wait send it to Carlo.'));
  assert.ok(found.some((cue) => cue.isRetraction));
});

test('adjacent cues are merged into one span', () => {
  // "actually" and "make that" are two cues back to back. Left separate, one of
  // them sits between the number being replaced and the number replacing it,
  // and the swap becomes invisible.
  const found = cues(tokeniseSpeech("Let's meet at 3 actually make that 4."));
  assert.equal(found.length, 1);
  assert.equal(found[0]!.start, 4);
  assert.equal(found[0]!.end, 7);
});

test('a cue at the start of the utterance retracts nothing', () => {
  const found = cues(tokeniseSpeech('Actually I think we should ship it.'));
  assert.ok(found.every((cue) => !cue.isRetraction));
});

// MARK: - The gate

test('ordinary dictation never pays for the network', () => {
  // Measured: a completion on this endpoint costs p50 284ms, which is more than
  // the whole dictation budget. Not asking is worth more than asking quickly.
  assert.equal(needsModelPass('Push the graphify build to Netlify tonight.'), false);
  assert.equal(needsModelPass("Yeah just push it and we'll see what breaks."), false);
  assert.equal(needsModelPass(''), false);
});

test('a retraction opens the gate', () => {
  assert.ok(needsModelPass('Send it to Noah no wait send it to Carlo.'));
  assert.ok(needsModelPass('The invoice is for 500 sorry 1500 dollars.'));
  assert.ok(needsModelPass('Send Carlo the invoice you know what never mind.'));
});

test('a stutter opens the gate even with no cue word', () => {
  assert.ok(needsModelPass('The the build is is failing on CI.'));
  assert.ok(needsModelPass('We should we should probably ship it tomorrow.'));
});

test('literal cue language keeps the gate shut', () => {
  // This is what makes the two cases no prompt could fix deterministic: they are
  // never sent. Measured 10/10 failures from llama-3.1-8b on both.
  assert.equal(needsModelPass('He said no wait and then walked off.'), false);
  assert.equal(needsModelPass('Tell them actually is spelled with two Ls.'), false);
  assert.equal(needsModelPass('She said sorry and I said sorry back.'), false);
});

test('legitimate doubled words are not stutters', () => {
  assert.equal(needsModelPass('I had had enough of it.'), false);
  assert.equal(needsModelPass('It was very very close.'), false);
});

// MARK: - Offline repair: the cases from the bug report

test('replaces a retracted name', () => {
  assert.equal(resolveSelfCorrection('Send it to Noah no wait send it to Carlo.'), 'Send it to Carlo.');
});

test('replaces a retracted time', () => {
  assert.equal(resolveSelfCorrection("Let's meet at 3 actually make that 4."), "Let's meet at 4.");
});

test('replaces a retracted number and keeps the unit after it', () => {
  assert.equal(
    resolveSelfCorrection('The invoice is for 500 sorry 1500 dollars.'),
    'The invoice is for 1500 dollars.',
  );
});

test('drops a restarted sentence', () => {
  assert.equal(
    resolveSelfCorrection('I was going to the I mean I went to the shop.'),
    'I went to the shop.',
  );
});

test('drops a false start', () => {
  assert.equal(
    resolveSelfCorrection('We should we should probably ship it tomorrow.'),
    'We should probably ship it tomorrow.',
  );
});

test('collapses repeated words', () => {
  assert.equal(
    resolveSelfCorrection('The the build is is failing on CI.'),
    'The build is failing on CI.',
  );
});

test('strips a trailing abandonment', () => {
  // Strips the abandonment, not the sentence. Deleting what was actually said
  // would insert nothing at all, which is indistinguishable from a crash.
  assert.equal(
    resolveSelfCorrection('Send Carlo the invoice you know what never mind.'),
    'Send Carlo the invoice.',
  );
});

test('swaps a proper noun across scratch that', () => {
  assert.equal(
    resolveSelfCorrection('Book it for Tuesday scratch that Wednesday.'),
    'Book it for Wednesday.',
  );
});

// MARK: - Offline repair: the cases it must not touch

test('leaves quoted cue language alone', () => {
  assert.equal(resolveSelfCorrection('He said no wait and then walked off.'), null);
  assert.equal(resolveSelfCorrection('Tell them actually is spelled with two Ls.'), null);
  assert.equal(resolveSelfCorrection('She said sorry and I said sorry back.'), null);
});

test('leaves ordinary dictation alone', () => {
  for (const text of [
    'Push the graphify build to Netlify tonight.',
    "Yeah just push it and we'll see what breaks.",
    'Ok so for the barber site I want the booking form on the home page.',
    'Ship the nxt onboarding build tonight.',
  ]) {
    assert.equal(resolveSelfCorrection(text), null, `mangled: ${text}`);
  }
});

test('a lone shared word is not evidence of a restart', () => {
  // "the" appears on both sides of the cue, but not at the start of the
  // utterance, so it is coincidence rather than a restart.
  assert.equal(resolveSelfCorrection('Put it on the shelf sorry the desk instead is fine.'), null);
});

test('a swap needs both sides to be the same kind of thing', () => {
  // "Tuesday" is a mid-sentence proper noun; "quickly" is not, so this is a
  // sentence rather than a swap.
  assert.equal(resolveSelfCorrection('Book it for Tuesday actually quickly if you can.'), null);
});

test('repair keeps the user’s own spelling at the start of a sentence', () => {
  // Deleting a false start can promote one of their terms to the front, and
  // "Graphify" is a different word from "graphify" — the AI guard rejects a
  // model response for exactly this, so the offline path must not commit the
  // same sin.
  const raw = 'graphify is broken no wait graphify is fine.';
  assert.equal(resolveSelfCorrection(raw, FIXTURE_TERMS), 'graphify is fine.');
  // Without the vocabulary it sentence-cases, which is the ordinary behaviour
  // and exactly what the term list is protecting against.
  assert.equal(resolveSelfCorrection(raw), 'Graphify is fine.');
});

// MARK: - It has to be cheap

test('repair is fast enough to be invisible', () => {
  // It runs before the model on every gated dictation, inside a tight budget.
  const text = 'Send it to Noah no wait send it to Carlo and tell him the the frames are ready.';

  // Warm up outside the measurement.
  for (let i = 0; i < 25; i += 1) resolveSelfCorrection(text);

  // Best of three batches, not one. A single batch shares the machine with
  // whatever else is running, and a red test that says nothing about the code
  // is worse than no test — it trains you to re-run.
  let best = Number.POSITIVE_INFINITY;
  for (let batch = 0; batch < 3; batch += 1) {
    const start = process.hrtime.bigint();
    for (let i = 0; i < 200; i += 1) resolveSelfCorrection(text);
    const perCall = Number(process.hrtime.bigint() - start) / 1e6 / 200;
    best = Math.min(best, perCall);
  }
  assert.ok(best < 2, `${best.toFixed(3)} ms per call`);
});

// MARK: - A restart begins where it was last said

test('a restart deletes only from where it actually restarted', () => {
  // The restart point is the most RECENT place those words were said. Taking
  // the first occurrence ate every clause in between — silently, on the offline
  // path, with no way for the user to know words they said had gone.
  const twoInput = 'Send it to Noah and then send it to Sam no wait send it to Carlo.';
  const two = resolveSelfCorrection(twoInput) ?? twoInput;
  assert.ok(two.toLowerCase().includes('noah'), `the un-retracted first instruction was deleted: ${two}`);
  assert.ok(two.toLowerCase().includes('carlo'));
  assert.ok(!two.toLowerCase().includes('sam'), `the retracted clause survived: ${two}`);

  // The single-word shape. The pass declines it — [add]'s LAST occurrence
  // before the cue is not the start of the utterance, so the one-word rule
  // correctly refuses to call it a restart. That leaves the retracted clause
  // in, which is not ideal; it is enormously better than deleting a clause the
  // user meant.
  const listInput = 'Add milk to the list and add bread to the list no wait add eggs to the list.';
  const list = resolveSelfCorrection(listInput) ?? listInput;
  assert.ok(list.toLowerCase().includes('milk'), `an un-retracted clause was deleted: ${list}`);
  assert.ok(list.toLowerCase().includes('eggs'));
});

test('a restart of the whole utterance still deletes all of it', () => {
  const input = 'I was going to the shop I mean I went to the market.';
  const out = resolveSelfCorrection(input) ?? input;
  assert.ok(!out.toLowerCase().includes('shop'), `the retracted opening survived: ${out}`);
  assert.ok(out.toLowerCase().includes('market'));
});
