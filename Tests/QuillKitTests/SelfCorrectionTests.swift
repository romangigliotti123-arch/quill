import Foundation
import Testing
@testable import QuillKit

// The deterministic half of spoken self-correction. Offline, no network, no
// model — which is also how it runs on a train, so these are not a stand-in for
// the live tests, they are the behaviour Roman gets most of the time.

// MARK: - Tokens

@Test func tokenisationKeepsPunctuationBesideTheWordRatherThanInsideIt() {
    let tokens = SpeechToken.tokenise("Send it to Noah, no wait, send it to Carlo.")
    #expect(tokens.map(\.normalised) == ["send", "it", "to", "noah", "no", "wait", "send", "it", "to", "carlo"])
    #expect(tokens[3].trail == ",")
    #expect(tokens[9].trail == ".")
    #expect(SpeechToken.join(tokens) == "Send it to Noah, no wait, send it to Carlo.")
}

@Test func normalisationIgnoresApostrophesSoLetsAndLetsCompareEqual() {
    // The model is allowed to add the apostrophe in "Let's"; that is a spelling
    // repair, not a changed word, and every check downstream depends on it.
    #expect(SpeechToken.tokenise("lets")[0].normalised == SpeechToken.tokenise("Let's")[0].normalised)
}

@Test func strayPunctuationDoesNotBecomeAWordlessToken() {
    let tokens = SpeechToken.tokenise("hello — world")
    #expect(tokens.map(\.word) == ["hello", "world"])
}

// MARK: - Telling a retraction from a quotation

@Test func aCueAfterAReportingVerbIsQuotedNotRetracted() {
    // The whole reason this feature is not just a find-and-replace on "no wait".
    let tokens = SpeechToken.tokenise("He said no wait and then walked off.")
    let cues = SelfCorrection.cues(in: tokens)
    #expect(cues.count == 1)
    #expect(cues[0].isRetraction == false)
}

@Test func aCueThatIsTheSubjectOfTheNextVerbIsContent() {
    let tokens = SpeechToken.tokenise("Tell them actually is spelled with two Ls.")
    #expect(SelfCorrection.cues(in: tokens).allSatisfy { !$0.isRetraction })
}

@Test func anOrdinaryRetractionIsRecognised() {
    let tokens = SpeechToken.tokenise("Send it to Noah no wait send it to Carlo.")
    #expect(SelfCorrection.cues(in: tokens).contains { $0.isRetraction })
}

@Test func adjacentCuesAreMergedIntoOneSpan() {
    // "actually" and "make that" are two cues back to back. Left separate, one of
    // them sits between the number being replaced and the number replacing it,
    // and the swap becomes invisible.
    let tokens = SpeechToken.tokenise("Let's meet at 3 actually make that 4.")
    let cues = SelfCorrection.cues(in: tokens)
    #expect(cues.count == 1)
    #expect(cues[0].range == 4 ..< 7)
}

@Test func aCueAtTheStartOfTheUtteranceRetractsNothing() {
    // There is nothing behind it to take back.
    let tokens = SpeechToken.tokenise("Actually I think we should ship it.")
    #expect(SelfCorrection.cues(in: tokens).allSatisfy { !$0.isRetraction })
}

// MARK: - The gate

@Test func ordinaryDictationNeverPaysForTheNetwork() {
    // Measured: a completion on this endpoint costs p50 284ms, which is more than
    // the whole dictation budget. Not asking is worth more than asking quickly.
    #expect(SelfCorrection.needsModelPass("Push the graphify build to Netlify tonight.") == false)
    #expect(SelfCorrection.needsModelPass("Yeah just push it and we'll see what breaks.") == false)
    #expect(SelfCorrection.needsModelPass("") == false)
}

@Test func aRetractionOpensTheGate() {
    #expect(SelfCorrection.needsModelPass("Send it to Noah no wait send it to Carlo."))
    #expect(SelfCorrection.needsModelPass("The invoice is for 500 sorry 1500 dollars."))
    #expect(SelfCorrection.needsModelPass("Send Carlo the invoice you know what never mind."))
}

@Test func aStutterOpensTheGateEvenWithNoCueWord() {
    #expect(SelfCorrection.needsModelPass("The the build is is failing on CI."))
    #expect(SelfCorrection.needsModelPass("We should we should probably ship it tomorrow."))
}

@Test func literalCueLanguageKeepsTheGateShut() {
    // This is what makes the two cases no prompt could fix deterministic: they
    // are never sent. Measured 10/10 failures from llama-3.1-8b on both.
    #expect(SelfCorrection.needsModelPass("He said no wait and then walked off.") == false)
    #expect(SelfCorrection.needsModelPass("Tell them actually is spelled with two Ls.") == false)
    #expect(SelfCorrection.needsModelPass("She said sorry and I said sorry back.") == false)
}

@Test func legitimateDoubledWordsAreNotStutters() {
    #expect(SelfCorrection.needsModelPass("I had had enough of it.") == false)
    #expect(SelfCorrection.needsModelPass("It was very very close.") == false)
}

// MARK: - Offline repair: the cases from the bug report

@Test func replacesARetractedName() {
    #expect(SelfCorrection.resolve("Send it to Noah no wait send it to Carlo.") == "Send it to Carlo.")
}

@Test func replacesARetractedTime() {
    #expect(SelfCorrection.resolve("Let's meet at 3 actually make that 4.") == "Let's meet at 4.")
}

@Test func replacesARetractedNumberAndKeepsTheUnitAfterIt() {
    #expect(SelfCorrection.resolve("The invoice is for 500 sorry 1500 dollars.")
            == "The invoice is for 1500 dollars.")
}

@Test func dropsARestartedSentence() {
    #expect(SelfCorrection.resolve("I was going to the I mean I went to the shop.")
            == "I went to the shop.")
}

@Test func dropsAFalseStart() {
    #expect(SelfCorrection.resolve("We should we should probably ship it tomorrow.")
            == "We should probably ship it tomorrow.")
}

@Test func collapsesRepeatedWords() {
    #expect(SelfCorrection.resolve("The the build is is failing on CI.") == "The build is failing on CI.")
}

@Test func stripsATrailingAbandonment() {
    // Strips the abandonment, not the sentence. Deleting what he actually said
    // would insert nothing at all, which is indistinguishable from a crash.
    #expect(SelfCorrection.resolve("Send Carlo the invoice you know what never mind.")
            == "Send Carlo the invoice.")
}

@Test func swapsAProperNounAcrossScratchThat() {
    #expect(SelfCorrection.resolve("Book it for Tuesday scratch that Wednesday.")
            == "Book it for Wednesday.")
}

// MARK: - Offline repair: the cases it must not touch

@Test func leavesQuotedCueLanguageAlone() {
    #expect(SelfCorrection.resolve("He said no wait and then walked off.") == nil)
    #expect(SelfCorrection.resolve("Tell them actually is spelled with two Ls.") == nil)
    #expect(SelfCorrection.resolve("She said sorry and I said sorry back.") == nil)
}

@Test func leavesOrdinaryDictationAlone() {
    let ordinary = [
        "Push the graphify build to Netlify tonight.",
        "Yeah just push it and we'll see what breaks.",
        "Ok so for the barber site I want the booking form on the home page.",
        "Ship the nxt onboarding build tonight.",
    ]
    for text in ordinary { #expect(SelfCorrection.resolve(text) == nil, "mangled: \(text)") }
}

@Test func aLoneSharedWordIsNotEvidenceOfARestart() {
    // "the" appears on both sides of the cue, but not at the start of the
    // utterance, so it is coincidence rather than a restart. One word of evidence
    // only counts when it restarts the whole sentence.
    #expect(SelfCorrection.resolve("Put it on the shelf sorry the desk instead is fine.") == nil)
}

@Test func aSwapNeedsBothSidesToBeTheSameKindOfThing() {
    // "Tuesday" is a mid-sentence proper noun; "quickly" is not, so this is a
    // sentence rather than a swap.
    #expect(SelfCorrection.resolve("Book it for Tuesday actually quickly if you can.") == nil)
}

@Test func repairKeepsRomansSpellingAtTheStartOfASentence() {
    // Deleting a false start can promote one of his terms to the front, and
    // "Graphify" is a different word from "graphify" as far as he is concerned —
    // AIOutputGuard rejects an AI response for exactly this, so the offline path
    // must not commit the same sin.
    let raw = "graphify is broken no wait graphify is fine."
    #expect(SelfCorrection.resolve(raw, protecting: VocabularyFixture.terms)
            == "graphify is fine.")
    // Without the vocabulary it sentence-cases, which is the ordinary behaviour
    // and exactly what the term list is protecting against.
    #expect(SelfCorrection.resolve(raw) == "Graphify is fine.")
}

// MARK: - It has to be cheap

@Test func repairIsFastEnoughToBeInvisible() {
    // It runs before the model on every gated dictation, inside a 250ms budget.
    let text = "Send it to Noah no wait send it to Carlo and tell him the the frames are ready."

    // Warm up outside the measurement. The first call pays for regex compilation
    // and the system spell checker waking up, which is real cost the app pays
    // once at launch and not the per-call cost this test is about.
    for _ in 0 ..< 25 { _ = SelfCorrection.resolve(text) }

    // Best of three batches, not one.
    //
    // A single batch shares the machine with whatever else is running, and this
    // suite is routinely run while a build or an eval is going. One descheduled
    // batch was failing a claim about the code — a red test that says nothing
    // about the code is worse than no test, because it trains you to re-run.
    // The fastest batch is the one least polluted by the scheduler, and it is
    // still an honest upper bound on the cost.
    let clock = ContinuousClock()
    var best = Duration.seconds(60)
    for _ in 0 ..< 3 {
        let start = clock.now
        for _ in 0 ..< 200 { _ = SelfCorrection.resolve(text) }
        best = min(best, start.duration(to: clock.now) / 200)
    }
    #expect(best < .milliseconds(2), "\(best) per call")
}

// MARK: - A restart begins where it was last said

/// The restart point is the most RECENT place those words were said. Taking the
/// first occurrence ate every clause in between — silently, on the offline path,
/// with no way for the user to know words they said had gone.
@Test func aRestartDeletesOnlyFromWhereItActuallyRestarted() {
    // Two parallel instructions; only the second is retracted.
    let twoInput = "Send it to Noah and then send it to Sam no wait send it to Carlo."
    let two = SelfCorrection.resolve(twoInput) ?? twoInput
    #expect(two.lowercased().contains("noah"),
            "the un-retracted first instruction was deleted: \(two)")
    #expect(two.lowercased().contains("carlo"))
    #expect(!two.lowercased().contains("sam"), "the retracted clause survived: \(two)")

    // The single-word shape, which reached the same bug through the `start == 0`
    // relaxation: head [add], first occurrence 0, so the whole utterance up to
    // the cue was deleted and "Add milk to the list" vanished.
    //
    // The pass now declines it instead — [add]'s LAST occurrence before the cue
    // is not the start of the utterance, so the one-word rule correctly refuses
    // to call it a restart. That leaves the retracted clause in, which is not
    // ideal; it is enormously better than deleting a clause the user meant. Nil
    // means "nothing changed", so the assertion is against the original.
    let listInput = "Add milk to the list and add bread to the list no wait add eggs to the list."
    let list = SelfCorrection.resolve(listInput) ?? listInput
    #expect(list.lowercased().contains("milk"), "an un-retracted clause was deleted: \(list)")
    #expect(list.lowercased().contains("eggs"))
}

/// The whole-utterance restart still works, which is what the one-word rule is
/// for.
@Test func aRestartOfTheWholeUtteranceStillDeletesAllOfIt() {
    let outInput = "I was going to the shop I mean I went to the market."
    let out = SelfCorrection.resolve(outInput) ?? outInput
    #expect(!out.lowercased().contains("shop"), "the retracted opening survived: \(out)")
    #expect(out.lowercased().contains("market"))
}

// MARK: - A restart may not reach back through a finished sentence

/// Regression, from Roman's own history on 24 Aug 2026. Eleven words of real
/// content deleted offline, by a rule, with no model anywhere near it — the exact
/// failure the whole file is written to avoid.
///
/// "actually" is a retraction cue; the two words after it are "look realistic";
/// and those two words also close the PREVIOUS sentence. So the restart matched
/// across the full stop and deleted everything between the two occurrences,
/// taking the sentence he actually meant with it.
@Test func aRestartDoesNotReachBackThroughAFinishedSentence() {
    let input = "They don't look realistic. I want the photos of the clothes to "
        + "actually look realistic. Not just like cartoons."
    let out = SelfCorrection.resolve(input) ?? input

    #expect(out.lowercased().contains("photos of the clothes"),
            "a whole sentence the speaker meant was deleted: \(out)")
    #expect(out.lowercased().contains("not just like cartoons"))
    // Nothing to correct here, so the resolver should decline outright.
    #expect(SelfCorrection.resolve(input) == nil,
            "the resolver changed a sentence that carried no retraction")
}

/// The other half of the same rule, and the reason the check ignores a
/// terminator sitting immediately before the cue: finishing a sentence and then
/// taking it back with your next word IS a retraction, and must still work.
@Test func aRetractionThatStartsRightAfterAFullStopStillResolves() {
    let input = "I went to the shop. Actually I went to the park."
    let out = SelfCorrection.resolve(input) ?? input
    #expect(!out.lowercased().contains("shop"), "the retracted sentence survived: \(out)")
    #expect(out.lowercased().contains("park"))
}

/// Same-sentence restarts are untouched by the sentence-boundary guard — there is
/// no terminator inside the span for it to trip on.
@Test func theSentenceBoundaryGuardLeavesSameSentenceRestartsAlone() {
    let input = "Send it to Noah and then send it to Sam no wait send it to Carlo."
    let out = SelfCorrection.resolve(input) ?? input
    #expect(out.lowercased().contains("noah"))
    #expect(out.lowercased().contains("carlo"))
    #expect(!out.lowercased().contains("sam"), "the retracted clause survived: \(out)")
}
