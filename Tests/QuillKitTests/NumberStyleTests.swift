import Foundation
import Testing
@testable import QuillKit

// A setting for how a spoken number is written down.
//
// The recogniser already chooses, and mostly chooses well — "I'm 15 years old"
// and "6th of April, 1830" come back as digits, "one of you" and "the two
// parties" as words. So the modes that override it wholesale are the dangerous
// ones, and the default is the ordinary writing rule: spell out one to nine, use
// digits from ten up, and leave anything structural alone.
//
// Every refusal below came from a real line in his corpus. "On 6 April 1830" is
// the one that would have shipped broken — "six April 1830" — if the month guard
// were not here.

private func spell(_ s: String) -> String {
    FastCleaner.applyNumberStyle(to: s, style: .spellOutSmall)
}
private func digits(_ s: String) -> String {
    FastCleaner.applyNumberStyle(to: s, style: .alwaysDigits)
}
private func words(_ s: String) -> String {
    FastCleaner.applyNumberStyle(to: s, style: .alwaysWords)
}

// MARK: - The default: spell out one to nine

@Test func spellsOutASmallCount() {
    #expect(spell("speaking of 4 men") == "speaking of four men")
    #expect(spell("Give me 5 minutes.") == "Give me five minutes.")
    #expect(spell("Let us meet at 3 actually make that full.")
            == "Let us meet at three actually make that full.")
}

@Test func leavesTenAndAboveAsDigits() {
    #expect(spell("I'm 15 years old") == "I'm 15 years old")
    #expect(spell("there were 42 of them") == "there were 42 of them")
}

@Test func leavesWordsThatAreAlreadyWords() {
    #expect(spell("one of you") == "one of you")
    #expect(spell("the two parties") == "the two parties")
}

// MARK: - The refusals

@Test func aDateKeepsItsDigits() {
    // The line that would have shipped as "six April 1830".
    #expect(spell("On 6 April 1830, the church was organised")
            == "On 6 April 1830, the church was organised")
    #expect(spell("due on May 3") == "due on May 3")
    #expect(spell("Tuesday the 12th") == "Tuesday the 12th")
    #expect(spell("the 6th of April") == "the 6th of April")
}

@Test func aVersionOrDecimalKeepsItsDigits() {
    #expect(spell("version 2.0 shipped") == "version 2.0 shipped")
    #expect(spell("the page loads in 1.4 seconds") == "the page loads in 1.4 seconds")
    #expect(spell("update to 1.2.7") == "update to 1.2.7")
}

@Test func aTimeKeepsItsDigits() {
    #expect(spell("meet at 5:30") == "meet at 5:30")
    #expect(spell("doors at 7pm") == "doors at 7pm")
}

@Test func moneyKeepsItsDigits() {
    #expect(spell("it cost $5") == "it cost $5")
    #expect(spell("about 5% slower") == "about 5% slower")
}

@Test func anAgeKeepsItsDigits() {
    #expect(spell("she is 5 years old") == "she is 5 years old")
    #expect(spell("aged 7") == "aged 7")
}

@Test func aNumberedReferenceKeepsItsDigits() {
    #expect(spell("see chapter 3") == "see chapter 3")
    #expect(spell("step 2 of the guide") == "step 2 of the guide")
    #expect(spell("on page 7") == "on page 7")
}

@Test func anAddressOrUrlKeepsItsDigits() {
    #expect(spell("mail romangigliotti123@gmail.com") == "mail romangigliotti123@gmail.com")
    #expect(spell("open localhost:3000/v2") == "open localhost:3000/v2")
    #expect(spell("call 555-1234") == "call 555-1234")
}

// MARK: - The other modes

@Test func alwaysDigitsTurnsWordsIntoNumerals() {
    #expect(digits("speaking of four men") == "speaking of 4 men")
    #expect(digits("twenty five people") == "25 people")
    #expect(digits("give me five minutes") == "give me 5 minutes")
    #expect(digits("twenty five thirty six") == "25 36")
}

@Test func joiningATensAndAUnitCannotReachAStructuralToken() {
    // The join that puts "twenty five" back together used to run as a regex over
    // the finished sentence, one step after the loop had skipped every structural
    // token — so it walked straight back into them. A word boundary sits after a
    // colon and after a dot, which is all it took.
    #expect(digits("the 10:30 5 minutes early") == "the 10:30 5 minutes early")
    #expect(digits("version 1.20 5 times") == "version 1.20 5 times")
    #expect(digits("call 555-20 5 back") == "call 555-20 5 back")

    // And digits he actually dictated as digits are two numbers, not one. The
    // split this repairs is one this pass caused; nothing else is its business.
    #expect(digits("I bought 20 5 packs") == "I bought 20 5 packs")
}

@Test func alwaysWordsTurnsNumeralsIntoWords() {
    #expect(words("speaking of 4 men") == "speaking of four men")
    #expect(words("I'm 15 years old") == "I'm fifteen years old")
    #expect(words("there were 42 of them") == "there were forty-two of them")
}

@Test func everyModeLeavesStructuralNumbersAlone() {
    // Whatever he picks, an address, a version and a time are not prose.
    for transform in [spell, digits, words] {
        #expect(transform("mail noah@kassbarbers.com.au") == "mail noah@kassbarbers.com.au")
        #expect(transform("version 2.0 at 5:30") == "version 2.0 at 5:30")
    }
}

@Test func asHeardChangesNothing() {
    let samples = ["speaking of 4 men", "one of you", "I'm 15 years old", "give me five minutes"]
    for s in samples {
        #expect(FastCleaner.applyNumberStyle(to: s, style: .asHeard) == s)
    }
}

// MARK: - Where it is allowed to apply

@Test func aTerminalKeepsItsDigits() {
    // "git log -3" becoming "git log -three" is a broken command, not a style.
    #expect(AppContextFormatter.apply("run it 3 times", context: .terminal, numbers: .spellOutSmall)
            == "run it 3 times")
    #expect(AppContextFormatter.apply("open 4 tabs", context: .query, numbers: .spellOutSmall)
            == "open 4 tabs")
    #expect(AppContextFormatter.apply("retry 3 times", context: .code, numbers: .spellOutSmall)
            == "retry 3 times")
}

@Test func proseGetsTheStyle() {
    #expect(AppContextFormatter.apply("speaking of 4 men", context: .prose, numbers: .spellOutSmall)
            == "speaking of four men")
}

@Test func aCallerWithNoOpinionChangesNothing() {
    // Every existing caller and every test that is not about numbers must see
    // exactly what it saw before this existed.
    #expect(AppContextFormatter.apply("speaking of 4 men", context: .prose)
            == "speaking of 4 men")
}

@Test func theCleanerItselfDoesNotRestyleNumbers() {
    // cleanFast is the repair pass. Presentation belongs downstream, or the eval
    // rig and the model tests start measuring a preference.
    #expect(FastCleaner().cleanFast("speaking of 4 men") == "Speaking of 4 men")
}

// MARK: - The setting itself

@Test func theSettingDefaultsToSpellingOutSmallNumbers() {
    #expect(QuillSettings.Values().numberStyle == .spellOutSmall)
}

@Test func theSettingSurvivesASaveAndLoad() throws {
    var values = QuillSettings.Values()
    values.numberStyle = .alwaysWords
    let data = try JSONEncoder().encode(values)
    let back = try JSONDecoder().decode(QuillSettings.Values.self, from: data)
    #expect(back.numberStyle == .alwaysWords)
}

@Test func anOldSettingsFileWithoutTheKeyStillLoads() throws {
    // Every settings file on his machine predates this key.
    let json = #"{"holdKeyCode":61,"toggleKeyCode":61,"liveText":true}"#
    let back = try JSONDecoder().decode(QuillSettings.Values.self,
                                        from: Data(json.utf8))
    #expect(back.numberStyle == .spellOutSmall)
    #expect(back.liveText == true)
}
