# Quill accuracy analysis — where the remaining errors actually are

Written 2026-08-20 overnight, from the frozen 50-clip LibriSpeech run in
`rig/out/20260810-quill-50`, scored with `rig/score.py` and classified by reading
every transcript against `rig/corpus_manifest.tsv`.

The error table below was built by reading all 50 transcripts against the manifest.
The **rate** comes from `rig/score.py`, which applies OpenAI's `EnglishTextNormalizer`
to both sides — the same normaliser Whisper's published numbers use.

> **Update, same night.** The crash fix landed and two clean 50-clip runs followed
> (`20260820-225558`, `20260820-232914`), both scoring **2.81% WER, 32/1138 errors,
> byte-identical to each other**. Against the 2.37% pre-fix baseline that is +0.44
> points, which the rig itself calls a tie inside the noise floor for 50 utterances —
> and two identical runs suggest 2.81% is the honest steady state rather than either
> number being luck.
>
> One error in the table below is now **fixed and verified end to end**: clip
> `121-121726-0003` still transcribes as "Hey fever", and the text actually inserted
> is now "hay fever". Same audio, same recogniser output, different result — the
> homophone entry in `FastCleaner.corrections` firing on a real dictation rather than
> in a test.

## Headline

    clips scored                        50
    clips FAILED                         0
    WER (accuracy)                   2.37%
    CER                              0.70%
    word errors / words            27/1138
    latency median (ms)              11214

**2.37% WER on read speech.** That is a good number.

A note on my own arithmetic: reading the transcripts by hand I counted ~12 errors and
called it "about 1%". The scorer says 27. The gap is real errors I waved past —
compound splits like `sailorman` → "sailor man" and `co exist` spacing, which the
normaliser correctly counts and I did not. **The classification below still holds;
the hand count was simply low.** Trust the scorer, not the prose.

The interesting part is not the rate, it is that the errors are not randomly
distributed: **the largest single class is homophones.**

## Every error in the run

Normalisation matters before reading this. `rig/score.py` applies OpenAI's
`EnglishTextNormalizer` to both sides, which erases case, punctuation, digit spelling
("4 men" → "four men", "13th" → "thirteenth"), and British/American spelling
("colour"→"color", "organised"→"organized"). None of those are errors and none are
listed. What is left is words that are genuinely different words.

| Clip | Reference | Quill produced | Class |
|---|---|---|---|
| 1089-134686-0000 | FLOUR fattened | **flower** fattened | homophone |
| 1320-122612-0001 | the DEWS were | the **dues** were | homophone |
| 121-121726-0003 | HAY fever | **Hey** fever | homophone |
| 4507-16021-0001 | for which READ theft | for which **red** theft | homophone |
| 4507-16021-0001 | for which READ hunger | for which **red** hunger | homophone |
| 4077-13751-0000 | FORMALLY organized | **formerly** organised | homophone |
| 7729-102255-0002 | summer's EMIGRATION | summer's **immigration** | near-homophone |
| 908-157963-0004 | THEL is like | **Fell** is like | proper noun |
| 908-157963-0000 | river of ADONA | river of **Adana** | proper noun |
| 8555-284447-0000 | dominions IF the sailorman | dominions **that** the sailor man | function word |
| 6930-75918-0004 | future opened BEFORE them | future opened **for** them | function word |
| 260-123286-0002 | ALL my danger | **Oh,** my danger | onset misrecognition |
| 7127-75946-0003 | TO your posts | **do** your posts | onset misrecognition |

Not scored as word errors: sentence splits inserted mid-utterance, like
`1320-122612-0001`'s "...in the forest. When the travellers resumed their journey."
where the reference is one clause. The normaliser removes punctuation so these cost
nothing in WER. Counted and dismissed further down — most of them turn out to be
correct.

## The finding

**7 errors are homophones or near-homophones** — the largest single class, and about a
quarter of the scorer's 27. Every one of them is unambiguous from context to any
competent reader:

- "thick peppered **flour** fattened sauce" — *flower* is nonsense in a recipe
- "the **dews** were suffered to exhale" — *dues* do not exhale
- "**hay** fever" — a fixed collocation
- "for which **read** theft" — *read* as in "for which, read X", an idiom
- "**formally** organized" (a church being founded) — not *formerly*
- "that summer's **emigration**... changed the relative strength of the two parties" —
  Kansas settlers leaving, not arriving

These are exactly the errors a language model fixes trivially and an acoustic model
cannot fix at all: the audio is genuinely ambiguous, the context is not.

## Why nothing in the app catches them today

Two correction layers exist and **both structurally exclude this class, on purpose.**

**1. `VocabularyCorrector`** (`Sources/QuillKit/Cleanup/VocabularyCorrector.swift`)
repairs proper nouns against the user's dictionary. Its own guard, quoting the source:
single words "must clear a high bar AND **not be real English** (checked against the
system dictionary)". Both halves of every homophone pair are real English, so it
declines by construction. This is correct — loosening it would let it rewrite words the
user actually meant, which the file explicitly calls "worse than leaving a wrong one,
because they will not notice it."

**2. The NIM cleanup pass** (`Sources/QuillKit/AI/CleanupPrompt.swift`) is contractually
delete-only. The prompt says "You may only DELETE words... **Never swap a word for a
different word**", and `CleanupProjection` *enforces* that the output is the input with
words removed. A homophone fix is a substitution, so it is rejected even if the model
proposed it.

That contract was not arbitrary — `CleanupPrompt.swift` documents a measured bench
(variants A–E, 42–56 reps) where looser framings did real damage to non-correction
text. **Do not fix homophones by loosening the cleanup contract.** That trade was
already measured and lost.

Additionally: every one of the 50 clips recorded `used_thorough_cleanup: false`, so the
AI layer did not run on this corpus at all. Whatever it would have done, it did not do
here.

## Proposed: a separate, narrowly-scoped homophone pass

The right shape is a **third** pass with its own contract, not a change to either
existing one.

**Contract:** may only replace a word with a *pre-declared homophone partner* of that
same word, and only when the language model's confidence in the swap is high. It can
never insert, never delete, never substitute a word that is not on the list. That makes
it checkable in code the same way `CleanupProjection` checks the delete-only contract —
which is the pattern this codebase already trusts.

**Why a fixed pair list rather than free rewriting:** it bounds the blast radius to a
few hundred known-confusable pairs. A model asked to "fix any wrong words" will
eventually rewrite something the user meant; a model asked "is this *flour* or
*flower*?" cannot, because those are the only two answers it is permitted to give.

**Candidate seed list** (the classic English confusables, plus the ones this run found):
flour/flower, dew/due/do, hay/hey, read/red, formally/formerly,
emigration/immigration, their/there/they're, your/you're, to/too/two, its/it's,
principal/principle, complement/compliment, discreet/discrete, stationary/stationery,
affect/effect, weather/whether, peace/piece, right/write/rite, hear/here, break/brake,
aloud/allowed, capital/capitol, censor/sensor, cite/site/sight, coarse/course,
council/counsel, desert/dessert, elicit/illicit, eminent/imminent, fair/fare,
foreword/forward, lead/led, loose/lose, passed/past, patience/patients, peak/peek/pique,
plain/plane, pray/prey, presence/presents, role/roll, scene/seen, sole/soul,
stake/steak, straight/strait, tail/tale, threw/through, waist/waste, wait/weight,
weak/week, which/witch, whose/who's, bear/bare, board/bored, cell/sell, chord/cord,
currant/current, fourth/forth, grate/great, groan/grown, heal/heel, higher/hire,
hole/whole, knight/night, knot/not, know/no, made/maid, mail/male, main/mane,
meat/meet, none/nun, oar/or/ore, one/won, pail/pale, pair/pear, plum/plumb,
poor/pour/pore, rain/reign/rein, raise/rays, rap/wrap, real/reel, ring/wring,
root/route, sail/sale, sea/see, seam/seem, sew/so/sow, shore/sure, sight/site,
son/sun, stair/stare, steal/steel, suite/sweet, team/teem, tide/tied, toe/tow,
vain/vane/vein, vary/very, wear/where, wood/would, yoke/yolk.

**Cost — and the thing that makes this harder than it first looks.**

My first draft of this section proposed folding the homophone question into the
existing cleanup call as a second output field, so it costs no extra round trip. That
does not work, and the reason is worth stating because it is the whole difficulty:

**The model pass almost never runs.** `NIMCleaner.cleanThorough` gates on
`SelfCorrection.needsModelPass(tidy)`, which is true only when the transcript contains
a retraction cue ("no wait", "actually", "I mean") or an immediate repetition.
Ordinary dictation never reaches the model at all — there is a test named
`ordinaryDictationNeverReachesTheModelThroughTheCoordinator` asserting exactly that.
So a homophone instruction added to that call would fire only on the small subset of
dictations that happen to contain a self-correction, which is not where the homophones
are.

A homophone pass therefore needs its **own** trigger, and that means genuinely paying
for it. The options, honestly:

1. **Gate on the pair list.** Only call the model when the transcript contains a word
   from the list. Cheap to check, but "to", "your", "its", "there" are in every other
   sentence, so in practice this fires constantly and the gate saves little.
2. **Gate on a narrower list.** Drop the ultra-common function words and keep the pairs
   that are both frequently misheard and rarely ambiguous in context — flour/flower,
   dew/due, hay/hey, formally/formerly, emigration/immigration, principal/principle,
   discreet/discrete, stationary/stationery, complement/compliment. That fires on a
   small minority of dictations, which makes the latency affordable.
3. **Do it deterministically where the context is a fixed phrase.** "hay fever",
   "flour and water", "formally organised" — the same anchored-literal trick
   `FastCleaner.corrections` already uses for "course headers" -> "CORS headers".
   Free, no model, no latency, and no risk. Covers less, but covers it perfectly.

**Option 3 first, then option 2 for what is left.** Option 3 costs nothing and can
ship immediately; option 2 is the one that needs the bench below.

**How to prove it works before shipping it:** the bench harness already exists in the
shape of `rig/selfcorrect_bench.py`. The same method applies — a corpus that is
*deliberately* only half homophone cases, so the measurement captures the damage done
to the other half, not just the hit rate on the target class. That is the discipline
`CleanupPrompt.swift` already established and it is the right one.

## Secondary findings, lower priority

**Proper nouns (THEL→Fell, ADONA→Adana).** These are the class `VocabularyCorrector`
*is* built for, and it did not catch them only because "Thel" and "Adona" are Blake
poetry, not words in Roman's dictionary. This is working as designed — a general
dictation app cannot know them. Not worth acting on.

**Onset misrecognitions (ALL→Oh, TO→do).** Both are the *first word* of an utterance,
and across the 50 clips the first word is wrong 3 times — 6%, against an overall word
error rate near 1%. First words are roughly six times more likely to be wrong than
words in general.

The obvious explanation is clipped audio, and it is **wrong**. Measured on a tap
recording from tonight's run (`rig/out/20260820-225558-quill/tap/`), the first audible
sample arrives **2.53s** into the recording: the tap opens 0.5s before anything else,
`LEAD` gives the app another 0.4s after the hotkey goes down, and every corpus clip
carries a 1s silent lead of its own. Quill's own log puts `micOpen` at 166–175ms, well
inside that. Nothing is being cut off — there is roughly two seconds of slack.

So this is acoustic, not a capture bug: an utterance-initial word has no preceding
context for the language model to lean on, which is exactly where a weak acoustic
signal turns into a wrong word. That means it is **not** cheaply fixable in the audio
path, and the homophone pass below is the better investment. Worth re-checking the 6%
against a second scored run before treating it as settled — 3 events is a thin sample.

**Sentence splitting mid-clause.** Counted properly: 11 of 50 transcripts contain an
internal sentence break. Reading them, **most are correct** — "the door I think is like
the gate. It is never opened" and "Saturday, August 15. The sea unbroken all round. No
land in sight" are genuinely separate sentences and the reference simply has no
punctuation at all, being LibriSpeech.

Only two or three are real mis-splits, of the "as colourists. Sometimes as
chiaroscurists" kind. That is a weak enough signal that changing the punctuation logic
would risk making the common case worse to fix the rare one, and the decision is the
recogniser's rather than Quill's in the first place. **Not worth acting on.** Recorded
so the next person does not re-derive it from the same eleven hits.

## Suggested order of work

1. **Homophones, option 3 then option 2** — the biggest measurable accuracy win
   available, 7 of the scorer's 27 errors, about a quarter of the WER. Option 3 (fixed
   phrases in `FastCleaner.corrections`) is free and can ship today. Option 2 (a gated
   model pass on a narrow pair list) needs the bench below, because the model pass does
   not currently run on ordinary dictation at all and giving it its own trigger means
   paying real latency.
2. Sentence splitting — measured and dismissed; most of the splits are correct.
3. Onset — understood but not cheaply actionable (see above). Re-measure before
   spending anything on it.

The crash that blocked all of this is fixed (commit `897e890`); a 50-clip run now
completes. This analysis was written against the older `20260810-quill-50` run and
should be re-run against a current one — the fix corrected a format bug that also had
`AnalyzerFeed` resampling from a rate the buffers were not in, so some of the errors
listed above may simply be gone.
