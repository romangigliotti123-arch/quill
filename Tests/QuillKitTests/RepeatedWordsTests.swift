import Foundation
import Testing
@testable import QuillKit

/// The stutter — saying it twice while you decide how the sentence goes.
///
/// Quill removed filled pauses and left every repetition untouched, so
/// "the the invoice", "can you can you check" and "we need to we need to fix"
/// all reached the document intact.
///
/// Three disfluency taggers were measured before this was written — 4M, 11M and
/// 66M parameter deletion-taggers, Apache-2.0, quantised ONNX, all under 2ms.
/// On Roman's 85 real dictations the 11M wanted to delete 89 words, of which 77%
/// were neither a filler nor a repetition: `"So sign in, sign out, create
/// account"` lost an item from its list, `"the option key for transforms"` lost
/// its preposition, `"Because it's wrong."` lost `"wrong"`. The one thing they
/// got right is the one thing that needs no judgement, so it is a rule here.
///
/// On the same 85 dictations this changes 4 and removes 10 words, every one of
/// them a real restart: "up to up to date", "And it's stored and it's stored",
/// "it sort of sort of shows", "It doesn't say, it doesn't say".
@Suite struct RepeatedWordsTests {

    @Test func anImmediateRepeatOfOneWordGoes() {
        #expect(RepeatedWords.collapse(in: "send the the invoice") == "send the invoice")
        #expect(RepeatedWords.collapse(in: "it is is ready") == "it is ready")
        #expect(RepeatedWords.collapse(in: "I I think so") == "I think so")
    }

    @Test func aRestartOfAWholePhraseGoes() {
        #expect(RepeatedWords.collapse(in: "can you can you check that")
                == "can you check that")
        #expect(RepeatedWords.collapse(in: "we need to we need to fix it")
                == "we need to fix it")
        #expect(RepeatedWords.collapse(in: "it should be up to up to date")
                == "it should be up to date")
    }

    /// The half that matters more. English doubles words on purpose, and a
    /// silent deletion inside someone's sentence is the failure this is written
    /// to avoid — so `that`, `had`, `no`, `very`, `so` and their like are
    /// deliberately absent from the single-word list.
    @Test func englishRepeatsWordsOnPurposeAndThoseStay() {
        for kept in [
            "I know that that is true",
            "the sound that that makes is wrong",
            "he had had enough by then",
            "no no leave it where it is",
            "that is very very good",
            "it went on and on for hours",
        ] {
            #expect(RepeatedWords.collapse(in: kept) == kept, "changed: \(kept)")
        }
    }

    /// The second copy is kept, not the first: a restart's second attempt is the
    /// one the speaker meant, and it carries the punctuation they ended on.
    @Test func theSecondAttemptIsTheOneKept() {
        #expect(RepeatedWords.collapse(in: "It doesn't say, it doesn't say a word")
                == "it doesn't say a word")
    }

    /// Through the whole cleanup, which is where it actually runs — and where
    /// the capital lost by keeping the second copy is put back.
    @Test func theCleanupRemovesFilledPausesAndRestartsTogether() {
        let cleaner = FastCleaner()
        #expect(cleaner.cleanFast("the thing is um the thing is it keeps crashing")
                == "The thing is it keeps crashing")
        #expect(cleaner.cleanFast("can you can you check whether the build passed")
                == "Can you check whether the build passed")
    }

    /// A number said twice is a number said twice — "two two" is a digit
    /// sequence, not a stutter, and no digit is on the safe list.
    @Test func repeatedNumbersAreLeftAlone() {
        #expect(RepeatedWords.collapse(in: "the code is two two five") == "the code is two two five")
        #expect(RepeatedWords.collapse(in: "call 9 9 8 now") == "call 9 9 8 now")
    }
}
