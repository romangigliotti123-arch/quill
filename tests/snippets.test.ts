import { test } from 'node:test';
import assert from 'node:assert/strict';
import { expandSnippets } from '../src/core/cleanup/snippetExpander';
import { SnippetStore, makeSnippet, snippetSeed, type Snippet } from '../src/core/stores/snippets';

// Matching is EXACT, and that is the whole design. The vocabulary corrector
// next door matches fuzzily on purpose — the worst case there is one wrong
// noun. Here the worst case is four hundred characters of a client quote
// landing in the middle of a message to someone else, and the user does not
// notice until after they hit send.

const email = makeSnippet({ phrase: 'my email', replacement: 'roman@example.com' });
const signoff = makeSnippet({
  phrase: 'sign off',
  replacement: 'Thanks,\nRoman.',
});
const standup = makeSnippet({
  phrase: 'standup',
  replacement: 'Yesterday:\nToday:\nBlocked on:',
  mode: 'alone',
});

const expand = (text: string, snippets: Snippet[] = [email, signoff, standup]): string =>
  expandSnippets(text, snippets).text;

test('fires in the middle of a sentence', () => {
  assert.equal(expand('send it to my email please'), 'send it to roman@example.com please');
});

test('capitalises the word after a replacement that ended the sentence', () => {
  // The cleaner has already run by this point — it must, or it would
  // sentence-case an email address — so a replacement ending in a full stop
  // leaves a lowercase word behind it. One character to fix.
  assert.equal(
    expand('sign off and I will follow up', [signoff]),
    'Thanks,\nRoman. And I will follow up',
  );
});

test('keeps the punctuation that followed the trigger', () => {
  // The replaced range covers the WORDS only. Eating the comma after a phrase
  // is the kind of bug that makes a feature feel unfinished.
  assert.equal(expand('use my email, then call'), 'use roman@example.com, then call');
});

test('forgives the capital the recogniser added', () => {
  assert.equal(expand('My email is the one to use'), 'roman@example.com is the one to use');
});

test('forgives punctuation inside the phrase', () => {
  // A comma the user never said is a transcription artefact, not a different
  // phrase.
  assert.equal(expand('use my, email now'), 'use roman@example.com now');
});

test('fires more than once in one utterance', () => {
  assert.equal(
    expand('my email and my email again'),
    'roman@example.com and roman@example.com again',
  );
});

test('does not fire on a near miss', () => {
  // No edit distance, no stemming, no "close enough".
  for (const said of ['my emails', 'me email', 'my e mail address']) {
    assert.equal(expand(said), said, `fired on a near miss: ${said}`);
  }
});

test('does not fire inside a longer word', () => {
  assert.equal(expand('standupright'), 'standupright');
});

test('disabled snippets never fire', () => {
  const off = { ...email, isEnabled: false };
  assert.equal(expand('send it to my email', [off]), 'send it to my email');
});

test('empty replacements never fire', () => {
  const blank = makeSnippet({ phrase: 'my email', replacement: '' });
  assert.equal(expand('send it to my email', [blank]), 'send it to my email');
});

test('the longest phrase wins', () => {
  const short = makeSnippet({ phrase: 'email', replacement: 'SHORT' });
  const long = makeSnippet({ phrase: 'my email address', replacement: 'LONG' });
  assert.equal(expand('use my email address today', [short, long]), 'use LONG today');
});

test('alone only fires when it is the whole utterance', () => {
  assert.equal(expand('standup'), 'Yesterday:\nToday:\nBlocked on:');
  // "standup" is one ordinary word: matched anywhere in a sentence it would
  // fire on "the standup is at nine" and eat the words.
  assert.equal(expand('the standup is at nine'), 'the standup is at nine');
});

test('alone beats anywhere when both could match', () => {
  const anywhere = makeSnippet({ phrase: 'standup', replacement: 'ANYWHERE' });
  assert.equal(expand('standup', [anywhere, standup]), 'Yesterday:\nToday:\nBlocked on:');
});

test('ranges point at the right text', () => {
  const result = expandSnippets('send it to my email please', [email]);
  assert.equal(result.firings.length, 1);
  const firing = result.firings[0]!;
  assert.equal('send it to my email please'.slice(firing.sourceStart, firing.sourceStart + firing.sourceLength), 'my email');
  assert.equal(result.text.slice(firing.outputStart, firing.outputStart + firing.outputLength), 'roman@example.com');
});

// MARK: - The store

test('expanding through the store counts the firing', () => {
  const store = SnippetStore.inMemory([{ ...email }]);
  assert.equal(store.expand('send it to my email'), 'send it to roman@example.com');
  const after = store.all[0]!;
  assert.equal(after.useCount, 1);
  assert.ok(after.lastUsed !== null);
});

test('an in-memory store never touches disk', () => {
  const store = SnippetStore.inMemory([{ ...email }]);
  store.upsert({ ...email, replacement: 'changed' });
  assert.equal(store.all[0]!.replacement, 'changed');
});

test('the editor owns the text and the store owns the counters', () => {
  // The editor's copy of the counters is a snapshot from whenever the row was
  // loaded, and a dictation may have fired the snippet since. Writing it back
  // whole rolls the count backwards, the ordering shuffles, and there is
  // nothing on screen to explain it.
  const store = SnippetStore.inMemory([{ ...email }]);
  const stale = { ...store.all[0]!, useCount: 0 };
  store.expand('my email');
  store.upsert({ ...stale, replacement: 'edited' });
  assert.equal(store.all[0]!.replacement, 'edited');
  assert.equal(store.all[0]!.useCount, 1, 'the use count rolled backwards');
});

test('ordering puts the one you just used on top', () => {
  const store = SnippetStore.inMemory([{ ...email }, { ...signoff }]);
  store.recordUses([signoff.id]);
  assert.equal(store.ordered[0]!.phrase, 'sign off');
});

test('the seed is a demonstration, not somebody’s life', () => {
  // It used to be the author's actual week: his email address, his studio URL,
  // his sign-off, his pricing. Useful to exactly one person and shipped to
  // everybody, so the first thing any other user had to do was delete somebody
  // else's contact details out of their own app.
  const seed = snippetSeed();
  assert.equal(seed.length, 3);
  const text = JSON.stringify(seed);
  for (const personal of ['gigliotti', 'romandesign', 'kassbarbers', 'Roman']) {
    assert.ok(!text.toLowerCase().includes(personal.toLowerCase()), `the seed names ${personal}`);
  }
  // And every trigger made of one ordinary word is `alone`, or it would fire
  // inside a sentence and eat it.
  for (const snippet of seed) {
    const words = snippet.phrase.trim().split(/\s+/).length;
    if (words === 1) {
      assert.equal(snippet.mode, 'alone', `"${snippet.phrase}" can fire mid-sentence`);
    }
  }
});
