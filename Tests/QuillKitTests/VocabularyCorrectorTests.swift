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

// MARK: - Manglings the fuzzy corrector cannot reach

@Test func anchoredCorrectionsFixWhatTheGuardsCorrectlyRefuse() {
    // Three of the proper-noun errors in Roman's corpus are unreachable by the
    // fuzzy corrector, and each for a good reason:
    //
    //   "course" for CORS   — "course" is real English, so the guard that stops
    //                         the corrector rewriting words he meant refuses it.
    //   "vespa"  for Vesper — same; "vespa" is a word.
    //   "SQ light" for SQLite — 0.57 against the term, far below the 0.85 bar,
    //                         and lowering that bar is what let "build a bed"
    //                         become "Builda Bed" this morning.
    //
    // A literal table reaches them because it asks a different question: not "is
    // this span near a term" but "is this the exact string I have watched the
    // recogniser produce for him".
    let cleaner = FastCleaner()
    #expect(cleaner.cleanFast("the API has no course headers").contains("CORS headers"))
    #expect(cleaner.cleanFast("a local SQ light database").contains("SQLite"))
    #expect(cleaner.cleanFast("Vespa is the lunar style rapper").hasPrefix("Vesper"))
    #expect(cleaner.cleanFast("push it to neglified tonight").contains("Netlify"))
}

@Test func theOrdinaryMeaningsOfThoseWordsSurvive() {
    // The whole reason the two real-English ones are anchored on the word that
    // followed them in his actual dictation. An unanchored "course" -> "CORS"
    // would rewrite "of course" every time he said it, which is a far commoner
    // sentence than anything about headers.
    let cleaner = FastCleaner()
    for sentence in [
        "of course I will send it tomorrow",
        "the course was harder than I expected",
        "he rode a Vespa around Rome",
        "turn the light off please",
    ] {
        let out = cleaner.cleanFast(sentence)
        let expected = sentence.prefix(1).uppercased() + sentence.dropFirst()
        #expect(out == expected, "rewrote an ordinary sentence: \(out)")
    }
}

// MARK: - The harvested dictionary

@Test func soundIsOnlyEvidenceWhenTheSpellingAgrees() {
    // "y t dlp" — the recogniser spelling out yt-dlp — was being replaced by
    // "Netlify". The two share 0.143 of their letters. Sound alone carried a
    // match that spelling could not support, and the guards above never saw it
    // because the input is his jargon rather than ordinary English, so the
    // damage half of the scoring harness could not catch it either.
    //
    // Every repair this route actually exists for looks at least somewhat like
    // its target: 0.57 for "net a fly", 0.67 for "Netterfly", 0.73 for
    // "Craigie Bear". A floor at 0.45 sits below all of them and far above the
    // collision.
    let corrector = VocabularyCorrector(vocabulary: .seed)
    #expect(corrector.correct("run y t dlp on that playlist") == "run y t dlp on that playlist")

    // and every phonetic repair still fires
    #expect(corrector.correct("push it to Netterfly tonight").contains("Netlify"))
    #expect(corrector.correct("until Craig Eburn is done").contains("Craigieburn"))
    #expect(corrector.correct("the grapify workspace").contains("graphify"))
}

@Test func theHarvestedTermsRepairTheSplitCompoundFailure() {
    // The recogniser's signature failure on a name it has never heard is to
    // split it — "blockcraft" as "block craft", "Firestore" as "fire store",
    // "graphify" as "graph if I". These terms were harvested from his machine
    // and have never appeared in the scored corpus, so this is the only evidence
    // available that they will do anything when they finally turn up in speech.
    let corrector = VocabularyCorrector(vocabulary: .seed)
    #expect(corrector.correct("open the media deck sidebar").contains("mediadeck"))
    #expect(corrector.correct("the t mux panes persist").contains("tmux"))
    #expect(corrector.correct("check the shad cn components").contains("shadcn"))
    #expect(corrector.correct("the space grotesk heading").contains("Space Grotesk"))
}

// Heard in a real dictation, 21 Aug 2026. The recogniser produced
//
//     "The client found me on Air Tasker. He's been discreet about budget"
//
// and what was typed into the document was
//
//     "The client found me on Airtasker been discreet about budget"
//
// "He's" is gone. This is the failure the comment above `isBoundaryWord` calls
// out — "the replacement swallowed the verb: 'Until Craigieburn done'" —
// recurring on a word class the guard does not cover. `boundaryWords` protects
// is/was/the/a and the rest of the closed-class words, but no pronouns, so a
// three-word span ending in "he's" is allowed to collapse into a one-word name.
@Test func doesNotSwallowAPronounAfterAName() {
    let c = VocabularyCorrector(vocabulary: Vocabulary(terms: ["Airtasker"]))
    #expect(c.correct("found me on Air Tasker. He's been discreet")
            == "found me on Airtasker. He's been discreet")
}

@Test func doesNotSwallowOtherPronounsEither() {
    let c = VocabularyCorrector(vocabulary: Vocabulary(terms: ["Airtasker"]))
    let cases = [
        ("I put it on Air Tasker they replied fast", "I put it on Airtasker they replied fast"),
        ("posted to Air Tasker she got back to me", "posted to Airtasker she got back to me"),
        ("listed on Air Tasker we waited a week", "listed on Airtasker we waited a week"),
        ("up on Air Tasker you can see it", "up on Airtasker you can see it"),
    ]
    for (input, expected) in cases {
        #expect(c.correct(input) == expected, "got: \(c.correct(input))")
    }
}
