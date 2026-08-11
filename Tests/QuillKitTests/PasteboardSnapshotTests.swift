import AppKit
import Testing
@testable import QuillKit

// A private pasteboard per test. Never `.general` — a test run has no business
// eating whatever the developer had on their clipboard.
private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.romangigliotti.quill.tests.\(UUID().uuidString)"))
}

// MARK: - Snapshot / restore

@Test func snapshotSurvivesTheClearThatInvalidatesLiveItems() {
    let board = scratchPasteboard()
    defer { board.releaseGlobally() }

    board.declareTypes([.string], owner: nil)
    board.setString("the user's own clipboard", forType: .string)

    let snapshot = PasteboardSnapshot.capture(from: board)
    board.clearContents()
    board.setString("Quill's dictated text", forType: .string)
    snapshot.restore(to: board)

    #expect(board.string(forType: .string) == "the user's own clipboard")
}

@Test func snapshotKeepsEveryFlavourNotJustPlainText() {
    let board = scratchPasteboard()
    defer { board.releaseGlobally() }

    let rich = NSPasteboardItem()
    rich.setData(Data("plain".utf8), forType: .string)
    rich.setData(Data("<b>rich</b>".utf8), forType: .html)
    board.clearContents()
    board.writeObjects([rich])

    let snapshot = PasteboardSnapshot.capture(from: board)

    #expect(snapshot.items.count == 1)
    #expect(snapshot.items[0][NSPasteboard.PasteboardType.string.rawValue] == Data("plain".utf8))
    #expect(snapshot.items[0][NSPasteboard.PasteboardType.html.rawValue] == Data("<b>rich</b>".utf8))
}

@Test func restoringAnEmptyClipboardLeavesItEmpty() {
    let board = scratchPasteboard()
    defer { board.releaseGlobally() }

    board.clearContents()
    let snapshot = PasteboardSnapshot.capture(from: board)
    #expect(snapshot.isEmpty)

    board.setString("something Quill put there", forType: .string)
    #expect(snapshot.restore(to: board) == false)
    #expect(board.string(forType: .string) == nil)
}

@Test func detachedItemsAreIndependentOfEachOther() {
    let items = PasteboardSnapshot.detach([
        ["public.utf8-plain-text": Data("one".utf8)],
        [:],
        ["public.utf8-plain-text": Data("two".utf8)],
    ])
    // The empty entry is dropped: an item with no types cannot be written and
    // makes writeObjects fail for the whole batch.
    #expect(items.count == 2)
    #expect(items[0].string(forType: .string) == "one")
    #expect(items[1].string(forType: .string) == "two")
}

@Test func aSnapshotThatMissedAnItemRefusesToCallItselfFaithful() {
    let complete = PasteboardSnapshot(
        items: [["public.utf8-plain-text": Data("one".utf8)]],
        sourceItemCount: 1,
        changeCount: 3
    )
    #expect(complete.isFaithful)

    // One item on the pasteboard whose every flavour was an unfulfilled promise.
    // Restoring this would clear a clipboard that had something in it.
    let lossy = PasteboardSnapshot(items: [[:]], sourceItemCount: 1, changeCount: 3)
    #expect(!lossy.isFaithful)
}

// MARK: - The restore race

@Test func restoreIsRefusedWhenSomeoneElseWroteFirst() {
    #expect(PasteboardSnapshot.restoreIsSafe(ourChangeCount: 12, currentChangeCount: 12))
    #expect(!PasteboardSnapshot.restoreIsSafe(ourChangeCount: 12, currentChangeCount: 13))
}

@Test func writeReportsTheChangeCountItClaimed() {
    let board = scratchPasteboard()
    defer { board.releaseGlobally() }

    let count = PasteboardSnapshot.write("dictated", to: board, transient: true)
    #expect(count == board.changeCount)
    #expect(board.string(forType: .string) == "dictated")
    // Marked transient so clipboard managers do not record a sentence that was
    // only ever passing through on its way to the focused app.
    #expect(board.data(forType: PasteboardSnapshot.transientType) != nil)
    #expect(PasteboardSnapshot.restoreIsSafe(ourChangeCount: count ?? -1,
                                             currentChangeCount: board.changeCount))
}

// MARK: - Typing fallback chunking

@Test func chunksReassembleIntoTheOriginalText() {
    let text = "Roman, the quick brown fox jumps over the lazy dog — twice."
    let rebuilt = SyntheticKeyboard.chunks(of: text)
        .map { String(utf16CodeUnits: $0, count: $0.count) }
        .joined()
    #expect(rebuilt == text)
}

@Test func chunkingNeverSplitsASurrogatePairOrEmojiSequence() {
    // Each of these is one grapheme cluster made of several UTF-16 units; split
    // across two events they type as their separate pieces.
    let text = String(repeating: "👨‍👩‍👧‍👦", count: 4) + "🇦🇺"
    for chunk in SyntheticKeyboard.chunks(of: text) {
        let decoded = String(utf16CodeUnits: chunk, count: chunk.count)
        #expect(!decoded.unicodeScalars.contains { $0.value == 0xFFFD })
        #expect(decoded.utf16.count == chunk.count)
    }
    let rebuilt = SyntheticKeyboard.chunks(of: text)
        .map { String(utf16CodeUnits: $0, count: $0.count) }
        .joined()
    #expect(rebuilt == text)
}

@Test func chunksStayUnderTheLimitUnlessOneClusterExceedsIt() {
    let plain = SyntheticKeyboard.chunks(of: String(repeating: "a", count: 100), limit: 16)
    #expect(plain.allSatisfy { $0.count <= 16 })
    #expect(plain.count == 7)

    // A cluster longer than the limit gets its own oversized chunk rather than
    // being cut in half.
    let family = SyntheticKeyboard.chunks(of: "👨‍👩‍👧‍👦", limit: 4)
    #expect(family.count == 1)
    #expect(family[0].count > 4)
}

@Test func chunkingEmptyTextProducesNothingToPost() {
    #expect(SyntheticKeyboard.chunks(of: "").isEmpty)
}

// MARK: - A damaged file is not an empty one

@Test func aStoreRefusesToOverwriteAFileItCouldNotRead() throws {
    // Every store in this app made the same mistake, and HistoryStore had already
    // been fixed for it in isolation, which is exactly how the other three
    // survived: a file that exists but will not decode was read as an empty
    // collection, and the next edit atomically wrote [] over the top. One partial
    // write during a crash and every note, snippet and dictionary word is gone,
    // silently, at the moment the user next touched anything.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Notes
    let notesURL = dir.appendingPathComponent("notes.json")
    try Data("{ this is not json".utf8).write(to: notesURL)
    let notes = NoteStore(url: notesURL)
    notes.upsert(Note(title: "new", body: "written after the damage"))
    let notesOnDisk = try String(contentsOf: notesURL, encoding: .utf8)
    #expect(notesOnDisk == "{ this is not json", "overwrote a damaged notes file")

    // Snippets
    let snippetsURL = dir.appendingPathComponent("snippets.json")
    try Data("[[[".utf8).write(to: snippetsURL)
    let snippets = SnippetStore(url: snippetsURL)
    snippets.upsert(Snippet(phrase: "brb", replacement: "be right back"))
    #expect(try String(contentsOf: snippetsURL, encoding: .utf8) == "[[[",
            "overwrote a damaged snippets file")

    // Vocabulary — the one where the fallback is not empty but the shipped seed,
    // so the damage would look like a factory reset rather than a deletion.
    let vocabURL = dir.appendingPathComponent("vocabulary.json")
    try Data("{\"terms\": ".utf8).write(to: vocabURL)
    let book = VocabularyBook(url: vocabURL)
    #expect(book.add("Craigieburn") == false, "wrote a term into a damaged file")
    #expect(try String(contentsOf: vocabURL, encoding: .utf8) == "{\"terms\": ",
            "overwrote a damaged vocabulary file")

    // And a copy of what could not be read is kept, every time.
    let salvaged = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.contains("unreadable") }
    #expect(salvaged.count == 3, "kept \(salvaged.count) salvage copies, expected 3")
}

@Test func anAbsentFileIsStillJustAnAbsentFile() throws {
    // The guard must not fire on a fresh install, or nothing is ever saved at all.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let vocabURL = dir.appendingPathComponent("vocabulary.json")
    let book = VocabularyBook(url: vocabURL)
    // Not a seed term — a missing file correctly falls back to the seed, so
    // adding something already in it is a no-op and would prove nothing.
    #expect(book.add("Wollongong"))
    #expect(book.terms.contains("Wollongong"))

    let notesURL = dir.appendingPathComponent("notes.json")
    let notes = NoteStore(url: notesURL)
    notes.upsert(Note(title: "first", body: "on a fresh install"))
    #expect(FileManager.default.fileExists(atPath: notesURL.path))
}
