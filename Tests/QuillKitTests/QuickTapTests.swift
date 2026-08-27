import CoreGraphics
import Foundation
import Testing
@testable import QuillKit

// Roman: "when I hold the right option key and then just sort of press it and
// change my mind about doing a dictation, the transcribing thing sits there for a
// couple of seconds and it's kind of annoying."
//
// It was worse than a couple of seconds. The key came up with nothing recognised,
// so `stop()` waited out its 2.5s short-utterance grace, then the drain, then the
// empty-transcript path put "Nothing was heard" on screen for another 1.6s.
//
// The fix bins a gesture that was BOTH brief and silent. Everything below is
// about the "and": each half alone would throw away something he actually said,
// and losing words is the one thing this app may never do.

private final class LevelTranscriber: Transcriber, @unchecked Sendable {
    weak var delegate: TranscriberDelegate?
    var onLevel: ((Float) -> Void)?
    let text: String
    private let lock = NSLock()
    private var _cancelled = false
    private var _stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }

    init(_ text: String) { self.text = text }
    func prepare() async {}
    func start() async throws {}
    func stop() async -> String { lock.lock(); _stopped = true; lock.unlock(); return text }
    func cancel() async { lock.lock(); _cancelled = true; lock.unlock() }

    /// Publishes a level the way the real transcriber does, so the coordinator
    /// can tell "heard silence" from "heard nothing at all".
    func publish(_ level: Float) { onLevel?(level) }
}

private final class TapHotkey: HotkeyEngine, @unchecked Sendable {
    weak var delegate: HotkeyEngineDelegate?
    func start() -> Bool { true }
    func stop() {}
}

private final class Recorder: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var _inserted: String?
    var inserted: String? { lock.lock(); defer { lock.unlock() }; return _inserted }
    func insert(_ text: String) -> InsertionResult {
        lock.lock(); _inserted = text; lock.unlock()
        return .inserted
    }
}

private final class Quiet: OverlayPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [String] = []
    var states: [String] { lock.lock(); defer { lock.unlock() }; return _states }
    func show(_ state: OverlayState) {
        lock.lock(); _states.append("\(state)"); lock.unlock()
    }
    func hide() { lock.lock(); _states.append("hide"); lock.unlock() }
}

@MainActor
private func make(_ transcript: String) -> (DictationCoordinator, LevelTranscriber, Recorder, Quiet) {
    _ = FastCleaner().cleanFast("warm the spell checker")
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-quicktap-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let transcriber = LevelTranscriber(transcript)
    let inserter = Recorder()
    let overlay = Quiet()
    let settings = QuillSettings(url: scratch.appendingPathComponent("settings.json"))
    settings.setLiveText(false)
    let coordinator = DictationCoordinator(
        hotkey: TapHotkey(),
        transcriber: transcriber,
        inserter: inserter,
        overlay: overlay,
        history: HistoryStore(url: scratch.appendingPathComponent("history.json")),
        snippets: SnippetStore(inMemory: []),
        settings: settings,
        liveTyper: LiveTyper(keyboard: SilentKeys()),
        context: { .prose }
    )
    return (coordinator, transcriber, inserter, overlay)
}

/// Waits for a condition instead of for the clock.
@MainActor
private func waitFor(_ timeout: Duration = .seconds(2),
                     _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private struct SilentKeys: KeystrokeEmitting {
    func type(_ text: String) -> Bool { true }
    func backspace(times: Int) -> Bool { true }
    func chord(key: CGKeyCode, flags: CGEventFlags) -> Bool { true }
}

@Test func theChangeOfMindRuleNeedsBothHalves() {
    let brief = DictationCoordinator.tapDuration / 2
    let long = DictationCoordinator.tapDuration * 3

    // Brief AND silent, with a working microphone: a change of mind. Binned.
    #expect(DictationCoordinator.isChangeOfMind(heldFor: brief, sawLevels: true, peak: 0.001))

    // Brief but it carried sound — a fast "Yes." is still speech.
    #expect(!DictationCoordinator.isChangeOfMind(heldFor: brief, sawLevels: true, peak: 0.4))

    // Silent but held: a dead microphone, and the moment he most needs telling.
    #expect(!DictationCoordinator.isChangeOfMind(heldFor: long, sawLevels: true, peak: 0.0))

    // Silent with no levels at all: nothing was ever delivered, which is a
    // different failure from hearing silence and must not be swallowed.
    #expect(!DictationCoordinator.isChangeOfMind(heldFor: brief, sawLevels: false, peak: 0.0))

    // Exactly at the floor is audible, and exactly at the threshold is a hold.
    #expect(!DictationCoordinator.isChangeOfMind(
        heldFor: brief, sawLevels: true, peak: DictationCoordinator.silenceFloor))
    #expect(!DictationCoordinator.isChangeOfMind(
        heldFor: DictationCoordinator.tapDuration, sawLevels: true, peak: 0.0))
}

@MainActor
@Test func aBriefTapThatCarriedSoundIsStillADictation() async {
    // The half that protects his shortest real dictations. "On my way." is 855ms
    // in his own corpus, but a fast "Yes." is shorter — and the moment it carries
    // audio it is speech, however brief.
    let (coordinator, transcriber, inserter, _) = make("Yes")
    coordinator.hotkeyMayBegin()
    coordinator.hotkeyPressed()
    transcriber.publish(0.4)
    await waitFor { coordinator.sawLevelsForTesting }
    coordinator.hotkeyReleased()

    for _ in 0 ..< 200 {
        if inserter.inserted != nil { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(inserter.inserted?.isEmpty == false, "threw away a short dictation that had audio in it")
    #expect(!transcriber.cancelled)
}

@MainActor
@Test func silenceWithNoLevelsAtAllIsNotTreatedAsATap() async {
    // A peak of zero has two meanings and only one of them is "he changed his
    // mind". If no level ever arrived, the microphone never delivered a buffer —
    // a different failure, and one he needs to be told about rather than have
    // silently swallowed. It is also every test double in this suite, which is
    // how the distinction got noticed.
    let (coordinator, transcriber, _, _) = make("something")
    coordinator.hotkeyMayBegin()
    coordinator.hotkeyPressed()
    coordinator.hotkeyReleased()

    try? await Task.sleep(for: .milliseconds(300))
    #expect(!transcriber.cancelled, "binned a dictation on the strength of never having heard anything")
}

@Test func theTapThresholdSitsUnderHisShortestRealDictation() {
    // "On my way." — 855ms, from rig/audio/voice/roman/manifest.tsv. The
    // threshold has to be comfortably under the shortest thing he actually says,
    // or the guard starts eating sentences.
    #expect(DictationCoordinator.tapDuration < 0.855)
    #expect(DictationCoordinator.tapDuration >= 0.2, "short enough to catch a key bounce and nothing else")
}

// MARK: - The busy flag must not survive the gesture

/// Found by review, and it was mine.
///
/// `isBusy` began life as a latched `AppDelegate.dictationInFlight`, set in
/// `beginDictation()` and cleared only in the finalisation Task's `defer`. A
/// change-of-mind tap never reaches that Task — it returns early — so the latch
/// stuck true for the rest of the process, and `applicationShouldTerminate` then
/// refused EVERY Apple-Event quit forever: the auto-quit case the guard was
/// written for, `osascript`, and macOS logout.
///
/// One silent ~200ms tap of the dictation key was enough to arm it.
@MainActor
@Test func aChangeOfMindTapDoesNotLeaveTheAppLookingBusy() async {
    let (coordinator, transcriber, _, _) = make("nothing")
    coordinator.hotkeyMayBegin()
    coordinator.hotkeyPressed()
    // A level arrives, but a silent one — which is what a tap on a live
    // microphone looks like, and what makes this the change-of-mind path.
    transcriber.publish(0.001)
    await waitFor { coordinator.sawLevelsForTesting }
    #expect(coordinator.isBusy, "a dictation in progress should read as busy")

    coordinator.hotkeyReleased()

    for _ in 0 ..< 200 {
        if !coordinator.isBusy { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(!coordinator.isBusy,
            "the tap left the app permanently busy — every scripted quit and macOS logout would now be refused")
}

/// The same for a cancelled dictation, the second path that skips the
/// finalisation Task.
@MainActor
@Test func aCancelledDictationDoesNotLeaveTheAppLookingBusy() async {
    let (coordinator, _, _, _) = make("nothing")
    coordinator.hotkeyMayBegin()
    coordinator.hotkeyPressed()
    #expect(coordinator.isBusy)

    coordinator.hotkeyCancelled(userKeystroke: "x")

    for _ in 0 ..< 200 {
        if !coordinator.isBusy { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(!coordinator.isBusy, "a cancelled dictation left the app permanently busy")
}

/// A quit that is not an Apple Event is never refusable, whatever the app is
/// doing — the menu and ⌘Q reach us that way, and refusing one of those is the
/// far worse bug.
@Test func aQuitThatIsNotAnAppleEventIsAlwaysHonoured() {
    // No Apple Event is being dispatched on this thread during a unit test, so
    // `currentAppleEvent` is nil — the menu/⌘Q shape.
    #expect(!AppDelegate.isRefusableQuit())
}
