import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import QuillKit

// The engine's job is what to do when the model is unavailable, wrong or slow,
// so every test here is one of those. None of them touches the network: the
// completer is a seam precisely so that "on a train" and "the model answered the
// text instead of reshaping it" are both one line to set up.

private struct FakeCompleter: TransformCompleting {
    /// nil is what a real client returns for every failure — no key, no network,
    /// breaker open, deadline missed.
    let reply: String?
    var seenSystem: @Sendable (String) -> Void = { _ in }

    func completeTransform(system: String, user: String, deadline: Duration) async -> String? {
        seenSystem(system)
        return reply
    }
}

/// `TextInserting` is deliberately not actor-isolated — the real inserter is
/// callable from wherever a result lands — so the double is locked rather than
/// pinned to the main actor.
private final class RecordingInserter: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var result: InsertionResult = .inserted

    var inserted: [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    func insert(_ text: String) -> InsertionResult {
        lock.lock()
        recorded.append(text)
        lock.unlock()
        return result
    }
}

/// Every double is wired here, and `postKey` is the one that matters: without
/// it the reselect path posts real ⇧← into whatever window happens to be focused
/// on the machine running the suite.
@MainActor
private func engine(completer: TransformCompleting?,
                    selection: SelectionOutcome = .empty,
                    last: TransformEngine.LastDictation? = nil,
                    inserter: RecordingInserter = RecordingInserter(),
                    keys: PostedKeys = PostedKeys(),
                    vocabulary: [String] = ["nxt"]) -> TransformEngine {
    TransformEngine(
        store: TransformStore(inMemory: TransformStore.seed),
        completer: completer,
        selection: StubSelectionReader(selection),
        inserter: inserter,
        pasteboard: NSPasteboard(name: .init("com.romangigliotti.quill.tests.\(UUID().uuidString)")),
        vocabulary: vocabulary,
        lastDictation: { last },
        sleep: { _ in },
        postKey: { code, flags in keys.record(code, flags) }
    )
}

/// Counts what the engine would have typed, and types nothing.
private final class PostedKeys {
    private(set) var posted: [(code: CGKeyCode, flags: CGEventFlags)] = []
    var succeeds = true
    func record(_ code: CGKeyCode, _ flags: CGEventFlags) -> Bool {
        posted.append((code, flags))
        return succeeds
    }
    var leftArrows: Int { posted.count { $0.code == TransformEngine.keyLeftArrow } }
    var collapses: Int { posted.count { $0.code == TransformEngine.keyRightArrow } }
}

private func transform(_ name: String) -> Transform {
    TransformStore.seed.first { $0.name == name }!
}

// MARK: - Producing text

@Test @MainActor func theModelIsUsedWhenItAnswersUsefully() async {
    let subject = engine(completer: FakeCompleter(reply: "- One\n- Two"))
    let result = await subject.produce(transform("Bullet points"), from: "One. Two.")
    #expect((try? result.get()) == TransformEngine.Produced(text: "- One\n- Two", via: .model))
}

@Test @MainActor func withNoNetworkTheDeterministicRecipeRuns() async {
    // A nil completer reply is exactly what NIMClient returns on a train.
    let subject = engine(completer: FakeCompleter(reply: nil))
    let result = await subject.produce(transform("Bullet points"), from: "One thing. Another thing.")
    #expect((try? result.get()) == TransformEngine.Produced(text: "- One thing\n- Another thing",
                                                          via: .offline(.bulletList)))
}

@Test @MainActor func withNoCompleterAtAllTheDeterministicRecipeStillRuns() async {
    // No API key configured is a state, not an error, and it must not cost the
    // transforms that never needed a model.
    let subject = engine(completer: nil)
    let result = await subject.produce(transform("More formal"), from: "I can't do it, it's too late")
    #expect((try? result.get()) == TransformEngine.Produced(text: "I cannot do it, it is too late",
                                                          via: .offline(.expandContractions)))
}

@Test @MainActor func aTransformWithNoOfflineAnswerSaysSoRatherThanReturningTheInput() async {
    // The failure mode this exists to prevent: returning the input unchanged,
    // which tells the user the transform ran and did nothing useful.
    let subject = engine(completer: FakeCompleter(reply: nil))
    let result = await subject.produce(transform("Summarise"), from: "a long paragraph about the quote")
    guard case .failure(let failure) = result else {
        #expect(Bool(false), "expected a failure")
        return
    }
    #expect(failure.reason.contains("no offline version"))
    #expect(failure.reason.contains("has not been changed"))
}

@Test @MainActor func anOfflineRecipeThatChangedNothingIsNotReportedAsSuccess() async {
    // Found in a live run: offline "More formal" on text with no contractions
    // and no filler came back character-identical and reported success, which
    // tells the user the transform ran.
    let subject = engine(completer: FakeCompleter(reply: nil))
    let result = await subject.produce(transform("More formal"), from: "The invoice follows the same day.")
    guard case .failure(let failure) = result else {
        #expect(Bool(false), "expected a refusal, not an unchanged success")
        return
    }
    #expect(failure.reason.contains("ran offline"))
    #expect(failure.reason.contains("found nothing it could change"))
}

@Test @MainActor func moreFormalOfflineDropsSpokenFillerTooNotJustContractions() async {
    let subject = engine(completer: FakeCompleter(reply: nil))
    let result = await subject.produce(transform("More formal"),
                                       from: "so um we can't send it, it's not ready")
    #expect((try? result.get())?.text == "So we cannot send it, it is not ready")
}

@Test @MainActor func aRejectedModelAnswerFallsBackRatherThanPasting() async {
    // The model answered the text instead of reshaping it. The guard rejects it
    // on length, and the deterministic recipe ships instead — the user gets
    // something honest, not a paragraph they did not write.
    let essay = String(repeating: "The deposit terms are as follows and here is why. ", count: 8)
    let subject = engine(completer: FakeCompleter(reply: essay))
    let result = await subject.produce(transform("Bullet points"), from: "One thing. Another thing.")
    // And it is reported as a refusal, not as "offline" — the network was fine,
    // and a user told "offline" while on wifi looks for the wrong problem.
    #expect((try? result.get())?.via == .guardedFallback(.bulletList))
}

@Test @MainActor func aModelThatNormalisedRomansVocabularyIsRejected() async {
    // Measured live, three runs out of three: asked to formalise "the nxt
    // fulfilment quote", llama-3.1-8b returns "the next fulfilment quote" every
    // time. This is that, reproduced offline.
    let subject = engine(completer: FakeCompleter(reply: "- The next fulfilment quote is ready"))
    let result = await subject.produce(transform("Bullet points"), from: "the nxt fulfilment quote is ready")
    #expect((try? result.get())?.via == .guardedFallback(.bulletList))
    #expect((try? result.get())?.text.contains("nxt") == true)
}

@Test @MainActor func aRefusedAnswerAndAnOfflineRefusalReadDifferently() {
    // The three states a user can land in must not share a sentence: never
    // asked, asked and refused, asked and used.
    #expect(TransformEngine.Applied.offline(.expandContractions).note
        == "offline — contractions and filler only")
    #expect(TransformEngine.Applied.guardedFallback(.expandContractions).note
        == "the AI answer was refused — contractions and filler only")
    #expect(TransformEngine.Applied.guardedFallback(.bulletList).note == "the AI answer was refused")
    #expect(TransformEngine.Applied.model.note == nil)
}

@Test @MainActor func shrinkingTransformsDoNotEnforceVocabulary() async {
    // Dropping words is the entire job of Shorter and Summarise. A vocabulary
    // check there would reject every correct answer.
    #expect(!transform("Shorter").preservesVocabulary)
    #expect(!transform("Summarise").preservesVocabulary)
    #expect(transform("Bullet points").preservesVocabulary)
    #expect(transform("Email").preservesVocabulary)
}

@Test @MainActor func theInstructionReachesTheModelUnderTheSharedRules() async {
    let seen = Locked<String>("")
    let completer = FakeCompleter(reply: "- One", seenSystem: { seen.value = $0 })
    _ = await engine(completer: completer).produce(transform("Bullet points"), from: "One. Two.")
    #expect(seen.value.contains("Return ONLY the rewritten text"))
    #expect(seen.value.contains("Never invent facts"))
    #expect(seen.value.contains("Rewrite the text as a bullet list"))
}

// MARK: - Putting it back

@Test @MainActor func aTransformedSelectionIsPastedOverTheSelection() async {
    let inserter = RecordingInserter()
    let subject = engine(completer: FakeCompleter(reply: "- One\n- Two"),
                         selection: .selected("One. Two.", via: .clipboard),
                         inserter: inserter)
    guard case .done(let success) = await subject.run(transform("Bullet points")) else {
        #expect(Bool(false), "expected a result")
        return
    }
    #expect(success.placement == .replacedSelection)
    #expect(inserter.inserted == ["- One\n- Two"])
}

@Test @MainActor func nothingIsTypedWhenTheTransformCouldNotRun() async {
    // The whole safety property in one test: a failed transform leaves the
    // document exactly as it was.
    let inserter = RecordingInserter()
    let subject = engine(completer: FakeCompleter(reply: nil),
                         selection: .selected("a long paragraph", via: .accessibility),
                         inserter: inserter)
    guard case .failed = await subject.run(transform("Summarise")) else {
        #expect(Bool(false), "expected a failure")
        return
    }
    #expect(inserter.inserted.isEmpty)
}

@Test @MainActor func anUnreadableSelectionIsReportedRatherThanGuessedAround() async {
    let inserter = RecordingInserter()
    let subject = engine(completer: FakeCompleter(reply: "anything"),
                         selection: .unavailable(reason: "Secure Input is on."),
                         last: .init(text: "the last dictation", insertedAt: Date()),
                         inserter: inserter)
    guard case .failed(let reason) = await subject.run(transform("Bullet points")) else {
        #expect(Bool(false), "expected a failure")
        return
    }
    // And in particular it does not quietly fall through to the last dictation,
    // which would transform text the user was not looking at.
    #expect(reason == "Secure Input is on.")
    #expect(inserter.inserted.isEmpty)
}

@Test @MainActor func withNothingSelectedTheLastDictationIsUsed() async {
    let subject = engine(completer: FakeCompleter(reply: "- One\n- Two"),
                         selection: .empty,
                         last: .init(text: "One. Two.", insertedAt: Date()))
    guard case .done(let success) = await subject.run(transform("Bullet points")) else {
        #expect(Bool(false), "expected a result")
        return
    }
    // Reselection cannot succeed against a stub reader that returns nothing, so
    // the result is parked rather than typed over whatever is under the caret.
    // That is the designed outcome: never type into a position we cannot verify.
    guard case .parkedOnClipboard = success.placement else {
        #expect(Bool(false), "expected the result to be parked, got \(success.placement)")
        return
    }
}

@Test @MainActor func withNothingSelectedAndNoHistoryTheUserIsTold() async {
    let subject = engine(completer: FakeCompleter(reply: "x"), selection: .empty, last: nil)
    guard case .failed(let reason) = await subject.run(transform("Bullet points")) else {
        #expect(Bool(false), "expected a failure")
        return
    }
    #expect(reason.contains("Nothing is selected"))
}

// MARK: - Reselecting the last dictation

@Test @MainActor func aStaleDictationIsNotReselected() {
    // Past the window the caret has almost certainly moved, and ⇧← would select
    // something else entirely.
    let subject = engine(completer: nil)
    let old = Date().addingTimeInterval(-120)
    #expect(subject.reselectRefusal("short text", insertedAt: old) != nil)
    #expect(subject.reselectRefusal("short text", insertedAt: Date()) == nil)
}

@Test @MainActor func aLongDictationIsNotReselected() {
    // Reselecting is one keystroke per character. Past the cap the result goes
    // to the clipboard, which is instant and cannot go wrong.
    let subject = engine(completer: nil)
    let long = String(repeating: "a", count: 400)
    #expect(subject.reselectRefusal(long, insertedAt: Date())?.contains("400 characters") == true)
}

@Test @MainActor func textWithAstralCharactersIsNotReselected() {
    // ⇧← moves by whatever the focused app calls a character, and apps do not
    // agree about emoji. An off-by-one selection deletes a character the user
    // typed.
    let subject = engine(completer: nil)
    #expect(subject.reselectRefusal("ship it 🚀", insertedAt: Date()) != nil)
    #expect(subject.reselectRefusal("ship it", insertedAt: Date()) == nil)
}

@Test @MainActor func aReselectionThatReadsBackWrongIsAbandoned() async {
    // The proof step. Counting keystrokes against a character count is a guess;
    // reading the selection back is what turns the guess into something safe to
    // type over.
    let inserter = RecordingInserter()
    let keys = PostedKeys()
    let subject = engine(completer: FakeCompleter(reply: "- One\n- Two"),
                         selection: .selected("something else entirely", via: .clipboard),
                         last: .init(text: "One. Two.", insertedAt: Date()),
                         inserter: inserter,
                         keys: keys)

    #expect(await subject.reselectLastDictation("One. Two.") == false)
    // One ⇧← per character, then a → to put the caret back where it was.
    #expect(keys.leftArrows == 9)
    #expect(keys.collapses == 1)
    #expect(inserter.inserted.isEmpty)
}

// MARK: - Routed utterances

@Test @MainActor func aRoutedCommandRunsAndARoutedSentenceDoesNot() async {
    let subject = engine(completer: FakeCompleter(reply: "- One\n- Two"),
                         selection: .selected("One. Two.", via: .accessibility))
    let router = CommandRouter()

    let command = router.route("make that a bullet list", transforms: TransformStore.seed)
    guard case .done = await subject.run(command) else {
        #expect(Bool(false), "expected the command to run")
        return
    }

    let sentence = router.route("send it to Carlo", transforms: TransformStore.seed)
    guard case .failed = await subject.run(sentence) else {
        #expect(Bool(false), "content must never reach the engine as a transform")
        return
    }
}

@Test @MainActor func aFreeformInstructionHasNoOfflineAnswer() async {
    // There is no way to know what an arbitrary spoken instruction means without
    // a model, so offline it refuses rather than inventing something.
    let subject = engine(completer: FakeCompleter(reply: nil),
                         selection: .selected("the quote is ready", via: .accessibility))
    let routing = CommandRouter().route("Quill, make it rhyme", transforms: TransformStore.seed)
    guard case .failed(let reason) = await subject.run(routing) else {
        #expect(Bool(false), "expected a failure")
        return
    }
    #expect(reason.contains("has not been changed"))
}

@Test @MainActor func theOverlayLineNamesTheOfflineLimitation() {
    // "More formal" done offline is contraction expansion and nothing else. A
    // user who thinks they got the full transform will not re-run it.
    let success = TransformEngine.Success(
        transformName: "More formal",
        original: "I can't",
        text: "I cannot",
        via: .offline(.expandContractions),
        placement: .replacedSelection)
    #expect(success.headline == "More formal — offline — contractions and filler only")
}

// MARK: - Helper

/// A tiny box so a `@Sendable` callback can report back into a test.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
