import Testing
@testable import QuillKit

// Misclassifying a command as content costs five words the user deletes.
// Misclassifying content as a command *deletes what they said* and runs a
// transform they never asked for. So the tests that matter here are the refusals,
// and most of this file is sentences that must survive being spoken near a
// command verb.

private let transforms = TransformStore.seed
private let router = CommandRouter()

private func route(_ utterance: String,
                   mode: CommandRouter.Mode = .automatic,
                   using list: [Transform] = transforms) -> CommandRouter.Routing {
    router.route(utterance, transforms: list, mode: mode)
}

private func transformName(_ routing: CommandRouter.Routing) -> String? {
    if case .transform(let t) = routing.decision { return t.name }
    return nil
}

// MARK: - The commands that must fire

@Test func exactTriggersFire() {
    #expect(transformName(route("make that a bullet list")) == "Bullet points")
    #expect(transformName(route("make it more formal")) == "More formal")
    #expect(transformName(route("summarise that")) == "Summarise")
    #expect(transformName(route("turn this into an email")) == "Email")
    #expect(transformName(route("shorten that")) == "Shorter")
    #expect(transformName(route("clean that up")) == "Fix grammar")
}

@Test func triggersSurviveWhatTheRecogniserAddsAndRemoves() {
    // Capitalisation, a full stop and a comma the user never said. The same
    // spoken instruction arrives all three ways across three dictations.
    #expect(transformName(route("Make that shorter.")) == "Shorter")
    #expect(transformName(route("MAKE THAT SHORTER")) == "Shorter")
    #expect(transformName(route("Make that, shorter")) == "Shorter")
}

@Test func politePrefixesAreStrippedBeforeTheVerbIsChecked() {
    #expect(transformName(route("can you make that shorter")) == "Shorter")
    #expect(transformName(route("please make it more formal")) == "More formal")
    #expect(transformName(route("just summarise that")) == "Summarise")
}

@Test func grammarPathGeneralisesBeyondTheTriggerList() {
    // Not a trigger, but verb + referent + a keyword and nothing unaccounted for.
    let routing = route("make this a lot shorter")
    #expect(transformName(routing) == "Shorter")
    #expect(routing.reason == .grammarMatch)
}

@Test func theBestKeywordMatchWinsRatherThanTheFirst() {
    // Both list transforms match "list"; only the numbered one matches "numbered".
    #expect(transformName(route("make that a numbered list")) == "Numbered list")
    #expect(transformName(route("make that a bullet list")) == "Bullet points")
}

// MARK: - The sentences that must never be eaten

@Test func theSelfCorrectionIdiomIsNotACommand() {
    // "make that X" is the command idiom *and* the spoken-self-correction idiom.
    // Anchoring the verb to the front of the utterance is the only thing that
    // separates them, and this is the sentence that proves it.
    let routing = route("send it to Noah no wait make that Carlo")
    #expect(routing.decision == .content)
    #expect(routing.reason == .noCommandVerb)
}

@Test func firstPersonNarrationIsNotACommand() {
    let routing = route("I need to make this shorter before Friday")
    #expect(routing.decision == .content)
    #expect(routing.reason == .noCommandVerb)
}

@Test func reportedSpeechIsNotACommand() {
    #expect(route("tell him to make it more formal").decision == .content)
    #expect(route("he said make it shorter").decision == .content)
    #expect(route("she asked me to summarise that").decision == .content)
}

@Test func aCompoundSentenceIsNotACommand() {
    // The instruction is real, but "mention the deposit" is content that firing
    // would silently throw away.
    let routing = route("make it more formal and mention the deposit")
    #expect(routing.decision == .content)
    #expect(routing.reason == .compoundInstruction("and"))
}

@Test func twoSentencesAreNeverACommand() {
    let routing = route("Make that shorter. Send it to Carlo.")
    #expect(routing.decision == .content)
    #expect(routing.reason == .moreThanOneSentence)
}

@Test func anAbbreviationIsNotASentenceBreak() {
    // "e.g." and "9 a.m." are full of full stops and are not two sentences. A
    // naive scan for "." would classify half of Roman's dictation as prose for
    // the wrong reason — right answer, wrong reason, one edit from being wrong.
    #expect(!CommandRouter.hasInteriorSentenceBreak("make that shorter e.g. like this"))
    #expect(CommandRouter.hasInteriorSentenceBreak("Make that shorter. Then send it."))
}

@Test func aVerbAndAReferentAreBothRequired() {
    // Verb, no referent.
    #expect(route("bullet points").reason == .noReferent)
    // Referent, no verb.
    #expect(route("that was too long").reason == .noCommandVerb)
}

@Test func anInstructionWithNoMatchingTransformIsTyped() {
    // The heuristic that says "this is an instruction" is the same heuristic that
    // just failed to find a match. It does not get a second, more dangerous
    // chance — it says the words.
    let routing = route("make that a haiku")
    #expect(routing.decision == .content)
    #expect(routing.reason == .noMatchingTransform)

    #expect(route("turn it off").decision == .content)
    #expect(route("change that to Tuesday").decision == .content)
    #expect(route("make that clear to him").decision == .content)
}

@Test func leftoverContentBlocksTheGrammarPath() {
    // Verb, referent and the "list" keyword all present — and "on" is not a word
    // this router forgives, because it attaches the instruction to something else.
    let routing = route("make it the last one on the list")
    #expect(routing.decision == .content)
    #expect(routing.reason == .leftoverContent(words: ["on"]))
}

@Test func longUtterancesAreAlwaysContent() {
    let routing = route("make that shorter for the client before we send the quote over on Monday morning")
    #expect(routing.decision == .content)
    if case .tooLong = routing.reason {} else {
        #expect(Bool(false), "expected the length guard, got \(routing.reason)")
    }
}

@Test func quotedAndLiteralTextIsAlwaysContent() {
    #expect(route("make that shorter \"like this\"").reason == .containsQuotedOrLiteralText)
    #expect(route("make that romangigliotti123@gmail.com").reason == .containsQuotedOrLiteralText)
    #expect(route("turn that into https://example.com").reason == .containsQuotedOrLiteralText)
}

@Test func emptyInputIsContent() {
    #expect(route("").decision == .content)
    #expect(route("   \n ").reason == .empty)
}

// MARK: - The escape hatches

@Test func theWakeWordSkipsEveryGuard() {
    // Same utterance, twice. Without the wake word it is a sentence; with it, it
    // is an instruction Quill has no transform for, and that is allowed to become
    // a free-form request precisely because the user said so.
    #expect(route("make that a haiku").decision == .content)

    let woken = route("Quill, make that a haiku")
    #expect(woken.decision == .freeform(instruction: "make that a haiku"))
    #expect(woken.reason == .wakeWord)

    #expect(route("hey Quill make it more formal").isCommand)
}

@Test func theWakeWordKeepsTheInstructionInTheUsersOwnWords() {
    // Rebuilt from the original string, not the tokens, so the model gets prose
    // rather than a lowercase word list.
    let routing = route("Quill, rewrite that as a Slack message, keep it blunt")
    #expect(routing.decision == .freeform(instruction: "rewrite that as a Slack message, keep it blunt"))
}

@Test func theWakeWordAloneDoesNothing() {
    // And in particular does not type the word "Quill" back at the user.
    #expect(route("Quill").decision == .content)
    #expect(route("Quill").reason == .empty)
}

@Test func explicitModeSkipsTheGuardsButStillPrefersAKnownTransform() {
    // The user held the command key. The guards answer "is this an instruction?",
    // which they have already answered.
    let held = route("I need to make this shorter before Friday", mode: .explicit)
    #expect(transformName(held) == "Shorter")

    let unknown = route("make it rhyme", mode: .explicit)
    #expect(unknown.decision == .freeform(instruction: "make it rhyme"))
}

// MARK: - User-defined transforms

@Test func aUserTriggerFiresWithoutAnyCommandVerb() {
    // The user typed this phrase into a box specifically so that saying it would
    // run this transform. That is stronger evidence than any grammar rule.
    let haiku = Transform(name: "Haiku", instruction: "Rewrite as a haiku.",
                          triggers: ["haiku that"], keywords: ["haiku"])
    let routing = route("haiku that", using: [haiku])
    #expect(transformName(routing) == "Haiku")
    #expect(routing.reason == .exactTrigger("haiku that"))
}

@Test func aDisabledTransformNeverFires() {
    var off = TransformStore.seed
    for index in off.indices { off[index].isEnabled = false }
    #expect(route("make that a bullet list", using: off).decision == .content)
}

@Test func aPartialTriggerIsNotATrigger() {
    // "make that" is the front of six built-in triggers and is also half of every
    // spoken correction Roman makes. Only the whole utterance counts.
    #expect(route("make that").decision == .content)
    #expect(route("no wait make that a bullet list").reason == .noCommandVerb)
}

// MARK: - The routing always carries the words

@Test func theSpokenTextSurvivesEveryDecision() {
    // Whatever the router decides, the caller can still type what was said. A
    // wrong answer here has to be recoverable, not lossy.
    for utterance in ["make that a bullet list", "send it to Carlo", "Quill, make it rhyme"] {
        #expect(route(utterance).spokenText == utterance)
    }
}
