import Foundation

/// Scratchpad notes. Flow calls this "for quick thoughts you want to come back to";
/// the useful part is that dictation has somewhere to go that is not another app's
/// text field, so a thought can be captured without choosing a destination first.
public struct Note: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var body: String
    public var created: Date
    public var modified: Date
    public var isPinned: Bool

    public init(id: UUID = UUID(), title: String = "", body: String = "",
                created: Date = Date(), modified: Date = Date(), isPinned: Bool = false) {
        self.id = id; self.title = title; self.body = body
        self.created = created; self.modified = modified; self.isPinned = isPinned
    }

    /// Flow shows "Untitled" forever. A note dictated in one breath has no title,
    /// so the first line becomes one — the user should not have to name a thought
    /// before they are allowed to have it.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Untitled" }
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }

    public var wordCount: Int {
        body.split(whereSeparator: { $0.isWhitespace }).count
    }
}

public final class NoteStore: @unchecked Sendable {
    public static let defaultURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quill/notes.json")
    }()

    private let url: URL
    private let lock = NSLock()
    private var notes: [Note]

    public static let shared = NoteStore()

    /// Tests pass their own URL. A self-test that writes to the real notes file is
    /// a bug, not a shortcut.
    public init(url: URL = NoteStore.defaultURL) {
        self.url = url
        switch StoreFile.read([Note].self, from: url, decoder: .quill) {
        case .missing:            notes = []
        case .decoded(let read):  notes = read
        case .unreadable:
            // NOT an empty notebook. See StoreFile.
            notes = []
            loadFailed = true
        }
    }

    public init(inMemory: [Note]) {
        self.url = URL(fileURLWithPath: "/dev/null")
        self.notes = inMemory
    }

    /// Pinned first, then most recently modified.
    public var all: [Note] {
        lock.lock(); defer { lock.unlock() }
        return notes.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.modified > $1.modified
        }
    }

    public func upsert(_ note: Note) {
        lock.lock()
        var updated = note
        updated.modified = Date()
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = updated }
        else { notes.append(updated) }
        persistLocked()
        lock.unlock()
    }

    public func delete(_ id: UUID) {
        lock.lock()
        notes.removeAll { $0.id == id }
        persistLocked()
        lock.unlock()
    }

    /// Set when the file exists and could not be read. While it is true nothing
    /// is written, because the alternative is replacing notes that are probably
    /// still recoverable with the empty list we fell back to.
    private var loadFailed = false

    private func persistLocked() {
        guard !loadFailed else { return }
        guard url.path != "/dev/null" else { return }
        guard let data = try? JSONEncoder.quill.encode(notes) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Atomic: a half-written notes file read mid-save loses the lot.
        try? data.write(to: url, options: .atomic)
    }

    public static func preview() -> NoteStore {
        NoteStore(inMemory: [
            Note(title: "", body: "Ask Carlo whether the reversible bedheads need a different rail for the king size, and whether Warwick railroaded cloth comes in the same width.",
                 modified: Date().addingTimeInterval(-3600), isPinned: true),
            Note(title: "nxt onboarding", body: "Stage 2 form still lets a client submit without a business name. Add the check before the Firestore write, not after.",
                 modified: Date().addingTimeInterval(-86400)),
            Note(title: "", body: "Idea: let a dictation start a note when nothing is focused, instead of dropping the text on the floor.",
                 modified: Date().addingTimeInterval(-172800)),
        ])
    }
}

extension JSONEncoder {
    static var quill: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var quill: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
