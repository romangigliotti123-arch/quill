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
| **Dashboard** | Insights, Dictation history, Dictionary, Snippets. All four beat Flow's equivalents in blind review. |
| **Tests** | 369. |

---

## Measured, head to head, on identical audio

Both apps were driven through one virtual audio device (BlackHole), and every
transcript is stamped with the microphone the app actually heard. A transcript
from the wrong device is refused rather than scored — that single check is what
separates this from a plausible-sounding table.

| Measure | Wispr Flow | Quill |
|---|---|---|
| WER, raw ASR — 50 clips | 2.11% (24/1138) | *see results below* |
| WER, raw ASR — 2-clip smoke | 4.35% | **2.17%** |
| Formatter divergence | 1.40% | **0.00%** |
| Latency, key-release → text | 807ms median | 0.39s median (own instrumentation) |
| Works offline | no | **yes** |

Corpus: a frozen, checksummed 50-utterance slice of LibriSpeech test-clean.

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

**3. Putting a vocabulary list in a model prompt makes the model spend from it.**
Giving the cleanup prompt Roman's project names caused it to inject "Builda Bed"
into a sentence that never mentioned it. Term survival is now enforced
deterministically. Prompting is the wrong tool for a checkable constraint.

---

## What is NOT done

- **Notetaker, Scratchpad, Style UI** — three of Flow's eight sections.
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
Scripts/test.sh                # 369 tests
rig/setup.sh                   # verifies every precondition, refuses to run on a broken rig
rig/run_eval.sh --app quill --settle 18
rig/score.py --run out/<run-id>
```

Traps that cost real time and are documented where they bite:

- Build output lives outside `~/Documents` because iCloud's `fileprovider` xattrs
  make `codesign` reject the bundle, and `xattr -cr` cannot remove them.
- Tests run on the CLT toolchain with an explicit `-plugin-path` and two
  `-rpath`s. Xcode's toolchain cannot be used at all — its 6.3.3 compiler rejects
  the 6.4 SDK, and without that SDK the Speech code does not compile.
- Never launch the binary directly to test permissions. Run from a shell and it
  inherits the shell's Accessibility grant and reports false success.
