import CoreGraphics
import Foundation
import Testing
@testable import QuillKit

// "Finish, then Enter" — Roman: release the dictation key, tap it again
// right away, and Quill sends Return once cleanup and insertion have
// actually finished, never before. Hooks the exact same tap-vs-hold
// distinction `QuickTapTests.swift` already covers (a quick tap that never
// becomes a real dictation lands as `hotkeyAborted()`), so these tests
// drive the coordinator the same way that file does, with their own small
// set of test doubles rather than reusing that file's `private` ones.

private final class InstantTranscriber: Transcriber, @unchecked Sendable {
    weak var delegate: TranscriberDelegate?
    var onLevel: ((Float) -> Void)?
    let text: String
    init(_ text: String) { self.text = text }
    func prepare() async {}
    func start() async throws {}
    func stop() async -> String { text }
    func cancel() async {}
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
    func show(_ state: OverlayState) {}
    func hide() {}
}

private struct SilentKeys: KeystrokeEmitting {
    func type(_ text: String) -> Bool { true }
    func backspace(times: Int) -> Bool { true }
    func chord(key: CGKeyCode, flags: CGEventFlags) -> Bool { true }
}

/// Counts calls rather than recording a boolean, so a test can also catch
/// the failure mode "fired twice" — one tap must mean one Return, not one
/// per event the tap happens to generate.
private final class ReturnSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func fire() { lock.lock(); _count += 1; lock.unlock() }
}

@MainActor
private func make(_ transcript: String, enabled: Bool = true)
    -> (DictationCoordinator, InstantTranscriber, Recorder, ReturnSpy) {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-finish-enter-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let transcriber = InstantTranscriber(transcript)
    let inserter = Recorder()
    let spy = ReturnSpy()
    let settings = QuillSettings(url: scratch.appendingPathComponent("settings.json"))
    settings.setLiveText(false)
    settings.setFinishThenEnterEnabled(enabled)
    let coordinator = DictationCoordinator(
        hotkey: TapHotkey(),
        transcriber: transcriber,
        inserter: inserter,
        overlay: Quiet(),
        history: HistoryStore(url: scratch.appendingPathComponent("history.json")),
        snippets: SnippetStore(inMemory: []),
        settings: settings,
        liveTyper: LiveTyper(keyboard: SilentKeys()),
        context: { .prose },
        sendReturn: { spy.fire() }
    )
    return (coordinator, transcriber, inserter, spy)
}

@MainActor
private func waitFor(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// A full, real dictation: press, speak, release, wait for it to land.
@MainActor
private func dictate(_ coordinator: DictationCoordinator, transcriber: InstantTranscriber,
                     inserter: Recorder) async {
    coordinator.hotkeyMayBegin()
    coordinator.hotkeyPressed()
    transcriber.publish(0.4)
    await waitFor { coordinator.sawLevelsForTesting }
    coordinator.hotkeyReleased()
    await waitFor { inserter.inserted != nil }
}

/// The tap itself: down, then up before the hold threshold — the exact
/// gesture `QuickTapTests.swift` proves gets binned as "not a dictation".
@MainActor
private func tap(_ coordinator: DictationCoordinator) {
    coordinator.hotkeyMayBegin()
    coordinator.hotkeyAborted()
}

@Test @MainActor func aTapRightAfterInsertionSendsReturnExactlyOnce() async {
    let (coordinator, transcriber, inserter, spy) = make("send it to Carlo")
    await dictate(coordinator, transcriber: transcriber, inserter: inserter)
    #expect(inserter.inserted != nil, "the dictation itself never landed")

    tap(coordinator)
    await waitFor { spy.count > 0 }
    #expect(spy.count == 1, "one tap sent \(spy.count) Returns")
}

@Test @MainActor func aTapWithNoDictationBeforeItSendsNothing() async {
    // The whole point of reading this off the existing tap/hold gesture
    // rather than a second watched key: an ordinary stray tap — nobody has
    // dictated anything yet — must stay exactly what it already was, a
    // silent no-op, not a stray Return into whatever the user is typing.
    let (coordinator, _, _, spy) = make("unused")
    tap(coordinator)
    // No `waitFor` to a positive condition here on purpose — this proves an
    // absence, so it has to wait out real time rather than a signal.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(spy.count == 0)
}

@Test @MainActor func theSettingOffMeansNoReturnEver() async {
    let (coordinator, transcriber, inserter, spy) = make("send it to Carlo", enabled: false)
    await dictate(coordinator, transcriber: transcriber, inserter: inserter)
    tap(coordinator)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(spy.count == 0, "fired even though the setting was off")
}

@Test @MainActor func aSecondDictationInsteadOfATapDoesNotAlsoSendReturn() async {
    // Holding the key again is an ordinary second dictation, not the tap
    // gesture — it must not leave a Return armed from the first one that
    // fires later and lands in the middle of whatever the second dictation
    // just typed.
    let (coordinator, transcriber, inserter, spy) = make("first one")
    await dictate(coordinator, transcriber: transcriber, inserter: inserter)

    coordinator.hotkeyMayBegin()
    coordinator.hotkeyPressed()
    transcriber.publish(0.4)
    await waitFor { coordinator.sawLevelsForTesting }
    coordinator.hotkeyReleased()
    try? await Task.sleep(for: .milliseconds(150))

    #expect(spy.count == 0, "a held second dictation was read as the tap-to-send gesture")
}
