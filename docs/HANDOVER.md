# Quill — where it stands

A from-scratch macOS dictation app, built to be judged against Wispr Flow rather
than described as similar to it. Written 9 August 2026.

Everything below is either measured on this Mac or marked as not measured. No
number here is an estimate dressed up as a result.

---

## The decisive fact about the bar

**Wispr Flow is 100% cloud.** Their own docs: *"Flow requires an internet
connection for voice transcription"*, and *"Flow runs entirely in the cloud and
is delivered as multi-tenant SaaS."* An account is mandatory; there is no offline
mode; their published dictation uptime is 99.47% over the last quarter.

That reshaped the whole comparison. An offline on-device app versus a server GPU
running a fine-tuned Llama is a fair fight on latency, insertion, reliability and
privacy — and a rigged one on raw formatting, unless ours gets a model of its
own. It now has one, on NVIDIA NIM, with the transcription still fully local.

---

## What works

| | |
|---|---|
| **Dictation** | Hold Right ⌥, speak, release. Text lands in the focused app. Double-tap locks hands-free; Escape cancels. |
| **Engine** | Apple `SpeechAnalyzer` + `SpeechTranscriber`, on-device. First partial ~1.0s, 43× real-time in batch, 0 MB of models in the bundle. |
| **AI layer** | NVIDIA NIM (`meta/llama-3.1-8b-instruct`). Spoken self-correction, style, transforms, command routing. Falls back to deterministic repair with no network. |
| **Live text** | Words land in the focused app as you speak, not on key release. Revisions are reconciled with the smallest possible edit; Escape takes all of it back. |
| **Settings** | Hold-to-talk and push-to-talk are separately bindable to any modifier, the microphone is selectable, and live text can be turned off. Persisted to `settings.json`, read live — no relaunch. |
| **Dashboard** | Insights, Dictation history, Dictionary, Snippets, Scratchpad, Style, Settings. |
| **Tests** | 393. |

---

## Measured, head to head, on identical audio

Both apps were driven through one virtual audio device (BlackHole), and every
transcript is stamped with the microphone the app actually heard. A transcript
from the wrong device is refused rather than scored — that single check is what
separates this from a plausible-sounding table.

| Measure | Wispr Flow | Quill |
|---|---|---|
| WER, raw ASR — 50 clips | **2.11%** (24/1138) | 2.37% (27/1138) |
| WER, raw ASR — 2-clip smoke | 4.35% | **2.17%** |
| Formatter divergence | 1.40% | **0.00%** |
| Latency, key-release → text | 807ms median | 0.39s median (own instrumentation) |
| Works offline | no | **yes** |

Corpus: a frozen, checksummed 50-utterance slice of LibriSpeech test-clean.

**A residual ~8-15% of clips still fail to read back through `run_eval.sh`.** The
app produces a transcript for every gesture — verified by instrumenting every
silent path in the coordinator and the event tap, all of which stayed quiet while
the app logged a completed dictation each time — so this is a rig problem, not a
product one. Until it is confirmed fixed, corpus numbers come from a simpler
hand-rolled loop (mark → `ptt hold` → `ffmpeg -re` → poll → `read_quill.sh
--since`) that has run 50/50 twice.

### 2026-08-20 — a candidate cause, patched but NOT yet verified on hardware

Read on Linux, so nothing below has been run. Treat it as a hypothesis with a
patch attached, not a result.

The verification tap is a **second CoreAudio client on the loopback device**, and
it was sized `dur + LEAD + TAIL + 1.0` — which put its exit ~500ms *after* the
hotkey came up, i.e. inside the window where the app is finalising the transcript
it is about to save. The `wait "$TAP_PID"` sitting immediately after the key
release then made the script block until precisely that happened, on every clip.
A client leaving a shared device can trigger a CoreAudio format renegotiation,
which stops an `AVAudioEngine` that is not handling
`AVAudioEngineConfigurationChange`.

That is the **one structural difference** between this script and the hand-rolled
loop that never lost a clip — the hand loop has no tap. It also explains the shape
of the failure: intermittent, `run_eval`-only, and invisible to the app's own
instrumentation, because a route change is not an error path.

The patch keeps the tap alive across finalisation and stops it (SIGINT, so ffmpeg
finishes the WAV header) only once the transcript has been read. `-t` is now just
a runaway ceiling. Trailing silence is free here: `fingerprint.py` anchors its
hash to the first audible sample over a fixed 3.0s window, so a longer recording
cannot change a fingerprint.

`run_eval.sh` also now re-reads once, 3s after any failure, and records
`arrived_late` in `results.jsonl`. That settles the question this note could not:
"the app never produced it" and "it arrived after we stopped looking" are opposite
problems that leave an identical results file, and a row sitting in `history.json`
by the time a human looks is *not* evidence it was there when the reader gave up.

**To verify, on the Mac:** run the corpus and check that `failed_clips` is empty.
If clips still fail, `grep arrived_late rig/out/<run-id>/results.jsonl` now says
which problem you have — `true` means raise `--settle`, `false` means the tap
theory is wrong and the app really is dropping dictations.

**Do not chase accuracy through `.fastResults`.** Dropping it scores better on
file-fed audio — 2.46% against 2.81%, four fewer errors — and is a disaster
through a microphone: the first partial cannot arrive before ~3.9s, so any
utterance ending before then returns an empty transcript, and roughly a quarter
of dictations produced nothing at all. The experiment is repeatable with
`QUILL_FAST_RESULTS=0`; the conclusion is that a benchmark win costing one
dictation in four is not a win.

**Flow is ahead on raw accuracy, by three words.** 27 errors against 24, on the
same 1138 reference words, every transcript audited to the loopback device. That
gap is not statistically meaningful at this sample size — but it is not a win
either, and the honest summary is that the two recognisers are level on read
American speech, with Flow a hair in front. Quill's case rests on the columns it
wins outright: offline, latency after release, and a formatter that does not
drift from what was said.

Worth knowing: the number was NOT produced by `rig/run_eval.sh`. That script
fails to read back a transcript after its first clip or two — the row lands in
Quill's history correctly and the reader reports `no_new_record` anyway — and the
cause is still unfound. The 50 clips were driven by a minimal loop doing the same
sequence by hand (mark → `ptt hold` → `ffmpeg -re` → settle → `read_quill.sh
--since`), which works every time. Anyone re-running this should treat run_eval
as suspect until that is chased down. Raw transcripts:
`rig/out/20260810-quill-50/transcripts.tsv`.

One trap found the hard way while writing that loop: **ffmpeg without `-nostdin`
swallows the driving loop's stdin** and silently skips clips — the first attempt
scored 25 clips while believing it had done 50. `rig/run_eval.sh` already passes
`-nostdin`, which is exactly why.

---

## Three findings worth keeping

**1. Apple's contextual-string biasing does nothing.** The documented way to
teach the recogniser your vocabulary is `AnalysisContext.contextualStrings`. It
is wired up, the API accepts the terms, and it changes nothing: the same audio
transcribed with 0 terms and with 25 produced byte-identical text. "graphify"
came out "graph if I" either way.

So proper nouns are repaired afterwards, and not by find-and-replace — the
recogniser splits one word into three, so matching runs over 1–3 word windows
against a letters-only normalisation, guarded by the system spell checker so a
real English word is never silently rewritten. Recovers `graph if I → graphify`,
`Craig Eburn → Craigieburn`, `neglify → Netlify`.

**2. The dropped-words bug was capture, not recognition.** Words went missing
when you started speaking immediately after pressing the key. The microphone
wasn't opening until the 120ms arm delay had elapsed *and* the audio engine had
spun up. Capture now starts at key-down, before the gesture is even known to be
dictation; if it turns out to be a chord or a stray tap the audio is binned.

**3. Live text has to type the *cleaned* partial, not the raw one.**
`SpeechTranscriber` returns the whole best-so-far string on every update, so live
typing is a diff: delete back to the longest common prefix, type the rest. Typing
raw hypotheses looks fine until the final pass capitalises the first letter — a
change at character zero, which is a delete-and-retype of the entire sentence at
the exact moment the user is waiting for it to finish. Running the deterministic
cleaner on every partial costs microseconds and makes the closing edit almost
always empty.

**4. Putting a vocabulary list in a model prompt makes the model spend from it.**
Giving the cleanup prompt Roman's project names caused it to inject "Builda Bed"
into a sentence that never mentioned it. Term survival is now enforced
deterministically. Prompting is the wrong tool for a checkable constraint.

---

## What is NOT done

- **Notetaker** — needs system-audio capture, calendar access and a consent story. The section says so rather than faking it.
- **Transforms and Help** — still the shell's placeholder.
- **Roman's voice.** Every number here comes from LibriSpeech: read speech, American
  strangers. It says nothing about an Australian accent or the words actually used
  day to day. `rig/record_voice.sh` puts a script on screen and records it — about
  15 minutes, and it is the only remaining thing nobody else can do.
- **The seven dictation pieces have not been gauntleted.** The rig exists and the
  baseline exists; the blind per-piece loop against them has not run.

---

## Running it

```bash
Scripts/build.sh --release     # signed, stable identity, TCC grants survive rebuilds
open "$HOME/Library/Application Support/Quill/build/Quill.app"
Scripts/test.sh                # 393 tests
rig/setup.sh                   # verifies every precondition, refuses to run on a broken rig
rig/run_eval.sh --app quill --settle 18
rig/score.py --run out/<run-id>

# Layout, at every size that has ever broken. Renders the REAL window after a
# real resize, so a stale tracking area or a frame that survives a shrink shows
# up — which an offscreen render at a fixed size structurally cannot catch.
QUILL_RESIZE_SWEEP=/tmp/sweep \
  QUILL_DASHBOARD_SECTIONS=insights,settings \
  "$HOME/Library/Application Support/Quill/build/Quill.app/Contents/MacOS/Quill"
```

**The measurement instrument was broken, and that is worse than a bad number.**
`rig/run_eval.sh` read the corpus manifest on stdin while spawning children that
also read stdin. One of them ate a byte, so clip two arrived as
`089-134686-0002` — leading 1 gone — and every clip after the first was either
corrupted or skipped. A fifty-clip run silently became twenty-five and printed
"ok" for each one. The manifest is now read on descriptor 3, every child is
denied stdin, and the run refuses to report at all if it saw fewer clips than the
manifest holds. It also polls for the transcript instead of sleeping four seconds
and looking once, which was separately calling six clips in thirty-five "failed"
while their transcripts sat in Quill's history.

**Tuning our own recogniser needs no microphone.** WER is scored on raw ASR, so
nothing downstream of the transcriber can move it — which means comparing two
recogniser configurations needs no loopback device, no synthetic keystrokes and
no idle machine. `QUILL_TRANSCRIBE_DIR=rig/audio/clips` runs the whole corpus
through the real transcription path in about a minute, or ~8 minutes with
`QUILL_TRANSCRIBE_REALTIME=1`. The loopback rig remains the only way to measure
*Flow*, which is a black box; it is not the way to tune ours.

Traps that cost real time and are documented where they bite:

- Build output lives outside `~/Documents` because iCloud's `fileprovider` xattrs
  make `codesign` reject the bundle, and `xattr -cr` cannot remove them.
- Tests run on the CLT toolchain with an explicit `-plugin-path` and two
  `-rpath`s. Xcode's toolchain cannot be used at all — its 6.3.3 compiler rejects
  the 6.4 SDK, and without that SDK the Speech code does not compile.
- Never launch the binary directly to test permissions. Run from a shell and it
  inherits the shell's Accessibility grant and reports false success.
