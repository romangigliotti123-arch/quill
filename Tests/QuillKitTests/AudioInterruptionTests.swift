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
    let overlay = Watching()
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-recover-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let quill = DictationCoordinator(
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
    )

    // Waited on by wall clock rather than by a fixed number of 5ms sleeps: the
    // suite runs in parallel, and under load each of those sleeps lands nearer
    // 65ms, which turned a generous bound into a flake that says nothing about
    // the code.
    func waitForStarts(_ n: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while transcriber.starts < n, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // The speculation opens on key-down and its start() throws.
    //
    // Waiting on `starts == 1` alone is not enough and was a flake: the counter
    // is bumped at the top of start(), and the throw, the catch and fail()'s
    // `isSpeculating = false` all happen after it. Wait for the *failure* to have
    // been processed, which is the state the recovery exists to recover from.
    quill.hotkeyMayBegin()
    await waitForStarts(1)
    let clock = ContinuousClock()
    let failed = clock.now.advanced(by: .seconds(10))
    while !overlay.states.contains(where: { if case .error = $0 { return true }; return false }),
          clock.now < failed {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(transcriber.starts == 1)

    // The arm timer then confirms the gesture. Nothing is capturing, so this is
    // the moment the recovery has to fire.
    quill.hotkeyPressed()
    await waitForStarts(2)
    #expect(transcriber.starts == 2)
}

// MARK: - An abandoned gesture must not supersede a finalising dictation

private final class SlowToFinish: Transcriber, @unchecked Sendable {
    weak var delegate: TranscriberDelegate?
    var onLevel: ((Float) -> Void)?
    let text: String
    init(_ text: String) { self.text = text }
    func prepare() async {}
    func start() async throws {}
    func stop() async -> String {
        // The real one waits out a short-utterance grace, then a drain, then a
        // bounded cancel barrier. Hundreds of milliseconds is the normal case,
        // and it is the whole window this test is about.
        try? await Task.sleep(for: .milliseconds(120))
        return text
    }
    func cancel() async {}
}

@MainActor
@Test func aSecondTapMeantAsAStopDoesNotPushTheSentenceToTheClipboard() async {
    // Hands-free is taught as a double-tap and nothing says stopping is a single
    // tap, so people double-tap to stop. Tap one stops the dictation and starts
    // the finalise; tap two, 150 ms later, lands in .idle and opens a
    // speculation. That speculation used to move `sessionID`, which was also the
    // fence on the insertion — so the sentence went to the clipboard with "You
    // started again before that finished", for a gesture made to STOP.
    //
    // An abandoned gesture has by definition inserted nothing. It has no business
    // invalidating the sentence in flight.
    let inserter = Inserted()
    let overlay = Watching()
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-epoch-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let quill = DictationCoordinator(
        hotkey: SilentHotkey(),
        transcriber: SlowToFinish("the sentence he was dictating"),
        inserter: inserter,
        overlay: overlay,
        cleaner: FastCleaner(),
        history: HistoryStore(url: scratch.appendingPathComponent("history.json")),
        snippets: SnippetStore(inMemory: []),
        settings: pasteOnlySettings(),
        liveTyper: LiveTyper(keyboard: SilentKeystrokes()),
        context: { .prose }
    )

    quill.hotkeyMayBegin()
    quill.hotkeyPressed()
    quill.hotkeyReleased()

    // The second tap of the double-tap, while the first is still finalising.
    try? await Task.sleep(for: .milliseconds(30))
    quill.hotkeyMayBegin()
    quill.hotkeyAborted()

    for _ in 0 ..< 200 where inserter.text == nil {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(inserter.text == "The sentence he was dictating")
    #expect(!overlay.states.contains { state in
        if case let .error(message) = state { return message.contains("clipboard") }
        return false
    })
}

// MARK: - The call that could kill the process

@Test func startingTwiceDoesNotStackTwoTapsOnOneBus() {
    // Not a unit test of AVAudioEngine — a statement of the rule that made the
    // crash possible, so it cannot be quietly dropped.
    //
    // `AudioCapture.start()` guards on `running`, and `running` is set at the
    // very END of the method, after the engine has started. Everything between
    // the guard and that line is therefore reachable twice: two starts racing
    // each other both pass, and both reach `installTapOnBus`. The second one
    // does not fail — it raises an Objective-C exception, which Swift cannot
    // catch, so the process aborts. Every one of the fourteen crash reports on
    // this machine is that line.
    //
    // The fix is a `removeTap` immediately before the install, which is a no-op
    // when there is nothing there. This test pins that the source still says so.
    let source = try! String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/QuillKit/Audio/AudioCapture.swift"),
        encoding: .utf8)

    guard let installIndex = source.range(of: "installTap(format: format, warmupDeadline:")?.lowerBound,
          let guardIndex = source.range(of: "guard !running else { return }")?.upperBound
    else {
        Issue.record("AudioCapture.start() no longer has the shape this pins")
        return
    }
    let between = source[guardIndex ..< installIndex]
    #expect(between.contains("removeTap(onBus: 0)"),
            "installTapOnBus can abort the process if a tap is already on the bus")
    #expect(between.contains("inputFormat(forBus: 0)"),
            "the format must be re-checked against the node immediately before the install")
}

@Test func onboardingActivatesBeforeItOrdersItsWindowFront() {
    // A second one of these. Three more crash reports on this Mac are AppKit
    // throwing out of `-[NSWindow _doOrderWindow:]` inside
    // `OnboardingWindowController.present()` — an uncatchable Objective-C
    // exception, same as the audio one above, for the same reason: Swift
    // cannot catch it, so it is not an error the app can handle, it is
    // `abort()`.
    //
    // The state that produces it is a window asked to become key while the
    // accessory app that owns it is not yet the frontmost application. This
    // method used to call `showWindow` — which orders the window — and only
    // afterward call `activate`, which is the one ordering that guarantees
    // that state exists for a moment. `DashboardWindowController.show` already
    // gets this right elsewhere in the app; this pins that `present()` now
    // matches it, in both branches.
    let source = try! String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/QuillKit/Onboarding/OnboardingWindow.swift"),
        encoding: .utf8)

    guard let bodyStart = source.range(of: "public static func present() -> OnboardingWindowController {")?.upperBound,
          let bodyEnd = source.range(of: "\n    }", range: bodyStart..<source.endIndex)?.lowerBound
    else {
        Issue.record("OnboardingWindowController.present() no longer has the shape this pins")
        return
    }
    let body = source[bodyStart..<bodyEnd]

    // Two branches — the panel already exists, and a fresh one is built — and
    // `activate` must come first in both, or the fix only covers whichever
    // branch happened to be checked by hand.
    guard let activateAt = body.range(of: "NSApp.activate(ignoringOtherApps: true)")?.lowerBound,
          let firstOrderAt = body.range(of: "makeKeyAndOrderFront(nil)")?.lowerBound
    else {
        Issue.record("expected both an activate call and a makeKeyAndOrderFront call")
        return
    }
    #expect(activateAt < firstOrderAt,
            "activate must run before the existing window is ordered front")

    guard let secondActivateAt = body.range(of: "NSApp.activate", range: firstOrderAt..<body.endIndex)?.lowerBound,
          let showWindowAt = body.range(of: "showWindow(nil)")?.lowerBound
    else {
        Issue.record("expected a second activate call before showWindow in the fresh-controller branch")
        return
    }
    #expect(secondActivateAt < showWindowAt,
            "activate must run before showWindow orders the new window front")
}
