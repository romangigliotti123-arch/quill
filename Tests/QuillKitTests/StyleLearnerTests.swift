import Foundation
import Testing
@testable import QuillKit

// Every pair below is shaped like a real correction — the text Quill inserted
// against the text the user kept — because the failure mode of a learner is not
// that it crashes, it is that it quietly learns nothing, or learns the wrong
// thing from a typo fix. Both are invisible without tests like these.

private let date = Date(timeIntervalSince1970: 1_770_000_000)

// MARK: - Diff

@Test func theDiffReportsOnlyWhatChanged() {
    let segments = StyleDiff.segments(["the", "cat", "sat"], ["the", "dog", "sat"])
    #expect(segments == [StyleDiff.Segment(from: ["cat"], to: ["dog"])])
}

@Test func theDiffIgnoresPunctuationAndCasing() {
    // Otherwise every trailing comma becomes a "phrasing".
    #expect(StyleDiff.segments(["Send", "it,"], ["send", "it"]).isEmpty)
}

@Test func theDiffHandlesInsertionsAndDeletions() {
    #expect(StyleDiff.segments(["a", "b"], ["a", "x", "b"]) == [StyleDiff.Segment(from: [], to: ["x"])])
    #expect(StyleDiff.segments(["a", "x", "b"], ["a", "b"]) == [StyleDiff.Segment(from: ["x"], to: [])])
    #expect(StyleDiff.segments(["a"], ["a"]).isEmpty)
}

@Test func theDiffRefusesToBuildAMillionCellTableForAPastedDocument() {
    let long = Array(repeating: "word", count: StyleDiff.maximumTokens + 1)
    let segments = StyleDiff.segments(long, ["short"])
    #expect(segments.count == 1)
    // And nothing that size can become a phrasing, so a giant paste teaches
    // nothing rather than hanging.
    #expect(StyleLearner.phrasings(segments: segments).isEmpty)
}

// MARK: - Spelling

@Test func aSpellingCorrectionIsLearnedFromTheEditItself() {
    let observation = StyleLearner.observe(
        dictated: "Check the capitalization on that heading.",
        edited: "Check the capitalisation on that heading."
    )
    #expect(observation.spelling == .british)
    // And it is not also filed as a phrasing — one edit, one explanation.
    #expect(observation.phrasings.isEmpty)
}

@Test func spellingIsAlsoReadFromTheTextHeKept() {
    // The commoner case: Quill never got it wrong, he simply writes "colour".
    let observation = StyleLearner.observe(
        dictated: "the colour is close enough",
        edited: "the colour is right"
    )
    #expect(observation.spelling == .british)
}

@Test func ordinaryEnglishIsNotEvidenceOfEitherConvention() {
    let observation = StyleLearner.observe(
        dictated: "I will advise them to raise it and exercise the option",
        edited: "I'll advise them to raise it and exercise the option"
    )
    // "advise", "raise" and "exercise" are spelled that way everywhere. A
    // detector that reads them as British finds British habits in everyone.
    #expect(observation.spelling == nil)
}

// MARK: - Contractions

@Test func expandingContractionsTeachesTheOppositeOfContractingThem() {
    #expect(StyleLearner.observe(dictated: "I do not think that is right.",
                                 edited: "I don't think that's right.").contractions == true)
    #expect(StyleLearner.observe(dictated: "I don't think that's right.",
                                 edited: "I do not think that is right.").contractions == false)
}

@Test func aContractionChangeIsNotAlsoRecordedAsAPhrasing() {
    let observation = StyleLearner.observe(dictated: "I do not think so today.",
                                           edited: "I don't think so today.")
    #expect(observation.phrasings.isEmpty)
}

@Test func oneFormalPhraseInAParagraphIsASentenceNotAHabit() {
    let observation = StyleLearner.observe(dictated: "It is ready for review now.",
                                           edited: "It is ready for review today.")
    #expect(observation.contractions == nil)
}

// MARK: - Formality

@Test func formalityIsLearnedOnlyFromASwapTheUserActuallyMade() {
    #expect(StyleLearner.observe(dictated: "Hello Noah, the invoice is attached.",
                                 edited: "hey Noah, the invoice is attached.").formality == .casual)
    #expect(StyleLearner.observe(dictated: "hey Noah, the invoice is attached.",
                                 edited: "Dear Noah, the invoice is attached.").formality == .formal)
}

@Test func aFormalWordMerelyBeingPresentTeachesNothing() {
    // The tempting bug: reading register off word frequency. "Thanks" appearing
    // in a message he happened to edit elsewhere is not a preference.
    let observation = StyleLearner.observe(dictated: "Thanks for sending the file over.",
                                           edited: "Thanks for sending the file through.")
    #expect(observation.formality == nil)
}

// MARK: - Punctuation

@Test func theSerialCommaIsReadOffRealLists() {
    #expect(StyleLearner.oxfordComma(in: "I got bread, milk, and eggs.") == true)
    #expect(StyleLearner.oxfordComma(in: "I got bread, milk and eggs.") == false)
}

@Test func aJoinedClauseIsNotAList() {
    // "I called Noah, and he said yes" has a comma before "and" and is not a
    // list. Reading it as one would teach the serial comma to everybody.
    #expect(StyleLearner.oxfordComma(in: "I called Noah, and he said yes.") == nil)
    #expect(StyleLearner.oxfordComma(in: "Ship it and let me know.") == nil)
}

@Test func aWriterWhoDoesBothHasNoPreferenceToLearn() {
    #expect(StyleLearner.oxfordComma(in: "I got bread, milk, and eggs. Then tea, toast and jam.") == nil)
}

@Test func deletedExclamationMarksAreASignalAndUnchangedOnesAreNot() {
    #expect(StyleLearner.observe(dictated: "Great work!", edited: "Great work.").exclamations == false)
    #expect(StyleLearner.observe(dictated: "Great work.", edited: "Great work!").exclamations == true)
    #expect(StyleLearner.observe(dictated: "Great work.", edited: "Good work.").exclamations == nil)
}

// MARK: - Sentence length

@Test func sentenceLengthIsMeasuredOnTheTextHeApproved() {
    #expect(StyleLearner.sentenceWords(in: "Ship it. Looks good to me.") == 3)
    // A fragment has no sentence-length habit in it.
    #expect(StyleLearner.sentenceWords(in: "on it") == nil)
}

@Test func lineBreaksEndSentencesToo() {
    // A bullet list has no full stops and is not one forty-word sentence.
    let list = "Yesterday: shipped the site\nToday: invoices\nBlocked on: nothing yet"
    #expect(StyleLearner.sentenceWords(in: list)! < 6)
}

// MARK: - Phrasings

@Test func aRewriteBecomesAPhrasing() {
    let observation = StyleLearner.observe(dictated: "Hi team, the invoice is attached.",
                                           edited: "hey, the invoice is attached.")
    #expect(observation.phrasings.map(\.from) == ["hi team"])
    #expect(observation.phrasings.map(\.to) == ["hey"])
}

@Test func aTypoFixIsNotAPhrasing() {
    // "Craigeburn" -> "Craigieburn" is VocabularyCorrector's job, and filing it
    // here would put a spelling repair into a table that rewrites wording.
    let observation = StyleLearner.observe(dictated: "the Craigeburn booking site",
                                           edited: "the Craigieburn booking site")
    #expect(observation.phrasings.isEmpty)
}

@Test func oneHeavilyRewrittenParagraphCannotFillTheTable() {
    let observation = StyleLearner.observe(
        dictated: "alpha one. bravo two. charlie three. delta four. echo five.",
        edited: "wolf one. tiger two. panther three. jaguar four. lion five."
    )
    #expect(observation.phrasings.count <= 3)
}

// MARK: - Applying

@Test func anUneditedDictationTeachesNothing() {
    let text = "Send Noah the invoice today."
    let observation = StyleLearner.observe(dictated: text, edited: text)
    #expect(observation.isEmpty)

    let profile = StyleLearner.apply(observation, to: .romanDefault, at: date)
    #expect(profile == StyleProfile.romanDefault)
    #expect(profile.correctionCount == 0)
}

@Test func learningIsPureAndRepeatable() {
    // Same inputs, same output, no clock and no disk anywhere in the path.
    let first = StyleLearner.learn(dictated: "I do not think that is right.",
                                   edited: "I don't think that's right.",
                                   into: .romanDefault, at: date)
    let second = StyleLearner.learn(dictated: "I do not think that is right.",
                                    edited: "I don't think that's right.",
                                    into: .romanDefault, at: date)
    #expect(first == second)
}

@Test func aPhrasingHasToEarnItsPlaceThreeTimesOver() {
    var profile = StyleProfile.romanDefault
    for _ in 0 ..< 3 {
        profile = StyleLearner.learn(dictated: "Hi team, the invoice is attached.",
                                     edited: "hey, the invoice is attached.",
                                     into: profile, at: date)
    }
    #expect(profile.phrasings.count == 1)
    #expect(profile.phrasings[0].count == 3)
    #expect(profile.correctionCount == 3)
    // And now it applies, offline, with no model involved.
    #expect(profile.applyDeterministically("Hi team, are we set for Friday?")
            == "hey, are we set for Friday?")
}

@Test func theProfileEventuallyChangesItsMindAboutSpelling() {
    // Seeded British. An American user correcting it should not have to do so
    // forever.
    var profile = StyleProfile.romanDefault
    #expect(profile.settled(profile.spelling) == .british)
    for _ in 0 ..< 4 {
        profile = StyleLearner.learn(dictated: "Check the capitalisation and the colour.",
                                     edited: "Check the capitalization and the color.",
                                     into: profile, at: date)
    }
    #expect(profile.settled(profile.spelling) == .american)
}

@Test func learningStopsWhenItIsTurnedOff() {
    var profile = StyleProfile.romanDefault
    profile.isLearningEnabled = false
    let after = StyleLearner.learn(dictated: "I do not think that is right.",
                                   edited: "I don't think that's right.",
                                   into: profile, at: date)
    #expect(after == profile)
}

@Test func thePhrasingTableIsBounded() {
    var profile = StyleProfile.romanDefault
    for index in 0 ..< StyleProfile.maximumPhrasings + 10 {
        profile = StyleLearner.learn(dictated: "send the alpha\(index) report",
                                     edited: "send the omega\(index) summary",
                                     into: profile, at: date)
    }
    #expect(profile.phrasings.count == StyleProfile.maximumPhrasings)
}

// MARK: - End to end

@Test func aWeekOfCorrectionsShowsUpInThePrompt() {
    // The whole feature, from corrections to the words the model is given.
    var profile = StyleProfile(preset: .casual)
    // Two of each, because one correction is never enough to settle a trait —
    // that is the whole point of the support gate.
    let corrections = [
        ("I do not think that is right.", "I don't think that's right."),
        ("It is not ready. That is fine.", "It isn't ready. That's fine."),
        ("Check the capitalization there.", "Check the capitalisation there."),
        ("The colour was wrong there.", "The colour was right there."),
        ("I got bread, milk, and eggs.", "I got bread, milk and eggs."),
        ("We need tea, toast, and jam.", "We need tea, toast and jam."),
        ("Great news, it shipped!", "Great news, it shipped."),
        ("Nice work!", "Nice work."),
    ]
    for (dictated, edited) in corrections {
        profile = StyleLearner.learn(dictated: dictated, edited: edited, into: profile, at: date)
    }

    let rules = profile.promptRules(forAppBundleID: "com.tinyspeck.slackmacgap")
    #expect(rules.contains("Use British/Australian spelling."))
    #expect(rules.contains("Use contractions."))
    #expect(rules.contains("No comma before the final \"and\" in a list."))
    #expect(rules.contains("No exclamation marks."))
    #expect(profile.correctionCount == corrections.count)
}
