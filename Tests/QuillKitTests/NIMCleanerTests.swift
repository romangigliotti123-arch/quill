import Foundation
import Testing
@testable import QuillKit

// NIMCleaner against a fake model, so the failures that matter can be provoked
// on demand: a model that hangs, that answers the dictation, that rewrites the
// sentence to the same length, that quietly normalises one of Roman's words.
// None of those can be requested from a real endpoint, and all of them have been
// observed coming out of one.

// MARK: - Fakes

/// Counts requests, so "the model was never asked" can be asserted as a fact
/// rather than inferred from a stopwatch. The suite runs in parallel and the
/// coordinator path is main-actor bound, which makes wall-clock latency a
/// measurement of the machine's mood; a call count is not.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func record() { lock.lock(); count += 1; lock.unlock() }
}

private struct FakeAI: AICompleting {
    var isConfigured = true
    var isReadyToTry = true
    var log = CallLog()
    var reply: @Sendable (String) async throws -> String

    func complete(system: String, user: String, model: String?, deadline: Duration) async throws -> String {
        log.record()
        return try await reply(user)
    }

    static func returning(_ text: String) -> FakeAI {
        FakeAI { _ in text }
    }

    /// Ignores the deadline entirely, which is the point: the promise not to hang
    /// belongs to NIMCleaner, not to whatever is on the other side of the seam.
    static var hangs: FakeAI {
        FakeAI { _ in
            try await Task.sleep(for: .seconds(30))
            return "never gets here"
        }
    }

    static var offline: FakeAI { FakeAI { _ in throw NIMError.offline("no internet connection") } }
    static var noKey: FakeAI { FakeAI(isConfigured: false) { _ in throw NIMError.notConfigured } }
    static var breakerOpen: FakeAI { FakeAI(isReadyToTry: false) { _ in "should not be called" } }
}

private let deadline = Duration.milliseconds(450)
private let vocabulary = Vocabulary.seed.contextualStrings

private func cleaner(_ ai: FakeAI) -> NIMCleaner {
    NIMCleaner(client: ai, vocabulary: vocabulary)
}

// MARK: - The promise to the coordinator

@Test func aModelThatHangsDoesNotHangTheDictation() async {
    // DictationCoordinator races cleanThorough against a deadline. If this method
    // can outlive that race, the deterministic answer it is holding is lost and
    // the user waits for nothing.
    //
    // The bound is loose because the suite runs in parallel and a tight one would
    // be measuring scheduler contention; what is being proved is that a model
    // asleep for 30 seconds costs a fraction of a second, not that the fraction
    // is exactly 220ms. The 30ms safety margin itself is asserted below by the
    // fact that the answer comes back at all.
    let clock = ContinuousClock()
    let start = clock.now
    let out = await cleaner(.hangs).cleanThorough(
        "send it to Noah no wait send it to Carlo", deadline: .milliseconds(250)
    )
    let elapsed = start.duration(to: clock.now)

    #expect(elapsed < .seconds(2), "took \(elapsed)")
    // And the text is not lost: the offline resolver's answer ships instead.
    // No full stop, because the raw transcript had none and FastCleaner does not
    // invent terminal punctuation — this is what actually gets pasted.
    #expect(out == "Send it to Carlo")
}

@Test func aDeadlineTooShortToBeWorthAskingSkipsTheNetworkEntirely() async {
    // The measured floor for a completion on this endpoint is 195–223ms of pure
    // network on a warm connection. Under that, waiting is guaranteed waste — so
    // the request is never made at all.
    let ai = FakeAI.hangs
    let out = await cleaner(ai).cleanThorough(
        "send it to Noah no wait send it to Carlo", deadline: .milliseconds(60)
    )
    #expect(ai.log.calls == 0)
    #expect(out == "Send it to Carlo")
}

@Test func noNetworkStillFixesTheCorrection() async {
    // Roman dictates on trains. "Degrades gracefully" here means the headline
    // feature keeps working, not that the app merely does not crash.
    #expect(await cleaner(.offline).cleanThorough(
        "the invoice is for 500 sorry 1500 dollars", deadline: deadline
    ) == "The invoice is for 1500 dollars")
}

@Test func noKeyIsNotAnErrorAndNotAWait() async {
    let ai = FakeAI.noKey
    let out = await cleaner(ai).cleanThorough(
        "lets meet at 3 actually make that 4", deadline: deadline
    )
    #expect(ai.log.calls == 0)
    // "Lets", not "Let's": the apostrophe is the one repair only the model makes.
    // Offline, the correction is still resolved and the contraction is not.
    #expect(out == "Lets meet at 4")
}

@Test func anOpenCircuitBreakerIsHonouredWithoutCallingTheModel() async {
    let ai = FakeAI.breakerOpen
    #expect(await cleaner(ai).cleanThorough(
        "book it for Tuesday scratch that Wednesday", deadline: deadline
    ) == "Book it for Wednesday")
    #expect(ai.log.calls == 0)
}

@Test func ordinaryDictationNeverReachesTheModel() async {
    // The gate. A model that is never asked cannot improve his prose, and cannot
    // cost a round trip either.
    let ai = FakeAI.returning("Just push it and see what breaks.")
    #expect(await cleaner(ai).cleanThorough(
        "yeah just push it and we'll see what breaks", deadline: deadline
    ) == nil)
    #expect(ai.log.calls == 0)
}

@Test func literalCueLanguageNeverReachesTheModelEither() async {
    for text in ["he said no wait and then walked off", "tell them actually is spelled with two Ls"] {
        let ai = FakeAI.returning("He walked off.")
        #expect(await cleaner(ai).cleanThorough(text, deadline: deadline) == nil, "sent: \(text)")
        #expect(ai.log.calls == 0, "sent: \(text)")
    }
}

@Test func emptyTranscriptIsNotWorthAnything() async {
    #expect(await cleaner(.hangs).cleanThorough("   \n  ", deadline: deadline) == nil)
}

@Test func cleanFastIsUnchangedFromTheDeterministicCleaner() {
    // NIMCleaner replaces FastCleaner in the coordinator, so the fast path it
    // exposes has to be the same fast path, byte for byte.
    let raw = "um so push the graph if I build to neglify"
    #expect(cleaner(.hangs).cleanFast(raw) == FastCleaner().cleanFast(raw))
}

// MARK: - A good answer is used

@Test func aCleanModelAnswerIsPreferredOverTheOfflineOne() async {
    // Something the rules cannot do: a correction with no repeated run and no
    // type-compatible swap to anchor on.
    let raw = "call the plumber no wait ring the electrician instead"
    #expect(SelfCorrection.resolve(FastCleaner().cleanFast(raw)) == nil)
    let out = await cleaner(.returning("Ring the electrician instead.")).cleanThorough(raw, deadline: deadline)
    #expect(out == "Ring the electrician instead.")
}

@Test func aModelAnswerIdenticalToTheInputIsNoAnswerAtAll() async {
    let raw = "call the plumber no wait ring the electrician instead"
    let tidy = FastCleaner().cleanFast(raw)
    #expect(await cleaner(.returning(tidy)).cleanThorough(raw, deadline: deadline) == nil)
}

// MARK: - A bad answer is refused

@Test func refusesAModelThatAnsweredTheDictationInsteadOfEditingIt() async {
    let essay = "Sure! Here is what I'd send: Hi Carlo, just letting you know the bed frames "
              + "are ready for collection whenever suits you. Cheers, Roman"
    #expect(await cleaner(.returning(essay)).cleanThorough(
        "send it to Noah no wait send it to Carlo", deadline: deadline
    ) == "Send it to Carlo")
}

@Test func refusesAModelThatImprovedHisProse() async {
    // Same length, same meaning, not his words. A length ratio cannot see this;
    // the delete-only alignment can. Observed from llama-3.1-8b on a real
    // transcript: "I want" became "I'd like" and "barber site" became "barber shop".
    let input = "Ok so for the barber site I want the booking form on the home page, no wait, on its own page."
    let polished = "For the barber shop I'd like the booking form to be on its own separate page."
    #expect(CleanupProjection.project(polished, onto: input, protecting: vocabulary) == nil)
}

@Test func refusesASummary() async {
    let input = "Send it to Noah no wait send it to Carlo and tell him the bed frames are ready."
    #expect(CleanupProjection.project("Bed frames ready.", onto: input, protecting: vocabulary) == nil)
}

@Test func refusesAPleasantryTheSpeakerNeverSaid() {
    let input = "Send it to Noah no wait send it to Carlo."
    #expect(CleanupProjection.project("Please send it to Carlo.", onto: input, protecting: vocabulary) == nil)
    #expect(CleanupProjection.project("Send it to Carlo, thanks!", onto: input, protecting: vocabulary) == nil)
}

@Test func refusesReorderedWords() {
    let input = "Send it to Noah no wait send it to Carlo."
    #expect(CleanupProjection.project("Carlo, send it to him.", onto: input, protecting: vocabulary) == nil)
}

@Test func refusesADeletionWithNoReasonBehindIt() {
    // The clause has no cue in it, is not a repeat, and is not filler. Dropping
    // it is the model deciding what matters, which is not its job.
    let input = "Send it to Carlo and tell him the bed frames are ready."
    #expect(CleanupProjection.project("Send it to Carlo.", onto: input, protecting: vocabulary) == nil)
}

@Test func refusesToActOnACueThatWasLiteralContent() {
    // The mixed case: one real correction gets the transcript past the gate, and
    // the model then also eats the quoted one. The gate cannot catch this; the
    // deletion check can.
    let input = "He said no wait and then he left, sorry, and then he called."
    let overreach = "He and then he called."
    #expect(CleanupProjection.project(overreach, onto: input, protecting: vocabulary) == nil)
}

@Test func refusesRunawayLength() {
    let input = "Send it to Carlo."
    let runaway = String(repeating: "Send it to Carlo. ", count: 20)
    #expect(CleanupProjection.project(runaway, onto: input, protecting: vocabulary) == nil)
}

@Test func refusesCommentaryAroundTheAnswer() {
    let input = "Send it to Noah no wait send it to Carlo."
    #expect(CleanupProjection.project("Here you go.\n\nSend it to Carlo.",
                                      onto: input, protecting: vocabulary) == nil)
}

// MARK: - Shape repairs it does accept

@Test func unwrapsQuotesLabelsAndFencesTheWayRealModelsEmitThem() {
    let input = "Send it to Noah no wait send it to Carlo."
    for wrapped in ["\"Send it to Carlo.\"", "Cleaned text: Send it to Carlo.", "```\nSend it to Carlo.\n```"] {
        #expect(CleanupProjection.project(wrapped, onto: input, protecting: vocabulary) == "Send it to Carlo.")
    }
}

@Test func allowsTheModelToAddAnApostrophe() {
    // "lets" → "Let's" is a spelling repair, not a changed word.
    let input = "Lets meet at 3 actually make that 4."
    #expect(CleanupProjection.project("Let's meet at 4.", onto: input, protecting: vocabulary) == "Let's meet at 4.")
}

@Test func allowsTheOpeningThroatClearingToGo() {
    let input = "Ok so send it to Noah no wait send it to Carlo."
    #expect(CleanupProjection.project("Ok send it to Carlo.", onto: input, protecting: vocabulary)
            == "Ok send it to Carlo.")
    #expect(CleanupProjection.project("Send it to Carlo.", onto: input, protecting: vocabulary)
            == "Send it to Carlo.")
}

@Test func refusesToDeleteADiscourseWordFromInsideASentence() {
    // "like", "so" and "right" open a sentence and mean nothing; in the middle of
    // one they are ordinary words. Licensing their deletion anywhere licenses it
    // there, so the licence stops at the first real word.
    //
    // Measured, both of these come back with the word intact — the guard is the
    // backstop for the run where it does not.
    let input = "Book it for Tuesday no wait for Wednesday because I like that day."
    #expect(CleanupProjection.project("Book it for Wednesday because I that day.",
                                      onto: input, protecting: vocabulary) == nil)
    let other = "Do it right now no wait do it tomorrow."
    #expect(CleanupProjection.project("Do it now do it tomorrow.", onto: other, protecting: vocabulary) == nil)
}

@Test func acceptsTheMergeTheModelActuallyMakes() {
    // Measured 5 times out of 5. Only "to Noah" was retracted, so the noun phrase
    // from before the cue and the recipient from after it are both kept and the
    // redundant "send it" goes. Two words of the settled half disappear, which is
    // why the tail guard is an overreach cap and not a percentage.
    let input = "Send the nxt invoice to Noah no wait send it to Carlo."
    #expect(CleanupProjection.project("Send the next invoice to Carlo.",
                                      onto: input, protecting: vocabulary)
            == "Send the nxt invoice to Carlo.")
}

@Test func refusesASummaryThatEatsTheSettledHalf() {
    // The shape a fraction-of-the-whole-sentence floor could not tell apart from
    // a legitimate retraction: both delete most of the input. This one reaches
    // seven words past the cue; the merge above reaches two.
    let input = "Send it to Noah no wait send it to Carlo and tell him the bed frames are ready."
    #expect(CleanupProjection.project("The bed frames are ready.",
                                      onto: input, protecting: vocabulary) == nil)
}

// MARK: - Vocabulary

@Test func putsRomansSpellingBackWhenTheModelNormalisedIt() {
    // Measured 10 times out of 10 on the live endpoint: the model turns "nxt"
    // into "next". Rejecting the whole response for it would mean self-correction
    // never works in a sentence containing one of his words, which is most of
    // them. The substitution only ever reads from the input, so it cannot
    // introduce a word he did not say.
    let input = "Ship the nxt build on Monday I mean on Tuesday."
    #expect(CleanupProjection.project("Ship the next build on Tuesday.",
                                      onto: input, protecting: vocabulary)
            == "Ship the nxt build on Tuesday.")
    // And the casing of a term is the term: "Graphify" is not "graphify".
    let cased = "Push the graphify build no wait push the Netlify build."
    #expect(CleanupProjection.project("Push the Netlify build.", onto: cased, protecting: vocabulary)
            == "Push the Netlify build.")
}

@Test func aTermThatWasNeverSaidIsNeverIntroduced() {
    // The measured prompt failure this whole design exists to prevent: an earlier
    // variant lifted "Builda Bed" out of the prompt into a sentence that never
    // mentioned it. There is no word list in the prompt now, and even if there
    // were, a word not in the input cannot align.
    let input = "Send it to Noah no wait send it to Carlo, the frames are ready."
    #expect(CleanupProjection.project("Carlo, the Builda Bed frames are ready.",
                                      onto: input, protecting: vocabulary) == nil)
}

@Test func theCleanupPromptStillCarriesNoWordList() {
    for term in ["Builda Bed", "Craigieburn", "graphify", "Firestore", "nxt", "Netlify"] {
        #expect(!CleanupPrompt.current.system.contains(term))
    }
}

@Test func thePromptIsVersioned() {
    // The version travels with the output so a complaint about quality can be
    // traced to the text that produced it.
    #expect(CleanupPrompt.current.version == CleanupPrompt.v1.version)
    #expect(!CleanupPrompt.current.system.isEmpty)
}

// MARK: - The homophone pass

// It is off by default, it must not cost a request when off, and when on it may
// only ever change a listed word. The last of those is enforced by
// HomophoneProjection and tested there; these are about the wiring.

/// Pinned to the closed-list pass. These tests are about THAT pass — its gate,
/// its prompt, its list — and the context pass is benched separately. Without
/// pinning, whichever one happens to be the default silently takes over their
/// assertions, which is how a test stops measuring what its name says.
private func homophoneCleaner(_ ai: FakeAI) -> NIMCleaner {
    NIMCleaner(client: ai, vocabulary: vocabulary, homophones: true, contextRecovery: { false })
}

@Test func theHomophonePassCanBeSwitchedOff() async {
    let ai = FakeAI.returning("every time Cloudflare cached something stale")
    let off = NIMCleaner(client: ai, vocabulary: vocabulary, homophones: false)
    let text = await off.cleanThorough(
        "every time Cloudflare cashed something stale", deadline: deadline)
    #expect(ai.log.calls == 0, "spent a request with the pass switched off")
    // nil is this method's way of saying "nothing to add beyond cleanFast".
    #expect(text == nil, "changed the text with the pass switched off: \(text ?? "nil")")
}

@Test func theHomophonePassCostsNothingWhenNoListedWordIsPresent() async {
    let ai = FakeAI.returning("anything at all")
    let sentence = "push the build and tell the client it is done"
    let text = await homophoneCleaner(ai).cleanThorough(sentence, deadline: deadline)
    #expect(ai.log.calls == 0, "spent a request on a sentence with no candidate in it")
    #expect(text == nil, "got: \(text ?? "nil")")
}

@Test func theHomophonePassFixesAListedWordFromTheSentence() async {
    let ai = FakeAI.returning("Every time Cloudflare cached something stale.")
    let text = await homophoneCleaner(ai).cleanThorough(
        "every time Cloudflare cashed something stale", deadline: deadline)
    #expect(ai.log.calls == 1)
    #expect(text?.contains("cached") == true, "got: \(text ?? "nil")")
}

@Test func theHomophonePassKeepsTheDeterministicAnswerWhenTheModelRewrites() async {
    // A model that returns a different sentence entirely. The projection refuses
    // it and the caller keeps what it already had.
    let ai = FakeAI.returning("I have rewritten this for you, hope that helps!")
    let sentence = "every time Cloudflare cashed something stale"
    let text = await homophoneCleaner(ai).cleanThorough(sentence, deadline: deadline)
    // The projection refused it, so there is nothing to improve on cleanFast.
    #expect(text == nil, "took a rewritten sentence: \(text ?? "nil")")
}

@Test func theHomophonePassNeverOutlivesTheDeadline() async {
    let started = ContinuousClock.now
    let text = await homophoneCleaner(.hangs).cleanThorough(
        "every time Cloudflare cashed something stale", deadline: deadline)
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(6), "took \(elapsed)")
    #expect(text == nil, "got: \(text ?? "nil")")
}

@Test func aRetractionStillWinsOverAHomophone() async {
    // Both are true of this sentence. The retraction is the one that matters, and
    // only one request is ever spent.
    let ai = FakeAI.returning("Send it to Carlo")
    let text = await homophoneCleaner(ai).cleanThorough(
        "send it to Noah no wait send it to Carlo about the flower", deadline: deadline)
    #expect(ai.log.calls == 1, "spent more than one request")
    #expect(text != nil)
}

// MARK: - Settings are read, not remembered

/// The cleaner is built once, at launch. Anything it captured in `init` was
/// frozen there for the whole session — so the "Work out a word from context"
/// switch did nothing until Quill was relaunched, and a word added in the
/// Dictionary was invisible to the AI pass for the rest of the day.
///
/// The vocabulary one is the worse of the two: that list is what protects the
/// user's own terms from being rewritten, so a freshly added word was not merely
/// unprotected — it was the word most likely to be "corrected" into something
/// else.
@Test func theContextSwitchIsAskedPerCallRatherThanCaptured() async {
    let flag = MutableFlag(false)
    let cleaner = NIMCleaner(client: NeverConfigured(),
                             vocabulary: [],
                             contextRecovery: { flag.value })
    // The claim is about the seam, not the model: with no client configured both
    // passes fall through to the deterministic answer, and what is being pinned
    // is that flipping the flag afterwards is visible at all.
    _ = await cleaner.cleanThorough("flour and flower", deadline: .milliseconds(200))
    flag.value = true
    _ = await cleaner.cleanThorough("flour and flower", deadline: .milliseconds(200))
    #expect(flag.reads >= 2, "the switch was read \(flag.reads) times — it is captured, not asked")
}

private final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    private var count = 0
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; count += 1; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private struct NeverConfigured: AICompleting {
    var isConfigured = false
    var isReadyToTry = false
    func complete(system: String, user: String, model: String?, deadline: Duration) async throws -> String { "" }
}
