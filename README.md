# Quill

Dictation for macOS that runs on your Mac.

Hold a key, speak, let go — the words land wherever your caret already is. No
window to open first, no account, no upload. Speech recognition uses Apple's own
on-device Speech framework, so it works on a plane and your voice never leaves
the machine.

<!-- A screenshot belongs here. -->

## What it does

- **Push to talk.** Hold right Option and speak. Double-tap it for hands-free.
- **Cleans up as it goes.** Punctuation, capitalisation, filler removal, spoken
  numbers written the way you want them — all offline, in under two milliseconds.
- **Learns your words.** Names, tools and jargon go in the Dictionary and stop
  coming out wrong. It notices which words you keep re-typing and offers them.
- **Takes it back.** ⌥⌫ deletes the last thing Quill inserted, verified against
  what is actually behind your caret before it deletes anything.
- **Snippets and transforms.** Say a phrase to expand it; say "make that a
  bullet list" to reshape what you just dictated.

## Requirements

macOS 26 or later, on Apple silicon. Speech recognition uses `SpeechAnalyzer`,
which does not exist before 26.

You also need the **Command Line Tools** installed, not just Xcode — the build
prefers CLT's toolchain because one API Quill uses ships only in the newer SDK.

```
xcode-select --install
```

## Building

```sh
Scripts/make_cert.sh          # run this FIRST, once, ever
Scripts/build.sh --install
open ~/Library/Application\ Support/Quill/build/Quill.app
```

**Do not skip `make_cert.sh`.** It creates a stable self-signed identity. Without
it, ad-hoc signing gives the app a new identity on every build, and macOS
silently drops all of its permissions each time you rebuild — while the System
Settings toggles keep *showing* as ON. The app then appears broken with no error
anywhere. This is the single most expensive mistake you can make here, and it
costs an evening.

`swift build` and `swift test` do not work on their own. Use the scripts.

## Permissions

Quill asks for three on first run, and each one fails silently when missing, so
grant all three:

| | why |
|---|---|
| **Microphone** | to hear you while the key is held |
| **Accessibility** | to see the hotkey and put text into the focused app |
| **Input Monitoring** | some macOS builds want this as well before an event tap starts |

All three live in System Settings ▸ Privacy & Security.

If the key does nothing and there is no error, it is almost always Accessibility
granted to an older build. Remove Quill from the list and add it again. The Help
tab inside the app has the rest.

## The AI cleanup is optional

Everything above works with no key, no account and no network.

A key adds one thing: a model pass that applies corrections you made out loud —
say *"send it to Noah, no wait, send it to Carlo"* and only Carlo is typed. If
the network is slow or gone, the deterministic result ships instead and you lose
nothing but the deadline.

Get a free key at [build.nvidia.com](https://build.nvidia.com/), then either
paste it into the setup window (Help ▸ Setup) or:

```sh
echo 'nvapi-…' > ~/Library/Application\ Support/Quill/nim-key.txt
chmod 600 ~/Library/Application\ Support/Quill/nim-key.txt
```

`QUILL_NIM_API_KEY` works too, and takes precedence.

## Your data

Everything lives in `~/Library/Application Support/Quill/` as plain JSON you can
read and edit. Dictations are kept for a month by default — changeable to a day,
a week, or forever in Settings ▸ Files, where there is also an **Erase
everything** button that puts the app back to how it was the day you installed it.

## Tests

```sh
QUILL_SKIP_LIVE_TESTS=1 Scripts/test.sh
```

656 tests, about ten seconds. Drop the variable to include the tests that call
the real model endpoint (needs a key).

## Repo layout

```
Sources/Quill/        the executable — env-var probes, then the app
Sources/QuillKit/     everything real, so it can be tested without a window
Tests/                the suite
Scripts/              build, sign, test
rig/                  the accuracy harness used to benchmark against Wispr Flow
docs/                 working notes kept for history, not documentation
```

## Licence

MIT. See [LICENSE](LICENSE).
