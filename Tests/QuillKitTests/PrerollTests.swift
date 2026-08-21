import AVFoundation
import Foundation
import Testing
@testable import QuillKit

// A preroll that is abandoned must not leave the microphone open.
//
// Quill opens the mic speculatively on key-down so that `start()` is close to
// free by the time the user has actually committed to speaking. The cost of that
// is a window in which a start is in flight and the gesture is already over —
// Right-Option pressed as part of ⌥⌫ or ⌥←, or a single tap of the trigger that
// never became a hold.

/// Records what was asked of it, and never touches hardware.
private final class SpyAudio: AudioSource, @unchecked Sendable {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime?) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let lock = NSLock()
    private var _running = false
    private var _starts = 0
    private var _prepares = 0
    /// How long `prepare()` blocks for. The real one is a ~155ms HAL open, and
    /// that window is the entire bug: it is where `cancel()` lands.
    var prepareDelay: TimeInterval = 0

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _running }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return _starts }
    var prepareCount: Int { lock.lock(); defer { lock.unlock() }; return _prepares }

    var captureFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    }

    func prepare() {
        lock.lock(); _prepares += 1; lock.unlock()
        if prepareDelay > 0 { Thread.sleep(forTimeInterval: prepareDelay) }
    }
    func start() throws {
        lock.lock(); _starts += 1; _running = true; lock.unlock()
    }
    func stop() {
        lock.lock(); _running = false; lock.unlock()
    }
}

/// Cancelling a preroll while `start()` is still inside its own awaits must stop
/// the start, not merely fail to find a session to tear down.
///
/// The failure this pins: `cancel()` arrives before `start()` has installed
/// `self.session`, so `teardown` early-returns having touched nothing, and
/// `audio.stop()` would have been a no-op anyway because the tap is not
/// installed yet. `start()` then ran on to `audio.start()` and opened the
/// microphone for a gesture that was already over — with no dictation, no
/// overlay, and nothing that would ever close it again.
@Test func cancellingAPrerollDoesNotLeaveTheMicrophoneOpen() async {
    let audio = SpyAudio()
    // Long enough that the cancel below lands inside the start, deterministically.
    audio.prepareDelay = 0.25
    let transcriber = SpeechAnalyzerTranscriber(audio: audio, prepareTimeout: 5)

    let starting = Task { try? await transcriber.start() }
    // Let start() get into prepare(), then abandon it — the shape of a single
    // tap, or of Right-Option pressed as half of ⌥⌫.
    try? await Task.sleep(for: .milliseconds(60))
    await transcriber.cancel()
    _ = await starting.value

    #expect(!audio.isRunning, "the microphone was left open by an abandoned preroll")
    #expect(audio.startCount == 0, "audio.start() ran \(audio.startCount) times after a cancel")
}

/// The same guard must not fire on the ordinary path, or every dictation is dead.
@Test func anUncancelledStartStillOpensTheMicrophone() async {
    let audio = SpyAudio()
    let transcriber = SpeechAnalyzerTranscriber(audio: audio, prepareTimeout: 20)

    // Best effort: on a machine with no speech assets the analyzer refuses and
    // `start()` throws before it reaches audio. That is a legitimate environment
    // rather than a regression, so the assertion is conditional on getting past
    // it — what must never happen is the guard silently eating a good start.
    do {
        try await transcriber.start()
        #expect(audio.isRunning, "a start nobody cancelled did not open the microphone")
        #expect(audio.startCount == 1)
        _ = await transcriber.stop()
    } catch {
        #expect(audio.startCount == 0, "audio started and then the start threw")
    }
}
