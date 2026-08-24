import Foundation

/// A named place to dictate into that isn't any particular app — a running
/// list, a set of ideas, a draft that doesn't have a home yet. Deliberately
/// two fields and nothing else: no folders, no tags, no formatting. The ask
/// this answers is "start talking and it's saved somewhere," not a second
/// document editor living inside a dictation app.
public struct Note: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var body: String
    public var created: Date
    public var updated: Date

    public init(id: UUID = UUID(), title: String = "", body: String = "",
                created: Date = Date(), updated: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.created = created
        self.updated = updated
    }

    /// Key by key, so a field added in a future release cannot make every note
    /// written before it undecodable. See `DictationRecord.init(from:)` — the
    /// whole array is read at once, so one missing key costs the user every
    /// note they have, not one field of one note.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? created
    }

    /// What a list row shows when there's no title yet — the first line of
    /// what was actually said, same idea as a Finder icon preview.
    public var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let firstLine = body.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Untitled note" : firstLine
    }

    public var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Thread-safe, disk-backed, same shape as `SnippetStore`: queue-serialised,
/// written atomically, injectable with a URL so a test never touches the
/// real file.
public final class NoteStore: @unchecked Sendable {

    public static let defaultURL: URL = QuillData.directory.appendingPathComponent("notes.json")
    public static let shared = NoteStore()

    private let url: URL?
    private let queue = DispatchQueue(label: "com.romangigliotti.quill.notes")
    private var items: [Note] = []
    private var loadFailed = false

    /// Nothing. A new install has an empty list — see `Note`'s own doc
    /// comment for why there is nothing to seed it with.
    public init(url: URL = NoteStore.defaultURL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch StoreFile.read([Note].self, from: url, decoder: decoder) {
        case .missing:           items = []
        case .decoded(let read): items = read
        case .unreadable:
            items = []
            loadFailed = true
        }
    }

    /// Memory only — for tests and the dashboard preview renderer.
    public init(inMemory items: [Note]) {
        self.url = nil
        self.items = items
    }

    public var all: [Note] { queue.sync { items } }
    public var isEmpty: Bool { queue.sync { items.isEmpty } }

    /// Most recently edited first — the one you were just talking into is the
    /// one you want back.
    public var ordered: [Note] { all.sorted { $0.updated > $1.updated } }

    @discardableResult
    public func upsert(_ note: Note) -> Note {
        queue.sync {
            var stamped = note
            stamped.updated = Date()
            if let index = items.firstIndex(where: { $0.id == note.id }) {
                items[index] = stamped
            } else {
                items.append(stamped)
            }
            persist()
            return stamped
        }
    }

    public func remove(id: UUID) {
        queue.sync {
            items.removeAll { $0.id == id }
            persist()
        }
    }

    public func note(id: UUID) -> Note? {
        queue.sync { items.first { $0.id == id } }
    }

    private func persist() {
        guard !loadFailed, let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
