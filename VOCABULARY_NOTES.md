# The vocabulary file — what is in it and why

Written 2026-08-20 overnight. Roman asked for "a word vocabulary that might be hard
for the dictation to pick up" — his example: *GitHub comes out as "get hub"*.

The file now exists at `~/Library/Application Support/Quill/vocabulary.json`,
136 terms. Before tonight there was **no file on disk at all**, so the shipped
71-term seed in `Vocabulary.swift` was what the corrector actually used.

`VocabularyBook` stats the file per dictation and re-reads when it moves, so this
file is live — no rebuild, no relaunch.

## Where the terms came from

Mined from what Roman has actually written, not guessed:

- **216 notes** in `Documents/Work/romans vault` (excluding the ~630 files under
  `node_modules`, which are npm licences and changelogs and were pure noise —
  the first extraction pass was 3,348 hits for `inspect-js` before that filter).
- **116 memory files** in `~/.claude/projects/.../memory/`.

Ranked by real frequency. The top of that list: `roman-design-studio` (143),
`GitHub` (95), `macOS` (83), `roman-design-co` (79), `graphify-viz` (35),
`claude-hub` (26), `orion-app` (21). Roughly forty high-frequency terms were
missing from the seed, including the one he named.

Then extended by inference, as he asked — the tools that go with the work he
does. He has never written "Waydroid" in a note that survived, but he runs Android
apps on Linux; he uses Syncthing daily but it appears mostly in filenames.

## What is deliberately NOT in it

`VocabularyCorrector` refuses to replace a single word the system spell checker
accepts — "a correctly spelled English word is presumed intentional". I checked
every candidate against the *same* `NSSpellChecker` call the corrector makes
(`scratchpad/audiotest/spell.swift`), and macOS already accepts as real English:

> GitHub, Claude, Anthropic, Electron, Syncthing, Astro, Tailwind, Stripe, Notion,
> Figma, Minecraft, ChatGPT, Gmail, Lighthouse, Orion, Xcode, SwiftUI, TypeScript,
> Obsidian, Ghostty, Playwright, Firebase, SQLite, Docker, Kubernetes, YouTube,
> Instagram, LinkedIn, WhatsApp, Discord, Spotify, Reddit …

Those are **inert as single-word repairs**. They are still in the file where they
earn their place another way (below), but nobody should expect
"I pushed it to guthub" to be fixed by the single-word route — it will not be.

These actually fire as single words, because macOS does not know them:

> CachyOS, Waydroid, Ollama, Qwen, Devstral, Vite, Vercel, Cloudflare, Canva,
> Airtable, Zapier, Vulkan, Sulkan, Optifine, Firestore, Netlify, Supabase,
> yt-dlp, tmux, Hammerspoon, pytest, venv, CPython, Fraunces, Kvadrat, Maharam,
> Martindale, Craigieburn, Airtasker, shadcn, originkit, mediadeck, graphify,
> blockcraft, Baymard, glassmorphism, colourway, Redis, nginx, webpack, eslint,
> Vitest

## Why "get hub" → GitHub still works

The real-English guard is `spanCount == 1` only (`VocabularyCorrector.swift:199`).
A **two-word** span is exempt from it. "get hub" / "git hub" normalises to
`gethub` / `githbub`, which is a near-exact letter match for `github`, and the
0.95 `ordinaryPhrase` bar does not apply because that only kicks in when the
*term* is multi-word — "GitHub" is one word.

So the compound-splitting case — the exact failure Roman described — is repaired,
while the single-word case is refused. That asymmetry is correct: splitting a name
into two words is unambiguously a mis-hearing, whereas a single real word is
probably what he meant.

Same mechanism covers: `chat g p t`, `type script`, `s q lite`, `you tube`,
`linked in`, `whats app`, `c python`, `swift u i`.

## Removed on purpose

Project names that are ordinary English words were dropped:

> Dawn, Clutch, Snap, Watt, Reel, Verity, Opus, Sonnet, Haiku, Atlas, Iris, Prism,
> Fabric, Sodium, Lunar, Cursor, Inter, Forge

Each is inert as a single word anyway, so keeping them buys nothing — and every
one is a live multi-word collision risk of exactly the kind the source file
already documents ("Roman design cost" → "Roman Design Co", verb deleted, silently).
The Minecraft ones are in the file under their unambiguous full names instead:
`Fabric Loader`, `Iris Shaders`, `Sodium mod`, `Prism Launcher`, `Lunar Client`.

## What has NOT been verified

The list is reasoned from the corrector's documented guards and a direct
`NSSpellChecker` probe, but **no term in it has been through a real dictation**.
The honest test is to say a sentence containing one and see what lands.

`Tests/QuillKitTests/` cannot currently build on this machine — `swift test` fails
on `AnalyzerInputConverter` not being in scope under either toolchain (a macOS 27
SDK gap, unrelated to any of tonight's changes), so the existing
`VocabularyCorrectorTests` could not be run or extended either. Worth fixing
separately; it means the vocabulary rules are currently untestable in CI.

The 50-clip eval corpus is LibriSpeech — 19th-century prose — so none of these
terms appear in it and the vocabulary change cannot move that WER either way.
