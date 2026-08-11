import Testing
@testable import QuillKit

// Every "recognised as" string below is real output from Apple's recogniser on
// this machine, not an invented example.
private let vocab = Vocabulary(terms: [
    "graphify", "Netlify", "Craigieburn", "Firestore", "Vesper",
    "blockcraft", "Nebula", "nxt", "Next Fulfilment", "Quill",
])
private func corrector() -> VocabularyCorrector { VocabularyCorrector(vocabulary: vocab) }

@Test func repairsAWordTheRecogniserSplitInThree() {
    // Actual failure: "Push the graphify build" -> "Push the graph if I build"
    let fixed = corrector().correct("Push the graph if I build")
    #expect(fixed == "Push the graphify build")
}

@Test func repairsAMisspelledProperNoun() {
    #expect(corrector().correct("deploy the neglify build") == "deploy the Netlify build")
}

@Test func repairsAPlaceNameSplitInTwo() {
    #expect(corrector().correct("until Craig Eburn is done") == "until Craigieburn is done")
}

@Test func keepsPunctuationAttachedToTheCorrectedWord() {
    #expect(corrector().correct("check neglify, then stop") == "check Netlify, then stop")
}

@Test func leavesOrdinaryEnglishAlone() {
    let sentence = "I need to send the invoice by Friday and then go home"
    #expect(corrector().correct(sentence) == sentence)
}

@Test func doesNotRewriteARealWordThatMerelyResemblesATerm() {
    // "nebula" the astronomical term is a real word; do not force the project casing
    // onto unrelated prose, and never turn "next" into "nxt".
    #expect(corrector().correct("the next meeting") == "the next meeting")
}

@Test func doesNotInventMatchesForShortTokens() {
    #expect(corrector().correct("go to it") == "go to it")
}

@Test func similarityIsSymmetricAndBounded() {
    #expect(VocabularyCorrector.similarity("graphify", "graphify") == 1.0)
    #expect(VocabularyCorrector.similarity("", "abc") == 0.0)
    let a = VocabularyCorrector.similarity("craigeburn", "craigieburn")
    #expect(a > 0.85 && a < 1.0)
}

@Test func normaliseStripsEverythingButLetters() {
    #expect(VocabularyCorrector.normalise("Graph if I!") == "graphifi")
}

// MARK: - Spoken decimals

@Test func aSpokenDecimalIsNotASentenceBoundary() {
    // Straight off Roman's voice corpus. He said "the page loads in about one
    // point four seconds"; the recogniser writes spoken "point" as a full stop,
    // and sentence-casing then did the rest:
    //
    //     The page loads in about one. 4 Seconds on a cold cache.
    //
    // Two errors and a capital in the middle of a sentence, from one decimal.
    #expect(FastCleaner().cleanFast("the page loads in about one. 4 seconds on a cold cache")
              == "The page loads in about 1.4 seconds on a cold cache")
    #expect(FastCleaner().cleanFast("version one. 2.7 went out this morning")
              == "Version 1.2.7 went out this morning")
    #expect(FastCleaner().cleanFast("we cut version two. 0 last night")
              == "We cut version 2.0 last night")
}

@Test func aRealSentenceEndingInANumberIsLeftAlone() {
    // The rule only fires after a spelled-out number word, because a DIGIT before
    // a full stop is far more likely to be a real sentence ending. Getting this
    // wrong would silently weld two sentences into a number.
    #expect(FastCleaner().cleanFast("it shipped in 2020. 3 people worked on it")
              == "It shipped in 2020. 3 people worked on it")
    #expect(FastCleaner().cleanFast("call him back. he is waiting")
              == "Call him back. He is waiting")
}

@Test func aDecimalPointDoesNotArmTheNextCapital() {
    // Pre-existing, and it affected every decimal anyone ever dictated: the
    // capitaliser armed on any full stop and then landed the capital on the next
    // letter however far away, so the digits could not absorb it.
    #expect(FastCleaner.capitaliseSentences(in: "that costs 4.5 dollars")
              == "That costs 4.5 dollars")
    #expect(FastCleaner.capitaliseSentences(in: "the build is 1.2 megabytes now")
              == "The build is 1.2 megabytes now")
    // A genuine break still capitalises.
    #expect(FastCleaner.capitaliseSentences(in: "done. next one")
              == "Done. Next one")
    // A sentence that opens with a number opens with a number; nothing later in
    // it gets promoted instead.
    #expect(FastCleaner.capitaliseSentences(in: "done. 3 people are waiting")
              == "Done. 3 people are waiting")
}

@Test func theTwoNamesThatFailedInHisOwnVoice() {
    // "Wispr Flow stores every transcript in a local SQLite database" came back
    // "Whisperflow stores every transcript in a local SQ light database". The
    // first is one edit from the term once spaces are dropped and is repaired now
    // that the term exists.
    #expect(FastCleaner().cleanFast("Whisperflow stores every transcript in a local database")
              .contains("Wispr Flow"))
}

// MARK: - The corrector must not rewrite sentences into brand names

@Test func anOrdinaryEnglishPhraseIsNeverRewrittenIntoATerm() {
    // Both of these shipped, in the DEFAULT seed vocabulary, and both were found
    // by running the real corrector rather than reading it.
    //
    // "Builda Bed" normalises to "buildabed" and so does "build a bed", and the
    // exact-match branch returned before any guard ran. "Roman design cost"
    // scores 0.867 against "Roman Design Co", cleared the 0.85 multi-word bar,
    // and DELETED the verb — the single-word route has refused real English
    // since the start, and the multi-word route had no such check at all, which
    // is the half where words go missing rather than merely changing spelling.
    let corrector = VocabularyCorrector(vocabulary: .seed)
    for sentence in [
        "I need to build a bed for the spare room",
        "he asked me to build a bed and I did",
        "we build a bed every week",
        "the Roman design cost a lot more than I thought",
        "we know the Roman design cost too much",
    ] {
        #expect(corrector.correct(sentence) == sentence,
                "rewrote ordinary English: \(corrector.correct(sentence))")
    }
}

@Test func everyRepairMeasuredOnHisVoiceStillFires() {
    // The guards above are worth nothing if they close the door on the repairs
    // the pass exists for. Each of these is a measured failure from Roman's own
    // corpus, and each must survive.
    let corrector = VocabularyCorrector(vocabulary: .seed)
    #expect(corrector.correct("push it to Netterfly tonight").contains("Netlify"))
    #expect(corrector.correct("the grapify workspace is fine").contains("graphify"))
    #expect(corrector.correct("run graph if I over the folder").contains("graphify"))
    #expect(corrector.correct("the block craft replica").contains("blockcraft"))
    #expect(corrector.correct("the fire store rules are open").contains("Firestore"))
    #expect(corrector.correct("send it to Noah Kess").contains("Noah Kass"))
    #expect(corrector.correct("until Craig Eburn is done").contains("Craigieburn"))
    // A single span word is the recogniser GLUING a name together, which is the
    // same failure as splitting one and has to stay reachable.
    #expect(corrector.correct("Whisperflow stores every transcript").contains("Wispr Flow"))
}

@Test func aMultiWordTermNeedsAMatchingNumberOfSpokenWords() {
    // "Builda Bed" is two words. A three-word span collapsing into it is a
    // sentence, not a mis-heard name. Single-word terms stay exempt, because a
    // name arriving as several words is the whole reason this pass exists.
    #expect(VocabularyCorrector.spanCanBe("Builda Bed", spanCount: 3) == false)
    #expect(VocabularyCorrector.spanCanBe("Builda Bed", spanCount: 2))
    #expect(VocabularyCorrector.spanCanBe("Builda Bed", spanCount: 1))
    #expect(VocabularyCorrector.spanCanBe("graphify", spanCount: 3))
    #expect(VocabularyCorrector.spanCanBe("Firestore", spanCount: 2))
}
