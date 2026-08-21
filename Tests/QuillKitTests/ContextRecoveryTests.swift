import Foundation
import Testing
@testable import QuillKit

// Roman: "if it can't really understand a word that I said, it should read the
// context of what I just said and figure out what word makes the most sense."
//
// The model is allowed to propose whatever it likes. ContextProjection is the
// only thing between that proposal and his document, so these are mostly tests
// of what it REFUSES. Every one of them is a way a model has actually been
// observed to answer a proofreading prompt.

private func project(_ model: String, onto input: String) -> String? {
    ContextProjection.project(model, onto: input)
}

// MARK: - What it accepts

@Test func acceptsASameSoundingSwap() {
    #expect(project("thick peppered flour fattened sauce",
                    onto: "thick peppered flower fattened sauce")
            == "thick peppered flour fattened sauce")
}

@Test func acceptsASwapTheHandWrittenListNeverKnewAbout() {
    // 2,281 words, generated from CMUdict, against 44 in HomophonePairs. None of
    // these pairs are on the hand-written list.
    #expect(project("the ceiling was cracked", onto: "the sealing was cracked")
            == "the ceiling was cracked")
    #expect(project("he rode the horse", onto: "he rowed the horse")
            == "he rode the horse")
    #expect(project("a coarse woollen blanket", onto: "a course woollen blanket")
            == "a coarse woollen blanket")
}

@Test func keepsTheInputsCapitalisation() {
    #expect(project("flour is expensive", onto: "Flower is expensive")
            == "Flour is expensive")
}

@Test func keepsEveryOtherCharacterVerbatim() {
    // Punctuation, spacing and casing come from the input, never the answer.
    let input = "Well —  the flower,   fattened sauce!"
    let out = project("Well - the flour, fattened sauce.", onto: input)
    #expect(out == "Well —  the flour,   fattened sauce!")
}

// MARK: - What it refuses, which is the point

@Test func refusesASynonym() {
    // The most likely way a helpful model gets this wrong.
    #expect(project("thick peppered wheat fattened sauce",
                    onto: "thick peppered flower fattened sauce") == nil)
}

@Test func refusesAGrammarFix() {
    #expect(project("the dews were suffered to exhale",
                    onto: "the dews was suffered to exhale") == nil)
}

@Test func refusesARewrittenSentence() {
    #expect(project("The sauce was thick, peppered and fattened with flour.",
                    onto: "thick peppered flower fattened sauce") == nil)
}

@Test func refusesAnInsertionOrDeletion() {
    #expect(project("thick peppered flour fattened sauce today",
                    onto: "thick peppered flower fattened sauce") == nil)
    #expect(project("thick peppered flour sauce",
                    onto: "thick peppered flower fattened sauce") == nil)
}

@Test func acceptsTwoRepairsInOneLongDictation() {
    // The cap was one while homophones were the only permitted repair. Dropped
    // endings changed that: he speaks fast, a 200-word dictation genuinely loses
    // more than one, and refusing the whole answer over the second repair would
    // throw away the first. See `atMostThreeWordsMayChange` for where it stops.
    #expect(project("the flour and the dews", onto: "the flower and the dues")
            == "the flour and the dews")
}

@Test func refusesAnExplanation() {
    #expect(project("The word should be \"flour\" because the sentence is about sauce.",
                    onto: "thick peppered flower fattened sauce") == nil)
}

@Test func refusesWhenNothingChanged() {
    // Nil means "keep the input", so an unchanged answer is not a result.
    #expect(project("thick peppered flour fattened sauce",
                    onto: "thick peppered flour fattened sauce") == nil)
}

@Test func refusesAWordThatMerelyLooksSimilar() {
    // The failure of the phonetic-key idea, pinned: under Quill's lossy key
    // "baffle" is a neighbour of "flour". Real pronunciations say otherwise.
    #expect(ContextProjection.sameSound("flour", "baffle") == false)
    #expect(ContextProjection.sameSound("flour", "flower") == true)
}

@Test func refusesTheModelInventingAWordOutsideTheTable() {
    #expect(project("thick peppered flar fattened sauce",
                    onto: "thick peppered flower fattened sauce") == nil)
}

// MARK: - Dropped endings, which is how he actually loses words

@Test func repairsAnEndingDroppedBySpeakingFast() {
    // Verbatim from his own dictation, and the reason this category exists:
    // he said "moved", the recogniser heard "move" because he was talking fast.
    #expect(project("I moved the whole front end to type scoops last night",
                    onto: "I move the whole front end to type scoops last night")
            == "I moved the whole front end to type scoops last night")
}

@Test func keepsTheGoodRepairWhenTheModelAlsoTriesABadOne() {
    // The measured failure of all-or-nothing. The model returned both "moved"
    // (a real repair) and "scripts" for "scoops" (not a repair at all), and
    // refusing the answer outright lost the first along with the second.
    #expect(project("I moved the whole front end to type scripts last night",
                    onto: "I move the whole front end to type scoops last night")
            == "I moved the whole front end to type scoops last night")
}

@Test func endingRepairsAreOnlyEndings() {
    #expect(ContextProjection.sameStem("move", "moved"))
    #expect(ContextProjection.sameStem("site", "sites"))
    #expect(ContextProjection.sameStem("carry", "carried"))
    #expect(ContextProjection.sameStem("quick", "quickly"))
    // A different word that happens to start the same way is not an ending.
    #expect(!ContextProjection.sameStem("move", "movement"))
    #expect(!ContextProjection.sameStem("book", "bookcase"))
}

@Test func shortFunctionWordsAreNeverTreatedAsStems() {
    // The pairs that would quietly change his meaning, and are the most common
    // words he says. All are prefixes of each other.
    #expect(!ContextProjection.sameStem("the", "they"))
    #expect(!ContextProjection.sameStem("a", "as"))
    #expect(!ContextProjection.sameStem("is", "it"))
    #expect(!ContextProjection.sameStem("he", "her"))
    #expect(!ContextProjection.sameStem("i", "in"))
    #expect(!ContextProjection.sameStem("on", "one"))
}

@Test func aRewrittenSentenceIsStillRefusedOutright() {
    // Partial acceptance must not become a way in for a rewrite. The word count
    // has to match exactly before any of it is considered, so the sentence the
    // model actually produced on his bug report is still thrown away whole.
    #expect(project("I've been experiencing bugs with the app",
                    onto: "Here are the following bugs I've been experiencing") == nil)
}

@Test func atMostThreeWordsMayChange() {
    #expect(ContextProjection.maximumSubstitutions == 3)
    // Four permitted swaps is a model rewriting with a thesaurus of homophones.
    #expect(project("the flour and the dews and the ceiling and the coarse",
                    onto: "the flower and the dues and the sealing and the course") == nil)
}

// MARK: - The table itself

@Test func theGeneratedTableIsPresentAndSane() {
    #expect(HomophoneTable.groupOf.count > 1_500)
    // Members of a group must all agree with each other, or the check is
    // direction-dependent and a swap would be legal one way and not the other.
    for (word, group) in HomophoneTable.groupOf.prefix(200) {
        #expect(group.contains(word))
        for other in group {
            #expect(HomophoneTable.groupOf[other]?.contains(word) == true)
        }
    }
}

@Test func theTableCarriesNoSurnames() {
    // Name spellings are VocabularyCorrector's job. Letting a model swap between
    // them would rewrite someone's name into a different spelling of it.
    for name in ["laurie", "lorry", "kerry", "siegel", "bailey"] {
        if let group = HomophoneTable.groupOf[name] {
            #expect(group.count <= 3, "\(name) pulled in a name cluster: \(group.sorted())")
        }
    }
}

@Test func theHandWrittenPairsStillWork() {
    // The generated table supplements the list, it does not replace it. "cached"
    // and "cashed" are not homophones in CMUdict; they are in Roman's mouth, and
    // that entry came from watching this recogniser fail on this voice.
    #expect(ContextProjection.sameSound("cashed", "cached") == true)
}

// MARK: - The gate

@Test func theGateStillDecidesWhetherToSpendARequest() {
    // The cheap local check runs first and is unchanged: no confusable word, no
    // request, no latency. Measured at 11% of his real transcripts.
    #expect(HomophonePairs.hasCandidate(in: "thick peppered flower fattened sauce"))
    #expect(!HomophonePairs.hasCandidate(in: "send the invoice tomorrow morning"))
}

@Test func theSettingDefaultsOnAndSurvivesAnOldFile() throws {
    // On because it was measured better: 5/10 fixed and 0 damaged against the
    // closed list's 3/6, and it reaches words the list does not contain. See the
    // table in QuillSettings.Values.contextRecovery.
    #expect(QuillSettings.Values().contextRecovery == true)
    let json = #"{"holdKeyCode":61,"liveText":true}"#
    let back = try JSONDecoder().decode(QuillSettings.Values.self, from: Data(json.utf8))
    #expect(back.contextRecovery == true)
}

@Test func aShortCommandNeverSpendsARequest() throws {
    // "build" and "billed" are homophones, so the word gate fires on this — and
    // six words that came out fine are not worth most of a second. The length
    // floor is what stops the feature taxing every quick command he dictates.
    #expect(!ContextProjection.hasCandidate(in: "push the build to Netlify tonight"))
    #expect(!ContextProjection.hasCandidate(in: "push the build and tell the client it is done"))
    #expect(ContextProjection.hasCandidate(
        in: "okay so the sealing in the back room was cracked and stained and needs doing before Friday"))
}
