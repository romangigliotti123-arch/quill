import AVFoundation
import Foundation
import Testing
@testable import QuillKit

// The microphone going away in the middle of a sentence.
//
// AirPods dropping out at the four-second mark of a nine-second dictation, a
// call starting and moving them between their 48 kHz and 16 kHz modes, a USB
// interface unplugged. The engine stops and uninitializes itself, taking the
// installed tap with it, and buffers simply stop arriving.
//
// Every existing signal says everything is fine: `running` is still true,
// `engine.isRunning` is read nowhere, and the only liveness the coordinator has
// is the level meter, which has no timeout on its own absence. So the first four
// seconds were inserted as though they were the whole sentence — a grammatical
// half-thought, which is the worst shape this failure can take, because it does
// not look like a failure.

private final class SilentHotkey: HotkeyEngine, @unchecked Sendable {
    weak var delegate: HotkeyEngineDelegate?
    func start() -> Bool { true }
    func stop() {}
}

private final class Heard: Transcriber, @unchecked Sendable {
    weak var delegate: TranscriberDelegate?
    var onLevel: ((Float) -> Void)?
    let text: String
    init(_ text: String) { self.text = text }
    func prepare() async {}
    func start() async throws {}
    func stop() async -> String { text }
    func cancel() async {}
}

private final class Inserted: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var _text: String?
    var text: String? { lock.lock(); defer { lock.unlock() }; return _text }
    func insert(_ text: String) -> InsertionResult {
        lock.lock(); _text = text; lock.unlock()
        return .inserted
    }
}

private final class Watching: OverlayPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [OverlayState] = []
    var states: [OverlayState] { lock.lock(); defer { lock.unlock() }; return log }
    func show(_ state: OverlayState) { lock.lock(); log.append(state); lock.unlock() }
    func hide() { lock.lock(); log.append(.hidden); lock.unlock() }
}

@MainActor
private func coordinator(heard: String,
                         _ inserter: Inserted,
                         _ overlay: Watching) -> (DictationCoordinator, Heard) {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-interrupt-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let transcriber = Heard(heard)
    return (DictationCoordinator(
        hotkey: SilentHotkey(),
        transcriber: transcriber,
        inserter: inserter,
        overlay: overlay,
        cleaner: FastCleaner(),
        history: HistoryStore(url: scratch.appendingPathComponent("history.json")),
        snippets: SnippetStore(inMemory: []),
        settings: pasteOnlySettings(),
        liveTyper: LiveTyper(keyboard: SilentKeystrokes()),
        context: { .prose }
    ), transcriber)
}

@MainActor
private func settle(_ inserter: Inserted) async {
    for _ in 0 ..< 400 {
        if inserter.text != nil { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Test func losingTheMicrophoneKeepsWhatWasAlreadyHeard() async {
    // The recording is short and carried no level callbacks, which is exactly
    // what a change of mind looks like from inside the coordinator — and the
    // change-of-mind shortcut bins the audio and hides the overlay without a
    // word. Correct when the user changed their mind, and the same silent loss
    // from the other end when the device did.
    let inserter = Inserted()
    let overlay = Watching()
    let (quill, mic) = coordinator(heard: "the first half of the sentence", inserter, overlay)

    quill.hotkeyMayBegin()
    quill.hotkeyPressed()
    // Levels arrived, and every one of them was under the silence floor — an
    // AirPods hand-off at the moment of the press. Short and silent is precisely
    // the shape the change-of-mind shortcut bins without a word.
    mic.onLevel?(0.001)
    // The handler hops to main before it records anything, so the flag is not
    // set until the next turn of the loop.
    try? await Task.sleep(for: .milliseconds(20))
    #expect(quill.sawLevelsForTesting)
    quill.transcriberDidLoseInput()
    await settle(inserter)

    #expect(inserter.text == "The first half of the sentence")
}

@MainActor
@Test func losingTheMicrophoneSaysSoRatherThanReportingANormalInsertion() async {
    // Half a sentence presented as a whole one is the failure this message
    // exists to break. The words are real and they go in; what changes is that
    // the user is told why they stop where they do.
    let inserter = Inserted()
    let overlay = Watching()
    let (quill, _) = coordinator(heard: "the first half of the sentence", inserter, overlay)

    quill.hotkeyMayBegin()
    quill.hotkeyPressed()
    quill.transcriberDidLoseInput()
    await settle(inserter)

    let spoke = overlay.states.contains { state in
        if case let .error(message) = state { return message.contains("disconnected") }
        return false
    }
    #expect(spoke)
    #expect(!overlay.states.contains { if case .inserted = $0 { return true }; return false })
}

@MainActor
@Test func anOrdinaryDictationStillReportsAnOrdinaryInsertion() async {
    // The other side of the same switch: nothing about the normal path moves.
    let inserter = Inserted()
    let overlay = Watching()
    let (quill, _) = coordinator(heard: "the whole sentence", inserter, overlay)

    quill.hotkeyMayBegin()
    quill.hotkeyPressed()
    quill.hotkeyReleased()
    await settle(inserter)

    #expect(inserter.text == "The whole sentence")
    #expect(overlay.states.contains { if case .inserted = $0 { return true }; return false })
}

@MainActor
@Test func losingTheMicrophoneBeforeTheGestureIsConfirmedIsNotAnnounced() async {
    // A speculation is not a dictation: nothing has been shown, so there is
    // nothing to explain. Bin it quietly rather than putting an error on screen
    // for a gesture the user never completed.
    let inserter = Inserted()
    let overlay = Watching()
    let (quill, _) = coordinator(heard: "never confirmed", inserter, overlay)

    quill.hotkeyMayBegin()
    quill.transcriberDidLoseInput()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(inserter.text == nil)
    #expect(!overlay.states.contains { if case .error = $0 { return true }; return false })
}

// MARK: - Recovering from a speculation that could not open the microphone

private final class FailsFirstStart: Transcriber, @unchecked Sendable {
    weak var delegate: TranscriberDelegate?
    var onLevel: ((Float) -> Void)?
    private let lock = NSLock()
    private var _starts = 0
    var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }

    func prepare() async {}
    func start() async throws {
        lock.lock(); _starts += 1; let n = _starts; lock.unlock()
        if n == 1 { throw AudioSourceError.noInputDevice }
    }
    func stop() async -> String { "recovered" }
    func cancel() async {}
}

@MainActor
@Test func aConfirmedGestureRecoversWhenItsSpeculationCouldNotOpenTheMicrophone() async {
    // The recovery beginDictation() documents, which could never once have run.
    //
    // It set `isDictating = true` and *then* called speculativelyBegin(), whose
    // first guard is `!isDictating` — so the call logged "key-down IGNORED:
    // already dictating" and returned. Roman then spoke a paragraph into a
    // coordinator that believed it was dictating and had no capture session at
    // all, and was told his microphone sent no sound, about a microphone that was
    // fine. No insertion, no clipboard, no history row.
    let transcriber = FailsFirstStart()
    let inserter = Inserted()
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-recover-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let quill = DictationCoordinator(
        hotkey: SilentHotkey(),
        transcriber: transcriber,
        inserter: inserter,
        overlay: Watching(),
        cleaner: FastCleaner(),
        history: HistoryStore(url: scratch.appendingPathComponent("history.json")),
        snippets: SnippetStore(inMemory: []),
        settings: pasteOnlySettings(),
        liveTyper: LiveTyper(keyboard: SilentKeystrokes()),
        context: { .prose }
    )

    // The speculation opens on key-down and its start() throws.
    quill.hotkeyMayBegin()
    for _ in 0 ..< 100 where transcriber.starts < 1 {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(transcriber.starts == 1)

    // The arm timer then confirms the gesture. Nothing is capturing, so this is
    // the moment the recovery has to fire.
    quill.hotkeyPressed()
    for _ in 0 ..< 100 where transcriber.starts < 2 {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(transcriber.starts == 2)
}
