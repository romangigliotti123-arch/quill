import Foundation
import Testing
@testable import QuillKit

/// A scripted field. Each `focusedText` call returns the next state, so a whole
/// editing session — including the half-typed states in the middle of it — can be
/// stepped through without a window server.
private final class ScriptedField: FocusedTextReading, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String?]
    private(set) var reads = 0

    init(_ states: [String?]) { self.states = states }

    func focusedText(pid: pid_t) -> String? {
        lock.withLock {
            reads += 1
            guard !states.isEmpty else { return nil }
            return states.count == 1 ? states[0] : states.removeFirst()
        }
    }
}

private func isolatedSettings(learnFromEdits: Bool = true) -> QuillSettings {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("quill-edit-\(UUID().uuidString)/settings.json")
    let settings = QuillSettings(url: url)
    settings.setLearnFromEdits(learnFromEdits)
    return settings
}

// MARK: - Finding the sentence again

/// The anchoring, on its own. Diffing two whole documents would find every change
/// in both of them, including the paragraph written afterwards, which says
/// nothing about how someone corrects dictation.
@Suite struct InsertedSpanTests {

    private let sentence = "send noah the deposit terms"

    @Test func anchorsRememberBothSidesOfWhereItLanded() throws {
        let field = "Morning. \(sentence) Cheers."
        let anchors = try #require(InsertedSpan.anchors(inserted: sentence, in: field))
        #expect(anchors.left == "Morning. ")
        #expect(anchors.right == " Cheers.")
        #expect(anchors.inserted == sentence)
    }

    @Test func thereAreNoAnchorsWhenTheFieldDoesNotHaveTheSentence() {
        // The app rewrote the text on arrival, or the insertion did not land.
        #expect(InsertedSpan.anchors(inserted: sentence, in: "something else entirely") == nil)
    }

    /// Two copies and there is no way to know which one was edited. A coin toss
    /// here teaches the profile from text the user never touched.
    @Test func twoCopiesOfTheSentenceMeanNoWatch() {
        #expect(InsertedSpan.anchors(inserted: sentence, in: "\(sentence) and again \(sentence)") == nil)
    }

    @Test func aSentenceLeftAloneReadsAsUnchanged() throws {
        let anchors = try #require(InsertedSpan.anchors(inserted: sentence, in: "Hi. \(sentence)"))
        #expect(InsertedSpan.verdict(for: anchors, in: "Hi. \(sentence)") == .unchanged)
    }

    /// The commonest thing that happens after a dictation: they keep it and carry
    /// on writing. Not a correction, and reading it as one would teach the tone of
    /// whatever they wrote next.
    @Test func keepingItAndWritingMoreIsNotACorrection() throws {
        let anchors = try #require(InsertedSpan.anchors(inserted: sentence, in: sentence))
        #expect(InsertedSpan.verdict(for: anchors, in: "\(sentence) and the invoice too.") == .unchanged)
    }

    @Test func anEditBetweenTheAnchorsIsTheCorrection() throws {
        let field = "Morning. \(sentence) Cheers."
        let anchors = try #require(InsertedSpan.anchors(inserted: sentence, in: field))
        let after = "Morning. Send Noah the deposit terms, please. Cheers."
        #expect(InsertedSpan.verdict(for: anchors, in: after)
                == .corrected("Send Noah the deposit terms, please."))
    }

    @Test func anEditAtTheEndOfTheFieldIsStillFound() throws {
        let anchors = try #require(InsertedSpan.anchors(inserted: sentence, in: "Morning. \(sentence)"))
        #expect(InsertedSpan.verdict(for: anchors, in: "Morning. Send Noah the deposit terms.")
                == .corrected("Send Noah the deposit terms."))
    }

    /// `⌥⌫`, or Quill mishearing entirely. Deleting a sentence is not a statement
    /// about spelling or tone.
    @Test func deletingTheSentenceTeachesNothing() throws {
        let field = "Morning. \(sentence) Cheers."
        let anchors = try #require(InsertedSpan.anchors(inserted: sentence, in: field))
        #expect(InsertedSpan.verdict(for: anchors, in: "Morning. Cheers.")
                == .notComparable(.deleted))
    }

    /// Replacing it with a different sentence is not correcting it.
    @Test func aRewriteIsRefusedRatherThanLearnedFrom() throws {
        let field = "Morning. \(sentence) Cheers."
        let anchors = try #require(InsertedSpan.anchors(inserted: sentence, in: field))
        let after = "Morning. Actually, let's talk about this on the phone tomorrow "
            + "instead, because there is a lot to go through and I would rather not "
            + "put all of it in writing. Cheers."
        #expect(InsertedSpan.verdict(for: anchors, in: after) == .notComparable(.rewritten))
    }

    @Test func losingTheSurroundingTextIsRefusedRatherThanGuessedAt() throws {
        let field = "Morning. \(sentence) Cheers."
        let anchors = try #require(InsertedSpan.anchors(inserted: sentence, in: field))
        #expect(InsertedSpan.verdict(for: anchors, in: "totally different document")
                == .notComparable(.anchorsLost))
    }
}

// MARK: - The watch itself

/// Roman: *"after i make a dictation make it watch where the text went and watch
/// what i change to adapt to what i said and what i meant to type."*
///
/// The half that was missing was not the learning — `StyleLearner` has eight
/// detectors and `StyleProfile` tallies them — it was that
/// `StyleStore.recordCorrection` **had no callers at all**. The profile could
/// only ever show its seeded defaults and "corrections seen" could only ever say
/// zero. So the assertion that matters most in here is the plain one: the profile
/// changed.
@Suite struct EditWatcherTests {

    private let sentence = "i recieve the invoice on monday"

    private func watcher(_ field: ScriptedField,
                         store: StyleStore,
                         settings: QuillSettings = isolatedSettings()) -> EditWatcher {
        EditWatcher(reader: field, store: store, settings: settings,
                    now: { Date(timeIntervalSince1970: 1_700_000_000) },
                    usesTimer: false)
    }

    @Test func aCorrectionThatHoldsStillIsLearned() throws {
        let corrected = "I receive the invoice on Monday."
        let field = ScriptedField([
            sentence,                    // begin(): where it landed
            corrected, corrected,        // two identical reads — they stopped typing
        ])
        let store = StyleStore(inMemory: .freshDefault)
        let w = watcher(field, store: store)

        #expect(store.profile.correctionCount == 0, "nothing has been learned yet")

        w.begin(inserted: sentence, pid: 1, bundleID: "com.apple.TextEdit")
        w.sample()
        w.sample()

        #expect(w.lastOutcome == .learned(from: sentence, to: corrected,
                                          bundleID: "com.apple.TextEdit"))
        // The whole point. Before this feature existed the pipeline had no caller
        // and this number could not move.
        #expect(store.profile.correctionCount == 1)
    }

    /// Someone fixing "recieve" passes through "recve" and "recei" on the way, and
    /// every one of those is a readable field value that says nothing true.
    @Test func halfTypedStatesAreNotLearnedFrom() throws {
        let field = ScriptedField([
            sentence,
            "i recve the invoice on monday",     // mid-fix
            "i recei the invoice on monday",     // still mid-fix
        ])
        let store = StyleStore(inMemory: .freshDefault)
        let w = watcher(field, store: store)
        w.begin(inserted: sentence, pid: 1, bundleID: "com.apple.TextEdit")
        w.sample()
        w.sample()

        #expect(w.lastOutcome == nil, "no conclusion while the text is still moving")
        #expect(store.profile.correctionCount == 0)
    }

    /// The measured reality: Ghostty's caret is frozen at zero, Chrome exposes an
    /// `AXGroup` with no text, VS Code exposes no focused element. Three of the
    /// four apps most dictated into cannot be read, and the feature has to say so
    /// rather than invent something.
    @Test func anAppThatWillNotSayIsReportedRatherThanGuessedAt() throws {
        let field = ScriptedField([nil])
        let store = StyleStore(inMemory: .freshDefault)
        let w = watcher(field, store: store)
        w.begin(inserted: sentence, pid: 1, bundleID: "com.mitchellh.ghostty")

        #expect(w.lastOutcome == .couldNotRead(bundleID: "com.mitchellh.ghostty"))
        #expect(store.profile.correctionCount == 0)
    }

    @Test func deletingTheSentenceStopsTheWatchWithoutLearning() throws {
        let field = ScriptedField(["Hi. \(sentence) Bye.", "Hi. Bye."])
        let store = StyleStore(inMemory: .freshDefault)
        let w = watcher(field, store: store)
        w.begin(inserted: sentence, pid: 1, bundleID: "com.apple.TextEdit")
        w.sample()

        #expect(w.lastOutcome == .ignored(.deleted))
        #expect(store.profile.correctionCount == 0)
    }

    /// Typing and then putting it back is not a correction either.
    @Test func anEditThatIsUndoneIsNotLearnedFrom() throws {
        let field = ScriptedField([
            sentence,
            "I receive the invoice on Monday.",   // edited
            sentence,                             // and reverted
            sentence,
        ])
        let store = StyleStore(inMemory: .freshDefault)
        let w = watcher(field, store: store)
        w.begin(inserted: sentence, pid: 1, bundleID: "com.apple.TextEdit")
        w.sample(); w.sample(); w.sample()

        #expect(store.profile.correctionCount == 0)
    }

    @Test func theSwitchInSettingsActuallyStopsIt() throws {
        let field = ScriptedField([sentence])
        let store = StyleStore(inMemory: .freshDefault)
        let w = watcher(field, store: store, settings: isolatedSettings(learnFromEdits: false))
        w.begin(inserted: sentence, pid: 1, bundleID: "com.apple.TextEdit")

        #expect(field.reads == 0, "switched off, it must not even read the field")
        #expect(w.lastOutcome == nil)
    }

    /// Learning off in the Style screen is a second, separate switch, and it has
    /// to win too.
    @Test func styleLearningTurnedOffAlsoStopsIt() throws {
        var profile = StyleProfile.freshDefault
        profile.isLearningEnabled = false
        let field = ScriptedField([sentence])
        let w = watcher(field, store: StyleStore(inMemory: profile))
        w.begin(inserted: sentence, pid: 1, bundleID: "com.apple.TextEdit")
        #expect(field.reads == 0)
    }

    /// The window closing is not evidence of anything. It waits.
    @Test func aFieldThatStopsAnsweringMidWatchIsNotAConclusion() throws {
        let field = ScriptedField([sentence, nil, nil])
        let store = StyleStore(inMemory: .freshDefault)
        let w = watcher(field, store: store)
        w.begin(inserted: sentence, pid: 1, bundleID: "com.apple.TextEdit")
        w.sample(); w.sample()

        #expect(w.lastOutcome == nil)
        #expect(store.profile.correctionCount == 0)
    }
}

// MARK: - Where the text went

@Test func aDictationRecordsWhichAppTheTextLandedIn() throws {
    let record = DictationRecord(
        id: UUID(), date: Date(), rawText: "hello", insertedText: "Hello.",
        wordCount: 1, inputDevice: "MacBook Air Microphone",
        destinationBundleID: "com.apple.TextEdit",
        timings: .init(timeToFirstWordMs: nil, finalToInsertedMs: nil, endToEndMs: nil,
                       audioDurationMs: nil, usedThoroughCleanup: false))

    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let round = try decoder.decode(DictationRecord.self, from: try encoder.encode(record))
    #expect(round.destinationBundleID == "com.apple.TextEdit")
}

/// Every record written before this field existed. See UpgradeSurvivalTests for
/// why that is checked at all.
@Test func aDictationFromBeforeThisFieldExistedStillLoads() throws {
    let json = #"""
    { "date": "2026-08-23T09:00:21Z", "insertedText": "Hello.", "rawText": "hello" }
    """#
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(DictationRecord.self, from: Data(json.utf8))
    #expect(record.destinationBundleID == nil)
    #expect(record.insertedText == "Hello.")
}
