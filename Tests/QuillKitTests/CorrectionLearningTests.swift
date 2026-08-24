import Foundation
import Testing
@testable import QuillKit

/// Roman: *"make the model train itself by the dictations I make so the longer I
/// use it, the more dictations I make, the smarter it gets."*
///
/// Three measurements first, because a transcript on its own turns out to teach
/// almost nothing. Across his 85 real dictations:
///
///   - harvesting unknown words proposed **one** term, and it was his own
///     pronunciation rather than a word the recogniser had missed;
///   - retraction cues found **two** genuine self-corrections, both already
///     handled, while the cue words themselves ("actually", "I mean") were
///     ordinary speech five times out of seven;
///   - repeated phrases worth a snippet: **four**, all connectives like "and
///     then they can".
///
/// A transcript records what the recogniser did. It cannot say what was wrong
/// with it. Only the user can, and the only moment they do is a correction — so
/// that moment has to be worth as much as possible, and it has to be capturable
/// for every dictation rather than only the ones that landed somewhere readable.
@Suite struct CorrectionLearningTests {

    /// English words are not Dictionary candidates however wrong they were.
    @Test func onlyWordsNoDictionaryKnowsAreProposed() {
        let english: Set<String> = ["send", "the", "invoice", "to", "tomorrow", "receive"]
        let out = CorrectionLearning.learn(
            was: "send the invoice to Netterfly tomorrow",
            now: "send the invoice to Netlify tomorrow",
            existingTerms: [],
            isKnownWord: { english.contains($0.lowercased()) })
        #expect(out.dictionaryCandidates == ["Netlify"])
    }

    /// A word already in the Dictionary is not offered again — it is already
    /// biasing the recogniser and the correction was about something else.
    @Test func aTermAlreadyInTheDictionaryIsNotProposedTwice() {
        let out = CorrectionLearning.learn(
            was: "push it to Netterfly", now: "push it to Netlify",
            existingTerms: ["Netlify", "graphify"],
            isKnownWord: { _ in false })
        #expect(out.dictionaryCandidates.isEmpty)
    }

    /// Only what the correction introduced. A word that was already there is not
    /// what the user was fixing, and proposing it wastes the one question the
    /// app gets to ask.
    @Test func wordsThatWereAlreadyThereAreNotProposed() {
        let out = CorrectionLearning.learn(
            was: "the graphify workspace is slow",
            now: "the graphify workspace is fast",
            existingTerms: [],
            isKnownWord: { $0.lowercased() != "graphify" })
        #expect(out.dictionaryCandidates.isEmpty)
    }

    @Test func punctuationAndShortFragmentsAreNotWords() {
        let out = CorrectionLearning.learn(
            was: "it broke", now: "it broke — MCP, v2, and 3 others",
            existingTerms: [], isKnownWord: { _ in false })
        // "MCP" is three letters and unknown, so it stays; "v2" and "3" are not.
        #expect(out.dictionaryCandidates == ["MCP", "and", "others"])
    }

    // MARK: - The store side

    private func scratchHistory() -> (HistoryStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quill-corr-\(UUID().uuidString)/history.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (HistoryStore(url: url, cutoff: { nil }), url)
    }

    private func record(_ text: String) -> DictationRecord {
        DictationRecord(id: UUID(), date: Date(), rawText: text, insertedText: text,
                        wordCount: text.split(separator: " ").count, inputDevice: nil,
                        timings: .init(timeToFirstWordMs: nil, finalToInsertedMs: nil,
                                       endToEndMs: nil, audioDurationMs: nil,
                                       usedThoroughCleanup: false))
    }

    @Test func correctingADictationKeepsBothVersions() throws {
        let (store, url) = scratchHistory()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let r = record("push it to Netterfly")
        store.append(r)

        let pair = try #require(store.correct(id: r.id, to: "push it to Netlify"))
        #expect(pair.was == "push it to Netterfly")
        #expect(pair.now == "push it to Netlify")

        let saved = try #require(store.all.first { $0.id == r.id })
        #expect(saved.correctedText == "push it to Netlify")
        // The original survives. It is half the evidence, and a diff against an
        // edited version is a diff against the wrong thing.
        #expect(saved.insertedText == "push it to Netterfly")
        #expect(saved.rawText == "push it to Netterfly")
    }

    @Test func correctingTwiceComparesAgainstTheLastCorrection() throws {
        let (store, url) = scratchHistory()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let r = record("one")
        store.append(r)
        _ = store.correct(id: r.id, to: "two")
        let second = try #require(store.correct(id: r.id, to: "three"))
        #expect(second.was == "two", "the second correction is a correction of the first")
    }

    @Test func aCorrectionThatChangesNothingTeachesNothing() throws {
        let (store, url) = scratchHistory()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let r = record("leave it alone")
        store.append(r)
        #expect(store.correct(id: r.id, to: "leave it alone") == nil)
        #expect(store.correct(id: r.id, to: "   ") == nil)
    }

    /// The whole point, end to end: correcting a dictation moves the profile.
    /// Before `EditWatcher` and this, `recordCorrection` had no callers at all
    /// and the Style screen could only ever report zero.
    @Test func aCorrectionMovesTheStyleProfile() throws {
        let (store, url) = scratchHistory()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let style = StyleStore(inMemory: .freshDefault)
        let r = record("I realize the color is wrong")
        store.append(r)

        #expect(style.profile.correctionCount == 0)
        let pair = try #require(store.correct(id: r.id, to: "I realise the colour is wrong"))
        _ = style.recordCorrection(dictated: pair.was, edited: pair.now)
        #expect(style.profile.correctionCount == 1)
        #expect(style.profile.spelling.value == .british, "two British spellings in one correction")
    }
}
