# rig — the comparison harness

This decides whether the quill project produces real numbers or invented ones.

A critic that cannot actually run both apps on the same audio will fill the gap
with a plausible story and approve everything. So every script here either
proves its preconditions or refuses to run, and there is no flag anywhere that
quietly disables a check.

Steps that need **you** — your password, a click, your voice — are marked
**👤 YOU**. Everything else is automatic.

---

## What proves a run is real

Four independent checks. A run that skips any of them is not evidence.

| Proof | Mechanism | Where |
|---|---|---|
| The app heard the loopback, not the room | Flow's `History.micDevice` must contain `BlackHole` | `read_flow.sh` |
| The system input never drifted mid-run | input device asserted before **and** after every clip | `run_eval.sh` |
| Audio actually reached the device | the clip's tap recording must be non-silent | `tools/fingerprint.py` |
| Both apps got the *same* audio | onset-anchored hash of both runs' taps must match | `verify_taps.sh` |

The transcript reader is the strictest of these: if `micDevice` says `Built-in`,
`read_flow.sh` exits non-zero and the run is void. That single column is the
difference between a measurement and a guess.

---

## One-time setup

### 1. Install BlackHole — **👤 YOU** (admin password + reboot)

The rig cannot do this for you: the installer needs an admin password and macOS
will not load a new audio driver until you reboot.

```bash
brew install --cask blackhole-2ch
sudo reboot
```

After rebooting, confirm:

```bash
SwitchAudioSource -a -t input | grep BlackHole
```

> Without BlackHole, clips play out of the speakers and the app records the
> room through the built-in mic. That still produces a WER. It is fiction.

### 2. Grant permissions to your terminal — **👤 YOU** (clicks)

Both are granted to **Ghostty**, not to the scripts.

- **System Settings › Privacy & Security › Accessibility** → add Ghostty.
  Needed to hold each app's push-to-talk key.
- **System Settings › Privacy & Security › Microphone** → add Ghostty.
  Needed for the verification tap.

Quit and reopen the terminal afterwards — macOS reads these at launch.

### 3. Sign into Wispr Flow — **👤 YOU** (account)

Flow is cloud-only. Signed out it still records audio and still writes a History
row, but with empty text. That looks like "the app got 100% WER" rather than
"the app was not logged in", which is exactly the kind of false result this rig
exists to prevent.

```bash
open -a "Wispr Flow"     # sign in, then dictate one sentence by hand
rig/read_flow.sh --latest --expect-device ''
```

If that prints your words, Flow is ready.

### 4. Set Flow's push-to-talk to a right-hand modifier — **👤 YOU** (click)

Flow ships on **Fn**. Fn is handled below the layer any script can post to, so a
synthetic hold does not reach it. In Flow's settings, rebind to **Right
Command**, then pass `--ptt-key 54`.

Quill uses **Right Option** (keycode 61) and needs no change.

### 5. Build the corpus (automatic, ~5 min)

```bash
rig/fetch_corpus.sh
```

Downloads LibriSpeech test-clean (CC BY 4.0, ~331 MiB, md5-verified), freezes a
**50-utterance slice across 40 speakers** into `corpus_manifest.tsv`, and
renders each to 48 kHz stereo `pcm_s16le` with a silent 1 s lead.

The manifest is checked into git and checksummed. Every script refuses to run if
it has been edited, because results either side of a change to the eval set are
not comparable. Re-baselining is deliberate: `--refreeze`.

### 6. Check everything

```bash
rig/setup.sh
```

Prints a per-item checklist and exits non-zero on any blocker, with the exact
command or click that fixes it.

---

## Running a comparison

Run **one app at a time** and quit the other — two listeners on one hotkey is a
guaranteed bad run.

```bash
# 1. prove the path works before committing to a 20-minute run
rig/run_eval.sh --app quill --preflight

# 2. the real runs
rig/run_eval.sh --app quill
rig/run_eval.sh --app flow --ptt-key 54

# 3. prove both apps received identical audio  ← do this BEFORE scoring
rig/verify_taps.sh out/<quill-run> out/<flow-run>

# 4. score
rig/score.py --run out/<quill-run> --run out/<flow-run>
```

`--preflight` runs a single clip and stops. Use it every time; it turns a
50-clip failure into a 30-second one.

If the **first** clip yields no transcript, `run_eval.sh` aborts immediately —
that is a setup problem, not flakiness, and 49 more failures would tell you
nothing new.

Expect roughly 20 s per clip for Flow (cloud round trip) and ~15 s for Quill.

---

## Blind scoring

Transcripts are self-labelling if you can see them side by side, so the critic
should not.

```bash
rig/blind.py seal --run out/<quill-run> --run out/<flow-run>
# critic scores the files under out/blind-<ts>/results/ — no app names anywhere
rig/blind.py unseal --dir out/blind-<ts>
```

`seal` drops any clip missing from either run, shuffles file order, names files
by UUID, and writes the map to a `chmod 400` sealed file that scoring never
reads. `unseal` verifies the seal's checksum and records that the set is no
longer blind.

**What blinding cannot do:** Flow's formatted output is punctuated and
capitalised; raw ASR is not. Anyone can de-blind that by eye. Sealing defaults
to the raw accuracy field for this reason, and `--field formatted` prints a
warning saying the blinding is decorative.

---

## The spoken corpus — **👤 YOU** (your voice, ~10 min)

LibriSpeech is 19th-century audiobook prose read by strangers. It says nothing
about how either app handles *"push the nxt onboarding manager to Netlify once
the Firestore rules are updated"*. That is where a cloud model with a large
vocabulary should beat a small local one, so it is the fair place to look.

```bash
rig/record_voice.sh
```

32 sentences — 14 loaded with your actual vocabulary (nxt, graphify, Nebula,
Vesper, blockcraft, Firestore, Netlify, Craigieburn, Melbourne), 18 ordinary
dictation prose. One sentence on screen at a time: press ENTER, speak, it stops
on its own when you stop talking, plays back, keep or redo. Ctrl-C is safe and
it resumes where you left off.

Output matches the LibriSpeech corpus exactly — same rate, padding and loudness
targets — so the same run/score commands work:

```bash
rig/run_eval.sh --app flow --expect-device 'Built-in'
rig/score.py --run out/<run> --manifest rig/audio/voice/roman/manifest.tsv
```

> `--expect-device 'Built-in'` relaxes the BlackHole assertion. It is correct
> **only** here, where a real microphone is the point, and the scripts print a
> warning every time it is used. Never pass it for a LibriSpeech run.

---

## Files

| | |
|---|---|
| `setup.sh` | preflight; blockers vs warnings, with fixes |
| `fetch_corpus.sh` | download, freeze, render, verify the eval set |
| `run_eval.sh` | the per-clip loop; `--app flow\|quill` |
| `read_flow.sh` | Flow's transcripts; **asserts `micDevice`** |
| `read_quill.sh` | Quill's transcripts; asserts freshness |
| `verify_taps.sh` | cross-run proof both apps heard the same audio |
| `score.py` | WER/CER via jiwer + Whisper's `EnglishTextNormalizer` |
| `blind.py` | sealed blind scoring |
| `record_voice.sh` | the spoken corpus harness |
| `corpus_manifest.tsv` | **the frozen eval set** — checked in, checksummed |
| `tools/ptt.swift` | synthesises a held modifier; `ptt selftest` proves it |
| `tools/fingerprint.py` | tap → comparable hash; fails on silence |

`audio/` and `out/` are gitignored; the manifest is not.

---

## Why normalisation is mandatory in `score.py`

Flow returns `"He hoped there would be stew for dinner."`
LibriSpeech ground truth is `"HE HOPED THERE WOULD BE STEW FOR DINNER"`.

Scored raw, that is **100% WER** — every word "wrong" purely from capitalisation
and a full stop. Normalised, it is **0%**.

```
$ rig/score.py selftest
  ok    formatting only      WER=0.0000   casing+punctuation normalise to zero errors
  Without normalisation that same pair scores WER=1.0000
```

So Whisper's `EnglishTextNormalizer` is applied to both sides of every
comparison. If it cannot be imported, `score.py` exits non-zero rather than
silently using something weaker. Dependencies are version-pinned; an instrument
whose metric moves when a package publishes a release is not an instrument.

Accuracy is scored on Flow's **`asrText`** (raw). `formattedText` is reported
separately, so you can see whether the formatter changed the *words* rather than
just the punctuation.

---

## When something breaks

| Symptom | Cause | Fix |
|---|---|---|
| `micDevice ... not BlackHole` | Flow keeps its own device preference | set it inside Flow too, then re-run the whole run |
| no new transcript, first clip | wrong push-to-talk key, or Flow signed out | `--ptt-key 54`; check sign-in |
| `tap contains no audio` | playback went somewhere else | `rig/setup.sh` re-resolves indices |
| `DIFFERENT` in verify_taps | the runs got different audio | re-run both; do not report the comparison |
| everything silently exits | Secure Input is on | close password fields; `rig/bin/ptt selftest` |

Never splice results from two partial runs. Re-run.
