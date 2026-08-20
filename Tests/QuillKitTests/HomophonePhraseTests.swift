import Testing
@testable import QuillKit

// The homophone entries in FastCleaner.corrections.
//
// Homophones are the largest single error class in the eval corpus and the one
// class neither correction layer can touch: VocabularyCorrector refuses any
// single word the spell checker accepts, and both halves of a homophone pair are
// real English; the model pass may only delete, never swap.
//
// Only the ones a FIXED PHRASE decides are handled here. "hey fever" is never
// right; "principle developer" is never right. Where the phrase does not decide
// it — peace vs piece of mind, led vs lead, its vs it's — the table stays out of
// the way, and the `leavesGenuinelyAmbiguousPairsAlone` test below is what keeps
// it that way.

private func clean(_ s: String) -> String { FastCleaner.applyCorrections(to: s) }

@Test func fixesHomophonesThatAFixedPhraseDecides() {
    #expect(clean("I get hey fever in spring") == "I get hay fever in spring")
    #expect(clean("he is a principle developer") == "he is a principal developer")
    #expect(clean("the principle amount owing") == "the principal amount owing")
    #expect(clean("agreed in principal") == "agreed in principle")
    #expect(clean("be discrete about it") == "be discreet about it")
    #expect(clean("from the stationary shop") == "from the stationery shop")
    #expect(clean("complimentary colours work best") == "complementary colours work best")
    #expect(clean("it compliments each other well") == "it complements each other well")
    #expect(clean("the affect on the layout") == "the effect on the layout")
    #expect(clean("no affect on performance") == "no effect on performance")
    #expect(clean("watch for side affects") == "watch for side effects")
    #expect(clean("your welcome to try") == "you're welcome to try")
    #expect(clean("we are loosing the thread") == "we are losing the thread")
}

@Test func leavesGenuinelyAmbiguousPairsAlone() {
    // Both readings are real. A table cannot decide these and must not try.
    let untouched = [
        "it gives me peace of mind",
        "a piece of mind is not a phrase I use",
        "loose the reins a little",
        "the lead time is two weeks",
        "she led by example",
        "the site has its own domain",
        "it's the same either way",
        "a compliment from a client",
        "the train was stationary",
        "keep it discrete and separate",
        "the principle of least surprise",
        "how does that affect the build",
    ]
    for sentence in untouched {
        #expect(clean(sentence) == sentence, "rewrote: \(sentence)")
    }
}
