import Foundation
import Testing
@testable import QuillKit

// The profile decides how every dictation sounds and, through
// `applyDeterministically`, rewrites text on its own. So the tests that matter
// are the ones about restraint: what it refuses to change, what it refuses to
// claim it has learned, and what it leaves alone when it is not sure.

// Never the real file. A self-test that writes to a user's style.json would
// teach the shipping app whatever the tests happened to assert.
private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-style-tests-\(UUID().uuidString)")
        .appendingPathComponent("style.json")
}

// MARK: - Traits

@Test func aTraitStaysUnknownUntilItHasEnoughAgreement() {
    var trait = StyleTrait<SpellingConvention>()
    #expect(trait.value == nil)

    trait.record(.british, at: Date())
    #expect(trait.value == .british)
    // One sighting is not a preference — the gate, not the raw value, is what
    // the prompt and the offline pass consult.
    #expect(trait.settled(minimumSupport: 2, minimumConfidence: 0.6) == nil)

    trait.record(.british, at: Date())
    #expect(trait.settled(minimumSupport: 2, minimumConfidence: 0.6) == .british)
}

@Test func aSettledTraitCanStillBeArguedOutOf() {
    var trait = StyleTrait<Bool>()
    trait.record(true, at: Date())
    trait.record(true, at: Date())
    #expect(trait.settled(minimumSupport: 2, minimumConfidence: 0.6) == true)

    // Three consistent corrections the other way, not thirty.
    trait.record(false, at: Date())
    trait.record(false, at: Date())
    #expect(trait.value == false)
    trait.record(false, at: Date())
    #expect(trait.settled(minimumSupport: 2, minimumConfidence: 0.6) == false)
}

@Test func aGenuineTieIsUnknownRatherThanAGuess() {
    // Not reachable through record() — a vote decrements its rivals — but
    // reachable the way it matters: style.json is meant to be readable and
    // hand-editable, so a file that says 3–3 must produce silence and not a
    // dictionary-ordering coin toss.
    let json = #"{"votes":{"british":3,"american":3}}"#
    let trait = try! JSONDecoder().decode(StyleTrait<SpellingConvention>.self, from: Data(json.utf8))
    #expect(trait.value == nil)
    #expect(trait.settled(minimumSupport: 2, minimumConfidence: 0.6) == nil)
}

@Test func votesAreCappedSoAnOldHabitDoesNotBecomePermanent() {
    var trait = StyleTrait<Bool>()
    for _ in 0 ..< 50 { trait.record(true, at: Date()) }
    #expect(trait.support == StyleTrait<Bool>.voteCeiling)
}

@Test func theRunningMeanForgets() {
    var mean = RunningMean()
    #expect(mean.average == nil)          // two samples is noise
    mean.add(10); mean.add(10)
    #expect(mean.average == nil)
    mean.add(10)
    #expect(mean.average == 10)

    for _ in 0 ..< 100 { mean.add(4) }
    #expect(mean.count == RunningMean.sampleCeiling)
    #expect(mean.average! < 4.2)          // the old habit is gone
}

// MARK: - Presets and tone

@Test func perAppToneBeatsTheBasePresetAndAnExplicitChoiceBeatsBoth() {
    var profile = StyleProfile(preset: .casual)
    // Mail is suggested professional even though the base is casual.
    #expect(profile.tone(forBundleID: "com.apple.mail") == .professional)
    // An app nobody has an opinion about falls back rather than guessing.
    #expect(profile.tone(forBundleID: "com.example.unknown") == .casual)
    #expect(profile.tone(forBundleID: nil) == .casual)

    profile.appTones["com.apple.mail"] = .casual
    #expect(profile.tone(forBundleID: "com.apple.mail") == .casual)
}

@Test func eachPresetSaysSomethingDifferentToTheModel() {
    let lines = Set(StylePreset.allCases.map(\.promptLine))
    #expect(lines.count == StylePreset.allCases.count)
}

// MARK: - Prompt

@Test func romansDefaultProfileAsksForAustralianSpellingAndContractions() {
    let rules = StyleProfile.romanDefault.promptRules()
    #expect(rules.first == StylePreset.casual.promptLine)
    #expect(rules.contains("Use British/Australian spelling."))
    #expect(rules.contains("Use contractions."))
}

@Test func anEmptyProfileSaysOnlyWhatItWasTold() {
    // Nothing learned yet: one preset line, no invented preferences.
    #expect(StyleProfile(preset: .neutral).promptRules() == [StylePreset.neutral.promptLine])
}

@Test func theSystemPromptKeepsTheCleanupRulesAndAppendsTheVoice() {
    let prompt = StyleProfile.romanDefault.systemPrompt(forAppBundleID: "com.tinyspeck.slackmacgap")
    #expect(prompt.hasPrefix(AIConfig.cleanupSystemPrompt))
    #expect(prompt.contains("Style:"))
    #expect(prompt.contains(StylePreset.casual.promptLine))
}

@Test func theStyleRulesNeverBlowThePrefillBudget() {
    // Every trait settled and shouting at once — prefill is on the critical
    // path, so the budget is a hard cap and not an average.
    var profile = StyleProfile(preset: .technical)
    for _ in 0 ..< 3 {
        profile.spelling.record(.british, at: Date())
        profile.contractions.record(false, at: Date())
        profile.oxfordComma.record(true, at: Date())
        profile.exclamations.record(false, at: Date())
    }
    for _ in 0 ..< 5 { profile.sentenceLength.add(7) }

    let rules = profile.promptRules()
    let cost = rules.reduce(0) { $0 + $1.count + 3 }
    #expect(cost <= StyleProfile.maximumPromptCharacters)
    #expect(rules.first == StylePreset.technical.promptLine)
}

@Test func anOrdinarySentenceLengthIsNotWorthTellingTheModelAbout() {
    var profile = StyleProfile()
    for _ in 0 ..< 5 { profile.sentenceLength.add(17) }
    #expect(!profile.promptRules().contains { $0.contains("sentence") })
}

@Test func noRuleEverAsksTheModelToRestructureASentence() {
    // Measured live: asking for shorter sentences cost a clause in one
    // dictation in twenty. Learned, shown in the summary, never sent.
    var profile = StyleProfile(preset: .casual)
    for _ in 0 ..< 5 { profile.sentenceLength.add(6) }
    #expect(!profile.promptRules().contains { $0.contains("sentence") })
    #expect(profile.summaryLine.contains("6 words/sentence"))
}

@Test func aLongSentenceHabitIsProtectedFromBeingSplitUp() {
    // The opposite instruction — it forbids restructuring rather than asking
    // for it, so it cannot cause the failure above.
    var profile = StyleProfile(preset: .casual)
    for _ in 0 ..< 5 { profile.sentenceLength.add(30) }
    #expect(profile.promptRules().contains("Long sentences are fine; do not split them up."))
}

// MARK: - Applied without a model

@Test func spellingIsFixedOfflineOnceItIsSettled() {
    let profile = StyleProfile.romanDefault
    #expect(profile.applyDeterministically("Check the capitalization and the color.")
            == "Check the capitalisation and the colour.")
}

@Test func spellingIsLeftAloneWhileTheConventionIsStillUnknown() {
    var profile = StyleProfile()
    profile.spelling.record(.british, at: Date())   // one vote, not settled
    #expect(profile.applyDeterministically("the color") == "the color")
}

@Test func spellingConversionDoesNotTouchCodeOrURLs() {
    let profile = StyleProfile.romanDefault
    let text = "Open Normalization.swift and hit https://example.com/customize now."
    #expect(profile.applyDeterministically(text) == text)
}

@Test func spellingConversionLeavesWordsThatOnlyLookAmerican() {
    let profile = StyleProfile.romanDefault
    // "size" and "prize" are not "-ize" verbs; "humorous" and "vigorous" keep
    // the American-looking spelling in British English.
    let text = "The prize is a decent size, and his humorous vigorous style seized me."
    #expect(profile.applyDeterministically(text) == text)
}

@Test func spellingConversionKeepsCasing() {
    #expect(Orthography.toBritish("Color") == "Colour")
    #expect(Orthography.toBritish("COLOR") == "COLOUR")
    #expect(Orthography.toBritish("(color),") == "(colour),")
}

@Test func spellingConversionPreservesLineBreaks() {
    #expect(Orthography.toBritish("first color\n\nsecond color") == "first colour\n\nsecond colour")
}

@Test func aPhrasingOnlyRewritesTextOnceItHasBeenSeenThreeTimes() {
    var profile = StyleProfile.romanDefault
    profile.phrasings = [StylePhrasing(from: "hi team", to: "hey", count: 2)]
    #expect(profile.applyDeterministically("Hi team, the invoice is ready.")
            == "Hi team, the invoice is ready.")

    profile.phrasings = [StylePhrasing(from: "hi team", to: "hey", count: 3)]
    #expect(profile.applyDeterministically("Hi team, the invoice is ready.")
            == "hey, the invoice is ready.")
}

@Test func aPhrasingContainingADollarSignSurvivesIntact() {
    // The replacement runs through a regex, where "$1" means capture group one.
    // A phrasing learned from a dictated price would otherwise delete itself.
    var profile = StyleProfile.romanDefault
    profile.phrasings = [StylePhrasing(from: "the usual deposit", to: "$100 up front", count: 3)]
    #expect(profile.applyDeterministically("Send them the usual deposit today.")
            == "Send them $100 up front today.")
}

@Test func aShortCommonWordIsNeverPromotedToAPhrasing() {
    // "and" appearing three times in the table would rewrite half of everything
    // he dictates, and there is no upper bound on the damage.
    let phrasing = StylePhrasing(from: "and", to: "plus", count: 9)
    #expect(!phrasing.isApplicable)
    #expect(StylePhrasing(from: "no worries", to: "all good", count: 3).isApplicable)
}

// MARK: - Guard

@Test func outputThatStartedSoundingLikeAnAssistantIsRejected() {
    let profile = StyleProfile.romanDefault
    let input = "Send Noah the invoice today."
    #expect(StyleGuard.sanitise("I hope this finds you well. Send Noah the invoice today.",
                                against: input, profile: profile) == nil)
    #expect(StyleGuard.introducedTells(input: input, output: "We seamlessly sent it") == ["seamlessly"])
}

@Test func realNewsletterSpeakFromTheModelIsCaught() {
    // Verbatim from a live run: the model was asked to make "The site is live.
    // Invoice attached, due in 7 days." sound warm, and produced this. The
    // length ceiling would have rejected it too, but a rewrite that kept the
    // length would not have been — so the tells have to catch it on their own.
    let input = "The site is live. Invoice attached, due in 7 days."
    let output = "Hello and welcome to our August newsletter! We're thrilled to start the month "
               + "off on a high note, as we've just launched a brand new website."
    #expect(!StyleGuard.introducedTells(input: input, output: output).isEmpty)
    #expect(StyleGuard.sanitise(output, against: input, profile: .romanDefault) == nil)
}

@Test func aTellTheSpeakerActuallySaidIsNotHeldAgainstTheModel() {
    let input = "Tell them we seamlessly moved the booking."
    #expect(StyleGuard.introducedTells(input: input, output: "Tell them we seamlessly moved the booking.").isEmpty)
}

@Test func theStyleGuardStillEnforcesEverythingAIOutputGuardDid() {
    let profile = StyleProfile.romanDefault
    // A dropped vocabulary term must still reject, and the style pass must not
    // be able to smuggle a bad response past it.
    #expect(StyleGuard.sanitise("Send the next onboarding records.",
                                against: "Send the nxt onboarding records.",
                                profile: profile,
                                preserving: ["nxt"]) == nil)
}

@Test func acceptedOutputComesBackWithTheProfileApplied() {
    let profile = StyleProfile.romanDefault
    let cleaned = StyleGuard.sanitise("Fix the color and the capitalization.",
                                      against: "fix the color and the capitalization",
                                      profile: profile)
    #expect(cleaned == "Fix the colour and the capitalisation.")
}

// MARK: - Model trust

@Test func theModelIsTrustedUntilThereIsRealEvidenceOtherwise() {
    var profile = StyleProfile()
    #expect(profile.trustsModel)
    for _ in 0 ..< 2 { profile.recordModelOutcome(accepted: false) }
    #expect(profile.trustsModel)                  // two reverts is not a verdict

    for _ in 0 ..< 4 { profile.recordModelOutcome(accepted: false) }
    #expect(!profile.trustsModel)
    for _ in 0 ..< 10 { profile.recordModelOutcome(accepted: true) }
    #expect(profile.trustsModel)
}

// MARK: - Persistence

@Test func theProfileSurvivesARestart() {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = StyleStore(url: url)
    store.setPreset(.professional)
    store.recordCorrection(dictated: "I do not think that is right.",
                           edited: "I don't think that's right.")

    let reopened = StyleStore(url: url)
    #expect(reopened.profile.preset == .professional)
    #expect(reopened.profile.correctionCount == 1)
    #expect(reopened.profile.contractions.value == true)
}

@Test func aProfileFileFromAnOlderVersionIsNotThrownAway() {
    // The synthesised decoder throws on a missing key and the store turns a
    // throw into a fresh profile — which would delete everything the user had
    // taught it the first time a field was added.
    let json = #"{"preset":"technical","correctionCount":7}"#
    let profile = try! JSONDecoder().decode(StyleProfile.self, from: Data(json.utf8))
    #expect(profile.preset == .technical)
    #expect(profile.correctionCount == 7)
    #expect(profile.isLearningEnabled)
    #expect(profile.phrasings.isEmpty)
}

@Test func learningCanBeTurnedOffAndForgotten() {
    let store = StyleStore(inMemory: StyleProfile.romanDefault)
    store.update { $0.isLearningEnabled = false }
    store.recordCorrection(dictated: "I do not think so.", edited: "I don't think so.")
    #expect(store.profile.correctionCount == 0)

    store.update { $0.isLearningEnabled = true }
    store.recordCorrection(dictated: "I do not think so.", edited: "I don't think so.")
    #expect(store.profile.correctionCount == 1)

    store.resetLearning()
    #expect(store.profile.correctionCount == 0)
    #expect(store.profile.preset == .casual)        // the choice survives the reset
}

@Test func theSummaryNeverImpliesLearningThatHasNotHappened() {
    #expect(StyleProfile(preset: .neutral).summaryLine == "Neutral · nothing learned yet")
    #expect(StyleProfile.romanDefault.summaryLine.contains("British spelling"))
}

// MARK: - The style profile actually reaches the model

/// `promptRules` was measured line by line against live transcripts, rendered on
/// its own dashboard screen, and called by nothing. Picking "Professional" wrote
/// style.json, moved the tick, and changed not one character of any dictation
/// that followed.
@Test func theTonePresetReachesTheCleanupPrompt() {
    let base = CleanupPrompt.current

    var casual = StyleProfile()
    casual.preset = .casual
    let casualPrompt = NIMCleaner.systemPrompt(base, style: casual)

    var technical = StyleProfile()
    technical.preset = .technical
    let technicalPrompt = NIMCleaner.systemPrompt(base, style: technical)

    #expect(casualPrompt != base.system, "the profile never reached the prompt")
    #expect(casualPrompt != technicalPrompt, "the tone made no difference to the prompt")
    // The measured base prompt is intact underneath; the rules are additive.
    #expect(casualPrompt.hasPrefix(base.system))
    #expect(technicalPrompt.hasPrefix(base.system))
}

/// And the tail is dropped rather than the prompt growing without bound.
@Test func theStyleRulesAreCappedRatherThanUnbounded() {
    var profile = StyleProfile()
    profile.preset = .professional
    let prompt = NIMCleaner.systemPrompt(CleanupPrompt.current, style: profile)
    let appended = prompt.dropFirst(CleanupPrompt.current.system.count)
    #expect(appended.count <= StyleProfile.maximumPromptCharacters + 40,
            "the appended rules ran to \(appended.count) characters")
}
