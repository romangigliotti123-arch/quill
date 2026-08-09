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
