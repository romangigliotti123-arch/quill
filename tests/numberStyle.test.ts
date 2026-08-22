import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyNumberStyle } from '../src/core/cleanup/numberStyle';
import { FastCleaner } from '../src/core/cleanup/fastCleaner';
import { applyAppContext } from '../src/core/cleanup/appContext';
import { VocabularyCorrector } from '../src/core/cleanup/vocabularyCorrector';

// A setting for how a spoken number is written down.
//
// The recogniser already chooses, and mostly chooses well — "I'm 15 years old"
// and "6th of April, 1830" come back as digits, "one of you" and "the two
// parties" as words. So the modes that override it wholesale are the dangerous
// ones, and the default is the ordinary writing rule.
//
// Every refusal below came from a real line in the corpus. "On 6 April 1830" is
// the one that would have shipped broken — "six April 1830" — if the month
// guard were not here.

const spell = (s: string) => applyNumberStyle(s, 'spellOutSmall');
const digits = (s: string) => applyNumberStyle(s, 'alwaysDigits');
const words = (s: string) => applyNumberStyle(s, 'alwaysWords');

// A cleaner with no terms at all, so these tests measure the number rules and
// not whatever happens to be in a dictionary.
const bareCleaner = () => new FastCleaner(new VocabularyCorrector({ terms: [] }));

test('spells out a small count', () => {
  assert.equal(spell('speaking of 4 men'), 'speaking of four men');
  assert.equal(spell('Give me 5 minutes.'), 'Give me five minutes.');
  assert.equal(
    spell('Let us meet at 3 actually make that full.'),
    'Let us meet at three actually make that full.',
  );
});

test('leaves ten and above as digits', () => {
  assert.equal(spell("I'm 15 years old"), "I'm 15 years old");
  assert.equal(spell('there were 42 of them'), 'there were 42 of them');
});

test('leaves words that are already words', () => {
  assert.equal(spell('one of you'), 'one of you');
  assert.equal(spell('the two parties'), 'the two parties');
});

test('a date keeps its digits', () => {
  assert.equal(
    spell('On 6 April 1830, the church was organised'),
    'On 6 April 1830, the church was organised',
  );
  assert.equal(spell('due on May 3'), 'due on May 3');
  assert.equal(spell('Tuesday the 12th'), 'Tuesday the 12th');
  assert.equal(spell('the 6th of April'), 'the 6th of April');
});

test('a version or decimal keeps its digits', () => {
  assert.equal(spell('version 2.0 shipped'), 'version 2.0 shipped');
  assert.equal(spell('the page loads in 1.4 seconds'), 'the page loads in 1.4 seconds');
  assert.equal(spell('update to 1.2.7'), 'update to 1.2.7');
});

test('a time keeps its digits', () => {
  assert.equal(spell('meet at 5:30'), 'meet at 5:30');
  assert.equal(spell('doors at 7pm'), 'doors at 7pm');
});

test('money keeps its digits', () => {
  assert.equal(spell('it cost $5'), 'it cost $5');
  assert.equal(spell('about 5% slower'), 'about 5% slower');
});

test('an age keeps its digits', () => {
  assert.equal(spell('she is 5 years old'), 'she is 5 years old');
  assert.equal(spell('aged 7'), 'aged 7');
});

test('a numbered reference keeps its digits', () => {
  assert.equal(spell('see chapter 3'), 'see chapter 3');
  assert.equal(spell('step 2 of the guide'), 'step 2 of the guide');
  assert.equal(spell('on page 7'), 'on page 7');
});

test('an address or url keeps its digits', () => {
  assert.equal(spell('mail romangigliotti123@gmail.com'), 'mail romangigliotti123@gmail.com');
  assert.equal(spell('open localhost:3000/v2'), 'open localhost:3000/v2');
  assert.equal(spell('call 555-1234'), 'call 555-1234');
});

test('always digits turns words into numerals', () => {
  assert.equal(digits('speaking of four men'), 'speaking of 4 men');
  assert.equal(digits('twenty five people'), '25 people');
  assert.equal(digits('give me five minutes'), 'give me 5 minutes');
  assert.equal(digits('twenty five thirty six'), '25 36');
});

test('joining a tens and a unit cannot reach a structural token', () => {
  // The join that puts "twenty five" back together used to run as a regex over
  // the finished sentence, one step after the loop had skipped every structural
  // token — so it walked straight back into them.
  assert.equal(digits('the 10:30 5 minutes early'), 'the 10:30 5 minutes early');
  assert.equal(digits('version 1.20 5 times'), 'version 1.20 5 times');
  assert.equal(digits('call 555-20 5 back'), 'call 555-20 5 back');
  // And digits dictated as digits are two numbers, not one.
  assert.equal(digits('I bought 20 5 packs'), 'I bought 20 5 packs');
});

test('always words turns numerals into words', () => {
  assert.equal(words('speaking of 4 men'), 'speaking of four men');
  assert.equal(words("I'm 15 years old"), "I'm fifteen years old");
  assert.equal(words('there were 42 of them'), 'there were forty-two of them');
});

test('every mode leaves structural numbers alone', () => {
  for (const transform of [spell, digits, words]) {
    assert.equal(transform('mail noah@kassbarbers.com.au'), 'mail noah@kassbarbers.com.au');
    assert.equal(transform('version 2.0 at 5:30'), 'version 2.0 at 5:30');
  }
});

test('as heard changes nothing', () => {
  for (const sample of ['speaking of 4 men', 'one of you', "I'm 15 years old", 'give me five minutes']) {
    assert.equal(applyNumberStyle(sample, 'asHeard'), sample);
  }
});

test('a terminal keeps its digits', () => {
  // "git log -3" becoming "git log -three" is a broken command, not a style.
  assert.equal(applyAppContext('run it 3 times', 'terminal', 'spellOutSmall'), 'run it 3 times');
  assert.equal(applyAppContext('open 4 tabs', 'query', 'spellOutSmall'), 'open 4 tabs');
  assert.equal(applyAppContext('retry 3 times', 'code', 'spellOutSmall'), 'retry 3 times');
});

test('prose gets the style', () => {
  assert.equal(applyAppContext('speaking of 4 men', 'prose', 'spellOutSmall'), 'speaking of four men');
});

test('a caller with no opinion changes nothing', () => {
  assert.equal(applyAppContext('speaking of 4 men', 'prose'), 'speaking of 4 men');
});

test('the cleaner itself does not restyle numbers', () => {
  // cleanFast is the repair pass. Presentation belongs downstream, or the eval
  // rig and the model tests start measuring a preference.
  assert.equal(bareCleaner().cleanFast('speaking of 4 men'), 'Speaking of 4 men');
});
