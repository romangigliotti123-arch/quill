import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  contextHasCandidate, contextMayReplace, isRegionalRespelling, projectContext,
  sameSound, sameStem, MINIMUM_WORDS,
} from '../src/core/cleanup/contextProjection';
import { appContextOf, applyAppContext, capitalisesSentences, keepsTrailingFullStop, lowercasingFirstLetterIfSafe } from '../src/core/cleanup/appContext';
import { undoChordClaims, CHORD_WINDOW_SECONDS } from '../src/core/hotkey/undoChord';
import { CONTEXT_PROMPT } from '../src/core/ai/prompts';

// MARK: - What the context pass is allowed to accept
//
// The model proposes freely and this refuses anything that is not a
// same-sounding swap or a dropped ending. The model is free; the acceptance is
// not, and everything below is the acceptance.

test('a true homophone may be swapped', () => {
  assert.ok(sameSound('flower', 'flour'));
  assert.ok(sameSound('dues', 'dews'));
  assert.ok(sameSound('cashed', 'cached'));
});

test('a synonym may not', () => {
  assert.equal(sameSound('want', 'would'), false);
  assert.equal(sameSound('site', 'website'), false);
  assert.equal(contextMayReplace('scoops', 'scripts'), false);
});

test('a dropped ending may be put back', () => {
  // The repair real dictation actually needs. Measured: "I move the whole front
  // end to type scoops last night" — "moved" was said and the recogniser
  // dropped the ending because it was spoken fast.
  assert.ok(sameStem('move', 'moved'));
  assert.ok(sameStem('site', 'sites'));
  assert.ok(sameStem('carry', 'carries'));
  assert.ok(sameStem('use', 'used'));
  assert.ok(sameStem('fix', 'fixed'));
});

test('a function word is never a stem', () => {
  // These are the most common words anyone says, so a swap between two of them
  // is both the likeliest to fire and the most damaging when it does — "the"
  // becoming "they" changes the sentence and reads as though the user said it.
  assert.equal(sameStem('the', 'they'), false);
  assert.equal(sameStem('our', 'ours'), false);
  assert.equal(sameStem('he', 'her'), false);
  assert.equal(sameStem('its', 'it'), false);
});

test('an Americanisation is refused even though it is a true homophone', () => {
  // "I cashed the cheque on Friday" came back as "I cashed the check on
  // Friday". Both are true homophones and the table is right about that, but
  // "cheque" was never the wrong word — no amount of context makes it one.
  assert.ok(isRegionalRespelling('cheque', 'check'));
  assert.equal(sameSound('cheque', 'check'), false);
  assert.equal(sameSound('metre', 'meter'), false);
});

test('the gate does not fire on a short command', () => {
  // "Push the build to Netlify tonight" trips the word gate, because build and
  // billed are homophones and the table is right about that. It is also six
  // words that need nothing, and paying most of a second on it is the tax that
  // quietly ends the habit of dictating at all.
  assert.equal(contextHasCandidate('Push the build to Netlify tonight'), false);
  assert.ok(MINIMUM_WORDS === 12);
});

test('the gate fires on a long sentence with a confusable in it', () => {
  assert.ok(contextHasCandidate(
    'every time the service cached something stale the preview page broke again for everyone',
  ));
});

test('the projection takes the repairs that check out and reverts the rest', () => {
  // All-or-nothing lost both. Measured: the model returned "I moved the whole
  // front end to type scripts" for "I move ... to type scoops" — the dropped
  // ending repaired, which is exactly what was asked for, and "scoops" turned
  // into "scripts", which is not.
  const input = 'I move the whole front end to type scoops last night';
  const model = 'I moved the whole front end to type scripts last night';
  assert.equal(projectContext(model, input), 'I moved the whole front end to type scoops last night');
});

test('the projection refuses a rewritten sentence outright', () => {
  const input = 'Here are the following bugs I have been experiencing with the app today';
  assert.equal(projectContext('I have been experiencing bugs with the app', input), null);
});

test('the projection refuses more than three changes', () => {
  // Every change is individually verified, and a model that wants four of them
  // in one sentence is doing something this pass is not for.
  const input = 'the flower and the dues and the principle and the site were fine';
  const model = 'the flour and the dews and the principal and the sight were fine';
  assert.equal(projectContext(model, input), null);
});

test('the context prompt states the default answer before the exception', () => {
  // v1 described the job and then asked for at most one change, and a model
  // given a job does it: 3/6 fixed, 3/6 damaged.
  assert.equal(CONTEXT_PROMPT.version, 3);
  assert.ok(CONTEXT_PROMPT.system.includes('UNCHANGED'));
  assert.ok(CONTEXT_PROMPT.system.includes('Australian spelling is correct'));
});

// MARK: - Where the words are going

test('a terminal gets no capital and no full stop', () => {
  // `Git status` is not a command, and the full stop has to be deleted by hand
  // every single time — exactly the kind of small tax that makes someone stop
  // using dictation without ever being able to say why.
  assert.equal(applyAppContext('Run the build.', 'terminal'), 'run the build');
  assert.equal(capitalisesSentences('terminal'), false);
  assert.equal(keepsTrailingFullStop('terminal'), false);
});

test('a code editor keeps its capitals, and that is a reversal', () => {
  // An editor is not only an editor: prose dictated into a chat panel inside
  // one came out lower-cased, four sentences in a row. An unwanted capital
  // inside a string literal is one keystroke to remove; a missing capital on
  // every sentence you dictate arrives in front of whoever you are writing to.
  assert.equal(applyAppContext('Try it again.', 'code'), 'Try it again.');
});

test('a question mark survives where a full stop does not', () => {
  // "did the build pass?" means something a full stop does not.
  assert.equal(applyAppContext('Did the build pass?', 'terminal'), 'did the build pass?');
  assert.equal(applyAppContext('Wait for it...', 'terminal'), 'wait for it...');
});

test('a name at the start of a command keeps its capital', () => {
  assert.equal(lowercasingFirstLetterIfSafe('Docker ps'), 'docker ps');
  // ALL CAPS is an acronym.
  assert.equal(lowercasingFirstLetterIfSafe('NPM install'), 'NPM install');
  // The same word capitalised again later is a name, not a sentence start.
  assert.equal(lowercasingFirstLetterIfSafe('Netlify deploy to Netlify'), 'Netlify deploy to Netlify');
});

test('the destination is recognised from what each platform actually reports', () => {
  // A Windows executable, an X11 window class, a macOS application name.
  assert.equal(appContextOf('windowsterminal.exe'), 'terminal');
  assert.equal(appContextOf('powershell.exe'), 'terminal');
  assert.equal(appContextOf('Alacritty'), 'terminal');
  assert.equal(appContextOf('gnome-terminal-server'), 'terminal');
  assert.equal(appContextOf('code.exe'), 'code');
  assert.equal(appContextOf('jetbrains-idea'), 'code');
  // A browser is deliberately prose: the address bar is a query and every other
  // field is not, and there is no way to tell them apart from outside.
  assert.equal(appContextOf('firefox'), 'prose');
  // And an app nobody has heard of is prose, which is the conservative answer.
  assert.equal(appContextOf('SomeInternalTool.exe'), 'prose');
  assert.equal(appContextOf(null), 'prose');
});

// MARK: - The undo chord

const idle = { kind: 'idle' as const };
const armed = { kind: 'armed' as const, token: 1 };
const holding = { kind: 'holding' as const };
const handsFree = { kind: 'handsFree' as const };

test('with nothing inserted the chord never fires', () => {
  assert.equal(undoChordClaims({
    gesture: idle, triggerHeldFor: null, heardSpeech: false, hasInsertion: false,
  }), false);
});

test('at rest, with something inserted, it fires', () => {
  assert.ok(undoChordClaims({
    gesture: idle, triggerHeldFor: null, heardSpeech: false, hasInsertion: true,
  }));
});

test('inside the arm delay it is the chord, not a gesture', () => {
  // Nobody starts a dictation and presses the undo chord inside 120 ms.
  assert.ok(undoChordClaims({
    gesture: armed, triggerHeldFor: 0.05, heardSpeech: false, hasInsertion: true,
  }));
});

test('once anything has been heard, the user is speaking', () => {
  // The gesture machine says holding 130 ms after the trigger goes down whether
  // or not the user is speaking, and only the audio knows which. Claiming the
  // chord here would delete the previous sentence as well as binning this one.
  assert.equal(undoChordClaims({
    gesture: holding, triggerHeldFor: 1, heardSpeech: true, hasInsertion: true,
  }), false);
});

test('a slower hand still reaches the chord while the microphone is silent', () => {
  // A clock was tried as the test and the measurement killed it: driving the
  // real chord through the real hook, the second key arrived 1.075 s after the
  // trigger went down. Any window a careful press falls outside of turns the
  // feature back into "sometimes".
  assert.ok(undoChordClaims({
    gesture: holding, triggerHeldFor: 1.5, heardSpeech: false, hasInsertion: true,
  }));
  assert.equal(undoChordClaims({
    gesture: holding, triggerHeldFor: CHORD_WINDOW_SECONDS + 1, heardSpeech: false, hasInsertion: true,
  }), false, 'the backstop for a microphone that never reports at all');
});

test('hands-free never claims it', () => {
  // Nothing is held here, so there is no chord to be halfway through — and
  // unlike a hold, hands-free is expected to survive typing.
  assert.equal(undoChordClaims({
    gesture: handsFree, triggerHeldFor: null, heardSpeech: false, hasInsertion: true,
  }), false);
});
