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

## Next — bugs Roman is about to report

He said on 21 Aug that he has hit "a few bugs" in normal use and was going to
describe them. That conversation was cut short by a session restart, so ASK HIM
for them first — they are real-use bugs from someone who dictates with this
daily, which is worth more than anything that can be found from the corpus.

For each: what he did, what he expected, what happened, and whether it is every
time or intermittent.

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
