# The vocabulary file — what is in it and why

Roman asked for "a word vocabulary that might be hard for the dictation to pick up".
His example: *GitHub comes out as "get hub"*.

The file is `~/Library/Application Support/Quill/vocabulary.json`, 142 terms. Before
this there was **no file on disk at all**, so the shipped 71-term seed in
`Vocabulary.swift` was what the corrector actually used. `VocabularyBook` stats the
file per dictation and re-reads when it moves, so edits are live — no rebuild, no
relaunch.

## Where the terms came from

Mined from what Roman has actually written, then extended by inference as he asked.

- **216 notes** in `Documents/Work/romans vault`, excluding the ~630 files under
  `node_modules` — those are npm licences and changelogs, and the first extraction
  pass was 3,348 hits for `inspect-js` before that filter went on.
- **116 memory files** in `~/.claude/projects/.../memory/`.
- **67 installed skills**, which are names he says out loud to invoke them.
- The five MCP servers actually configured on this Mac.

Ranked by real frequency. The top of that list: `roman-design-studio` (143), `GitHub`
(95), `macOS` (83), `roman-design-co` (79), `graphify-viz` (35), `claude-hub` (26).
Roughly forty high-frequency terms were missing from the seed, including the one he
named.

## The important part: most terms do nothing, and this file says which

Two mechanisms could act on a vocabulary term. **One of them is dead.**

**Contextual biasing does not work.** `VocabularyCorrector`'s own header records the
measurement: the same audio transcribed with 0 biasing terms and with 25 produced
byte-identical text. "graphify" came out "graph if I" either way. Apple's API accepts
the terms and ignores them.

**So the only live mechanism is `VocabularyCorrector`**, and it refuses to replace a
single word the system spell checker accepts — "a correctly spelled English word is
presumed intentional". I ran every candidate through the *same* `NSSpellChecker` call
the corrector makes. macOS already accepts as real English:

> GitHub, Claude, Anthropic, Electron, Syncthing, Astro, Tailwind, Stripe, Notion,
> Figma, Minecraft, ChatGPT, Gmail, Lighthouse, Orion, Xcode, SwiftUI, TypeScript,
> Obsidian, Ghostty, Playwright, Firebase, SQLite, Docker, Kubernetes, YouTube,
> Instagram, LinkedIn, WhatsApp, Discord, Spotify, Reddit …

A single-word term on that list can never fire. **49 such terms were removed** rather
than left in to pad the count — a list that claims to be doing something and is not is
worse than a shorter one, because the next person cannot tell which entries are
load-bearing.

These do fire as single words, because macOS does not know them:

> CachyOS, Waydroid, Ollama, Qwen, Devstral, Vite, Vercel, Cloudflare, Canva,
> Airtable, Zapier, Vulkan, Sulkan, Optifine, Firestore, Netlify, Supabase, yt-dlp,
> tmux, Hammerspoon, pytest, venv, CPython, Fraunces, Kvadrat, Maharam, Martindale,
> Craigieburn, Airtasker, shadcn, originkit, mediadeck, graphify, blockcraft,
> Baymard, glassmorphism, colourway, Redis, nginx, webpack, eslint, Vitest

Some real-English names are kept deliberately — GitHub, Syncthing, ChatGPT, Postgres
and the like — because they are the *replacement text* for a split form handled in
`FastCleaner.corrections`, and the canonical spelling has to live somewhere editable.

## Why "get hub" → GitHub works anyway

Not through this file. Through `FastCleaner.corrections`, the literal table.

The corrector's real-English guard is `spanCount == 1` only
(`VocabularyCorrector.swift:199`), so a two-word span is exempt — but a span of
entirely ordinary English matched against a term is then held to a near-exact bar,
and "get hub" does not clear it against "github" by letters alone. So the literal
table handles it, beside `"course headers" -> "CORS headers"`, which is there for
exactly the same reason.

That table now covers `git hub`, `gethub`, `chat gpt`, `post gres`, `cloud flare`,
`web pack`, `vs code`, `node js`, `next js`, `three js` unanchored, plus anchored
forms for the ones whose split IS ordinary English — `get hub repo`, `in type
script`, `to you tube`, `with tail wind`, `in air table`, `linked in profile`.

The anchors are not decoration. The first version of that table rewrote

    "I need to get hub caps for the car" -> "I need to GitHub caps for the car"
    "you tube of toothpaste"             -> "YouTube of toothpaste"
    "a tail wind helped the flight"      -> "a Tailwind helped the flight"

Seven false fires in twenty-six cases. `Tests/QuillKitTests/CompoundNameCorrectionTests.swift`
keeps them dead.

## Removed on purpose

Project names that are ordinary English words: Dawn, Clutch, Snap, Watt, Reel,
Verity, Opus, Sonnet, Haiku, Atlas, Iris, Prism, Fabric, Sodium, Lunar, Cursor,
Inter, Forge. Inert as single words, and every one a live multi-word collision risk of
the kind the source already documents ("Roman design cost" → "Roman Design Co", verb
deleted, silently). The Minecraft ones are in under unambiguous full names instead:
`Fabric Loader`, `Iris Shaders`, `Sodium mod`, `Prism Launcher`, `Lunar Client`.

## What has not been verified

No term in this file has been through a real dictation. The list is reasoned from the
corrector's documented guards and a direct `NSSpellChecker` probe, and the compound
table is covered by tests, but the honest test is to say a sentence containing one and
see what lands.

The 50-clip eval corpus is LibriSpeech — nineteenth-century prose — so none of these
terms appear in it and the vocabulary cannot move that WER either way.
