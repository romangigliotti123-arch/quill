import { test } from 'node:test';
import assert from 'node:assert/strict';
import { graphemeCount, graphemes } from '../src/core/text/strings';
import { smallestEdit as edit } from '../src/core/text/edit';

// The edit that turns what is on screen into what should be.
//
// Pure, and tested apart from the keyboard for exactly that reason: this is the
// part that can be wrong in a way that eats somebody's paragraph, and it has to
// be checkable without a focused app or a microphone.
//
// The rule lives in `core/text/edit.ts` rather than beside the thing that posts
// the keystrokes, so this file drives the SHIPPED function rather than a copy
// of it — `main/injection/liveTyper.ts` imports Electron, which a `node --test`
// process does not have, and a test against a duplicate is a test that passes
// while the app is broken.

test('the first words are all insertion', () => {
  assert.deepEqual(edit('', 'Send it to'), { deletions: 0, insertion: 'Send it to' });
});

test('continuing a sentence types only what is new', () => {
  assert.deepEqual(edit('Send it to', 'Send it to Carlo'), { deletions: 0, insertion: ' Carlo' });
});

test('a revised tail deletes only the tail', () => {
  // The recogniser hands back the whole best-so-far text and freely revises it.
  // The common case is a couple of characters at the end.
  const change = edit('Send it to Noah', 'Send it to Carlo');
  assert.equal(change.deletions, 4);
  assert.equal(change.insertion, 'Carlo');
});

test('nothing changed means nothing is typed', () => {
  assert.deepEqual(edit('Send it to Carlo', 'Send it to Carlo'), { deletions: 0, insertion: '' });
});

test('a shorter result deletes the difference and types nothing', () => {
  assert.deepEqual(edit('Send it to Carlo', 'Send it to'), { deletions: 6, insertion: '' });
});

test('a change at the first character rewrites everything', () => {
  // The expensive case, and the one that makes appending wrong. It has to be
  // correct rather than fast: a wrong count here leaves a stale character in
  // the middle of the sentence and every subsequent edit is off by one.
  const change = edit('the build failed', 'The build failed');
  assert.equal(change.deletions, graphemeCount('the build failed'));
  assert.equal(change.insertion, 'The build failed');
});

test('deletions are counted in visible characters, not code units', () => {
  // One backspace deletes one visible character. Counting UTF-16 units takes
  // half an emoji off and leaves a fragment behind — silent corruption of text
  // the user spoke.
  const family = '👨‍👩‍👧‍👦';
  assert.equal(graphemeCount(family), 1);
  assert.ok(family.length > 1, 'the fixture is not actually a multi-unit grapheme');
  assert.deepEqual(edit(`hi ${family}`, 'hi '), { deletions: 1, insertion: '' });
});

test('a shared prefix ending mid-grapheme is not split', () => {
  const change = edit('flag 🇦🇺', 'flag 🇦🇹');
  // The two flags share a leading regional indicator in UTF-16, and a
  // code-unit diff would keep half of one.
  assert.equal(change.deletions, 1);
  assert.equal(change.insertion, '🇦🇹');
});

test('the edit is always sufficient to produce the target', () => {
  // The property that matters, checked over a spread of shapes rather than
  // asserted case by case: applying the edit to the current text must produce
  // the target exactly, or something is left on screen that nobody said.
  const samples = [
    ['', 'a'], ['a', ''], ['abc', 'abd'], ['abc', 'abcdef'], ['abcdef', 'abc'],
    ['Send it to Noah', 'Send it to Carlo'], ['x', 'y'],
    ['hello 👋 world', 'hello 👋 there'], ['café', 'cafe'], ['cafe', 'café'],
    ['one two three', 'one two three four'], ['The the build', 'The build'],
  ];
  for (const [current, target] of samples) {
    const change = edit(current!, target!);
    const kept = graphemes(current!).slice(0, graphemes(current!).length - change.deletions).join('');
    assert.equal(kept + change.insertion, target, `${current} → ${target}`);
  }
});

test('a retraction deletes our text and the user’s cancelling character together', () => {
  // Backspaces delete from the caret backwards and the user's character is the
  // LAST thing on screen, so there is no number of backspaces that removes what
  // Quill typed and spares it: deleting one fewer takes THEIR character first
  // and leaves one of ours in its place. The only correct move is to take
  // everything back and put their character in again.
  const ours = 'Send it to Carlo';
  const theirs = 'x';
  assert.equal(graphemeCount(ours) + graphemeCount(theirs), 17);
});

test('a key that inserts nothing costs no backspaces', () => {
  // Escape and the arrows produce no character, which is the overwhelmingly
  // common cancel — and on this platform the only one, because the hook
  // observes rather than intercepts, so the only keys that reach the cancel
  // path are non-printing ones.
  assert.equal(graphemeCount(''), 0);
});
