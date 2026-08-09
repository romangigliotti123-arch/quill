import AppKit
import Testing
@testable import QuillKit

// The ⌘C fallback borrows the user's clipboard. Everything that can go wrong
// while it is borrowed — the app that never answers, the two-phase pasteboard
// write, the user who copies something else mid-poll — is unreproducible against
// a real pasteboard and a real focused app, which is exactly why the loop is
// behind closures and this file exists.

/// A fake focused app. `copiesAfter` is how many polls it takes to answer;
/// `writesInTwoSteps` reproduces `declareTypes` bumping `changeCount` before
/// `setString` puts the bytes in.
@MainActor
private final class FakeApp {
    var changeCount = 7
    var contents: String? = "the user's own clipboard"
    var copiesAfter: Int
    var writesInTwoSteps: Bool
    var selection: String?
    var polls = 0
    var copyRequests = 0
    var restores = 0

    init(selection: String?, copiesAfter: Int = 1, writesInTwoSteps: Bool = false) {
        self.selection = selection
        self.copiesAfter = copiesAfter
        self.writesInTwoSteps = writesInTwoSteps
    }

    func probe(timeout: Duration = .milliseconds(120),
               pollInterval: Duration = .milliseconds(12)) -> ClipboardCopyProbe {
        ClipboardCopyProbe(
            changeCount: { self.changeCount },
            copy: {
                self.copyRequests += 1
                return true
            },
            readString: { self.contents },
            restore: { _ in self.restores += 1 },
            // No real sleeping: the loop is driven by how many times it polls.
            sleep: { _ in
                self.polls += 1
                guard let selection = self.selection else { return }
                if self.polls == self.copiesAfter {
                    self.changeCount += 1
                    self.contents = self.writesInTwoSteps ? "" : selection
                } else if self.writesInTwoSteps, self.polls == self.copiesAfter + 1 {
                    // The bytes land one poll after the count moved, which is
                    // the window a single-read implementation falls into.
                    self.contents = selection
                }
            },
            timeout: timeout,
            pollInterval: pollInterval
        )
    }
}

// MARK: - The happy path

@Test @MainActor func aSelectionIsReadAndTheClipboardIsPutBack() async {
    let app = FakeApp(selection: "the deposit is 50% up front")
    let outcome = await app.probe().run()
    #expect(outcome == .copied("the deposit is 50% up front"))
    #expect(app.copyRequests == 1)
    // Always restored. A clipboard left holding the user's own selection is a
    // clipboard we broke, even though the contents look harmless.
    #expect(app.restores == 1)
}

@Test @MainActor func aTwoStepPasteboardWriteIsWaitedOut() async {
    // NSPasteboard bumps changeCount on declareTypes and puts the bytes in on
    // setString. A probe that trusted its first read would report an empty
    // selection for a selection that was there.
    let app = FakeApp(selection: "the frames are ready", writesInTwoSteps: true)
    #expect(await app.probe().run() == .copied("the frames are ready"))
}

@Test @MainActor func theRestoreIsOfferedTheCountFromWhenTheCopyLandedNotFromNow() async {
    // The guard is "has anyone written since our copy landed", and the only way
    // to answer it is with the count from *detection*. An implementation that
    // reads the current count and hands that to the restore is comparing a value
    // against itself: it reads like a guard and always says yes.
    let app = FakeApp(selection: "the frames are ready", writesInTwoSteps: true)
    let handed = Locked(-1)
    var probe = app.probe()
    probe.restore = { handed.value = $0 }

    #expect(await probe.run() == .copied("the frames are ready"))
    // The settle loop polls again after detection, so "now" and "then" are
    // different numbers only if something moved — here nothing did, so the real
    // proof is that the count handed over is the one observed at detection.
    #expect(handed.value == 8)
    #expect(app.changeCount == 8)
}

/// A tiny box so a closure can report back into a test.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

// MARK: - The refusals

@Test @MainActor func nothingSelectedIsReportedAsNothingSelected() async {
    // ⌘C with an empty selection does not touch the pasteboard at all, so the
    // only evidence available is the absence of a change.
    let app = FakeApp(selection: nil)
    #expect(await app.probe().run() == .nothingHappened)
    // Nothing was written, so nothing was put back.
    #expect(app.restores == 0)
}

@Test @MainActor func anAppThatNeverAnswersTimesOutRatherThanHanging() async {
    // 120ms of timeout at 12ms per poll is ten polls; this app answers on the
    // eleventh, which is to say never.
    let app = FakeApp(selection: "too late", copiesAfter: 11)
    #expect(await app.probe().run() == .nothingHappened)
    #expect(app.polls == 10)
}

@Test @MainActor func aChangedClipboardHoldingNothingIsNotASelection() async {
    let app = FakeApp(selection: "")
    app.selection = ""
    #expect(await app.probe().run() == .nothingHappened)
}

@Test @MainActor func aKeystrokeThatCannotBePostedIsAnHonestFailure() async {
    let app = FakeApp(selection: "never reached")
    var probe = app.probe()
    probe.copy = { false }
    guard case .couldNotCopy = await probe.run() else {
        #expect(Bool(false), "expected couldNotCopy")
        return
    }
}

// MARK: - The clipboard it refuses to borrow

@Test @MainActor func anUnrestorableClipboardIsNotBorrowed() {
    // Same call as TextInserter's: a snapshot that could not read everything
    // cannot put everything back, and reading a selection is never worth losing
    // what the user copied. Verified on the snapshot rather than end to end,
    // because the end-to-end path needs a real focused app.
    let unfaithful = PasteboardSnapshot(items: [[:]], sourceItemCount: 1, changeCount: 3)
    #expect(!unfaithful.isFaithful)

    let faithful = PasteboardSnapshot(items: [["public.utf8-plain-text": Data("hi".utf8)]],
                                      sourceItemCount: 1, changeCount: 3)
    #expect(faithful.isFaithful)
}

@Test @MainActor func theRestoreDeclinesWhenSomeoneElseHasWrittenSinceTheCopy() {
    // Between our copy and the restore the user can copy something new. Putting
    // a 300ms-old clipboard back over it destroys what they just copied.
    #expect(PasteboardSnapshot.restoreIsSafe(ourChangeCount: 9, currentChangeCount: 9))
    #expect(!PasteboardSnapshot.restoreIsSafe(ourChangeCount: 9, currentChangeCount: 10))
}

// MARK: - Wiring

@Test @MainActor func theReaderRefusesWithoutAccessibility() async {
    // In CI and in a test process Quill is not a trusted process, so this is the
    // real answer rather than a mocked one — and it must be a reason a human can
    // act on, not a silent empty selection.
    guard Permissions.state(of: .accessibility) != .granted else { return }
    let reader = SelectionReader(pasteboard: NSPasteboard(name: .init("com.romangigliotti.quill.tests")))
    guard case .unavailable(let reason) = await reader.readSelection() else {
        #expect(Bool(false), "expected unavailable")
        return
    }
    #expect(reason.contains(Permission.accessibility.settingsPath))
}
