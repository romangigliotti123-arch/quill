# Next session — a full layout overhaul

Roman's ask, verbatim: *"I want you to do a full workover of the layout because
I'm not really happy with it at the moment."*

Everything below is what this session learned the hard way. Read it before
touching the design, because most of it cost a measurement to find and several
things that look wrong are deliberate.

---

## Start here

The app is on branch `worktree-livetype-latency`, **not merged to master**. It is
installed at BOTH `/Applications/Quill.app` and
`~/Library/Application Support/Quill/build/Quill.app` — they are the same build as
of the last commit. `/Applications` was ten days stale until it was noticed; if
the app ever behaves like an older version, check which one is running.

```
cd ~/Documents/Work/Projects/quill
git log --oneline -12          # today's work
Scripts/build.sh --install     # build + install to /Applications
QUILL_SKIP_LIVE_TESTS=1 Scripts/test.sh   # 564 tests, ~5s
```

## How to actually see the app

This is the part that wasted the most time. The dashboard is a menu-bar window:
`open` will not raise it.

```bash
# Open the dashboard from a shell
xcrun swift rig/tools/show_dashboard.swift        # posts the showWindow notification

# Photograph it — by WINDOW ID, because it opens on whichever Space it was last
# on and a plain screencapture only sees the current one
xcrun swift rig/tools/dashboard_window_id.swift   # prints the window id
screencapture -o -x -l <id> out.png
```

Offscreen renders are faster and need no window server, and they are how every
section should be compared:

```bash
open -a /Applications/Quill.app \
  --env QUILL_DASHBOARD_SHOTS=/tmp/shots \
  --env QUILL_DASHBOARD_SECTIONS=dictation,insights \
  --env QUILL_SHOT_SIZE=1240x860
```

**Offscreen renders do NOT show translucency.** `NSVisualEffectView` draws nothing
through `CALayer.render(in:)`, so every material falls back to the opaque colour
behind it (`DashboardMaterialView.fallback`). Judge layout offscreen; judge
material and blur only from a real screenshot.

## What is already decided, and why — do not undo these

- **Native macOS, not a dashboard.** Real `NSVisualEffectView` materials,
  behind-window blending, content edge to edge, no floating panel, no drop
  shadows. He rejected the previous look explicitly.
- **Colours come from the system.** `.labelColor`, `.separatorColor`,
  `.controlAccentColor`. His Mac is on the **Graphite** accent, so the app is
  monochrome by design — that is macOS being followed, not a missing colour.
- **No shadows anywhere.** `DashboardShadow.none` in all four slots.
- **Ink is shifted one step up the semantic ladder** (`inkTertiary` →
  `.secondaryLabelColor`). Translucency costs contrast; the obvious mapping made
  row subtitles unreadable.
- **No logo, no wordmark, no status pill inside the window.** No Apple app labels
  its own window.
- **No separators between dictation rows.** He asked twice.
- **Sidebar order is by value, not by build order**: Insights, Dictation,
  Dictionary, Snippets, Style, Transforms, Notetaker, Scratchpad. Pinned by a
  test.
- **One animation for every section: fade only, no movement.** The rise animated
  the frame origin, which `layout()` overwrites, so sections that laid themselves
  out mid-animation lost it and the rest kept it — one code path, two animations.
  Do not reintroduce positional entrance animation.
- **Springs, not Bezier curves**, for anything interruptible. `DashboardMotion`
  has Apple's duration/bounce model; bounce is 0 everywhere on purpose.
- **Section titles are aligned to within 1pt** and there is a test
  (`everySectionPutsItsTitleInTheSamePlace`). It was 65pt before. Do not let it
  drift.
- **The icon is a waveform**, flat, and its detail is gated by size (7 bars, 5
  under 48pt, 3 under 24) with every bar pixel-snapped below 64. The snapping is
  what stops it greying out — not the bar count.

## What he still wants — the actual brief

1. **The Music/Podcasts direction, properly.** He picked "editorial, art-led" over
   Mail-style utility. The type scale went to 28pt bold and containers receded,
   but the *architecture* never changed: Dictation is still two side-by-side
   boxes with a large void in the right-hand one. Music is a single composed
   column — hero, then dense sections down the page. This is the main job and it
   means rewriting `DictationSection` (968 lines) and `DictationDetail` (504),
   not retuning tokens.
2. **Less bloat.** The four timing metrics are gone; look for the same kind of
   thing elsewhere. His test: *"the average user doesn't need to know that."*
3. **More micro-interaction.** Hover and press states across rows, buttons and
   controls. `DashboardTween` already exists for hand-drawn views and ticks a
   display link only while moving.

## Traps

- **Do not judge a screenshot at one size.** The old icon read fine at 1024 and
  was mush at 16. The old title alignment looked fine until it was measured.
- **`Scripts/test.sh` needs the plugin flag** it now passes; if `#expect` ever
  fails to expand again, that is SwiftPM dropping `libTestingMacros`, not a
  missing file.
- **Live model tests hit a real endpoint** that rate-limits hard. Six suite runs
  in an hour and the closed-list pass scores 0/6 — that is throttling, not a
  regression. Use `QUILL_SKIP_LIVE_TESTS=1` while iterating on UI.
- **The window sits above a FULLSCREEN app** and only a fullscreen one. Six
  hypotheses were tested and eliminated (window level, stolen activation,
  activation policy, deprecated `activate(ignoringOtherApps:)`, `orderBack` on
  resign, `.managed` collection behaviour). All the fixes were reverted; nothing
  speculative is left in the tree. He says normal windows are fine, so this is
  low priority — but do not "fix" it without reproducing it against a fullscreen
  app first.

## Still open, not started

- Merge to master (`git merge worktree-livetype-latency`) — his call, never done
  automatically.
- Re-run the live model benches on a rested endpoint; the 5/10-fixed figure for
  the context pass was taken on a healthy one and deserves confirming.
- He has more real-use bugs to report; asking for the next one has beaten
  anything found from the corpus every time this session.
