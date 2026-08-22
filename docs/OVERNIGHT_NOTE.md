# Overnight session — 2026-08-20 into the 21st

**The crash is fixed and verified. A full 50-clip run passes, 0 failures.**

## What was wrong

Quill aborted on every dictation whenever the selected input device did not run at
44100 Hz. Eleven crash reports in one evening, all identical:

    com.apple.coreaudio.avfaudio:
    required condition is false: format.sampleRate == inputHWFormat.sampleRate

`AudioCapture.captureFormat` read `inputNode.outputFormat(forBus: 0)`. On the input
node that is **not** the hardware's format — it is what the node hands the rest of the
graph, and it stays on the rate the engine was built against. `inputFormat(forBus: 0)`
is the device's. With the built-in microphone both say 44100 and everything works,
which is why this survived every test that used it. Point the unit anywhere else:

    device's own nominal rate     48000
    inputNode.inputFormat         48000   <- the hardware
    inputNode.outputFormat        44100   <- the graph, unchanged

`installTap` validates against the hardware side and throws an Objective-C exception,
which Swift cannot catch, so the process aborts.

It reads like a race — CoreAudio really does renegotiate for ~300ms after a device
switch, walking through three device ids and both sample rates — and it is not one.
**Five fixes were tried against that theory and all five failed**: waiting, polling
until two reads agree, skipping the redundant device set, `engine.reset()`, and
observing `AVAudioEngineConfigurationChange` (Apple's own documented answer for this
exact assertion). None worked, because `outputFormat` is not stale. It is a different
number, stable, and never the one `installTap` was going to check.

What settled it was a standalone harness — `scratchpad/audiotest/probe2.swift` — that
asked the device, the audio unit and the engine the same question and printed all
three answers side by side. Two minutes of output after hours of theorising.

The same wrong format was also passed to `AnalyzerFeed`, which builds the converter
from capture format to analyzer format. Where it did not crash it was resampling from
a rate the buffers were not in.

## Verified

- **Two** clean 50-clip runs, 0 failures each (`20260820-225558`, `20260820-232914`).
  100 dictations through the path that used to abort on the first one.
- Both score **2.81% WER, 32/1138, byte-identical to each other**. Pre-fix baseline
  was 2.37%. That gap is inside the rig's own stated noise floor for 50 utterances —
  a tie, not a regression — and two identical runs are better evidence that 2.81% is
  the steady state than either figure alone. 42 of 50 transcripts are word-identical
  across runs; the 8 that differ are recogniser variance on hard proper nouns
  (Tintoret, chiaroscurists, Pegrine), and one got *better*: `260-123286-0002` went
  "oh my danger" -> "all my danger", matching the reference.
- **No crash since the fix landed.** Newest report in DiagnosticReports is 22:29;
  the fix went in at 22:45 and everything above ran after it.
- `rig/bin/device_switch_probe`: 8 device switches, both directions, 4 rounds, all
  install a tap and capture. Every BlackHole iteration reports `in=48000 out=44100
  [DIFFER]` — each one would have aborted the old code.
- 462 tests pass. (One flake, `aSelfCorrectionIsFixedEvenWhenTheModelNeverAnswers`,
  when the suite is run *while* an eval is saturating the machine. Its own comment
  documents that it is wall-clock bound and competes with the live network tests.
  Green on an idle machine.)

## Also done

**`Scripts/test.sh`** — the test suite could not be run at all before tonight, for two
stacked reasons (Xcode's SDK lacks `AnalyzerInputConverter`; CLT lacks the test
runtime on any path dyld searches). Both are worked around and documented in the
script's header. One thing is still unresolved: some files fail under CLT with
"plugin for module 'TestingMacros' not found", inconsistently — pass `--filter` for
now.

**Compound name corrections** — "get hub" -> GitHub and fifteen others, in
`FastCleaner.corrections`. The first version of that table did real damage in testing
("I need to get hub caps for the car" -> "I need to GitHub caps for the car"), so the
ambiguous half is anchored on the following word. 38 of 38 cases pass, including every
false-fire guard.

**`vocabulary.json`** — 136 terms, mined from 216 vault notes and 116 memory files by
frequency, then extended by inference. There was no file on disk before tonight, so
the shipped 71-term seed was what the corrector used. See `VOCABULARY_NOTES.md`,
which also records which terms are *inert* and why — macOS's spell checker already
accepts "GitHub", "Claude", "Minecraft" and forty others as real English, and the
corrector refuses to replace a single real word.

**`ACCURACY_ANALYSIS.md`** — every word error in the 50-clip run, classified.
Homophones are the largest single class (7 of 27) and neither correction layer can
fix them by design. Proposal and the reason not to just loosen the existing contract
are in that file.

## State — ready to use

Rebuilt from the latest commit and left running:

- system input **MacBook Air Microphone**, Quill's own `inputDeviceUID`
  **BuiltInMicrophoneDevice** — both put back after the evals. Worth checking after
  any eval run: leave Quill on BlackHole and dictation silently hears nothing, which
  cost hours tonight before it was understood.
- `vocabulary.json` 142 terms, verified to decode rather than silently falling back
  to the seed.
- Just hold Right Option and talk.

## Bugs Roman reported — 21 Aug

He gave them one at a time, wanting each fixed before describing the next.

### 1. A long dictation falls behind, judders, and keeps listening — FIXED

His words: read a paragraph for ~30 seconds, and the text keeps appearing for
about 30 seconds after you stop; the waveform bar at the bottom goes juddery and
then freezes; and letting go of the key does not end capture — it keeps hearing
you until all the text has landed.

Three symptoms, one cause. Everything that draws or decides funnels through the
main queue: `emit` posts one block per partial, `publish(level:)` one per audio
buffer, `HotkeyEngine.deliver` one for the key release — deliberately, so press
and release keep their order. Live typing calls `cleanFast` on the WHOLE
transcript so far, once per partial, on that queue. And `VocabularyCorrector`,
99% of `cleanFast`'s cost, was re-deciding every span it had already decided.

Measured, release build: **0.67ms per character**, so 284ms for one pass over 400
characters, 543ms over 800, 1.1s over 1600 — and a dictation of N characters runs
it ~N/20 times against a growing prefix. Quadratic in how long you spoke, all of
it on the thread that draws the waveform and services the key release.

The matcher is a pure function of (span, span length, whether sound may decide)
and the term list, so the second pass over a sentence can only reach the answers
the first one did. `MatchMemo` remembers them. Two things came out of the hot
loop at the same time: `normalise` and `wordCount` of each TERM were recomputed
for every candidate span — 142 terms re-normalised per window — and the phonetic
branch was rebuilding both phonetic keys three times over per term.

Result, over one 83-second dictation driven from real audio through the real
transcriber:

| | before | after |
|---|---|---|
| cleanFast on the main thread | 26,894 ms | 2,457 ms |
| share of the time spent speaking | 33% | 4% |
| main-queue lateness, p95 | 242 ms | 17 ms |
| main-queue lateness, worst | 860 ms | 356 ms |
| heartbeats missing their 50ms slot by >100ms | 70 | 3 |

Cold-pass cost fell the same way: 0.67ms/char to 0.067ms/char.

Verified it still says the same thing: **299 distinct raw transcripts** — every
one the rig has ever recorded — cleaned by the old build and the new one,
byte-for-byte identical, and no warm/cold disagreement on any of them. 492 tests
pass. The 2.81% WER is untouched because the output is untouched.

The instrument is `Sources/LiveTypeProbe`. It feeds a real recording through the
real transcriber at 1x and pays the real per-partial cost on the main queue,
with a heartbeat measuring how late that queue runs. `--bench` is the
per-character table, `--replay` is the corpus comparison. Reach for it before
theorising about latency again; it took two minutes to answer what an hour of
reading could not.

**Still measured and NOT fixed:** the keystroke bursts. When the recogniser
revises a word early in the sentence, backspacing to it means deleting and
retyping everything after — one update at t=73s deleted 359 characters and
retyped 371, and the whole 83s dictation posts 735 backspaces and 1,729
characters for a 994-character result. That is now the largest remaining cost
(735ms of the 3,192ms, and the CGEvents themselves cost the TARGET app more than
the sleeps cost us). Left alone deliberately: the fix is either a shorter gap
between backspaces, which is what stops text views coalescing and dropping them,
or holding volatile text back from the screen, which changes what live typing
feels like. Neither should be guessed at — measure whether Roman can still see it
first.

### 2. Spoken email addresses, and a setting for numbers — DONE

Not a bug, a request. Three parts; the first two are built, the third is
deliberately not.

**Emails.** His real failure, from history on 20 Aug: "send it to the Gmail Grace
Kingston 20 at gmail.com" arrived as prose with the domain broken into
"gmail. Com" on top. The broken domain was already fixed by the node.js work on
21 Aug. `FastCleaner.formatSpokenEmails` does the rest.

It **anchors on the domain, never on the word "at"**, which is the whole safety
argument — "meet me at the shop at four" has no domain and is never considered.
Only once a domain is found does it read left for a local part, and it refuses
when the word in front of "at" is one English puts there. Handles both spoken
("gmail dot com", "kass barbers dot com dot au" — the recogniser splits domain
labels exactly as it splits names) and already-dotted forms, folds spoken digits,
and lowercases.

**Numbers.** `QuillSettings.Values.NumberStyle`, defaulting to `spellOutSmall`
(one to nine as words, ten and up as digits) — his pick, after being shown that a
blunt toggle would turn "one of you" into "1 of you" and 1830 into a sentence.
Picker is in Settings > Dictation, with a live example under it.

It lives in `AppContextFormatter`, **not** in `cleanFast`, and that placement is
load-bearing twice over. It is presentation rather than repair, so the eval rig
and the model tests do not start measuring a preference; and the destination gets
a vote, so a terminal, a search field and a code editor all keep their digits —
`git log -3` becoming `git log -three` is a broken command, not a style.

**What the corpus caught that no unit test would have.** Replaying all 376
transcripts on this machine — the rig's 299 plus 77 of his own — through the old
build and the new one turned up exactly two changes. One was the Grace Kingston
address, correct. The other was a genuine bug:

    said:  "...for example, if I say Roman Gigliotti, 123, at gmail.com..."
    got:   "...if isayromangigliotti123@gmail.com..."

The verb and the pronoun glued onto the front of the name, because "say" and "I"
were not stop words. Both are now, along with the other speech verbs, and that
sentence is pinned as a test. After the fix: two changes across 376, both right,
no false fires anywhere else. `LiveTypeProbe --replay` is how to re-run it and
`--demo` shows the whole path end to end.

The stop-word list is the honest weak point. It is explicit and it will need a
word added the first time one is missed — which is exactly how
`VocabularyCorrector.boundaryWords` and the compound-name anchors got their
entries too. The six-token cap is the backstop for when that happens.

533 tests pass.

### 3b. What he actually asked for, after seeing the first attempt

He restated the goal and it is bigger than homophones: "have some sort of model
connected so that even if I murmur something or speak fast or say 'do this
actually do this' it all gets picked up without me having to edit it after...
accurate enough for me to just speak, trust what it said, and click send."

**First finding: everything before this was measured on the wrong corpus.**
LibriSpeech is clean, read-aloud, 19th-century prose. He dictates a median of 18
words of fast, self-correcting speech. Profiling his 736 real dictations:
self-correction cues in ~8%, filler in 7%, and the cleanup changed the text on
21%. The acoustic path is already at its practical limit — `.fastResults` off and
`DictationTranscriber` are both documented in `SpeechAnalyzerTranscriber` as
measured and correctly rejected, and re-running them is a waste of an evening.

**Second finding, and the one that mattered: the delete-only contract was the
bottleneck, not the gate.** Running the cleanup prompt on his own dictations with
the gate removed, 17 of 17 non-trivial answers were REFUSED by
`CleanupProjection` and zero calls failed. Reading the refusals is what showed why:

    said     "I move the whole front end to type scoops last night"
    model    "I moved the whole front end to type scripts last night"

"moved" is a real repair — he said it, and the recogniser dropped the ending
because he was talking fast. "scripts" for "scoops" is not. Delete-only cannot
tell them apart, so it refused both. On the next sentence the same model turned
"Here are the following bugs I've been experiencing" into "I've been experiencing
bugs with the app", which is exactly the damage the contract exists to stop.

So the fix was not to loosen the contract but to make the permission *specific*.
Three changes:

1. **Dropped endings became a second verifiable repair.** `ContextProjection.
   sameStem` allows a swap only when it is the same stem plus an ending English
   actually uses, with a floor that keeps "the"/"they" and "is"/"it" out.
2. **Partial acceptance.** The projection keeps the repairs that check out and
   reverts the ones that do not, instead of discarding a good fix because the
   model also tried a bad one. Not a weaker guarantee: every surviving change is
   still individually verified and the word count must still match exactly, so a
   rewritten sentence is still refused whole.
3. **A twelve-word floor on the gate.** "Push the build to Netlify tonight" trips
   the word gate (build/billed are homophones) and needs nothing. His errors
   accumulate with length. 24% -> 18% of his real dictations.

Measured on the half-correct corpus, lengthened to realistic sentences:

| pass | words | trigger | fixed | damaged |
|---|---|---|---|---|
| closed list | 44 | 11% | 3/6 | 0/6 |
| context v1 | 2281 | 31% | 3/6 | **3/6** |
| context v2 | 2281 | 31% | 2/10 | 0/10 |
| **context v3 + endings** | **2281** | **18%** | **5/10** | **0/10** |

So it is now ON by default. It fixes more than the closed list, damages nothing,
and reaches words the list does not contain — coarse/course, sealing/ceiling,
rode/rowed.

**Re-confirm those live numbers on a rested endpoint before trusting them.** This
key 429s easily and a throttled run reports "fixed 0/6" on the closed-list pass
too, which is the tell.

**Fixed for real: the TestingMacros plugin drop (old issue #3).** SwiftPM
intermittently omits `libTestingMacros` from `-load-resolved-plugin`. Naming it
explicitly — `-Xswiftc -load-plugin-library -Xswiftc <path>` — fixes it every
time, and `Scripts/test.sh` now does. Also both model benches sat outside the live
SUITE and only checked for a key, so `QUILL_SKIP_LIVE_TESTS` did not skip them and
an offline machine read as a correctness failure. Both now use the same guard.

### 3. Context-aware word recovery — the first attempt, kept for the record

His words: "if it can't really understand a word that I said, it should read the
context of what I just said and figure out what word makes the most sense."

**Four ways of bounding the general version were measured. All four failed.**
Writing them down because each one looks obviously correct until you measure it,
and the next person will think of them in the same order.

1. **Ask the recogniser what it was unsure about.** `SpeechTranscriber.Result`
   carries `alternatives` and Quill never requested them. Turn on
   `.alternativeTranscriptions` and they arrive populated — and they are
   *punctuation* variants. `" peppered flour"` against `" peppered, flour"`,
   every span, every clip. There is no lexical n-best to lean on.
   (`LiveTypeProbe --alternatives <wav>` reproduces it.)
2. **"The replacement must sound similar,"** using Quill's `phoneticKey`. 85% of
   English words have a neighbour under it and "flour" has 1140, including
   "baffle". That key folds b/p/v/f and c/k/g/q/j together on purpose — it is for
   matching mis-split proper nouns against a 142-term dictionary — and it bounds
   nothing here.
3. **Offer the model every true homophone in the sentence,** generated from
   CMUdict. Fires on 98% of his 376 real transcripts, median ten decisions each.
   Ten decisions per sentence is ten chances to damage a word he meant.
4. **Filter that list to ordinary words.** Still 81%, and dominated by pairs like
   the/thee, but/butt, would/wood — all risk, no upside, because he does not say
   "thee". Filtering to pairs where *both* members appear in his corpus leaves
   five, which is the hand-written list again.

**What was built instead: propose-then-verify.** Invert the shape. The model
reads the sentence and proposes a fix freely; `ContextProjection` refuses the
proposal unless the replacement is a true homophone of the word that was heard,
checked against `HomophoneTable` — 1,073 sets and 2,281 words generated from
CMUdict by `rig/tools/make_homophone_table.py`, surnames excluded. The model is
free, the acceptance is not, and the blast radius is "words that sound the same"
by construction. At most one word may change.

**And it is measurably worse than the closed list it was meant to replace:**

| pass | words | trigger | fixed | damaged |
|---|---|---|---|---|
| closed list (`HomophonePairs`) | 44 | 11% | 3/6 | 0/6 |
| context, prompt v1 | 2281 | 31% | 3/6 | **3/6** |
| context, prompt v2 | 2281 | 31% | 2/10 | 0/10 |

v1 matched the closed list and rewrote half the correct sentences — "the flower
shop on the corner" became "the flour shop", "the principle of least surprise"
became "principal", and "cheque" was Americanised. v2 moved the burden of proof
(return it unchanged unless the sentence is impossible as written) and a
code-level refusal handles regional spellings, because no amount of context makes
Australian spelling wrong. That took damage to zero and hits down with it: it
fixed one of the four cases the closed list cannot reach at all.

So it ships **off**, with the numbers in `QuillSettings.Values.contextRecovery`
and a switch in Settings. Choosing from a short list beats proposing freely on an
8B model at a 450ms deadline. The lever that would change it is a larger model,
and `gemma-4-31b` is 1678ms at p50 — see `AIConfig`.

**Do not tune the prompt against that 12-sentence bench.** Two versions already
moved along the same trade curve, and a third that scores better on twelve
sentences has probably learned the twelve sentences.

### Two things this turned up that are not about homophones

**The live benches rate-limit.** Six suite runs in an hour and the closed-list
pass fell from 3/6 to 1/6 with a 27-second call — the shape of throttling, not of
a regression. `fixed >= 3` in `theHomophonePassOnTheRealModel` is also right at
the edge of what the model does reliably; a clean cold run scored 2/6 with the
homophone path byte-identical to before. Left pinned rather than loosened,
because loosening someone's measured bar to go green is how a bar stops meaning
anything. Re-run it on an idle endpoint before believing a failure.

**Issue #3 in the old list, better characterised but still not solved.**
`libTestingMacros.dylib` gets dropped from `-load-resolved-plugin` and the whole
suite fails to compile. New this round: it is not only `--filter` builds, it hits
full runs too, and rerunning does NOT reliably clear it — one sequence failed
four times running. A fresh `QUILL_SCRATCH` path helped twice out of three, so it
is a better bet than rerunning in place, but it is not a fix and must not be
written up as one. Still unexplained.

### The original note's item 3 — the model-backed homophone half

His third ask: when the recogniser produces a word that makes no sense, read the
surrounding sentence and work out what he actually said. This is the
model-backed pass that `ACCURACY_ANALYSIS.md` already scoped, and it was split
out on purpose rather than bolted on. The two traps are recorded there and in
`CleanupPrompt.swift`: do not loosen the cleanup contract (there is a bench where
that was tried and lost), and the model pass does not currently run on ordinary
dictation at all, so it needs its own trigger and has to pay for its own latency
— measured from Melbourne, 250ms catches 11% of calls, 350ms catches 78%.

Brainstorm it properly before writing anything.

## Next — everything else

1. **The model-backed half of the homophone work.** The free half shipped: fixed
   phrases in `FastCleaner.corrections`, and `hay fever` is verified fixed on real
   audio. The rest — flour/flower, dews/dues, read/red, where only the sentence
   decides — needs a gated model pass. `ACCURACY_ANALYSIS.md` has the design and the
   two traps: do not loosen the cleanup contract (`CleanupPrompt.swift` documents the
   bench where that was tried and lost), and note the model pass does not currently
   run on ordinary dictation at all, so it needs its own trigger and has to pay for it.
2. **Say a sentence with a new vocabulary term in it.** 142 terms are in the file and
   none has been through a real dictation — the reasoning is sound and the compound
   table is tested, but that is not the same as evidence.
3. **The TestingMacros plugin race.** The full suite runs, but a narrowed `--filter`
   build sometimes drops `libTestingMacros` from `-load-resolved-plugin` and fails.
   Rerunning clears it. Understanding it would remove the last rough edge in
   `Scripts/test.sh`.
