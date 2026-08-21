import Foundation
import Testing
@testable import QuillKit

// Live typing calls cleanFast on the WHOLE transcript so far, once per partial.
// So a dictation is not one pass over N characters, it is ~N/20 passes over a
// growing prefix — and the vocabulary matcher, the expensive part, was redoing
// every decision it had already made on every one of them.
//
// Measured before this was fixed, on the release build: 37ms to clean 50
// characters, 284ms for 400, 543ms for 800, 1.1s for 1600. All of it on the main
// thread, which is also the thread that draws the waveform and services the key
// release. Roman's report — "I read out a long paragraph and the text keeps
// appearing for 30 seconds after I stop, the waveform freezes, and it keeps
// listening after I let go" — is that one fact wearing three faces.
//
// These count matcher work rather than timing it. A clock on this machine
// measures whatever else the machine is doing; a counter measures the algorithm.

private let vocab = Vocabulary(terms: [
    "graphify", "Netlify", "Craigieburn", "Firestore", "Vesper",
    "blockcraft", "Nebula", "nxt", "Next Fulfilment", "Quill",
])

/// Ordinary prose with no vocabulary terms in it — the common case, and the one
/// that has to be cheap.
private let paragraph = """
there is a moment in every long piece of dictation where the recogniser has \
heard enough to be confident and begins revising what it already said which is \
exactly when the text on screen has to be rewritten from the point of the \
revision onwards and that is the moment the whole thing has to still be fast \
enough to keep up with someone who is still talking about something else
"""

private func words() -> [String] {
    paragraph.split(separator: " ").map(String.init)
}

@Test func cleaningAGrowingTranscriptDoesNotRedecideWhatItAlreadyDecided() {
    let corrector = VocabularyCorrector(vocabulary: vocab)
    let all = words()
    // Enough words that a quadratic pass is unmistakably distinguishable from a
    // linear one, without making the pre-fix run slow enough to be annoying.
    let count = min(all.count, 50)

    var perPartial: [Int] = []
    for n in 1...count {
        let before = corrector.spansMatchedForTesting
        _ = corrector.correct(all[0..<n].joined(separator: " "))
        perPartial.append(corrector.spansMatchedForTesting - before)
    }

    // The tenth partial and the fiftieth both add one word to the end. They must
    // cost about the same. Before the memo the later one cost five times the
    // earlier, because it re-matched every span in the sentence from the start.
    let early = perPartial[9]
    let late = perPartial[count - 1]
    #expect(late <= early + 4,
            "partial \(count) matched \(late) spans, partial 10 matched \(early): the work is growing with the transcript instead of with what was added")

    // And the whole dictation must be linear in what was said, not quadratic.
    // One new word can open at most three new spans (1, 2 and 3 tokens wide).
    let total = perPartial.reduce(0, +)
    #expect(total <= count * 3 + 10,
            "matched \(total) spans over \(count) partials; a linear pass is at most \(count * 3 + 10)")
}

@Test func rememberingASpanDoesNotChangeWhatItDecides() {
    // The memo is only correct if the matcher is a pure function of the span, the
    // span length and whether sound may decide. Same corrector, same sentence,
    // twice: the second answer comes from the cache and must be the first one.
    let corrector = VocabularyCorrector(vocabulary: vocab)
    let sentences = [
        "Push the graph if I build",
        "deploy the neglify build",
        "until Craig Eburn is done",
        "check neglify, then stop",
        "I need to build a bed for the spare room",
        "the Roman design cost a lot more than I thought",
        "fire store rules are in the console",
        paragraph,
    ]
    for sentence in sentences {
        let first = corrector.correct(sentence)
        let second = corrector.correct(sentence)
        #expect(first == second, "second pass over \(sentence.prefix(40)) differed")
    }
}

@Test func aFreshCorrectorAgreesWithAWarmOne() {
    // The cache must not be able to carry an answer that a cold corrector would
    // not have reached — including across sentences, where the same span recurs
    // in a different neighbourhood.
    let warm = VocabularyCorrector(vocabulary: vocab)
    let sentences = [
        "Push the graph if I build",
        "the graph if I run finished",
        "deploy the neglify build",
        "neglify is down again",
        "until Craig Eburn is done",
        "Craig Eburn station closes at ten",
        paragraph,
    ]
    // Warm it on everything first, so every span below is served from the cache.
    for sentence in sentences { _ = warm.correct(sentence) }

    for sentence in sentences {
        let cold = VocabularyCorrector(vocabulary: vocab).correct(sentence)
        #expect(warm.correct(sentence) == cold,
                "warm and cold disagreed on \(sentence.prefix(40))")
    }
}

@Test func editingTheDictionaryTakesEffectOnTheNextSentence() {
    // The reason `terms` is read per call and not held: a word added in the
    // Dictionary has to work immediately. A cache keyed on nothing would break
    // exactly that, silently.
    // A real file, so the book behaves as it does in the app rather than falling
    // back to the shipped seed — which contains Netlify, and would make this
    // pass without proving anything.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-memo-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(Vocabulary(terms: ["Craigieburn"]).save(to: url))

    let book = VocabularyBook(url: url)
    let corrector = VocabularyCorrector(book: book)

    #expect(corrector.correct("deploy the neglify build") == "deploy the neglify build")

    #expect(book.add("Netlify"))
    #expect(corrector.correct("deploy the neglify build") == "deploy the Netlify build",
            "a term added to the book did not take effect on the next sentence")
}
