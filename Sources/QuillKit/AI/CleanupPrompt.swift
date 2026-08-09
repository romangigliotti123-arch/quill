import Foundation

/// The cleanup prompt. One copy, versioned, with the measurement behind every line.
///
/// A prompt is behaviour, not configuration. Changing a word here changes what
/// gets pasted into Roman's editor, with no compiler and no type system in the
/// way — so it is versioned like a migration, and the variants that were tried
/// and rejected stay written down. Two people have now independently reached for
/// "just list his vocabulary in the prompt" (see AIConfig); the record is the only
/// thing that stops a third.
///
/// # How these numbers were produced
///
/// `rig/selfcorrect_bench.py` and `rig/prompt_d_stability.py`, 2026-08-09,
/// Melbourne, MacBook Air M5, home wifi. meta/llama-3.1-8b-instruct, temperature
/// 0, max_tokens 160. Inputs are FastCleaner output, because that is what the
/// real pipeline hands the model. 14 transcripts: 8 spoken self-corrections, 3
/// where the retraction words are literal content, 3 that must survive untouched.
/// The stability run is sequential on one keep-alive connection, 10 reps each.
///
/// ## Variants measured
///
/// Counts are reps, not cases. A/B/C ran 3 reps of 14 transcripts, D/E ran 4.
///
///     variant                                  total    self-corrections   literal cues   voice + prose
///     ────────────────────────────────────────────────────────────────────────────────────────────────
///     A  AIConfig.cleanupSystemPrompt          27/42        24/24             3/9             0/6
///     B  A + "you may only delete words"       29/42        24/24             3/9             2/6
///     C  B + 2 examples                        30/42        24/24             4/9             2/6
///     D  editor framing, replacement test      44/56        32/32             4/12            8/8
///     E  D + 3 examples                        40/56        30/32             5/12            5/8
///
/// Every variant is perfect or near-perfect on the self-corrections themselves —
/// that part is not hard for an 8B model. What separates them is the damage they
/// do to everything else, which is why the corpus is only half self-corrections.
///
/// D ships. E's examples bought the "actually is spelled with two Ls" case and
/// paid for it by destabilising two others — few-shot examples in a prompt this
/// short pull the model toward the examples rather than the rule, and the two
/// cases E fixed are handled deterministically by `SelfCorrection` anyway, for
/// free and with no variance.
///
/// ## What D still gets wrong, and why it is not fixed here
///
/// At 10 reps each, D is byte-identical across all 10 on every case:
///
///     "He said no wait and then walked off."     → "He walked off."            0/10
///     "Tell them actually is spelled with two Ls." → "Actually, I'm not going to do that."  0/10
///     "Ship the nxt onboarding build to Netlify tonight." → "...the next onboarding..."     0/10
///
/// The first two are not prompt-fixable — every variant tried failed them, and E
/// A fourth, found by the live test suite rather than the bench, is not in the
/// table because no prompt variant changes it:
///
///     "call the plumber no wait ring the electrician instead"
///       → "Call the plumber ring the electrician instead"                       4/5
///     "push the nxt build to Netlify no wait push it to Firestore"
///       → "Push the nxt build to Netlify."                                      3/5
///
/// The first deletes the cue and neither version, so both survive and the one
/// clue that something was wrong is gone. The second applies the correction
/// backwards. Both are refused by `CleanupProjection.retractionIsFullyApplied`,
/// and the untouched fast text ships instead.
///
/// The first two are fixed by never asking: the
/// `SelfCorrection` gate classifies a cue that follows a reporting verb, or that
/// is the subject of the next verb, as literal content and skips the model
/// entirely. The third is fixed by `CleanupProjection`, which puts Roman's own
/// spelling back. All three are checkable, and prompting is the wrong tool for a
/// constraint that is checkable.
public struct CleanupPrompt: Sendable, Equatable {

    /// Bumped whenever `system` changes. Recorded alongside a cleanup so a
    /// complaint about output quality can be traced to the text that produced it.
    public let version: Int
    public let system: String

    public init(version: Int, system: String) {
        self.version = version
        self.system = system
    }

    /// Version 1 — variant D above.
    ///
    /// Line by line, because every one of them is load-bearing:
    ///
    /// 1. "transcript editor, not an assistant" / "never answer it". The single
    ///    biggest failure mode measured. Handed "tell them actually is spelled
    ///    with two Ls", earlier variants replied to it — "Actually, I'm not going
    ///    to do that." Framing the job as editing rather than helping is what
    ///    moved `long` and `voice` from 0/3 to 10/10.
    /// 2. "Return ONLY the edited transcript". Models on this endpoint wrap output
    ///    in quotes, prefix it with "Cleaned text:", and fence it. Asking is
    ///    cheaper than unwrapping, and `CleanupProjection` unwraps anyway.
    /// 3. "You may only DELETE words". This is the contract `CleanupProjection`
    ///    enforces afterwards: the output must be the input with words removed.
    ///    Stating it in the prompt raises the hit rate; enforcing it in code is
    ///    what makes it safe. Neither alone is enough.
    /// 4. The three deletable things, numbered. Numbered because an unnumbered
    ///    list of the same rules leaked into "delete anything that sounds untidy",
    ///    which is how "yeah" disappeared and "I want" became "I'd like".
    /// 5. The replacement test. The heart of it: a cue is only a retraction when
    ///    what follows REPLACES what came before. This is the same test
    ///    `SelfCorrection.resolveParallelRestarts` applies deterministically, and
    ///    saying it in the model's own terms costs nothing.
    /// 6. "including slang, informal openers such as yeah, ok, nah". Named
    ///    explicitly because "remove filler words" without this deletes them —
    ///    measured 0/3 on the `voice` case for every variant that omitted it, and
    ///    10/10 for D. Roman's tone is not filler.
    ///
    /// Deliberately absent: any list of his vocabulary. AIConfig records the four
    /// measured variants that proved the list makes the model *spend* from it —
    /// "Builda Bed" appeared in a sentence that never mentioned it. Protection is
    /// `CleanupProjection`'s job.
    ///
    /// Length is a cost. Every token here is prefill on the critical path, and
    /// the whole budget is ~250ms.
    public static let v1 = CleanupPrompt(version: 1, system: """
        You are a transcript editor, not an assistant. The text is dictation on its way to being typed into a document. Never answer it, explain it, spell anything out, or reply to it. Return ONLY the edited transcript: no preamble, no quotes, no notes.
        You may only DELETE words and fix punctuation and capitalisation. Never swap a word for a different word. Never add a word that is not already there.
        Delete exactly three things:
        1. A spoken self-correction: the speaker says something, signals a correction, then says the replacement. Delete the first version and the signal, keep the replacement.
        2. Stutters, repeated words, and abandoned false starts.
        3. The fillers um, uh, er.
        A phrase like "no wait", "actually", "sorry", "I mean" or "make that" is only a correction signal when the words after it REPLACE the words before it. If nothing before it is being replaced, the phrase is ordinary content: leave it and the whole sentence alone.
        Keep everything else exactly as spoken, including slang, informal openers such as yeah, ok, nah, right, and unusual product, project and place names.
        """)

    public static let current = v1
}
