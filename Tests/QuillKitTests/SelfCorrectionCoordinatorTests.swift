import Foundation
import Testing
@testable import QuillKit

// The whole path, with the real DictationCoordinator: key down, transcript,
// cleanup race, text inserted. The unit tests prove NIMCleaner keeps its
// promises; this proves the coordinator is actually asking it, and that the
// promises are the ones the coordinator needs.
//
// The model is a fake that never answers, because that is the interesting case:
// it is what a train looks like, and it is also what 5% of calls look like at his
// desk. If the text still lands, correct and on time, the feature holds.

// MARK: - Fakes

private final class FakeHotkey: HotkeyEngine, @unchecked Sendable {
    weak var delegate: HotkeyEngineDelegate?
    func start() -> Bool { true }
    func stop() {}
}

private final class FakeTranscriber: Transcriber, @unchecked Sendable {
    weak var delegate: TranscriberDelegate?
    var onLevel: ((Float) -> Void)?
    let text: String
    init(_ text: String) { self.text = text }
    func prepare() async {}
    func start() async throws {}
    func stop() async -> String { text }
    func cancel() async {}
}

private final class RecordingInserter: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var _inserted: String?
    var inserted: String? { lock.lock(); defer { lock.unlock() }; return _inserted }
    func insert(_ text: String) -> InsertionResult {
        lock.lock(); _inserted = text; lock.unlock()
        return .inserted
    }
}

private final class SilentOverlay: OverlayPresenting, @unchecked Sendable {
    func show(_ state: OverlayState) {}
    func hide() {}
}

/// Never answers, and counts how many times it was asked. The count is the
/// assertion: whether the gate saved a round trip is a fact, while how long the
/// dictation took in a parallel test suite is a measurement of the scheduler.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func record() { lock.lock(); count += 1; lock.unlock() }
}

private struct NeverAnswers: AICompleting {
    var isConfigured = true
    var isReadyToTry = true
    let log = CallLog()
    func complete(system: String, user: String, model: String?, deadline: Duration) async throws -> String {
        log.record()
        try await Task.sleep(for: .seconds(30))
        return "never gets here"
    }
}

/// Everything the coordinator persists, pointed somewhere disposable. A test
/// suite that writes into the user's real history is a test suite that can lose
/// his data, and "this one is read-only" is how that starts.
@MainActor
private func makeCoordinator(transcript: String) -> (DictationCoordinator, RecordingInserter, NeverAnswers) {
    // FastCleaner reaches NSSpellChecker through VocabularyCorrector, and its
    // first call in a process spins up an XPC service — measured at ~500ms, once.
    // Warmed here so whichever test happens to run first does not pay for it
    // inside a timed region and report it as a latency regression.
    _ = FastCleaner().cleanFast("warm the spell checker")

    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-selfcorrect-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let inserter = RecordingInserter()
    let ai = NeverAnswers()
    let coordinator = DictationCoordinator(
        hotkey: FakeHotkey(),
        transcriber: FakeTranscriber(transcript),
        inserter: inserter,
        overlay: SilentOverlay(),
        cleaner: NIMCleaner(client: ai, vocabulary: Vocabulary.seed.contextualStrings),
        history: HistoryStore(url: scratch.appendingPathComponent("history.json")),
        snippets: SnippetStore(inMemory: []),
        settings: pasteOnlySettings(),
        liveTyper: LiveTyper(keyboard: SilentKeystrokes())
    )
    return (coordinator, inserter, ai)
}

@MainActor
private func dictate(_ coordinator: DictationCoordinator, _ inserter: RecordingInserter) async -> (String?, Duration) {
    let clock = ContinuousClock()
    let start = clock.now
    coordinator.hotkeyMayBegin()
    coordinator.hotkeyPressed()
    coordinator.hotkeyReleased()
    // Poll rather than sleep a fixed amount: the elapsed time is the assertion.
    for _ in 0 ..< 400 {
        if let text = inserter.inserted { return (text, start.duration(to: clock.now)) }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return (nil, start.duration(to: clock.now))
}

// MARK: - Tests

@MainActor
@Test func aSelfCorrectionIsFixedEvenWhenTheModelNeverAnswers() async {
    let (coordinator, inserter, ai) = makeCoordinator(transcript: "send it to Noah no wait send it to Carlo")
    let (text, elapsed) = await dictate(coordinator, inserter)

    #expect(text == "Send it to Carlo")
    #expect(ai.log.calls == 1, "the cued transcript should have been offered to the model")
    // The model is asleep for 30 seconds. Anything in this ballpark proves the
    // deterministic answer came back inside the race instead of being lost to it;
    // the exact figure is scheduler noise in a parallel suite and is measured
    // properly in NIMCleanerTests.
    #expect(elapsed < .seconds(3), "took \(elapsed)")
}

@MainActor
@Test func ordinaryDictationNeverReachesTheModelThroughTheCoordinator() async {
    // The gate, end to end. No retraction and no stutter means no model call —
    // the feature costs nothing on the dictations that do not need it, which is
    // nearly all of them.
    let (coordinator, inserter, ai) = makeCoordinator(transcript: "push the build to Netlify tonight")
    let (text, _) = await dictate(coordinator, inserter)

    #expect(text == "Push the build to Netlify tonight")
    #expect(ai.log.calls == 0)
}

@MainActor
@Test func quotedCueLanguageSurvivesTheWholePipelineUntouched() async {
    let (coordinator, inserter, ai) = makeCoordinator(transcript: "he said no wait and then walked off")
    let (text, _) = await dictate(coordinator, inserter)

    #expect(text == "He said no wait and then walked off")
    #expect(ai.log.calls == 0)
}

@MainActor
@Test func anEmptyTranscriptInsertsNothing() async {
    let (coordinator, inserter, _) = makeCoordinator(transcript: "   ")
    _ = await dictate(coordinator, inserter)
    #expect(inserter.inserted == nil)
}

// MARK: - The deadline must actually bound the wait

// Regression for a stall that cost 59 seconds in a real eval run. The old
// implementation used withTaskGroup, which awaits every child at scope exit, so
// a slow operation that ignored cancellation held the dictation hostage until
// its own network timeout expired. It presented as "it just didn't paste".

@Test func aSlowOperationThatIgnoresCancellationCannotHoldUpInsertion() async {
    // The property under test is "bounded by the deadline, not by the operation".
    // The threshold is generous on purpose: this suite runs while the machine may
    // be saturated, and scheduler jitter under load is on the order of a second.
    // A tighter bound would be measuring the CI box, not the code. The failure
    // this guards against overshot by 59 SECONDS, so a 4x margin still catches it.
    let deadline = Duration.milliseconds(500)
    let operationLength = Duration.seconds(8)

    let start = ContinuousClock.now
    let result: String? = await DictationCoordinatorTestHooks.withDeadline(deadline) {
        // Deliberately ignores cancellation, exactly like a URLSession call.
        try? await Task.sleep(for: operationLength)
        return "too late"
    }
    let elapsed = ContinuousClock.now - start

    #expect(result == nil)
    #expect(elapsed < .seconds(4), "deadline did not bound the wait: \(elapsed)")
}

@Test func aFastOperationStillWins() async {
    let result: String? = await DictationCoordinatorTestHooks.withDeadline(.seconds(2)) {
        "in time"
    }
    #expect(result == "in time")
}

// MARK: - The speculation deadlock — NOT covered by a test, deliberately

// The fix is in DictationCoordinator.cancelDictation: a cancel arriving between
// key-down and gesture-confirmation used to leave isSpeculating true forever and
// the app stopped dictating silently until relaunch.
//
// Four attempts at a unit test are recorded in git history and none of them
// discriminate. The obstacle is real rather than laziness: when the coordinator
// is wedged, the STALE session from the wedged key-down is still open and answers
// stop() with perfectly good text, so every observable signal — text inserted,
// capture opened — looks identical to the fixed behaviour. Telling them apart
// needs a transcriber fake that models session identity, which is a bigger piece
// of test infrastructure than the fix.
//
// The evidence for the fix is a traced run: a 112-second gap in which three
// dictations were requested and no session started at all, and which does not
// reproduce afterwards. A green test that passes with the bug present would be
// worse than no test, so there is no test here.
