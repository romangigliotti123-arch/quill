import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  CommandRouter, Routing, RouterMode, hasInteriorSentenceBreak, routingIsCommand,
} from '../src/core/transforms/commandRouter';
import { makeTransform, transformSeed, type Transform } from '../src/core/transforms/transforms';

// Misclassifying a command as content costs five words the user deletes.
// Misclassifying content as a command *deletes what they said* and runs a
// transform they never asked for. So the tests that matter here are the
// refusals, and most of this file is sentences that must survive being spoken
// near a command verb.

const seed = transformSeed();
const router = new CommandRouter();

const route = (
  utterance: string,
  mode: RouterMode = 'automatic',
  list: Transform[] = seed,
): Routing => router.route(utterance, list, mode);

const name = (routing: Routing): string | null =>
  (routing.decision.kind === 'transform' ? routing.decision.transform.name : null);

// MARK: - The commands that must fire

test('exact triggers fire', () => {
  assert.equal(name(route('make that a bullet list')), 'Bullet points');
  assert.equal(name(route('make it more formal')), 'More formal');
  assert.equal(name(route('summarise that')), 'Summarise');
  assert.equal(name(route('turn this into an email')), 'Email');
  assert.equal(name(route('shorten that')), 'Shorter');
  assert.equal(name(route('clean that up')), 'Fix grammar');
});

test('triggers survive what the recogniser adds and removes', () => {
  // Capitalisation, a full stop and a comma the user never said. The same
  // spoken instruction arrives all three ways across three dictations.
  assert.equal(name(route('Make that shorter.')), 'Shorter');
  assert.equal(name(route('MAKE THAT SHORTER')), 'Shorter');
  assert.equal(name(route('Make that, shorter')), 'Shorter');
});

test('polite prefixes are stripped before the verb is checked', () => {
  assert.equal(name(route('can you make that shorter')), 'Shorter');
  assert.equal(name(route('please make it more formal')), 'More formal');
  assert.equal(name(route('just summarise that')), 'Summarise');
});

test('the grammar path generalises beyond the trigger list', () => {
  // Not a trigger, but verb + referent + a keyword and nothing unaccounted for.
  const routing = route('make this a lot shorter');
  assert.equal(name(routing), 'Shorter');
  assert.equal(routing.reason.kind, 'grammarMatch');
});

test('the best keyword match wins rather than the first', () => {
  // Both list transforms match "list"; only the numbered one matches "numbered".
  assert.equal(name(route('make that a numbered list')), 'Numbered list');
  assert.equal(name(route('make that a bullet list')), 'Bullet points');
});

// MARK: - The sentences that must never be eaten

test('the self-correction idiom is not a command', () => {
  // "make that X" is the command idiom *and* the spoken-self-correction idiom.
  // Anchoring the verb to the front of the utterance is the only thing that
  // separates them, and this is the sentence that proves it.
  const routing = route('send it to Noah no wait make that Carlo');
  assert.equal(routing.decision.kind, 'content');
  assert.equal(routing.reason.kind, 'noCommandVerb');
});

test('first-person narration is not a command', () => {
  const routing = route('I need to make this shorter before Friday');
  assert.equal(routing.decision.kind, 'content');
  assert.equal(routing.reason.kind, 'noCommandVerb');
});

test('reported speech is not a command', () => {
  assert.equal(route('tell him to make it more formal').decision.kind, 'content');
  assert.equal(route('he said make it shorter').decision.kind, 'content');
  assert.equal(route('she asked me to summarise that').decision.kind, 'content');
});

test('a compound sentence is not a command', () => {
  // The instruction is real, but "mention the deposit" is content that firing
  // would silently throw away.
  const routing = route('make it more formal and mention the deposit');
  assert.equal(routing.decision.kind, 'content');
  assert.equal(routing.reason.kind, 'compoundInstruction');
  assert.equal(routing.reason.kind === 'compoundInstruction' ? routing.reason.word : '', 'and');
});

test('two sentences are never a command', () => {
  const routing = route('Make that shorter. Send it to Carlo.');
  assert.equal(routing.decision.kind, 'content');
  assert.equal(routing.reason.kind, 'moreThanOneSentence');
});

test('an abbreviation is not a sentence break', () => {
  // "e.g." and "9 a.m." are full of full stops and are not two sentences. A
  // naive scan for "." would classify half of a dictation as prose for the
  // wrong reason — right answer, wrong reason, one edit from being wrong.
  assert.equal(hasInteriorSentenceBreak('make that shorter e.g. like this'), false);
  assert.equal(hasInteriorSentenceBreak('Make that shorter. Then send it.'), true);
});

test('a verb and a referent are both required', () => {
  assert.equal(route('bullet points').reason.kind, 'noReferent');
  assert.equal(route('that was too long').reason.kind, 'noCommandVerb');
});

test('an instruction with no matching transform is typed', () => {
  // The heuristic that says "this is an instruction" is the same heuristic that
  // just failed to find a match. It does not get a second, more dangerous
  // chance — it says the words.
  const routing = route('make that a haiku');
  assert.equal(routing.decision.kind, 'content');
  assert.equal(routing.reason.kind, 'noMatchingTransform');

  assert.equal(route('turn it off').decision.kind, 'content');
  assert.equal(route('change that to Tuesday').decision.kind, 'content');
  assert.equal(route('make that clear to him').decision.kind, 'content');
});

test('leftover content blocks the grammar path', () => {
  // Verb, referent and the "list" keyword all present — and "on" is not a word
  // this router forgives, because it attaches the instruction to something else.
  const routing = route('make it the last one on the list');
  assert.equal(routing.decision.kind, 'content');
  assert.equal(routing.reason.kind, 'leftoverContent');
  assert.deepEqual(routing.reason.kind === 'leftoverContent' ? routing.reason.words : [], ['on']);
});

test('long utterances are always content', () => {
  const routing = route('make that shorter for the client before we send the quote over on Monday morning');
  assert.equal(routing.decision.kind, 'content');
  assert.equal(routing.reason.kind, 'tooLong');
});

test('quoted and literal text is always content', () => {
  assert.equal(route('make that shorter "like this"').reason.kind, 'containsQuotedOrLiteralText');
  assert.equal(route('make that romangigliotti123@gmail.com').reason.kind, 'containsQuotedOrLiteralText');
  assert.equal(route('turn that into https://example.com').reason.kind, 'containsQuotedOrLiteralText');
});

test('empty input is content', () => {
  assert.equal(route('').decision.kind, 'content');
  assert.equal(route('   \n ').reason.kind, 'empty');
});

// MARK: - The escape hatches

test('the wake word skips every guard', () => {
  // Same utterance, twice. Without the wake word it is a sentence; with it, it
  // is an instruction Quill has no transform for, and that is allowed to become
  // a free-form request precisely because the user said so.
  assert.equal(route('make that a haiku').decision.kind, 'content');

  const woken = route('Quill, make that a haiku');
  assert.equal(woken.decision.kind, 'freeform');
  assert.equal(woken.decision.kind === 'freeform' ? woken.decision.instruction : '', 'make that a haiku');
  assert.equal(woken.reason.kind, 'wakeWord');

  assert.ok(routingIsCommand(route('hey Quill make it more formal')));
});

test('the wake word keeps the instruction in the user’s own words', () => {
  // Rebuilt from the original string, not the tokens, so the model gets prose
  // rather than a lowercase word list.
  const routing = route('Quill, rewrite that as a Slack message, keep it blunt');
  assert.equal(routing.decision.kind, 'freeform');
  assert.equal(
    routing.decision.kind === 'freeform' ? routing.decision.instruction : '',
    'rewrite that as a Slack message, keep it blunt',
  );
});

test('the wake word alone does nothing', () => {
  // And in particular does not type the word "Quill" back at the user.
  assert.equal(route('Quill').decision.kind, 'content');
  assert.equal(route('Quill').reason.kind, 'empty');
});

test('explicit mode skips the guards but still prefers a known transform', () => {
  // The user held the command key. The guards answer "is this an instruction?",
  // which they have already answered.
  assert.equal(name(route('I need to make this shorter before Friday', 'explicit')), 'Shorter');

  const unknown = route('make it rhyme', 'explicit');
  assert.equal(unknown.decision.kind, 'freeform');
  assert.equal(unknown.decision.kind === 'freeform' ? unknown.decision.instruction : '', 'make it rhyme');
});

// MARK: - User-defined transforms

test('a user trigger fires without any command verb', () => {
  // The user typed this phrase into a box specifically so that saying it would
  // run this transform. That is stronger evidence than any grammar rule.
  const haiku = makeTransform({
    name: 'Haiku',
    instruction: 'Rewrite as a haiku.',
    triggers: ['haiku that'],
    keywords: ['haiku'],
  });
  const routing = route('haiku that', 'automatic', [haiku]);
  assert.equal(name(routing), 'Haiku');
  assert.equal(routing.reason.kind, 'exactTrigger');
});

test('a disabled transform never fires', () => {
  const off = transformSeed().map((transform) => ({ ...transform, isEnabled: false }));
  assert.equal(route('make that a bullet list', 'automatic', off).decision.kind, 'content');
});

test('a partial trigger is not a trigger', () => {
  // "make that" is the front of six built-in triggers and is also half of every
  // spoken correction anybody makes. Only the whole utterance counts.
  assert.equal(route('make that').decision.kind, 'content');
  assert.equal(route('no wait make that a bullet list').reason.kind, 'noCommandVerb');
});

// MARK: - The routing always carries the words

test('the spoken text survives every decision', () => {
  // Whatever the router decides, the caller can still type what was said. A
  // wrong answer here has to be recoverable, not lossy.
  for (const utterance of ['make that a bullet list', 'send it to Carlo', 'Quill, make it rhyme']) {
    assert.equal(route(utterance).spokenText, utterance);
  }
});
