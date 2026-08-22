# The layout overhaul — what it did, and what is still open

Roman's brief, in his own words, taken off his own dictation history rather than
paraphrased:

> "for the layout, at the moment, I'm only really liking the Insights and the
> Dictionary tabs, everything else I just don't really like. I think it's either
> bloated, there's just too many little visual bugs that just put me off, or it's
> just not how the other tabs have been styled. I want you to go over all of them
> fully and look at every little tiny little detail ... make sure that everything
> looks perfect."

> "i don't really want any unneeded little bits of information or little bits of
> text, et cetera. So try get rid of that as much as possible, only [what is]
> actually needed, the things that the average user is actually going to use."

**Insights and Dictionary are the bar.** Everything else had to reach them.

---

## The instrument, first

`QUILL_LAYOUT_PROBE=1` prints, per section: where the title starts, how far
content reaches, the tallest empty band, and what fraction of a 16×16 grid has
anything in it.

```bash
QUILL_LAYOUT_PROBE=1 QUILL_SHOT_SIZE=1350x850 \
  "$HOME/Library/Application Support/Quill/build/Quill.app/Contents/MacOS/Quill"
```

It located the complaint in one run: the two screens he liked were the two above
70% coverage, and the three he could not name a reason for were at 5, 21 and 22 —
and were also the three whose headings sat 24 points lower than everywhere else.
His taste and the numbers agreed exactly, and neither of us could have said that
from screenshots.

**One rule makes it work: only LEAVES count.** The first version walked every
subview's frame and reported Dictation as full — because its list well and its
record card both stretched to the bottom padding while the card was two thirds
empty inside. A box is not content, it is a box.

Second rule: normalise for flipped coordinates. Half the sections were manual
layout in a flipped view and half were Auto Layout in an unflipped one, and
reading `.origin.y` from both reported a 30pt drift as 670.

| | before | after |
|---|---|---|
| title spread | 24pt | **0pt** |
| dictation coverage | 69% | 83% |
| transforms | 54% | 57%, void gone |
| settings dead width | 450pt | 0 |

---

## What changed

**Dictation is one column.** A hero record sized to its content, then the whole
history at full width, grouped by day. It was a 452pt list beside a half-window
card: every dictation longer than six words truncated, and the card was two
thirds empty on every record. Starved and empty at once, in the same 1350 points.
Row text went from ~370pt to ~800pt. The hero cannot leave a void because nothing
under it is pinned — the list takes whatever is left. **Transforms and Scratchpad
now use the same shape**, so three screens share one arrangement.

**Every section gets its title from `DashboardSectionHeader`.** Ten sections used
to build their own out of the same three ingredients; two stacked an empty
eyebrow above the title, one centred its meta line, three used Auto Layout in an
unflipped view. Nine correct headers and one wrong one is a coin flip every time
a section is edited.

**Settings and Help are two balanced columns** (`DashboardColumns`), not a 620pt
stripe with 450 points of empty window beside it. The row measure stays capped —
a label and its control a hand's width apart really is worse to read — and the
page gets a second column instead. Which is what Insights and Dictionary, the two
he likes, already do.

**Bloat cut:** per-row latency, "clean" on every row, `54 wpm · MacBook Air
Microphone · Fast cleanup`, Transforms' entire "Guards" block (the 60%/160%
length ratio, the after-the-fact dictionary check), and it no longer prints the
raw model prompt as "What it does". `1 words` → `1 word`.

**Insights' response-time histogram → words over time**, bucketed day/week/month
by range. Thirty daily columns against a real habit is twenty-four empty slots and
one spike, which reads as broken rather than sparse — the bucket has to widen with
the window, as every Apple health chart does. Hovering a column swaps the headline
to that period.

---

## Bugs found, and what they teach

**The Dictionary filter was a picture of a control.** All / Added by you /
Learned had no tracking area, no `mouseDown`, no `mouseUp` and no callback. Drawn
perfectly. Every instrument passed it: the screenshot harness (it draws, and
draws correctly), the layout tests (its frame is right). Only clicking could tell.
`everyControlOnEveryScreenRespondsToTheMouse` in `DashboardLayoutTests.swift` now
walks every section's real view tree and asserts anything control-shaped answers
the mouse. **Add new drawn controls to that list** — it is the register.

**The title-alignment test had been passing vacuously since it was written.** It
matched on `NSTextField.font`, and every label here sets `attributedStringValue`
without touching the cell's font — so it asked for 28pt and was told 13pt, matched
nothing, and `guard let low = values.min() else { return }` returned a pass. Green
for its whole life while three sections sat 24 points out of line. It now asserts
the count before the spread, and `theTitleFinderCanActuallyFail` pins the finder.

**A system colour resolved outside a draw cycle takes the SYSTEM's appearance.**
`InsightsInlineLegend` drew a white dot on a white card in light mode while the
bar directly above it used the identical expression and was fine — the bar
computed it inside `draw(_:)`, the legend in `configure`. `.labelColor` is dynamic;
ask for it at draw time, never store the result. Written up at the top of
`DashboardStyle.swift`.

**⌥⌫ would have deleted the user's own typing.** The guard that makes overriding
"delete the previous word" defensible is "any keystroke since the insertion
disarms it", and it lives on the tap's `.keyDown` branch — but the tap goes blind
on `.tapDisabledByTimeout`, on Secure Input (Ghostty has a setting for it), and
while `scheduleRetry` polls. Type a paragraph in that window, press ⌥⌫, and it
backspaced over your words. `undo?.discard()` now runs on every blind path;
`losingTheTapThrowsTheUndoRecordAway` is mutation-checked.

---

## Still open

- **~110 verified review findings are unread.** The defect-hunt workflow hit the
  session limit with 113 of 231 agents finished. The two high-severity ones are
  fixed (Dictation's hero vanishing on a zero-result query, Insights' footnote
  drawn outside its card at 1060×700). The rest are in the workflow output under
  `.../tasks/wqt6339rv.output` and deserve a pass.
- **Style (28%) and Scratchpad (16%) are still thin.** Style genuinely has almost
  no learned data yet and Scratchpad has one empty note; both fill with use. Judge
  them again after a week of real use rather than tuning them against empty
  stores.
- **No note editor.** Scratchpad lists notes and opens one for reading. Clicking
  copies, because that is the only honest thing a click can do until there is
  somewhere to type.
- ~~**The ⌥⌫ hole that could not be closed**~~ — closed 22 Aug, and the strict
  version turned out to be the bug. A probe (`QUILL_CARET_PROBE=1`) asked every
  running app what it exposes: Ghostty answers `AXTextArea` with a caret pinned
  at 0 on an attribute that is not even settable, Chrome an `AXGroup` with no
  caret, VS Code no focused element — TextEdit alone answers exactly. Three of
  four, and the three he dictates into. Now: a caret at 0 is read as "no caret"
  rather than "the field is too short", and such a field is verified against its
  visible text instead (`AXValue`, whitespace- and frame-insensitive), which
  works in a terminal. `QUILL_LOG_UNDO=1` traces every decision on the path.
- **Live model benches** still want a rested endpoint.

## How to see it

```bash
Scripts/build.sh --install
QUILL_SKIP_LIVE_TESTS=1 Scripts/test.sh          # 599 tests, ~10s

xcrun swift rig/tools/show_dashboard.swift        # raise the window
xcrun swift rig/tools/dashboard_window_id.swift   # then screencapture -o -x -l <id>
```

Offscreen renders (`QUILL_DASHBOARD_SHOTS`, `QUILL_DICTATION_SHOTS`) do NOT show
translucency — `NSVisualEffectView` draws nothing through `CALayer.render(in:)`.
Judge layout, type and spacing there; judge material only from a real screenshot.
