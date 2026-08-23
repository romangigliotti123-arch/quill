import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import QuillKit

// Roman: plain-Option dictation was running a transform the instant an
// utterance happened to match one of its trigger phrases — dictating the
// actual words "make that a bullet list" ran the transform instead of typing
// them. The fix lives entirely in `DictationCoordinator.hotkeyTriggerIncludes-
// Command(_:)` and the one `if let transforms, self.transformGestureActive`
// gate it feeds — these tests drive that gate directly, the same way
// `FinishThenEnterTests.swift` drives the tap/hold gesture directly, rather
// than going through the real event tap.

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

private struct FakeCompleter: TransformCompleting {
    let reply: String?
    func completeTransform(system: String, user: String, deadline: Duration) async -> String? { reply }
}

/// `FastCleaner` capitalises the first letter of a sentence, which would make
/// an exact-equality assertion against `triggerPhrase` fragile for reasons
/// that have nothing to do with the gate under test. Passed through instead.
private struct IdentityCleaner: TranscriptCleaning {
    func cleanFast(_ raw: String) -> String { raw }
    func cleanThorough(_ raw: String, deadline: Duration) async -> String? { raw }
}

private let triggerPhrase = "make that a bullet list"

/// One transform, reachable only by `triggerPhrase`, whose target is a plain
/// selection — the simplest placement path, with no reselect-and-verify
/// round trip to fake.
private func testTransform() -> Transform {
    Transform(name: "Test Bullets", instruction: "as a list", triggers: [triggerPhrase],
              target: .selection, isBuiltIn: false, created: Date())
}

@MainActor
private func make(_ transcript: String, includesCommand: Bool?)
    -> (DictationCoordinator, InstantTranscriber, Recorder) {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-transform-gesture-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let transcriber = InstantTranscriber(transcript)
    // The same recorder backs both the coordinator's own inserter and the
    // transform engine's — so whichever path actually ran is the one whose
    // text lands in `inserted`.
    let inserter = Recorder()
    let settings = QuillSettings(url: scratch.appendingPathComponent("settings.json"))
    settings.setLiveText(false)
    let router = CommandRouter()
    let store = TransformStore(inMemory: [testTransform()])
    let engine = TransformEngine(
        store: store,
        completer: FakeCompleter(reply: "- One\n- Two"),
        selection: StubSelectionReader(.selected("irrelevant", via: .accessibility)),
        inserter: inserter,
        pasteboard: NSPasteboard(name: .init("com.romangigliotti.quill.tests.\(UUID().uuidString)")),
        sleep: { _ in }
    )
    let coordinator = DictationCoordinator(
        hotkey: TapHotkey(),
        transcriber: transcriber,
        inserter: inserter,
        overlay: Quiet(),
        cleaner: IdentityCleaner(),
        history: HistoryStore(url: scratch.appendingPathComponent("history.json")),
        snippets: SnippetStore(inMemory: []),
        settings: settings,
        liveTyper: LiveTyper(keyboard: SilentKeys()),
        transforms: (router: router, engine: engine),
        context: { .prose }
    )
    if let includesCommand {
        coordinator.hotkeyTriggerIncludesCommand(includesCommand)
    }
    return (coordinator, transcriber, inserter)
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

@Test @MainActor func plainDictationTypesTheTriggerPhraseInsteadOfRunningIt() async {
    let (coordinator, transcriber, inserter) = make(triggerPhrase, includesCommand: false)
    await dictate(coordinator, transcriber: transcriber, inserter: inserter)
    #expect(inserter.inserted == triggerPhrase,
            "plain-Option dictation ran the transform instead of typing the words")
}

@Test @MainActor func theCommandGestureRunsTheMatchingTransformInstead() async {
    let (coordinator, transcriber, inserter) = make(triggerPhrase, includesCommand: true)
    await dictate(coordinator, transcriber: transcriber, inserter: inserter)
    #expect(inserter.inserted == "- One\n- Two",
            "holding ⌘ too did not reach the router — got \(inserter.inserted ?? "nil") instead")
}

/// The gate defaults closed: a coordinator nobody has ever told about the
/// modifier must behave exactly like plain dictation, not like a chord that
/// happened to get lucky.
@Test @MainActor func theGateDefaultsToPlainDictationWhenNeverToldAboutTheModifier() async {
    let (coordinator, transcriber, inserter) = make(triggerPhrase, includesCommand: nil)
    await dictate(coordinator, transcriber: transcriber, inserter: inserter)
    #expect(inserter.inserted == triggerPhrase,
            "an untold gate ran the transform instead of defaulting to plain dictation")
}
