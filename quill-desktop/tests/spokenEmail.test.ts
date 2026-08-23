import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatSpokenEmails } from '../src/core/cleanup/spokenEmail';
import { FastCleaner } from '../src/core/cleanup/fastCleaner';
import { VocabularyCorrector } from '../src/core/cleanup/vocabularyCorrector';

// Dictated email addresses arriving as prose. The real failure:
//
//   said:     "...send it to the Gmail Grace Kingston 20 at gmail.com?"
//   inserted: "...send it to the Gmail Grace Kingston 20 at gmail. Com?"
//
// The dangerous direction is a false fire. "Meet me at the shop" must never
// become an email, and neither must "I'll look at netlify.com later" — the
// guard is that the step anchors on a DOMAIN and then refuses when the word in
// front of "at" is one that ordinary English puts there.

const email = (s: string) => formatSpokenEmails(s);
const cleaner = () => new FastCleaner(new VocabularyCorrector({ terms: [] }));

test('joins a name and a dotted domain', () => {
  assert.equal(
    email('Send it to Roman Gigliotti 123 at gmail.com'),
    'Send it to romangigliotti123@gmail.com',
  );
});

test('joins a spoken domain', () => {
  assert.equal(
    email('my email is roman gigliotti at gmail dot com'),
    'my email is romangigliotti@gmail.com',
  );
});

test('keeps a dot inside the local part', () => {
  assert.equal(
    email('email me at roman dot gigliotti at outlook dot com'),
    'email me at roman.gigliotti@outlook.com',
  );
});

test('glues a domain the recogniser split in two', () => {
  assert.equal(
    email('send the invoice to noah at kass barbers dot com dot au'),
    'send the invoice to noah@kassbarbers.com.au',
  );
});

test('stops at the provider word in front of the name', () => {
  // "Gmail" here names the service, it is not part of the address — walking
  // through it would produce gmailgracekingston20@gmail.com.
  assert.equal(
    email('send it to the Gmail Grace Kingston 20 at gmail.com?'),
    'send it to the Gmail gracekingston20@gmail.com?',
  );
});

test('keeps the trailing punctuation', () => {
  assert.equal(email('is it roman at gmail dot com?'), 'is it roman@gmail.com?');
  assert.equal(email('write to roman at gmail.com.'), 'write to roman@gmail.com.');
});

test('spoken digits inside an address become digits', () => {
  assert.equal(
    email('roman gigliotti one two three at gmail dot com'),
    'romangigliotti123@gmail.com',
  );
});

test('lowercases the whole address', () => {
  assert.equal(email('Send To Noah At Gmail Dot Com'), 'Send To noah@gmail.com');
});

test('handles a country domain already dotted', () => {
  assert.equal(
    email('invoice noah at kassbarbers.com.au please'),
    'invoice noah@kassbarbers.com.au please',
  );
});

// MARK: - The false fires, which matter more

test('a place is not an email', () => {
  assert.equal(email('meet me at the shop at four'), 'meet me at the shop at four');
});

test('a verb before at refuses even with a real domain', () => {
  assert.equal(email("I'll look at gmail.com later"), "I'll look at gmail.com later");
  assert.equal(email('we looked at netlify.com yesterday'), 'we looked at netlify.com yesterday');
  assert.equal(email('it is hosted at netlify.com'), 'it is hosted at netlify.com');
});

test('a determiner before at refuses', () => {
  assert.equal(email('the docs are at three.js dot org'), 'the docs are at three.js dot org');
});

test('no domain means no email', () => {
  assert.equal(email('I am at home'), 'I am at home');
  assert.equal(email('give me five minutes at most'), 'give me five minutes at most');
});

test('a sentence boundary stops the local part', () => {
  assert.equal(email('that is done. roman at gmail dot com'), 'that is done. roman@gmail.com');
});

test('does not invent a domain from an ordinary dotted word', () => {
  assert.equal(email('the node.js version bump'), 'the node.js version bump');
});

test('talking about an address does not swallow the verb', () => {
  // Found by replaying real dictation history. The first version turned
  // "if I say Roman Gigliotti, 123, at gmail.com" into
  // "if isayromangigliotti123@gmail.com".
  assert.equal(
    email('for example, if I say Roman Gigliotti, 123, at gmail.com, it should work'),
    'for example, if I say romangigliotti123@gmail.com, it should work',
  );
});

test('an address the recogniser already built is left alone', () => {
  assert.equal(
    email('mail romangigliotti123@gmail.com now'),
    'mail romangigliotti123@gmail.com now',
  );
});

// MARK: - Through the whole cleaner

test('survives the full cleanup pipeline', () => {
  assert.equal(
    cleaner().cleanFast('send it to roman gigliotti at gmail dot com'),
    'Send it to romangigliotti@gmail.com',
  );
});

test('sentence casing does not capitalise an address', () => {
  assert.equal(
    cleaner().cleanFast('roman at gmail dot com is the address'),
    'roman@gmail.com is the address',
  );
});

test('the vocabulary corrector leaves an address alone', () => {
  const corrector = new VocabularyCorrector({ terms: ['Netlify', 'Craigieburn'] });
  assert.equal(corrector.correct('mail noah@netlifi.com now'), 'mail noah@netlifi.com now');
});

// MARK: - A noun in front of "at" is not an email address

test('talking about a website does not produce an email address', () => {
  const fast = cleaner();
  for (const said of [
    'read the docs at netlify.com',
    'my site at romangigliotti.com',
    'the booking form at kassbarbers.com.au',
    'the pricing page at netlify.com',
    'the status page at firebase.google.com',
  ]) {
    const out = fast.cleanFast(said);
    assert.ok(!out.includes('@'), `${said} → ${out}`);
  }
});

test('spoken addresses still form', () => {
  const fast = cleaner();
  for (const said of [
    'send it to noah at kassbarbers.com.au',
    'email me at roman at gmail dot com',
    'my address is romangigliotti123 at gmail dot com',
    'forward it to accounts at netlify.com',
  ]) {
    const out = fast.cleanFast(said);
    assert.ok(out.includes('@'), `an address stopped forming: ${said} → ${out}`);
  }
});
