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

- 50/50 clips captured, 0 failed (`rig/out/20260820-225558-quill`).
- 2.81% WER vs 2.37% on the pre-fix run. **That gap is inside the rig's own stated
  noise floor for 50 utterances — it is a tie, not a regression.** 42 of 50
  transcripts are word-identical between the runs; the 8 that differ are ordinary
  recogniser variance on hard proper nouns (Tintoret, chiaroscurists, Pegrine), and
  one of them got *better*: `260-123286-0002` went "oh my danger" -> "all my danger",
  which matches the reference.
- Both devices proven directly: built-in mic (44100/1ch) and BlackHole (48000/2ch)
  each install a tap and deliver audio.

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

## State

Quill is running, pointed at the built-in microphone, with the new vocabulary loaded.
`settings.json` was left on BlackHole by the eval and has been put back — worth
checking after any eval run, because dictation silently hears nothing otherwise.

## Next

1. **Homophone pass.** Biggest accuracy win left, ~a quarter of remaining errors.
   Design in `ACCURACY_ANALYSIS.md`. Do not do it by loosening the cleanup contract;
   `CleanupPrompt.swift` documents the bench where that was already tried and lost.
2. **The TestingMacros plugin problem**, so the whole suite runs rather than a filter.
3. Re-score against a second post-fix run before quoting any WER delta as real.
