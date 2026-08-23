import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  VocabularyCorrector, normalise, similarity, spanCanBe, termWordCount, phoneticSimilarity,
} from '../src/core/cleanup/vocabularyCorrector';
import { FastCleaner, capitaliseSentences } from '../src/core/cleanup/fastCleaner';
import { projectHomophones } from '../src/core/cleanup/homophoneProjection';
import { HOMOPHONE_GROUPS, HOMOPHONE_GROUP_OF, homophoneHasCandidate } from '../src/core/cleanup/homophonePairs';
import { makeHomophonePrompt } from '../src/core/ai/prompts';
import { FIXTURE_TERMS } from './fixtures';

// Every "recognised as" string below is real output from a speech recogniser on
// real audio, not an invented example.
const VOCAB = [
  'graphify', 'Netlify', 'Craigieburn', 'Firestore', 'Vesper',
  'blockcraft', 'Nebula', 'nxt', 'Next Fulfilment', 'Quill',
];
const corrector = () => new VocabularyCorrector({ terms: VOCAB });
const fixture = () => new VocabularyCorrector({ terms: FIXTURE_TERMS });
const fixtureCleaner = () => new FastCleaner(fixture());
const bareCleaner = () => new FastCleaner(new VocabularyCorrector({ terms: [] }));

test('repairs a word the recogniser split in three', () => {
  // Actual failure: "Push the graphify build" -> "Push the graph if I build"
  assert.equal(corrector().correct('Push the graph if I build'), 'Push the graphify build');
});

test('repairs a misspelled proper noun', () => {
  assert.equal(corrector().correct('deploy the neglify build'), 'deploy the Netlify build');
});

test('repairs a place name split in two', () => {
  assert.equal(corrector().correct('until Craig Eburn is done'), 'until Craigieburn is done');
});

test('keeps punctuation attached to the corrected word', () => {
  assert.equal(corrector().correct('check neglify, then stop'), 'check Netlify, then stop');
});

test('leaves ordinary English alone', () => {
  const sentence = 'I need to send the invoice by Friday and then go home';
  assert.equal(corrector().correct(sentence), sentence);
});

test('does not rewrite a real word that merely resembles a term', () => {
  // "nebula" the astronomical term is a real word; do not force the project
  // casing onto unrelated prose, and never turn "next" into "nxt".
  assert.equal(corrector().correct('the next meeting'), 'the next meeting');
});

test('does not invent matches for short tokens', () => {
  assert.equal(corrector().correct('go to it'), 'go to it');
});

test('similarity is symmetric and bounded', () => {
  assert.equal(similarity('graphify', 'graphify'), 1.0);
  assert.equal(similarity('', 'abc'), 0.0);
  const a = similarity('craigeburn', 'craigieburn');
  assert.ok(a > 0.85 && a < 1.0, `got ${a}`);
});

test('normalise strips everything but letters', () => {
  assert.equal(normalise('Graph if I!'), 'graphifi');
});

// MARK: - Spoken decimals

test('a spoken decimal is not a sentence boundary', () => {
  assert.equal(
    bareCleaner().cleanFast('the page loads in about one. 4 seconds on a cold cache'),
    'The page loads in about 1.4 seconds on a cold cache',
  );
  assert.equal(
    bareCleaner().cleanFast('version one. 2.7 went out this morning'),
    'Version 1.2.7 went out this morning',
  );
  assert.equal(
    bareCleaner().cleanFast('we cut version two. 0 last night'),
    'We cut version 2.0 last night',
  );
});

test('a real sentence ending in a number is left alone', () => {
  assert.equal(
    bareCleaner().cleanFast('it shipped in 2020. 3 people worked on it'),
    'It shipped in 2020. 3 people worked on it',
  );
  assert.equal(
    bareCleaner().cleanFast('call him back. he is waiting'),
    'Call him back. He is waiting',
  );
});

test('a decimal point does not arm the next capital', () => {
  assert.equal(capitaliseSentences('that costs 4.5 dollars'), 'That costs 4.5 dollars');
  assert.equal(capitaliseSentences('the build is 1.2 megabytes now'), 'The build is 1.2 megabytes now');
  assert.equal(capitaliseSentences('done. next one'), 'Done. Next one');
  // A sentence that opens with a number opens with a number; nothing later in
  // it gets promoted instead.
  assert.equal(capitaliseSentences('done. 3 people are waiting'), 'Done. 3 people are waiting');
});

test('the two names that failed in real voice', () => {
  // "Wispr Flow stores every transcript in a local SQLite database" came back
  // "Whisperflow stores every transcript in a local SQ light database".
  assert.ok(
    fixtureCleaner()
      .cleanFast('Whisperflow stores every transcript in a local database')
      .includes('Wispr Flow'),
  );
});

// MARK: - The corrector must not rewrite sentences into brand names

test('an ordinary English phrase is never rewritten into a term', () => {
  // Both of these shipped, in the DEFAULT seed vocabulary, and both were found
  // by running the real corrector rather than reading it.
  const c = fixture();
  for (const sentence of [
    'I need to build a bed for the spare room',
    'he asked me to build a bed and I did',
    'we build a bed every week',
    'the Roman design cost a lot more than I thought',
    'we know the Roman design cost too much',
  ]) {
    assert.equal(c.correct(sentence), sentence, `rewrote ordinary English: ${c.correct(sentence)}`);
  }
});

test('every repair measured on real voice still fires', () => {
  const c = fixture();
  assert.ok(c.correct('push it to Netterfly tonight').includes('Netlify'));
  assert.ok(c.correct('the grapify workspace is fine').includes('graphify'));
  assert.ok(c.correct('run graph if I over the folder').includes('graphify'));
  assert.ok(c.correct('the block craft replica').includes('blockcraft'));
  assert.ok(c.correct('the fire store rules are open').includes('Firestore'));
  assert.ok(c.correct('send it to Noah Kess').includes('Noah Kass'));
  assert.ok(c.correct('until Craig Eburn is done').includes('Craigieburn'));
  // A single span word is the recogniser GLUING a name together, which is the
  // same failure as splitting one and has to stay reachable.
  assert.ok(c.correct('Whisperflow stores every transcript').includes('Wispr Flow'));
});

test('a multi-word term needs a matching number of spoken words', () => {
  assert.equal(spanCanBe(termWordCount('Builda Bed'), 3), false);
  assert.ok(spanCanBe(termWordCount('Builda Bed'), 2));
  assert.ok(spanCanBe(termWordCount('Builda Bed'), 1));
  assert.ok(spanCanBe(termWordCount('graphify'), 3));
  assert.ok(spanCanBe(termWordCount('Firestore'), 2));
});

// MARK: - Manglings the fuzzy corrector cannot reach

test('anchored corrections fix what the guards correctly refuse', () => {
  const cleaner = bareCleaner();
  assert.ok(cleaner.cleanFast('the API has no course headers').includes('CORS headers'));
  assert.ok(cleaner.cleanFast('a local SQ light database').includes('SQLite'));
  assert.ok(cleaner.cleanFast('Vespa is the lunar style rapper').startsWith('Vesper'));
  assert.ok(cleaner.cleanFast('push it to neglified tonight').includes('Netlify'));
});

test('the ordinary meanings of those words survive', () => {
  const cleaner = bareCleaner();
  for (const sentence of [
    'of course I will send it tomorrow',
    'the course was harder than I expected',
    'he rode a Vespa around Rome',
    'turn the light off please',
  ]) {
    const out = cleaner.cleanFast(sentence);
    const expected = sentence.slice(0, 1).toUpperCase() + sentence.slice(1);
    assert.equal(out, expected, `rewrote an ordinary sentence: ${out}`);
  }
});

// MARK: - Sound is only evidence when the spelling agrees

test('sound is only evidence when the spelling agrees', () => {
  // "y t dlp" — the recogniser spelling out yt-dlp — was being replaced by
  // "Netlify". The two share 0.143 of their letters.
  const c = fixture();
  assert.equal(c.correct('run y t dlp on that playlist'), 'run y t dlp on that playlist');
  // and every phonetic repair still fires
  assert.ok(c.correct('push it to Netterfly tonight').includes('Netlify'));
  assert.ok(c.correct('until Craig Eburn is done').includes('Craigieburn'));
  assert.ok(c.correct('the grapify workspace').includes('graphify'));
});

test('the harvested terms repair the split compound failure', () => {
  const c = fixture();
  assert.ok(c.correct('open the media deck sidebar').includes('mediadeck'));
  assert.ok(c.correct('the t mux panes persist').includes('tmux'));
  assert.ok(c.correct('check the shad cn components').includes('shadcn'));
  assert.ok(c.correct('the space grotesk heading').includes('Space Grotesk'));
});

// Heard in a real dictation. The recogniser produced
//
//     "The client found me on Air Tasker. He's been discreet about budget"
//
// and what was typed into the document was
//
//     "The client found me on Airtasker been discreet about budget"
test('does not swallow a pronoun after a name', () => {
  const c = new VocabularyCorrector({ terms: ['Airtasker'] });
  assert.equal(
    c.correct("found me on Air Tasker. He's been discreet"),
    "found me on Airtasker. He's been discreet",
  );
});

test('does not swallow other pronouns either', () => {
  const c = new VocabularyCorrector({ terms: ['Airtasker'] });
  const cases: [string, string][] = [
    ['I put it on Air Tasker they replied fast', 'I put it on Airtasker they replied fast'],
    ['posted to Air Tasker she got back to me', 'posted to Airtasker she got back to me'],
    ['listed on Air Tasker we waited a week', 'listed on Airtasker we waited a week'],
    ['up on Air Tasker you can see it', 'up on Airtasker you can see it'],
  ];
  for (const [input, expected] of cases) {
    assert.equal(c.correct(input), expected, `got: ${c.correct(input)}`);
  }
});

// MARK: - Homophone pass
//
// The projection is the safety property of the whole homophone pass, so most of
// these are about what it REFUSES.

test('homophone projection takes a legal swap', () => {
  const input = 'every time Cloudflare cashed something stale';
  const model = 'every time Cloudflare cached something stale';
  assert.equal(projectHomophones(model, input), 'every time Cloudflare cached something stale');
});

test('homophone projection keeps the input casing and punctuation', () => {
  const input = 'Flower, and water. Nothing else!';
  const model = 'flour and water nothing else';
  assert.equal(projectHomophones(model, input), 'Flour, and water. Nothing else!');
});

test('homophone projection refuses a word that is not on the list', () => {
  const input = 'the flower shop was closed';
  const model = 'the flour shop was shut';  // "closed" -> "shut" is not ours to make
  assert.equal(projectHomophones(model, input), null);
});

test('homophone projection refuses any change of length', () => {
  const input = 'the flower shop was closed';
  assert.equal(projectHomophones('the flour shop was closed today', input), null);
  assert.equal(projectHomophones('the flour shop closed', input), null);
});

test('homophone projection refuses a swap outside the words own group', () => {
  const input = 'the flower shop';
  assert.equal(projectHomophones('the week shop', input), null);
});

test('homophone projection reports nothing when nothing changed', () => {
  const input = 'the flour was fine';
  assert.equal(projectHomophones('the flour was fine', input), null);
});

test('homophone projection refuses an explanation', () => {
  const input = 'the flower shop';
  const model = 'the flour shop\n\nI changed flower to flour because you meant the ingredient.';
  assert.equal(projectHomophones(model, input), null);
});

test('homophone gate stays off for ordinary sentences', () => {
  assert.ok(!homophoneHasCandidate('push the build and tell the client it is done'));
  assert.ok(homophoneHasCandidate('every time Cloudflare cashed something stale'));
});

test('homophone prompt names only the live choices', () => {
  const prompt = makeHomophonePrompt('the flower was discrete');
  assert.ok(prompt !== null);
  assert.ok(prompt!.system.includes('flower: flour (the baking ingredient) / flower (the plant)'));
  assert.ok(prompt!.system.includes('discrete: discreet (careful not to attract attention)'));
  assert.ok(!prompt!.system.includes('stationery'));
  assert.equal(makeHomophonePrompt('nothing on the list here at all'), null);
});

test('every homophone group is well formed', () => {
  for (const group of HOMOPHONE_GROUPS) {
    assert.ok(group.length >= 2, `a group of one can never be a choice: ${group}`);
    assert.equal(new Set(group).size, group.length, `duplicate inside a group: ${group}`);
    for (const word of group) {
      assert.equal(
        HOMOPHONE_GROUP_OF.get(word.toLowerCase())?.size,
        new Set(group).size,
        `${word} was overwritten by another group — the lists overlap`,
      );
    }
  }
});

// MARK: - The detector that will not work
//
// The tempting design is to use the phonetic scorer as a cheap detector — flag
// anything that sounds like a term, let a model decide. This measures why that
// fails: ordinary English reaches 1.00 against the seed vocabulary ("not leave"
// -> Netlify), while the real manglings sit at 0.75-0.86. There is no threshold
// between them.
//
// Pinned as a REFUSAL, not an aspiration. If someone tightens the scorer and
// this drops, the design becomes worth revisiting — and this test failing is
// how they will find out.
test('a loose detector would fire on most ordinary English', () => {
  const sentences = [
    'I need to send the invoice by Friday and then go home',
    'the client wants the booking form on its own page',
    'can you check whether the deposit came through this morning',
    'we should meet at four and go over the quote together',
    'the frames are ready but the fabric has not arrived yet',
    'tell him the job will take about three weeks from now',
    'I had to get hub caps for the car on the way back',
    'she said the colour looked too dark on the phone screen',
    'put the address on the second line of the letter',
    'there is a fly in the kitchen and it will not leave',
    'the tail wind helped us get there before the rain',
    'he was born in the same year as my father was',
  ];
  let flagged = 0;
  for (const sentence of sentences) {
    const words = sentence.split(' ');
    let hit = false;
    for (let width = 1; width <= 3 && !hit; width += 1) {
      for (let start = 0; start + width <= words.length && !hit; start += 1) {
        const a = normalise(words.slice(start, start + width).join(' '));
        if (a.length < 3) continue;
        for (const term of FIXTURE_TERMS) {
          const b = normalise(term);
          if (b.length < 3) continue;
          if (phoneticSimilarity(a, b) >= 0.7) { hit = true; break; }
        }
      }
    }
    if (hit) flagged += 1;
  }
  assert.ok(
    flagged > sentences.length / 2,
    `only ${flagged} of ${sentences.length} flagged — the scorer may have tightened enough that a detector-plus-model pass is worth rebuilding`,
  );
});

// MARK: - Punctuation the user said survives a repair

test('a repair never spans a full stop or comma', () => {
  const cleaner = bareCleaner();
  assert.ok(
    cleaner.cleanFast('Ship the code. Sign the release before you go').includes('code.'),
    'a full stop inside a span was eaten',
  );
  assert.ok(
    !cleaner.cleanFast('Ship the code. Sign the release before you go').toLowerCase().includes('codesign'),
  );
  assert.ok(
    cleaner.cleanFast('pushed the code, sign off').includes('code,'),
    'a comma inside a span was eaten',
  );
});

test('a repair keeps the quote or bullet in front of the word', () => {
  const c = new VocabularyCorrector({ terms: ['Netlify', 'Firestore'] });
  const quoted = c.correct('he said "netlify" was down');
  assert.ok(quoted.includes('"Netlify"'), `lost the opening quote: ${quoted}`);
  const bulleted = c.correct('- netlify is down');
  assert.ok(bulleted.startsWith('- '), `lost the bullet: ${bulleted}`);
  assert.ok(bulleted.includes('Netlify'));
});

test('a stray dash between words is not eaten by a repair', () => {
  const c = new VocabularyCorrector({ terms: ['Netlify'] });
  const out = c.correct('I checked - netlify was down');
  assert.ok(out.includes('-'), `the dash was swallowed: ${out}`);
  assert.ok(out.includes('Netlify'));
});
