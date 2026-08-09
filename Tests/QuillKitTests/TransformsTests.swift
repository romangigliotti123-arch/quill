import CoreGraphics
import Foundation
import Testing
@testable import QuillKit

// Two things are being defended here.
//
// The offline recipes are what Roman gets on a train, so they have to be exactly
// right rather than approximately right — a bullet list that split "9 a.m." into
// two bullets is worse than no bullet list.
//
// The output guard is the last thing between a language model and text that gets
// sent to a client. Its job is to refuse, and the tests are mostly refusals.

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-transform-tests-\(UUID().uuidString)")
        .appendingPathComponent("transforms.json")
}

// MARK: - Offline recipes

@Test func bulletsSplitProseIntoSentences() {
    let text = "We start Monday. The deposit is 50%. It goes live in a week."
    #expect(OfflineTransforms.apply(.bulletList, to: text) == """
        - We start Monday
        - The deposit is 50%
        - It goes live in a week
        """)
}

@Test func bulletsDoNotSplitOnAnAbbreviation() {
    // ICU sentence breaking rather than a regex on ".!?" — dictation is full of
    // "e.g." and "9 a.m.", and a regex turns every one of them into two bullets
    // ("- Call him at 9 a" / "- m."), which is unreadable.
    //
    // The honest cost of ICU is the other direction: it is conservative, so a
    // real sentence that follows an abbreviation stays in the same bullet. One
    // bullet too few is a miss; a word chopped in half is corruption, and this
    // recipe would rather miss.
    #expect(OfflineTransforms.apply(.bulletList, to: "Call him at 9 a.m. Bring the invoice.")
        == "- Call him at 9 a.m. Bring the invoice")
    // And where a real break exists it is still found, with the abbreviation and
    // the domain both intact — three full stops in that first sentence, none of
    // which is a bullet boundary.
    #expect(OfflineTransforms.apply(.bulletList, to: "Use a short domain, e.g. nxt.com. Then send it.")
        == "- Use a short domain, e.g. nxt.com\n- Then send it")
}

@Test func bulletsKeepLinesThatWereAlreadyLines() {
    // A paragraph the user deliberately laid out is not re-split by sentence.
    let text = "Yesterday: shipped the quote\nToday: chase Carlo\nBlocked on: nothing"
    #expect(OfflineTransforms.apply(.bulletList, to: text) == """
        - Yesterday: shipped the quote
        - Today: chase Carlo
        - Blocked on: nothing
        """)
}

@Test func rebulletingAListDoesNotDoubleTheMarkers() {
    let text = "- one\n* two\n3. three\n4) four"
    #expect(OfflineTransforms.apply(.bulletList, to: text) == "- one\n- two\n- three\n- four")
}

@Test func numberedListsAreNumberedFromOne() {
    let text = "Open the file. Change the price. Save it."
    #expect(OfflineTransforms.apply(.numberedList, to: text) == """
        1. Open the file
        2. Change the price
        3. Save it
        """)
}

@Test func onlyAFullStopIsStrippedFromABullet() {
    // A question mark and an exclamation carry meaning; a trailing full stop on
    // a bullet is noise.
    let text = "Is the deposit paid? Chase Carlo!"
    #expect(OfflineTransforms.apply(.bulletList, to: text) == "- Is the deposit paid?\n- Chase Carlo!")
}

@Test func contractionsExpandInBothApostropheForms() {
    // The recogniser emits a typographic apostrophe; a user editing a transform
    // types the ASCII one. Both have to work or the recipe fires half the time.
    #expect(OfflineTransforms.apply(.expandContractions, to: "I can't do it today")
        == "I cannot do it today")
    #expect(OfflineTransforms.apply(.expandContractions, to: "I can\u{2019}t do it today")
        == "I cannot do it today")
}

@Test func longerContractionsWinOverTheirPrefixes() {
    // "wouldn't" must not be half-matched by a shorter key, and "they're" must
    // not be reached by "he's".
    #expect(OfflineTransforms.apply(.expandContractions, to: "they wouldn't say they're done")
        == "They would not say they are done")
}

@Test func spokenShorthandIsExpandedToo() {
    #expect(OfflineTransforms.apply(.expandContractions, to: "gonna sort it, kinda urgent")
        == "Going to sort it, kind of urgent")
}

@Test func aRecipeWithNoOfflineAnswerSaysSo() {
    // Not the input unchanged. A transform that quietly returns its input has
    // told the user it ran.
    #expect(OfflineTransforms.apply(.none, to: "anything") == nil)
    #expect(OfflineTransforms.apply(.bulletList, to: "   ") == nil)
}

@Test func caseRecipesAreExact() {
    #expect(OfflineTransforms.apply(.upperCase, to: "quote sent") == "QUOTE SENT")
    #expect(OfflineTransforms.apply(.lowerCase, to: "Quote Sent") == "quote sent")
    #expect(OfflineTransforms.apply(.sentenceCase, to: "QUOTE SENT. INVOICE NEXT.")
        == "Quote sent. Invoice next.")
}

// MARK: - Output guard

private let emailBounds = LengthBounds(minRatio: 0.8, maxRatio: 3.0, slack: 120)
private let shorterBounds = LengthBounds(minRatio: 0.15, maxRatio: 1.0, slack: 8)

@Test func theGuardStripsWhatModelsWrapAroundAnswers() {
    let input = "send the quote today"
    #expect(TransformOutputGuard.sanitise("\"Send the quote today.\"", against: input,
                                          bounds: .reshaping, preserving: []) == "Send the quote today.")
    #expect(TransformOutputGuard.sanitise("Rewritten text: Send the quote today.", against: input,
                                          bounds: .reshaping, preserving: []) == "Send the quote today.")
    #expect(TransformOutputGuard.sanitise("```\nSend the quote today.\n```", against: input,
                                          bounds: .reshaping, preserving: []) == "Send the quote today.")
}

@Test func theGuardRejectsAModelThatStartedTalking() {
    // "Sure, here you go" means it answered the request instead of performing it.
    let input = "send the quote today"
    #expect(TransformOutputGuard.sanitise("Sure! Send the quote today.", against: input,
                                          bounds: .reshaping, preserving: []) == nil)
    #expect(TransformOutputGuard.sanitise("Certainly, here is the rewritten text.", against: input,
                                          bounds: .reshaping, preserving: []) == nil)
}

@Test func theGuardDoesNotMistakeARealSentenceForAPreamble() {
    // "Here is the deposit schedule" is text someone is transforming, not a
    // model being chatty. The opener has to be followed by an aside.
    let input = "here is the deposit schedule for the job"
    #expect(TransformOutputGuard.sanitise("Here is the deposit schedule for the job.",
                                          against: input, bounds: .reshaping, preserving: []) != nil)
}

@Test func boundsAreWhatMakeShorterAndEmailBothPossible() {
    let input = "we should probably send the quote over to Carlo at some point this week"

    // A halving is correct for Shorter and is a red flag for a reshaping transform.
    let halved = "Send Carlo the quote this week."
    #expect(TransformOutputGuard.sanitise(halved, against: input,
                                          bounds: shorterBounds, preserving: []) != nil)
    #expect(TransformOutputGuard.sanitise(halved, against: input,
                                          bounds: .reshaping, preserving: []) == nil)

    // A doubling is correct for Email and is a red flag for Shorter.
    let asEmail = """
        Hey —

        We should send the quote over to Carlo this week. I'll get it out today unless you want to look first.

        Cheers,
        Roman
        """
    #expect(TransformOutputGuard.sanitise(asEmail, against: input,
                                          bounds: emailBounds, preserving: []) != nil)
    #expect(TransformOutputGuard.sanitise(asEmail, against: input,
                                          bounds: shorterBounds, preserving: []) == nil)
}

@Test func theGuardRefusesWhenTheModelNormalisedRomansVocabulary() {
    // Measured in AIConfig: every prompt variant without an explicit word list
    // turns "nxt" into "next". The prompt cannot win that; a string comparison
    // can, exactly and for free.
    let input = "the nxt fulfilment quote is ready"
    let normalised = "The next fulfilment quote is ready."
    #expect(TransformOutputGuard.sanitise(normalised, against: input,
                                          bounds: .reshaping, preserving: ["nxt"]) == nil)
    #expect(TransformOutputGuard.sanitise("The nxt fulfilment quote is ready.", against: input,
                                          bounds: .reshaping, preserving: ["nxt"]) != nil)
}

@Test func paragraphsAreAllowedWhereTheCleanupGuardWouldRefuseThem() {
    // AIOutputGuard rejects "\n\n" as a model that started explaining. That rule
    // is right for a cleanup pass and would reject every correct email.
    let input = "tell Carlo the frames are ready and the invoice follows"
    let asEmail = "Hey Carlo —\n\nThe frames are ready. The invoice follows today.\n\nCheers,\nRoman"
    #expect(AIOutputGuard.sanitise(asEmail, against: input) == nil)
    #expect(TransformOutputGuard.sanitise(asEmail, against: input,
                                          bounds: emailBounds, preserving: []) != nil)
}

// MARK: - Store

@Test func theStoreRoundTripsThroughDisk() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = TransformStore(url: url)
    let mine = Transform(name: "Slack", instruction: "Rewrite as a Slack message.",
                         triggers: ["make that a slack message"], keywords: ["slack"])
    store.upsert(mine)

    let reopened = TransformStore(url: url)
    #expect(reopened.all.contains { $0.id == mine.id && $0.name == "Slack" })
    // And the built-ins survived alongside it.
    #expect(reopened.all.contains { $0.name == "Bullet points" })
}

@Test func aTransformFileMissingNewFieldsStillLoads() throws {
    // The durability rule this type's hand-written decoder exists for: one new
    // non-optional field with a synthesised decoder makes every previously-saved
    // file fail to decode, and the store then falls back to the seed with the
    // user's own transforms gone.
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let minimal = #"[{"name":"Old","instruction":"Do the old thing."}]"#
    try Data(minimal.utf8).write(to: url)

    let store = TransformStore(url: url)
    #expect(store.all.count == 1)
    #expect(store.all[0].name == "Old")
    #expect(store.all[0].target == .automatic)
    #expect(store.all[0].offline == .none)
    #expect(store.all[0].isEnabled)
}

@Test func usageCountsAreSeparateFromEdits() {
    // Same reasoning as SnippetStore: running a transform must not race an open
    // editor into overwriting an edit.
    let store = TransformStore(inMemory: TransformStore.seed)
    let bullets = store.all.first { $0.name == "Bullet points" }!
    store.recordUse(bullets.id)
    store.recordUse(bullets.id)
    #expect(store.transform(id: bullets.id)?.useCount == 2)
    #expect(store.transform(id: bullets.id)?.lastUsed != nil)
}

@Test func removingATransformRemovesIt() {
    let store = TransformStore(inMemory: TransformStore.seed)
    let id = store.all[0].id
    store.remove(id: id)
    #expect(store.transform(id: id) == nil)
}

@Test func everySeededTriggerRoutesBackToItsOwnTransform() {
    // The seed's triggers and the router are two halves of one contract. A
    // trigger that does not route is a feature that silently does not exist.
    let seed = TransformStore.seed
    let router = CommandRouter()
    for transform in seed {
        for trigger in transform.triggers {
            let routing = router.route(trigger, transforms: seed)
            guard case .transform(let hit) = routing.decision else {
                #expect(Bool(false), "\"\(trigger)\" did not route at all")
                continue
            }
            #expect(hit.name == transform.name,
                    "\"\(trigger)\" routed to \(hit.name), not \(transform.name)")
        }
    }
}

@Test func noSeededTriggerIsAPlausibleSentence() {
    // Every trigger has to contain a command verb and a referent, or it is a
    // phrase someone could dictate — "bullet points" is the example this rule
    // exists to keep out of the list.
    for transform in TransformStore.seed {
        for trigger in transform.triggers {
            let tokens = CommandRouter.stripPoliteness(CommandRouter.tokenise(trigger))
            #expect(tokens.contains { CommandRouter.commandVerbs.contains($0) },
                    "\"\(trigger)\" has no command verb")
            #expect(tokens.contains { CommandRouter.referents.contains($0) },
                    "\"\(trigger)\" never refers to existing text")
        }
    }
}

// MARK: - Hotkeys

@Test func aTransformHotkeyMustCarryAModifier() {
    // A transform on bare "B" is a machine that cannot type the letter B, and
    // the user would have no way to work out why.
    #expect(TransformHotkey(keyCode: 11, modifiers: []) == nil)
    #expect(TransformHotkey(keyCode: 11, modifiers: .maskCommand) != nil)
}

@Test func hotkeyMatchingIgnoresTheBitsBuiltInKeyboardsAddOnTheirOwn() {
    // Raw flags from a built-in keyboard carry .maskSecondaryFn and the numeric
    // pad bit on ordinary keys, so an equality test on the raw value silently
    // never matches.
    let hotkey = TransformHotkey(keyCode: 11, modifiers: [.maskCommand, .maskShift])!
    #expect(hotkey.matches(keyCode: 11, flags: [.maskCommand, .maskShift]))
    #expect(hotkey.matches(keyCode: 11, flags: [.maskCommand, .maskShift, .maskSecondaryFn]))
    #expect(!hotkey.matches(keyCode: 11, flags: [.maskCommand]))
    #expect(!hotkey.matches(keyCode: 9, flags: [.maskCommand, .maskShift]))
}

@Test func theHotkeyRouterFindsAndRefusesTheRightThings() {
    let hotkey = TransformHotkey(keyCode: 11, modifiers: [.maskCommand, .maskAlternate])!
    var bullets = TransformStore.seed.first { $0.name == "Bullet points" }!
    bullets.hotkey = hotkey
    var disabled = TransformStore.seed.first { $0.name == "Shorter" }!
    disabled.hotkey = hotkey
    disabled.isEnabled = false

    let list = [disabled, bullets]
    #expect(TransformHotkeyRouter.transform(forKeyCode: 11,
                                            flags: [.maskCommand, .maskAlternate],
                                            in: list)?.name == "Bullet points")
    #expect(TransformHotkeyRouter.transform(forKeyCode: 11, flags: [.maskCommand], in: list) == nil)
    #expect(TransformHotkeyRouter.conflicts(with: hotkey, excluding: bullets.id, in: list)
        .map(\.name) == ["Shorter"])
}

@Test func hotkeyNamesReadTheWayAMenuWouldPrintThem() {
    #expect(TransformHotkey(keyCode: 11, modifiers: [.maskCommand, .maskShift])?.displayName == "⇧⌘B")
    #expect(TransformHotkey(keyCode: 9, modifiers: [.maskControl, .maskAlternate])?.displayName == "⌃⌥V")
}
