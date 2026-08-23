# Quill

Dictation that runs on your machine.

Hold a key, speak, let go — the words land wherever your caret already is. No
window to open first, no account required, no upload. Speech recognition runs
on-device — Apple's own Speech framework on macOS, Whisper locally on Windows
and Linux — so it works on a plane and your voice never leaves the machine.

<!-- A screenshot belongs here. -->

## Get it

Two downloads, one app: **[Releases](../../releases/latest)**.

- **macOS** (Apple silicon, macOS 26+) — a signed `.app` you unzip and run.
  It is self-signed rather than notarised, so the first launch shows a
  Gatekeeper warning; see below.
- **Windows and Linux** — an installer for each, built from
  [`quill-desktop/`](quill-desktop), a full Electron rebuild of the same app:
  same cleanup passes, same vocabulary guards, same command router, same
  measured thresholds, ported rather than reimagined.

### Gatekeeper, on first launch (macOS)

Quill is signed with a self-signed identity, not an Apple Developer ID, so
macOS will say it "cannot be opened because it is from an unidentified
developer" or similar. This is expected, not a sign anything is wrong — right-click
the app ▸ **Open** ▸ **Open** again in the dialog that follows, once. macOS
remembers the choice after that.

## What it does

- **Push to talk.** Hold right Option and speak. Double-tap it for hands-free,
  or leave the key alone entirely and use the **overlay** — a small bar docked
  to a screen edge, always there, that expands on hover to a click-to-dictate
  button. Position and visibility are both in Settings.
- **Cleans up as it goes.** Punctuation, capitalisation, filler removal, spoken
  numbers written the way you want them — all offline, in under two milliseconds.
- **Finishes, then sends.** Tap the dictation key again right after releasing
  it and Quill sends Return once your words have actually finished landing —
  never the instant you tap, so it can never cut a dictation off mid-flight.
  On by default.
- **Learns your words.** Names, tools and jargon go in the Dictionary and stop
  coming out wrong. It notices which words you keep re-typing and offers them.
- **Takes it back.** ⌥⌫ deletes the last thing Quill inserted, verified against
  what is actually behind your caret before it deletes anything.
- **Notes.** A simple place to dictate into directly — name a note, talk, done.
- **Snippets and transforms.** Say a phrase to expand it; hold ⌘ together with
  the dictation key and say "make that a bullet list" to reshape what you just
  dictated instead of typing it. The extra modifier is deliberate — plain
  dictation never risks running a transform by accident just because a
  sentence happened to contain the words.
- **An optional account.** Sign in and Quill can sync your history, vocabulary,
  snippets, transforms and learned writing style to another machine, and
  unlocks MCP — a real local server (`QuillMCP`, bundled in the app) that lets
  Claude read your writing voice and dictation history to answer in your own
  style. Nothing about it touches email or any other account directly; that
  access, if any, is something you grant Claude yourself. Everything above
  works exactly the same with no account at all.

The list above is the macOS app. `quill-desktop` carries the core across —
transcription, cleanup, vocabulary, snippets, transforms, undo, style — but
trails on the newest additions: no overlay, Notes, "finish, then Enter", the
transform modifier gesture, or accounts/MCP yet. Its own README says exactly
what has landed.

## Building from source (macOS)

For Windows and Linux, see [`quill-desktop/README.md`](quill-desktop/README.md)
instead — different toolchain, different repo layout, its own instructions.

macOS 26 or later, on Apple silicon. Speech recognition uses `SpeechAnalyzer`,
which does not exist before 26.

You also need the **Command Line Tools** installed, not just Xcode — the build
prefers CLT's toolchain because one API Quill uses ships only in the newer SDK.

```
xcode-select --install
```

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

700+ tests, about ten seconds. Drop the variable to include the tests that call
the real model endpoint (needs a key). `quill-desktop/` has its own suite —
see its own README.

## Repo layout

```
Sources/Quill/        the macOS executable — env-var probes, then the app
Sources/QuillKit/     everything real, so it can be tested without a window
Sources/QuillMCP/     the stdio MCP server bundled into Quill.app
Tests/                the macOS suite
Scripts/              build, sign, test
rig/                  the accuracy harness used to benchmark against Wispr Flow
docs/                 working notes kept for history, not documentation
quill-desktop/        the Windows/Linux Electron rebuild — its own repo layout,
                       its own README, folded in here so there is one place to
                       find either download
```

## Release notes

Kept on the [Releases](../../releases) page, one entry per release, updated
alongside every change that ships.

## Licence

MIT for both the macOS app and `quill-desktop`. See [LICENSE](LICENSE).
