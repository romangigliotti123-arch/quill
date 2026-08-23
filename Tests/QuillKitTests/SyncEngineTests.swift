import Foundation
import Testing
@testable import QuillKit

/// Pure merge-logic tests — no network, no `AccountStore`, no `QuillData.directory`.
/// The two-device, real-Firestore path is exercised separately by
/// `QUILL_SYNC_TEST=1` in `main.swift`, matching how `AccountStore` itself was
/// proven (`QUILL_ACCOUNT_TEST=1`): these tests prove the merge is correct in
/// isolation, the manual run proves it survives an actual round trip.
struct SyncEngineTests {

    // MARK: - The generic union

    @Test func newOnEitherSideSurvives() {
        struct Item: Identifiable, Equatable { let id: Int; let tag: String }
        let local = [Item(id: 1, tag: "local-only")]
        let remote = [Item(id: 2, tag: "remote-only")]
        let merged = SyncEngine.mergeByID(local: local, remote: remote) { a, _ in a }
        #expect(Set(merged.map(\.id)) == [1, 2])
    }

    @Test func aCollisionIsDecidedByTheTiebreaker() {
        struct Item: Identifiable, Equatable { let id: Int; let score: Int }
        let local = [Item(id: 1, score: 3)]
        let remote = [Item(id: 1, score: 9)]
        let merged = SyncEngine.mergeByID(local: local, remote: remote) { a, b in
            a.score >= b.score ? a : b
        }
        #expect(merged == [Item(id: 1, score: 9)])
    }

    @Test func nothingIsEverDropped() {
        struct Item: Identifiable, Equatable { let id: Int }
        let local = (0..<20).map { Item(id: $0) }
        let remote = (10..<30).map { Item(id: $0) }
        let merged = SyncEngine.mergeByID(local: local, remote: remote) { a, _ in a }
        #expect(Set(merged.map(\.id)) == Set(0..<30))
    }

    // MARK: - History: union by id, favoring whichever side already has it

    @Test func historyMergeUnionsBothDevicesWithoutDuplicating() {
        let shared = record("shared, said on both Macs")
        let onlyOnA = record("said on Mac A only")
        let onlyOnB = record("said on Mac B only")

        let merged = SyncEngine.mergeHistory([shared, onlyOnA], [shared, onlyOnB])

        #expect(merged.count == 3)
        #expect(Set(merged.map(\.id)) == Set([shared, onlyOnA, onlyOnB].map(\.id)))
    }

    @Test func historyMergeIsOrderIndependent() {
        let a = record("a"), b = record("b"), c = record("c")
        let forward = SyncEngine.mergeHistory([a, b], [b, c])
        let backward = SyncEngine.mergeHistory([b, c], [a, b])
        #expect(Set(forward.map(\.id)) == Set(backward.map(\.id)))
    }

    private func record(_ text: String) -> DictationRecord {
        DictationRecord(
            id: UUID(), date: Date(), rawText: text, insertedText: text,
            wordCount: text.split(separator: " ").count, inputDevice: "MacBook Air Microphone",
            timings: .init(timeToFirstWordMs: 100, finalToInsertedMs: 10,
                           endToEndMs: 900, audioDurationMs: 800, usedThoroughCleanup: false))
    }

    // MARK: - Vocabulary: case-insensitive set union, matching `VocabularyBook.add()`

    @Test func vocabularyMergeUnionsWithoutCaseDuplicates() {
        let local = Vocabulary(terms: ["Craigieburn", "graphify"])
        let remote = Vocabulary(terms: ["craigieburn", "Netlify"])
        let merged = SyncEngine.mergeVocabulary(local, remote)
        #expect(merged.terms.count == 3)
        #expect(merged.terms.contains("Craigieburn"))
        #expect(merged.terms.contains("graphify"))
        #expect(merged.terms.contains("Netlify"))
    }

    @Test func vocabularyMergeKeepsLocalCasingOnACollision() {
        let local = Vocabulary(terms: ["Craigieburn"])
        let remote = Vocabulary(terms: ["craigieburn"])
        let merged = SyncEngine.mergeVocabulary(local, remote)
        #expect(merged.terms == ["Craigieburn"])
    }

    @Test func vocabularyMergeWithAnEmptySideReturnsTheOther() {
        let local = Vocabulary(terms: [])
        let remote = Vocabulary(terms: ["Netlify"])
        #expect(SyncEngine.mergeVocabulary(local, remote).terms == ["Netlify"])
        #expect(SyncEngine.mergeVocabulary(remote, local).terms == ["Netlify"])
    }

    // MARK: - AI key: a scalar, not a collection

    @Test func apiKeyMergeKeepsLocalWhenBothAreSet() {
        #expect(SyncEngine.mergeAPIKey("local-key", "remote-key") == "local-key")
    }

    // MARK: - Snippets: the Identifiable overload, with the real type

    @Test func snippetMergeKeepsTheHigherUseCountOnACollision() {
        let id = UUID()
        let local = Snippet(id: id, phrase: "sig", replacement: "Roman", useCount: 2)
        let remote = Snippet(id: id, phrase: "sig", replacement: "Roman", useCount: 40)
        let merged = SyncEngine.mergeByID(local: [local], remote: [remote]) { a, b in
            a.useCount >= b.useCount ? a : b
        }
        #expect(merged.count == 1)
        #expect(merged[0].useCount == 40)
    }

    @Test func snippetMergeUnionsDistinctSnippets() {
        let local = [Snippet(phrase: "sig", replacement: "Roman")]
        let remote = [Snippet(phrase: "addr", replacement: "123 Main St")]
        let merged = SyncEngine.mergeByID(local: local, remote: remote) { a, b in
            a.useCount >= b.useCount ? a : b
        }
        #expect(merged.count == 2)
    }

    // MARK: - Style: the full profile merge, exercised as SyncEngine will call it

    @Test func styleMergeCombinesLearnedTraitsFromBothDevices() {
        var local = StyleProfile.freshDefault
        var remote = StyleProfile.freshDefault
        local.correctionCount = 5
        remote.correctionCount = 7
        let merged = local.merged(with: remote)
        #expect(merged.correctionCount == 12)
    }
}
