import Foundation

// The seams of the app. Every subsystem is written against these and nothing
// else, so any one of them can be swapped or faked in tests without the others
// noticing. Deliberately small — a seam that needs a paragraph to explain is a
// seam in the wrong place.

// MARK: - Hotkey

/// What the hotkey engine reports. Push-to-talk is a *hold*, so down and up are
/// separate events rather than one toggle.
///
/// @MainActor is enforced rather than merely requested: the tap callback runs on
/// its own runloop, and an engine that forwards straight from there would race
/// the coordinator's state. Making it a compile error is cheaper than finding it
/// as an intermittent bug later.
@MainActor
public protocol HotkeyEngineDelegate: AnyObject {
    func hotkeyPressed()
    func hotkeyReleased()
    /// Escape, or any keystroke that means "throw this dictation away".
    func hotkeyCancelled()
    /// The tap died or could not be created. Carries something a human can act on.
    func hotkeyEngineUnavailable(reason: String)
}

public protocol HotkeyEngine: AnyObject {
    var delegate: HotkeyEngineDelegate? { get set }
    /// Returns false if the tap could not be installed; the delegate gets the reason.
    @discardableResult func start() -> Bool
    func stop()
}

// MARK: - Transcription

public struct Transcript: Sendable, Equatable {
    /// Best text so far. For a volatile result this changes on the next update.
    public let text: String
    /// True once this span is settled and will not be revised.
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Same reasoning as HotkeyEngineDelegate: Speech delivers on its own queue, and
/// forwarding from there would race the coordinator.
@MainActor
public protocol TranscriberDelegate: AnyObject {
    /// Called for every partial and final.
    func transcriber(didProduce transcript: Transcript)
    func transcriber(didFail error: Error)
}

public protocol Transcriber: AnyObject {
    var delegate: TranscriberDelegate? { get set }
    /// Live input level, 0...1, for the overlay's waveform. In the protocol
    /// rather than on the concrete type because a HUD animating to nothing is
    /// the difference between an instrument and a decoration.
    var onLevel: ((Float) -> Void)? { get set }
    /// Warm the model. Called on hotkey-down, before audio, so the first word
    /// is not paying for model load.
    func prepare() async
    func start() async throws
    /// Returns the settled full text for the session.
    func stop() async -> String
    func cancel() async
}

// MARK: - Insertion

public enum InsertionResult: Sendable, Equatable {
    case inserted
    /// Could not type into the focused app; text was put on the clipboard so
    /// the user does not lose it. Never fail silently.
    case fellBackToClipboard(reason: String)
    case failed(reason: String)
}

public protocol TextInserting: AnyObject {
    func insert(_ text: String) -> InsertionResult
}

// MARK: - Overlay

public enum OverlayState: Sendable, Equatable {
    case hidden
    case listening(level: Float)
    case transcribing
    case inserted(words: Int)
    case error(String)
}

public protocol OverlayPresenting: AnyObject {
    func show(_ state: OverlayState)
    func hide()
}

// MARK: - Instrumentation

/// murmur shipped three build passes with no latency number anywhere. This is
/// the fix: every dictation stamps the same five moments, so "is it fast
/// enough" is answerable from a log instead of a guess.
public struct DictationTimeline: Sendable {
    public var hotkeyDown: Date?
    public var audioFirstBuffer: Date?
    public var firstPartial: Date?
    public var finalTranscript: Date?
    public var textInserted: Date?

    public init() {}

    private func ms(_ a: Date?, _ b: Date?) -> Int? {
        guard let a, let b else { return nil }
        return Int(b.timeIntervalSince(a) * 1000)
    }

    /// The number that decides the latency piece: key release → text on screen.
    public var timeToFirstWordMs: Int? { ms(hotkeyDown, firstPartial) }
    public var finalToInsertedMs: Int? { ms(finalTranscript, textInserted) }
    public var endToEndMs: Int? { ms(hotkeyDown, textInserted) }

    public var logLine: String {
        let f = { (v: Int?) in v.map(String.init) ?? "—" }
        return "ttfw=\(f(timeToFirstWordMs))ms final→insert=\(f(finalToInsertedMs))ms e2e=\(f(endToEndMs))ms"
    }
}
