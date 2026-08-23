# Quill

Hold a key, speak, let go. The words land where your caret already is — in the
terminal, in a chat box, in a form field, in whatever you were about to type in
anyway.

Windows, Linux and macOS. Transcription runs on your machine; nothing leaves it
unless you turn the optional AI pass on yourself.

---

## What this is

Quill was a native macOS app: Swift, AppKit, `NSStatusItem`, Apple's
`SpeechAnalyzer`, `CGEventTap`, `AXUIElement`. This is that app rebuilt so it
runs on Windows and Linux as well, with the parts that only exist on a Mac
replaced rather than stubbed out.

The behaviour is meant to be the same app, not a port that reads like one. The
dictation coordinator, the cleanup passes, the vocabulary guards, the command
router, the undo chord, the style learner and the live typer are the same logic
with the same measured thresholds, and the comments that explain *why* a
threshold is the number it is came across intact.

## Getting it running

```sh
npm install
npm start          # build and launch
npm run dev        # same, with the dashboard open
npm test           # 303 tests, no Electron needed
npm run typecheck
```

To build installers:

```sh
npm run dist:win     # nsis installer + portable .exe
npm run dist:linux   # AppImage, deb, rpm
npm run dist:mac     # dmg, zip
```

Nothing is signed. Windows SmartScreen will warn on first run and macOS will
need a right-click → Open; both warnings are honest, because there is no
certificate. Buying one is a decision with a yearly bill attached, so it is left
to whoever ships this.

## What replaced what

| macOS original | Here | Cost of the substitution |
|---|---|---|
| `SpeechAnalyzer` (streaming, built in) | Whisper via `@huggingface/transformers`, WebGPU with a CPU fallback | A ~210 MB download on first use. Whisper is batch, not streaming, so partials are produced by re-transcribing the whole buffer every 900 ms — which happens to give the live typer exactly the contract it was written against |
| `NSStatusItem` | Electron `Tray` | Windows hides new tray icons in the overflow chevron. Linux has no tray in the Wayland protocol at all — it needs `libayatana-appindicator`, and GNOME needs an extension on top of that. So the tray is a convenience here, never the only way in |
| `CGEventTap` | `uiohook-napi` | An optional dependency with prebuilt binaries. If it will not load, Quill still runs: the dashboard opens, the global shortcut works, and the hold-to-talk key is what is missing |
| `CGEventKeyboardSetUnicodeString` | Clipboard + a synthetic paste | Quill borrows the clipboard for a few milliseconds and puts back exactly what was there. There is no cross-platform way to type arbitrary Unicode without a compiled native module |
| `AXUIElement` / `NSWorkspace` | PowerShell on Windows, `xprop -root -spy` on X11, `swaymsg`/`hyprctl` on Wayland | Used only to tell a terminal from a text field, which changes capitalisation and the trailing full stop. When it cannot tell, everything is formatted as prose |
| `NSSpellChecker` | A bundled 1.2M-word list | ~18 MB of RAM as one sorted string plus an `Int32Array` of offsets. Also *deterministic*: the macOS build asked the system checker and got Australian spellings marked as errors depending on which dictionary answered first |
| `Locale`, `NSNumberFormatter` | `Intl` | Same behaviour, one implementation, no per-platform surprise |
| The system accent colour | Quill's own teal | Windows and Linux do not expose one the way macOS does. Picking a colour is better than picking whichever grey each desktop defaults to |

## How the speech engine is put together

The interesting decision is that the model and the microphone live in the same
hidden window, and that window has no network.

`getUserMedia` and `AudioWorklet` only exist in a renderer, so the audio has to
be captured there. The model is kept beside it because Whisper is fed the whole
buffer from the start on every partial — the alternative is copying a growing
`Float32Array` across an IPC boundary five times a second.

The main process is the only thing that talks to Hugging Face. It fetches model
files with Electron's own network stack, caches them in `<data>/models/`, and
serves them to the speech window from an origin that does not exist:

```
https://models.quill.invalid/hf/…       the model
https://models.quill.invalid/runtime/…  the WebAssembly backend
https://models.quill.invalid/app/…      the speech page itself
```

`.invalid` is reserved by RFC 2606 and can never resolve, and the session
handler refuses every request to any other host. So the window that executes
WebAssembly compiled from a downloaded model cannot reach the internet — not
because a header asks it not to, but because there is nothing there.

Three things fall out of that, and all three are better than what they replaced:
the cache is a folder you can see, copy and delete; offline behaviour is
deterministic, with no network call to time out; and the download percentage is
bytes actually written rather than a guess.

It also has to be an `https` origin rather than a scheme of Quill's own, which
cost a day to learn. `@huggingface/transformers` checks whether an optional file
exists with a one-byte ranged GET, and that check begins by refusing any URL
that is not `http:` or `https:`. Under a custom scheme every probe answers "does
not exist", the pipeline is built with no tokenizer and no feature extractor
**without raising anything**, and the first transcription dies on
`Cannot read properties of null (reading 'feature_extractor')` — 200 MB and
forty seconds away from the cause.

## Verifying it without a microphone

Dictation needs a person holding a key and speaking, which no build machine has.
Since the speech engine is the part whose failure makes the rest pointless,
there is an instrument for it:

```sh
QUILL_TRANSCRIBE=some-speech.wav npm start
```

It decodes the WAV, resamples to 16 kHz, runs the same pipeline the microphone
feeds, prints the text, and exits non-zero if nothing came back. That is one
command that proves the model downloads, the proxy serves it, the WebAssembly
survived packaging, and the words are right — on any platform, with nobody
watching.

Two more, for the interface:

```sh
QUILL_CAPTURE=./shots npm start   # a PNG of every screen
QUILL_PROBE='<expression>' npm start   # evaluate it in the dashboard, print the result
```

Set `QUILL_DATA_DIR` to a scratch folder for any of these. `npm run words`
regenerates the bundled dictionary; `node scripts/seed_dev_data.mjs` fills a
scratch data directory with plausible history and refuses to run without
`QUILL_DATA_DIR` set.

## Measurements

3.84 s of speech, M5 MacBook Air, model already cached:

| Backend | Decoder weights | Time |
|---|---|---|
| WebGPU | q4 | 2.8 s |
| CPU (WASM) | q4 | 5.4 s |
| CPU (WASM) | fp32 | 37.1 s — more accurate and unusable |
| CPU (WASM) | q8 | fails to build a session |

So `q4` on both, which also means switching between CPU and GPU costs no second
download. `q8` is the obvious choice for a CPU backend and does not load at all:
`Missing required scale: model.decoder.embed_tokens.weight_merged_0_scale`, out
of the runtime's own quantisation pass, on the published weights.

The speech page *is* cross-origin isolated — it is served with COOP and COEP, so
`SharedArrayBuffer` exists and asking for four threads gives four. Both ways of
using them fail on this runtime: on the main thread the first inference never
returns, and in a proxy worker the worker dies at construction. One thread it
is. The isolation is left in place because it costs nothing and is the hard
part; if a later runtime fixes the worker, it is a one-line change.

## The honest caveats

Things that work less well here than they did on macOS, or than they should:

- **Wayland.** The keyboard hook needs read access to `/dev/input/event*`, which
  usually means adding yourself to the `input` group and logging out and back
  in. X11 needs nothing. There is no way around this that does not involve a
  compositor-specific protocol.
- **The Linux tray** needs `libayatana-appindicator3`, and GNOME needs the
  AppIndicator extension on top. Packaged as a *recommends*, not a *depends*,
  because Quill is usable without a tray and a hard dependency would refuse to
  install on a system that has none.
- **AltGr.** On most continental European layouts, right Alt *is* AltGr and
  types characters. Quill's default key is right Alt. Settings says so, and
  right Control is the sane choice on those layouts.
- **The clipboard is borrowed** on every insertion, and put back. If another app
  reads the clipboard on a timer, it may see a fragment of your dictation. The
  macOS build had the same trade-off in live-typing mode; here it applies to
  both modes, because nothing cross-platform can type arbitrary Unicode.
- **Undo verification is skipped in terminals**, because it works by reselecting
  and copying, and in a terminal `Ctrl+C` is SIGINT rather than copy.
- **Nothing is signed**, as above.

## Where things live

```
src/core/        no Electron, no DOM — cleanup, stores, style, hotkey logic,
                 transforms, the dictionary, the WAV reader, the mark
src/main/        windows, tray, the keyboard hook, injection, the speech engine's
                 main-process half, the model proxy, IPC
src/preload/     three narrow bridges, one per window
src/renderer/    the dashboard, the overlay, the speech page
tests/           303 tests over src/core, run with node:test
scripts/         build, dictionary generation, icon generation, dev seeding
```

Your data lives in `%APPDATA%\Quill` on Windows, `$XDG_CONFIG_HOME/quill` (or
`~/.config/quill`) on Linux, and `~/Library/Application Support/Quill` on macOS.
Plain JSON, one file per thing, and the Settings screen has a button that erases
all of it and says exactly what it will delete.
