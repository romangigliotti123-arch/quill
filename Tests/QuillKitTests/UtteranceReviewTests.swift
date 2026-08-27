import Foundation
import Testing
@testable import QuillKit

// The last look at the utterance before it is typed. These are the cases that
// decide whether a cleanup pass gets to be wrong in silence.

// MARK: - The backstop

/// The failure this whole type was written for, checked at the layer that is
/// supposed to catch it regardless of which pass caused it.
///
/// This is deliberately NOT the same test as the one in `SelfCorrectionTests`.
/// That one pins the fix in `resolveParallelRestarts`; this one pins the safety
/// net, by handing the review the damaged text directly. If someone removes the
/// sentence-boundary guard, that test goes red and this one keeps the words.
@Test func theReviewOverrulesAPassThatDeletedASentenceItCannotAccountFor() {
    let plain = "They all look bad. They don't look realistic. I want the photos "
        + "of the clothes to actually look realistic. Not just like cartoons."
    // Exactly what the offline resolver produced on 24 Aug 2026.
    let damaged = "They all look bad. They don't look realistic. Not just like cartoons."

    let verdict = UtteranceReview.review(damaged, against: plain)

    #expect(verdict.revertedUnjustifiedDeletion)
    #expect(verdict.text.contains("photos of the clothes"),
            "the review shipped text that had lost a sentence: \(verdict.text)")
    #expect(verdict.note?.contains("photos") == true,
            "the note should name what went missing, got: \(verdict.note ?? "nil")")
}

/// Cleanup reducing an utterance to nothing is never right.
@Test func theReviewRefusesAnEmptyRewrite() {
    let verdict = UtteranceReview.review("", against: "Send the invoice on Friday.")
    #expect(verdict.revertedUnjustifiedDeletion)
    #expect(verdict.text == "Send the invoice on Friday.")
}

/// The deletions the cleaner is *supposed* to make must pass through untouched,
/// or the backstop would undo the app's own work on every second dictation.
@Test func justifiedDeletionsAreLeftAlone() {
    // Filler.
    let filler = UtteranceReview.review("So the build is failing.",
                                        against: "So um the build is failing.")
    #expect(!filler.revertedUnjustifiedDeletion, "a filler removal was overruled")

    // An exact adjacent repeat.
    let repeated = UtteranceReview.review("The build is failing.",
                                          against: "The the build is failing.")
    #expect(!repeated.revertedUnjustifiedDeletion, "a stutter collapse was overruled")

    // A genuine retraction, which is allowed to eat everything before the cue.
    let retraction = UtteranceReview.review("Send it to Carlo.",
                                            against: "Send it to Noah no wait send it to Carlo.")
    #expect(!retraction.revertedUnjustifiedDeletion, "a real retraction was overruled")
}

/// Passes that make the text LONGER are outside what this check can judge, and
/// must not be blocked by it — snippet expansion and the number style both do.
@Test func aPassThatAddedWordsIsNotAccusedOfDeleting() {
    let expanded = UtteranceReview.review(
        "Send it to romangigliotti123@gmail.com on Friday the 3rd.",
        against: "Send it to my email on Friday the 3rd.")
    #expect(!expanded.revertedUnjustifiedDeletion)
    #expect(expanded.text.contains("gmail.com"))
}

/// Unchanged text is the overwhelmingly common case and must be a no-op.
@Test func anUntouchedUtterancePassesStraightThrough() {
    let text = "Can you check whether the deploy finished?"
    let verdict = UtteranceReview.review(text, against: text)
    #expect(verdict.text == text)
    #expect(!verdict.revertedUnjustifiedDeletion)
    #expect(verdict.note == nil)
}

/// Protected vocabulary is not a free deletion.
@Test func droppingAProtectedTermIsNotJustified() {
    let verdict = UtteranceReview.review("Push it to the repo.",
                                         against: "Push it to the Syncthing repo.",
                                         protecting: ["Syncthing"])
    #expect(verdict.revertedUnjustifiedDeletion)
    #expect(verdict.text.contains("Syncthing"))
}

// MARK: - Punctuation the recogniser opened and never closed

@Test func anOrphanedOpeningBracketIsDropped() {
    #expect(UtteranceReview.repairOrphanedPunctuation(in: "Call Noah (about the frames")
        == "Call Noah about the frames")
    #expect(UtteranceReview.repairOrphanedPunctuation(in: "Call Noah about the frames)")
        == "Call Noah about the frames")
}

@Test func balancedPunctuationIsLeftExactlyAsItIs() {
    let balanced = "Call Noah (about the frames) and say \"it is ready\"."
    #expect(UtteranceReview.repairOrphanedPunctuation(in: balanced) == balanced)

    let nested = "Check the log [line 42 (the one that throws)] again."
    #expect(UtteranceReview.repairOrphanedPunctuation(in: nested) == nested)
}

/// Only the unmatched kind is touched — a stray parenthesis must not take a
/// balanced pair of brackets with it.
@Test func onlyTheUnmatchedKindIsDropped() {
    #expect(UtteranceReview.repairOrphanedPunctuation(in: "Check (the log [line 42] again")
        == "Check the log [line 42] again")
}

@Test func anOddNumberOfQuotesLosesTheLastOne() {
    #expect(UtteranceReview.repairOrphanedPunctuation(in: "He said \"it is ready and left")
        == "He said it is ready and left")
}

/// The sweep runs on the unchanged path too, because an orphaned bracket comes
/// from the recogniser rather than from a cleanup pass.
@Test func theSweepRunsEvenWhenNoPassRewroteAnything() {
    let text = "Call Noah (about the frames"
    let verdict = UtteranceReview.review(text, against: text)
    #expect(verdict.text == "Call Noah about the frames")
}

/// A word must never be lost to the punctuation sweep, whatever it is handed.
@Test func thePunctuationSweepNeverRemovesAWord() {
    let cases = [
        "Call Noah (about the frames",
        "He said \"it is ready and left",
        "Check (the log [line 42] again",
        "Nothing to do here at all.",
        "((()))",
        "\"\"",
    ]
    for input in cases {
        let out = UtteranceReview.repairOrphanedPunctuation(in: input)
        let inWords = input.split(whereSeparator: \.isWhitespace)
            .map { $0.filter(\.isLetter) }.filter { !$0.isEmpty }
        let outWords = out.split(whereSeparator: \.isWhitespace)
            .map { $0.filter(\.isLetter) }.filter { !$0.isEmpty }
        #expect(inWords == outWords, "words changed for \(input): \(out)")
    }
}

// MARK: - Cost

/// The review runs on EVERY dictation, on the path between the key coming up and
/// the words appearing, so it has to be free. Measured on his longest real
/// dictation rather than a short fixture — the alignment is quadratic in the
/// worst case, and a 29-second utterance is where that would show.
///
/// Same best-of-three shape as `repairIsFastEnoughToBeInvisible`, for the same
/// reason: one batch shares the machine with whatever else is running.
@Test func theReviewIsFreeOnTheLongestRealDictation() {
    // Roman's 24 Aug dictation, 29 seconds — the longest in his history.
    let plain = "I like all of the ideas from the designs, but I don't like how "
        + "you executed them. All of them just like look like cartoons. They all "
        + "look bad. They don't look realistic. I want the photos of the clothes "
        + "to actually look realistic. Not just like cartoons. So you can like "
        + "look online and find tools to actually make them look like actual "
        + "pieces of clothing, not just like 2D shapes."
    let candidate = plain.replacingOccurrences(
        of: "I want the photos of the clothes to actually look realistic. ", with: "")

    for _ in 0 ..< 25 { _ = UtteranceReview.review(candidate, against: plain) }

    let clock = ContinuousClock()
    var best = Duration.seconds(60)
    for _ in 0 ..< 3 {
        let start = clock.now
        for _ in 0 ..< 200 { _ = UtteranceReview.review(candidate, against: plain) }
        best = min(best, start.duration(to: clock.now) / 200)
    }
    #expect(best < .milliseconds(2), "\(best) per call")
}

/// The common case — nothing was rewritten — must be cheaper still, because it
/// is what almost every dictation does.
@Test func theUnchangedPathCostsAlmostNothing() {
    let text = "Can you check whether the deploy finished and let me know either way?"
    for _ in 0 ..< 25 { _ = UtteranceReview.review(text, against: text) }

    let clock = ContinuousClock()
    var best = Duration.seconds(60)
    for _ in 0 ..< 3 {
        let start = clock.now
        for _ in 0 ..< 500 { _ = UtteranceReview.review(text, against: text) }
        best = min(best, start.duration(to: clock.now) / 500)
    }
    #expect(best < .microseconds(200), "\(best) per call")
}
