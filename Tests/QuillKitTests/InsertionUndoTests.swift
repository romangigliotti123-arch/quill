import CoreGraphics
import Foundation
import Testing
@testable import QuillKit

// ⌥⌫ — take back the sentence Quill just inserted.
//
// Every test here is about a way of NOT firing. The chord overrides "delete the
// previous word", a binding every macOS text field has and every user relies on
// without thinking, so the interesting question is never "does it delete" — it
// is "does it refuse, and does the user's keystroke survive the refusal". A
// happy-path-only suite would pass just as well against code that deletes a
// paragraph somebody wrote themselves.

private let anotherApp: pid_t = 4242
private let ourApp: pid_t = 1234

/// Records what was posted instead of posting it. The real emitter backspaces
/// into whatever app is frontmost, which during a test run is an editor.
private final class Recorder: KeystrokeEmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var actions: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    @discardableResult func type(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        log.append("type(\(text))")
        return true
    }

    @discardableResult func backspace(times: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        log.append("backspace(\(times))")
        return true
    }

    @discardableResult func chord(key: CGKeyCode, flags: CGEventFlags) -> Bool {
        lock.lock(); defer { lock.unlock() }
        log.append("chord(\(key),\(flags.rawValue))")
        return true
    }
}

/// Answers as if the field held exactly `text` before the caret, and REMEMBERS
/// the length it was asked for.
///
/// It used to throw that length away under a comment claiming it was "exercised
/// rather than assumed" — so the one place the grapheme/UTF-16 split actually
/// reaches Accessibility was unpinned, and the comment asserted coverage that
/// did not exist. A reader trusts a line like that and stops looking.
private final class FixedCaret: CaretTextReading, @unchecked Sendable {
    let reading: CaretReading
    private let lock = NSLock()
    private var lengths: [Int] = []

    init(reading: CaretReading) { self.reading = reading }

    var requestedLengths: [Int] {
        lock.lock(); defer { lock.unlock() }
        return lengths
    }

    static func holding(_ text: String) -> FixedCaret { FixedCaret(reading: .text(text)) }

    func textBeforeCaret(pid: pid_t, length: Int) -> CaretReading {
        lock.lock(); lengths.append(length); lock.unlock()
        return reading
    }
}

@MainActor
private func store(_ keyboard: Recorder,
                   caret: CaretTextReading = FixedCaret(reading: .unknown),
                   frontmost: pid_t? = ourApp) -> InsertionUndo {
    InsertionUndo(keyboard: keyboard, caret: caret, frontmost: { frontmost })
}

/// The chord as the app puts it back, for asserting the user's keystroke was
/// not eaten.
private let putBack = "chord(\(UndoChord.keyCode),\(UndoChord.flags.rawValue))"

// MARK: - Deleting exactly what was inserted

@MainActor
@Test func theChordDeletesExactlyWhatQuillInserted() {
    let keys = Recorder()
    let undo = store(keys, caret: FixedCaret.holding("Hello there Roman."))
    undo.record("Hello there Roman.", pid: ourApp)

    #expect(undo.undoLastInsertion())
    #expect(keys.actions == ["backspace(18)"])
}

@MainActor
@Test func theCountIsInVisibleCharactersNotUTF16Units() {
    // "👍🏽" is one backspace and four UTF-16 units. Counting the units takes half
    // the emoji off and leaves the fragment behind — and then eats a character
    // of the user's own text to make up the difference.
    let text = "Nice 👍🏽"
    let keys = Recorder()
    let undo = store(keys, caret: FixedCaret.holding(text))
    undo.record(text, pid: ourApp)

    #expect(undo.undoLastInsertion())
    #expect(keys.actions == ["backspace(\(text.count))"])
    #expect(text.count != text.utf16.count, "the emoji stopped being a multi-unit character")
}

// MARK: - The guards

@MainActor
@Test func nothingInsertedMeansTheKeystrokeGoesStraightThrough() {
    let keys = Recorder()
    let undo = store(keys)

    #expect(!undo.undoLastInsertion())
    #expect(keys.actions == [putBack], "the user's ⌥⌫ was swallowed and never put back")
}

@MainActor
@Test func aDiscardedInsertionIsNotTakenBack() {
    // What the event tap does on every real keystroke, the mouse monitor does on
    // every click, and the coordinator does at the start of every dictation.
    let keys = Recorder()
    let undo = store(keys, caret: FixedCaret.holding("Hello there"))
    undo.record("Hello there", pid: ourApp)
    undo.discard()

    #expect(!undo.undoLastInsertion())
    #expect(keys.actions == [putBack])
}

@MainActor
@Test func aDifferentAppInFrontMeansNoDeletion() {
    // The record is dropped on app switches, but a switch landing between the
    // tap's cheap check and the main-thread decision has not been seen yet. This
    // is the second half of that guard, and the one that stops backspaces going
    // into a document Quill never wrote in.
    let keys = Recorder()
    let undo = store(keys, caret: FixedCaret.holding("Hello there"), frontmost: anotherApp)
    undo.record("Hello there", pid: ourApp)

    #expect(!undo.undoLastInsertion())
    #expect(keys.actions == [putBack])
}

@MainActor
@Test func textThatIsNoLongerThereIsNotDeleted() {
    // The app rewrote it, or the caret is somewhere else entirely. Either way
    // what sits behind the caret is somebody else's, and deleting eighteen
    // characters of it is the worst thing this app could do.
    let keys = Recorder()
    let undo = store(keys, caret: FixedCaret.holding("something else en"))
    undo.record("Hello there Roman.", pid: ourApp)

    #expect(!undo.undoLastInsertion())
    #expect(keys.actions == [putBack])
}

@MainActor
@Test func aLiveSelectionIsNeverBackspacedOver() {
    // The first backspace would delete the selection whole, so every count after
    // it is wrong. Accessibility can see this; the disturbance guards cannot.
    let keys = Recorder()
    let undo = store(keys, caret: FixedCaret(reading: .unsafe))
    undo.record("Hello there", pid: ourApp)

    #expect(!undo.undoLastInsertion())
    #expect(keys.actions == [putBack])
}

@MainActor
@Test func oneChordIsOneAttempt() {
    // Pressing it twice must not try again against a field we have just failed
    // to recognise — the second press belongs to the app.
    let keys = Recorder()
    let undo = store(keys, caret: FixedCaret.holding("Hello there"))
    undo.record("Hello there", pid: ourApp)

    #expect(undo.undoLastInsertion())
    #expect(!undo.undoLastInsertion())
    #expect(keys.actions == ["backspace(11)", putBack])
}

@MainActor
@Test func anEmptyInsertionIsNotWorthRemembering() {
    let keys = Recorder()
    let undo = store(keys)
    undo.record("", pid: ourApp)

    #expect(!undo.isArmed)
    #expect(!undo.undoLastInsertion())
}

@MainActor
@Test func accessibilityDecliningRefusesRatherThanTrustingTheGuards() {
    // Roman's call, asked directly and answered: when the field will not confirm
    // our sentence is still behind the caret, Quill does not delete.
    //
    // This is the ordinary answer in Electron apps, web views and most terminals,
    // so the visible consequence is that ⌥⌫ in those apps now always deletes a
    // word, exactly as it did before Quill existed. That is the price of never
    // backspacing over text somebody wrote themselves in a document Quill cannot
    // read back — the disturbance guards cannot see an app that rewrote the text
    // on its own, and not firing costs one gesture where firing wrongly costs a
    // sentence.
    let keys = Recorder()
    let undo = store(keys, caret: FixedCaret(reading: .unknown))
    undo.record("Hello there", pid: ourApp)

    #expect(!undo.undoLastInsertion())
    // The keystroke is handed back, so the app still deletes a word.
    #expect(keys.actions == [putBack])
}

@MainActor
@Test func armingIsWhatTheEventTapAsks() {
    let undo = store(Recorder())
    #expect(!undo.isArmed)
    undo.record("Hello there", pid: ourApp)
    #expect(undo.isArmed)
    undo.discard()
    #expect(!undo.isArmed)
}

// MARK: - Claiming the keystroke

private func claims(_ keyCode: UInt16,
                    _ flags: CGEventFlags,
                    _ gesture: HotkeyStateMachine.State = .idle,
                    heldFor: TimeInterval? = nil,
                    insertion: Bool = true) -> Bool {
    UndoChord.claims(keyCode: keyCode, flags: flags, gesture: gesture,
                     triggerHeldFor: heldFor, hasInsertion: insertion)
}

@Test func optionDeleteIsClaimedWhenThereIsSomethingToTakeBack() {
    #expect(claims(UndoChord.keyCode, .maskAlternate))
}

@Test func withNothingInsertedTheChordIsNotClaimedAtAll() {
    // The whole safety of overriding a standard binding rests on this line: with
    // no record, ⌥⌫ is never swallowed and deletes a word exactly as it always
    // did.
    #expect(!claims(UndoChord.keyCode, .maskAlternate, insertion: false))
}

@Test func abareBackspaceIsNotTheChord() {
    #expect(!claims(UndoChord.keyCode, []))
}

@Test func addingAnyOtherModifierGivesTheKeystrokeBack() {
    // ⇧⌥⌫ and ⌘⌥⌫ are other people's bindings.
    #expect(!claims(UndoChord.keyCode, [.maskAlternate, .maskShift]))
    #expect(!claims(UndoChord.keyCode, [.maskAlternate, .maskCommand]))
    #expect(!claims(UndoChord.keyCode, [.maskAlternate, .maskControl]))
}

@Test func theFnAndNumericPadBitsDoNotDisqualifyTheChord() {
    // Arrow and Return key-downs arrive with .maskSecondaryFn set on a built-in
    // keyboard, which is why every comparison in this app masks down first. A
    // raw equality check here would have made the chord work on some keyboards
    // and not others.
    #expect(claims(UndoChord.keyCode, [.maskAlternate, .maskSecondaryFn]))
}

@Test func anyOtherKeyIsNotTheChord() {
    #expect(!claims(HotkeyBinding.escapeKeyCode, .maskAlternate))
    #expect(!claims(SyntheticKeyboard.keyV, .maskAlternate))
}

@Test func theChordIsRefusedWhileTheUserIsSpeaking() {
    // Mid-dictation a ⌫ means "bin this", which the state machine already
    // handles. Claiming it would bin the current sentence AND delete the
    // previous one.
    #expect(!claims(UndoChord.keyCode, .maskAlternate, .holding, heldFor: 1.5))
    #expect(!claims(UndoChord.keyCode, .maskAlternate, .handsFree, heldFor: 0.05))
}

@Test func aSlowerHandStillGetsTheChord() {
    // The bug this pins: right Option is the shipped trigger, so ⌥⌫ arms a
    // speculation and the arm timer moves the machine to .holding after 120 ms —
    // whether or not the user has done anything. A deliberate thumb-to-Delete
    // reach routinely takes longer than that, and every one of those presses used
    // to fall through as a plain ⌥⌫ word-delete that chewed one word off the end
    // of Quill's own insertion, then discarded the record so the next press ate
    // another. Working or not working depending on how fast you chord reads as
    // "it just doesn't work sometimes", which is the report.
    #expect(claims(UndoChord.keyCode, .maskAlternate, .holding, heldFor: 0.30))
    #expect(claims(UndoChord.keyCode, .maskAlternate, .holding, heldFor: UndoChord.chordWindow))

    // And the far side of the window is a dictation, not a chord.
    #expect(!claims(UndoChord.keyCode, .maskAlternate, .holding, heldFor: 0.41))

    // No trigger held at all: the machine is in .holding but the key is up, which
    // cannot be half of a chord. Refuse rather than guess.
    #expect(!claims(UndoChord.keyCode, .maskAlternate, .holding, heldFor: nil))

    // Unchanged in every other state — the window only ever adds to .holding.
    #expect(!claims(UndoChord.keyCode, .maskAlternate, .holding, heldFor: 0.30, insertion: false))
}

@Test func theChordSurvivesTheDictationKeyBeingAnOption() {
    // Right Option is the shipped binding, so pressing ⌥⌫ arms a speculation
    // with the modifier and delivers the ⌫ inside the 120ms arm delay. Without
    // this the feature would never fire for anyone who had not rebound the key.
    #expect(claims(UndoChord.keyCode, .maskAlternate, .armed(token: 1)))
}


// MARK: - The two counts, both halves

@MainActor
@Test func theAccessibilityRangeIsAskedForInUTF16UnitsNotCharacters() {
    // The two counts in this file are deliberately different units and only one
    // of them was tested. Backspaces are graphemes, because that is what a
    // delete key removes; an AX range is UTF-16, because every AX range in the
    // system is counted in those. An emoji is one grapheme and two UTF-16 units,
    // so asking for `text.count` units reads back a SHORT string, the comparison
    // against our sentence fails, and the chord silently refuses on any dictation
    // containing one — which is the failure that looks like "it just doesn't
    // work sometimes".
    let text = "Ship it 🚀"
    #expect(text.count == 9)
    #expect(text.utf16.count == 10)

    let keyboard = Recorder()
    let caret = FixedCaret.holding(text)
    let undo = store(keyboard, caret: caret)
    undo.record(text, pid: ourApp)
    // Synchronous, like every other test here. `requestUndo()` hops to main and
    // would leave the assertions racing the work they are about to check.
    #expect(undo.undoLastInsertion())

    #expect(caret.requestedLengths == [text.utf16.count],
            "asked Accessibility for \(caret.requestedLengths) units, not \(text.utf16.count)")
    // And the delete itself is still counted the other way.
    #expect(keyboard.actions == ["backspace(\(text.count))"])
}

// MARK: - Blind spells disarm the record

/// The seam the engine holds, recorded rather than performed.
///
/// It also answers the reasonable objection to `InsertionUndoing` existing at
/// all — one conformer, no double, no substitution. This is the double, and the
/// thing it substitutes for is the one behaviour in the feature that cannot be
/// checked any other way: the engine disarming the chord when it goes blind.
private final class SpyUndo: InsertionUndoing, @unchecked Sendable {
    private let lock = NSLock()
    private var discards = 0
    private var armed = true

    var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return armed
    }
    var discardCount: Int {
        lock.lock(); defer { lock.unlock() }
        return discards
    }
    func discard() {
        lock.lock(); discards += 1; armed = false; lock.unlock()
    }
    func requestUndo() {}
}

@MainActor
@Test func losingTheTapThrowsTheUndoRecordAway() {
    // The guard that makes ⌥⌫ defensible is "any keystroke since the insertion
    // disarms it", and that guard is implemented on the keyDown branch of the
    // event tap. So every path where the tap stops seeing keys is a path where
    // the guard silently stops running while the record stays armed — and the
    // user can then type a paragraph the tap never saw, press ⌥⌫ expecting a
    // word delete, and get their own text backspaced away instead.
    //
    // The engine's own log already says what a disabled tap costs: "events in
    // that window were lost". Blind has to mean disarmed.
    //
    // `stop()` is the one blind path reachable without an Accessibility grant, so
    // it is the one pinned here; the tap-disabled and unavailable branches use
    // the same single call for the same stated reason.
    let spy = SpyUndo()
    let engine = EventTapHotkeyEngine(undo: spy)
    #expect(spy.isArmed)

    engine.stop()
    #expect(spy.discardCount == 1, "stopping the engine left the chord armed")
    #expect(!spy.isArmed)
}

// MARK: - The record has to outlive its own gesture

private final class SilentHotkey: HotkeyEngine, @unchecked Sendable {
    weak var delegate: HotkeyEngineDelegate?
    func start() -> Bool { true }
    func stop() {}
}

private final class SaysNothing: Transcriber, @unchecked Sendable {
    weak var delegate: TranscriberDelegate?
    var onLevel: ((Float) -> Void)?
    func prepare() async {}
    func start() async throws {}
    func stop() async -> String { "" }
    func cancel() async {}
}

private final class AcceptsAnything: TextInserting, @unchecked Sendable {
    func insert(_ text: String) -> InsertionResult { .inserted }
}

private final class NoOverlay: OverlayPresenting, @unchecked Sendable {
    func show(_ state: OverlayState) {}
    func hide() {}
}

@MainActor
@Test func startingADictationDoesNotByItselfThrowTheRecordAway() async {
    // The bug this pins, and it is the half that makes the chord work at all.
    //
    // The shipped trigger is right Option, so ⌥⌫ *is* a trigger press followed by
    // a ⌫. beginDictation() used to discard the record — 120 ms after the trigger
    // went down, before the ⌫ of the user's own chord could arrive. The feature
    // was destroyed by the gesture that invokes it, and the arm delay decided
    // whether it happened.
    //
    // Nothing has been typed at this point: no partial has arrived, no paste has
    // landed, and the previous sentence is still the last thing at the caret and
    // still exactly what "take that back" means.
    let keys = Recorder()
    let undo = store(keys, caret: FixedCaret.holding("Hello there Roman."))
    undo.record("Hello there Roman.", pid: ourApp)
    #expect(undo.isArmed)

    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-undo-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let coordinator = DictationCoordinator(
        hotkey: SilentHotkey(),
        transcriber: SaysNothing(),
        inserter: AcceptsAnything(),
        overlay: NoOverlay(),
        cleaner: FastCleaner(),
        history: HistoryStore(url: scratch.appendingPathComponent("history.json")),
        snippets: SnippetStore(inMemory: []),
        settings: pasteOnlySettings(),
        liveTyper: LiveTyper(keyboard: SilentKeystrokes()),
        undo: undo,
        context: { .prose }
    )

    coordinator.hotkeyMayBegin()
    coordinator.hotkeyPressed()
    #expect(undo.isArmed)
    #expect(undo.undoLastInsertion())
    #expect(keys.actions.contains("backspace(18)"))
    coordinator.hotkeyCancelled(userKeystroke: "")
}
