import Foundation
import Testing
@testable import QuillKit

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("quill-notes-\(UUID().uuidString).json")
}

struct NoteStoreTests {

    @Test func aFreshStoreIsEmpty() {
        let store = NoteStore(url: scratch())
        #expect(store.isEmpty)
        #expect(store.all.isEmpty)
    }

    @Test func upsertAddsThenUpdatesTheSameNote() {
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = NoteStore(url: url)

        let created = store.upsert(Note(title: "Groceries", body: "Milk"))
        #expect(store.all.count == 1)

        var edited = created
        edited.body = "Milk, eggs"
        let updated = store.upsert(edited)
        #expect(store.all.count == 1, "a second upsert of the same id updated in place rather than duplicating")
        #expect(updated.body == "Milk, eggs")
    }

    @Test func upsertStampsUpdatedRegardlessOfWhatTheCallerPassedIn() {
        let store = NoteStore(url: scratch())
        let stale = Note(title: "x", body: "y", updated: Date(timeIntervalSince1970: 0))
        let saved = store.upsert(stale)
        #expect(saved.updated.timeIntervalSince1970 > 0,
                "the store's own clock decides `updated`, not whatever the caller had lying around")
    }

    @Test func removeDeletesExactlyThatNote() {
        let store = NoteStore(url: scratch())
        let a = store.upsert(Note(title: "A"))
        let b = store.upsert(Note(title: "B"))
        store.remove(id: a.id)
        #expect(store.all.map(\.id) == [b.id])
    }

    @Test func orderedIsMostRecentlyEditedFirst() {
        let store = NoteStore(url: scratch())
        let older = store.upsert(Note(title: "older"))
        // A real clock tick between the two upserts, so `updated` genuinely differs.
        Thread.sleep(forTimeInterval: 0.01)
        let newer = store.upsert(Note(title: "newer"))
        #expect(store.ordered.map(\.id) == [newer.id, older.id])
    }

    @Test func persistsAcrossInstancesOfTheSameFile() {
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = NoteStore(url: url)
        first.upsert(Note(title: "Survives a relaunch", body: "Because it went to disk"))

        let second = NoteStore(url: url)
        #expect(second.all.count == 1)
        #expect(second.all.first?.title == "Survives a relaunch")
    }

    @Test func aDamagedFileIsNotTreatedAsEmpty() throws {
        // Same rule as every other store here — see `StoreFile`'s own doc
        // comment: a file that exists but will not decode is NOT zero notes,
        // and the next write must not be allowed to overwrite it with `[]`.
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)

        let store = NoteStore(url: url)
        #expect(store.all.isEmpty, "nothing decodable, so nothing in memory")
        store.upsert(Note(title: "should not be written"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json",
                "a damaged file must never be silently overwritten")
    }

    // MARK: - Note itself

    @Test func displayTitleFallsBackToTheFirstLineOfTheBody() {
        let untitled = Note(title: "", body: "Call the vet\nabout the appointment")
        #expect(untitled.displayTitle == "Call the vet")
    }

    @Test func displayTitleIsUntitledNoteWhenThereIsNothingAtAll() {
        #expect(Note(title: "", body: "").displayTitle == "Untitled note")
    }

    @Test func displayTitlePrefersAnActualTitleOverTheBody() {
        let note = Note(title: "Groceries", body: "Milk, eggs")
        #expect(note.displayTitle == "Groceries")
    }

    @Test func isBlankIgnoresWhitespaceOnly() {
        #expect(Note(title: "  ", body: "\n \t").isBlank)
        #expect(!Note(title: "", body: "x").isBlank)
    }
}
