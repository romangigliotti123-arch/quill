import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  applyDeterministically, freshProfile, introducedTells, promptRules, settled,
  styleSanitise, styleSummaryLine, traitValue, recordTrait, emptyTrait, VOTE_CEILING,
  makePhrasing, phrasingIsApplicable, addSample, meanAverage,
} from '../src/core/style/styleProfile';
import { learnStyle, observeStyle, diffSegments, tokensOf } from '../src/core/style/styleLearner';
import { spellingConvention, toBritish } from '../src/core/style/orthography';
import { computeInsights, percentile, alignForFixes } from '../src/core/insights/insightsMetrics';
import { InsightsFormat } from '../src/core/insights/insightsFormat';
import type { DictationRecord } from '../src/core/stores/history';
import { uuid } from '../src/core/stores/storeFile';

// MARK: - Orthography

test('british spelling is recognised only where it is unambiguous', () => {
  // "advise", "surprise" and "raise" are spelled that way on both sides of the
  // Atlantic, so a detector that reads any "-ise" as British evidence would
  // find British habits in every writer alive.
  assert.equal(spellingConvention('colour'), 'british');
  assert.equal(spellingConvention('centre'), 'british');
  assert.equal(spellingConvention('organisation'), 'british');
  assert.equal(spellingConvention('color'), 'american');
  assert.equal(spellingConvention('organize'), 'american');
  for (const ambiguous of ['advise', 'surprise', 'raise', 'promise', 'exercise', 'the']) {
    assert.equal(spellingConvention(ambiguous), null, `${ambiguous} was read as evidence`);
  }
});

test('the conversion leaves anything that is not prose alone', () => {
  // A URL, a file name or an identifier that happens to contain "ize" is not a
  // spelling mistake.
  assert.equal(toBritish('normalize the color'), 'normalise the colour');
  assert.equal(toBritish('Normalization.ts'), 'Normalization.ts');
  assert.equal(toBritish('https://example.com/customize'), 'https://example.com/customize');
  // And a word at the end of a sentence still converts — testing the whole
  // token instead of its core refused every one of them.
  assert.equal(toBritish('pick a color.'), 'pick a colour.');
});

test('the conversion does not break words British English spells the American way', () => {
  for (const word of ['humorous', 'vigorous', 'honorary', 'laborious', 'size', 'prize', 'seize']) {
    assert.equal(toBritish(word), word, `broke ${word}`);
  }
});

// MARK: - Traits

test('a trait needs support and confidence before it counts', () => {
  const profile = freshProfile();
  recordTrait(profile.spelling, 'british', new Date());
  assert.equal(settled(profile, profile.spelling), null, 'one observation settled a trait');
  recordTrait(profile.spelling, 'british', new Date());
  assert.equal(settled(profile, profile.spelling), 'british');
});

test('a trait can be argued out of', () => {
  // People change, and a preference learned in March should not need until
  // December to unlearn. Each vote also takes one off every rival.
  const trait = emptyTrait();
  for (let i = 0; i < VOTE_CEILING; i += 1) recordTrait(trait, 'british', new Date());
  assert.equal(traitValue(trait), 'british');
  for (let i = 0; i < VOTE_CEILING; i += 1) recordTrait(trait, 'american', new Date());
  assert.equal(traitValue(trait), 'american');
});

test('a genuine tie is unknown, not a coin toss', () => {
  const trait = emptyTrait();
  trait.votes.british = 2;
  trait.votes.american = 2;
  assert.equal(traitValue(trait), null);
});

test('a running mean forgets', () => {
  // Sentence length is a habit, not a constant. An average taken over every
  // dictation since installation stops responding to the writer in month two.
  //
  // What it actually is, stated rather than implied: once the sample ceiling is
  // reached each new sample drops one sample's worth AT THE CURRENT MEAN, which
  // makes it an exponential moving average rather than a hard window. So it
  // never snaps to a new habit — it converges on one, most of the way inside a
  // window's worth of samples and effectively all the way inside three. That is
  // the right shape for a habit: a week of unusually short sentences should move
  // it, not replace it.
  const mean = { total: 0, count: 0 };
  for (let i = 0; i < 60; i += 1) addSample(mean, 10);
  assert.equal(mean.count, 40, 'the window did not stop growing');
  assert.equal(meanAverage(mean), 10);

  for (let i = 0; i < 40; i += 1) addSample(mean, 30);
  const afterOneWindow = meanAverage(mean)!;
  assert.ok(afterOneWindow > 20 && afterOneWindow < 25,
    `one window of the new habit should move it most of the way, got ${afterOneWindow}`);

  for (let i = 0; i < 80; i += 1) addSample(mean, 30);
  assert.ok(Math.abs(meanAverage(mean)! - 30) < 1,
    `three windows should be effectively all the way, got ${meanAverage(mean)}`);
});

// MARK: - Learning

test('one correction is one vote per trait', () => {
  // A paragraph containing "colour" four times is one piece of evidence about
  // spelling, not four. Without that rule a single long email settles the whole
  // profile and the tally stops meaning what it says.
  const before = freshProfile();
  const after = learnStyle(
    'the color of the color of the color of the color',
    'the colour of the colour of the colour of the colour',
    before,
  );
  assert.equal(after.spelling.votes.british, 1);
  assert.equal(after.correctionCount, 1);
});

test('formality is learned only from a swap the user actually made', () => {
  // The trait most tempting to infer from vibes, and the one where being wrong
  // is most obvious because it changes how every dictation sounds.
  assert.equal(observeStyle('Hey Carlo, the frames are ready', 'Dear Carlo, the frames are ready').formality, 'formal');
  assert.equal(observeStyle('the frames are ready', 'The frames are ready.').formality, null);
});

test('a near-identical respelling is a typo fix, not a phrasing', () => {
  const observation = observeStyle('send it to Netlfy', 'send it to Netlify');
  assert.equal(observation.phrasings.length, 0);
});

test('a genuine choice of words becomes a phrasing', () => {
  const observation = observeStyle('Kind regards, Roman', 'Cheers, Roman');
  assert.ok(observation.phrasings.some((p) => p.from.includes('kind regards')));
});

test('a phrasing needs three sightings and a distinctive trigger', () => {
  assert.equal(phrasingIsApplicable(makePhrasing('kind regards', 'cheers', 2)), false);
  assert.equal(phrasingIsApplicable(makePhrasing('kind regards', 'cheers', 3)), true);
  // A single short word is grammar; rewriting it on the strength of three
  // coincidences would be a disaster with no upper bound on the damage.
  assert.equal(phrasingIsApplicable(makePhrasing('and', 'plus', 5)), false);
});

test('learning can be turned off and then teaches nothing', () => {
  const profile = { ...freshProfile(), isLearningEnabled: false };
  const after = learnStyle('color', 'colour', profile);
  assert.equal(after.correctionCount, 0);
});

test('the diff reports changes of wording, not changes of typography', () => {
  // Tokens are matched on a normalised form, so "team," and "team" are the same
  // word — otherwise a comma the cleaner added paints the whole sentence as
  // changed.
  assert.deepEqual(diffSegments(tokensOf('hi team'), tokensOf('hi team,')), []);
  assert.equal(diffSegments(tokensOf('hi team'), tokensOf('hello team')).length, 1);
});

// MARK: - Applying a profile

test('a settled British profile converts spelling offline', () => {
  const profile = freshProfile();
  recordTrait(profile.spelling, 'british', new Date());
  recordTrait(profile.spelling, 'british', new Date());
  assert.equal(applyDeterministically(profile, 'pick a color'), 'pick a colour');
});

test('an applicable phrasing rewrites, and a price in it survives', () => {
  // The replacement is escaped as a TEMPLATE, not as a pattern: "$100" read as
  // capture group 1 would vanish. They are different escapings and using one
  // for both is silent corruption.
  const profile = freshProfile();
  profile.phrasings = [makePhrasing('the usual rate', '$100 an hour', 3)];
  assert.equal(applyDeterministically(profile, 'It is the usual rate.'), 'It is $100 an hour.');
});

test('the summary never implies a personalisation that is not there', () => {
  assert.ok(styleSummaryLine(freshProfile()).includes('nothing learned yet'));
});

test('the prompt budget drops the tail rather than the head', () => {
  const profile = freshProfile();
  const rules = promptRules(profile);
  assert.equal(rules.length, 1, 'a fresh profile should contribute only the voice line');
  assert.ok(rules[0]!.length > 0);
});

// MARK: - The tone guard

test('a model that came back sounding like a model is refused', () => {
  const input = 'The site is live. Invoice attached, due in 7 days.';
  const output = "Hello and welcome to our August newsletter! We're thrilled to share that the site is live.";
  assert.ok(introducedTells(input, output).length > 0);
  assert.equal(styleSanitise(output, input, freshProfile()), null);
});

test('a tell the speaker actually said is not a tell', () => {
  // The asymmetry is what keeps a list this blunt safe: each phrase is judged
  // only when it appears in the OUTPUT and not in the input.
  const input = 'I had to delve into the logs to find it.';
  assert.deepEqual(introducedTells(input, 'I had to delve into the logs to find it.'), []);
});

// MARK: - Insights

function record(daysAgo: number, words: number, audioMs: number | null): DictationRecord {
  return {
    id: uuid(),
    date: new Date(Date.now() - daysAgo * 86_400_000),
    rawText: 'the neglify build',
    insertedText: 'the Netlify build',
    wordCount: words,
    inputDevice: 'Shure MV7',
    timings: {
      timeToFirstWordMs: 800, finalToInsertedMs: 30, endToEndMs: 4000,
      audioDurationMs: audioMs, usedThoroughCleanup: false, releaseToInsertedMs: 400,
      micOpenMs: 100, speechOnsetMs: 300, recogniserFirstWordMs: 400,
    },
  };
}

test('no dictations means no invented numbers', () => {
  const metrics = computeInsights([], { vocabulary: { terms: [] }, range: 'month' });
  assert.equal(metrics.sessions, 0);
  assert.equal(metrics.totalWords, 0);
  assert.equal(metrics.wordsDelta, null, 'a delta against zero history is theatre');
  assert.equal(metrics.medianWPM, 0);
  assert.equal(metrics.hasReleaseLatency, false);
  assert.equal(metrics.observedDays, 0);
});

test('the observed-days denominator starts at the first dictation', () => {
  // It used to be the whole heatmap window — ten months of squares — so a new
  // install read "3 days you dictated on, out of 308", counting 305 days
  // before the app existed as days the user failed to use it.
  const metrics = computeInsights([record(1, 10, 5000), record(0, 10, 5000)],
    { vocabulary: { terms: [] }, range: 'all' });
  assert.ok(metrics.observedDays <= 3, `counted ${metrics.observedDays} days`);
  assert.equal(metrics.activeDays, 2);
});

test('a record with no audio length cannot contribute a rate', () => {
  // And a sub-second clip divides into nonsense — both are dropped rather than
  // clamped, because a clamped outlier still moves the median.
  const metrics = computeInsights([record(1, 10, null), record(1, 10, 500)],
    { vocabulary: { terms: [] }, range: 'month' });
  assert.equal(metrics.medianWPM, 0);
});

test('a dictionary repair is counted apart from a punctuation one', () => {
  const metrics = computeInsights([record(1, 3, 4000)],
    { vocabulary: { terms: ['Netlify'] }, range: 'month' });
  assert.equal(metrics.dictionaryFixes, 1);
  assert.ok(metrics.topFixes.some((fix) => fix.written === 'Netlify' && fix.isDictionary));
});

test('percentiles interpolate rather than snapping to a sample', () => {
  // Nearest-rank jumps in visible steps on small samples, which makes a median
  // look like it is snapping to individual dictations.
  assert.equal(percentile([0, 10], 0.5), 5);
  assert.equal(percentile([], 0.5), 0);
  assert.equal(percentile([7], 0.9), 7);
});

test('the fix alignment pairs runs off as substitutions', () => {
  const changes = alignForFixes(['the', 'neglify', 'build'], ['the', 'Netlify', 'build']);
  assert.equal(changes.length, 1);
  assert.equal(changes[0]!.kind, 'substitute');
});

test('a duration with two units keeps both', () => {
  // "1h 52m" has no honest single unit, which is why it is not a value and a
  // caption.
  assert.equal(InsightsFormat.duration(6720).map((part) => part.text).join(''), '1h 52m');
  assert.equal(InsightsFormat.duration(180).map((part) => part.text).join(''), '3m');
});
