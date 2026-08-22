import Foundation

/// A spoken phrase that stands in for a block of text.
///
/// Wispr Flow keeps these in the same sqlite table as the dictionary, flagged
/// `isSnippet=1`, with the replacement stored as rich content. We keep a
/// separate file for one reason that matters: the dictionary is a *bias* — it
/// nudges what the recogniser hears and is harmless when it is wrong — while a
/// snippet is an *edit* that drops hundreds of characters into a document
/// someone is already typing in. Two things with that different a blast radius
/// should not share a table, a migration or an editor.
public struct Snippet: Codable, Sendable, Equatable, Identifiable {

    /// Where in an utterance the phrase is allowed to fire.
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Anywhere inside a sentence: "send them the deposit terms and I'll follow up".
        case anywhere
        /// Only when the phrase is the entire dictation. For triggers whose
        /// words are too ordinary to be safe mid-sentence ("sign off").
        case alone

        public var title: String {
            switch self {
            case .anywhere: return "Anywhere in a sentence"
            case .alone: return "Only on its own"
            }
        }
    }

    public let id: UUID
    /// What you say. Matched word-for-word after punctuation and case are
    /// discarded — never fuzzily. See `SnippetExpander` for why.
    public var phrase: String
    /// What gets typed. Newlines are preserved exactly as written.
    public var replacement: String
    public var mode: Mode
    public var isEnabled: Bool
    public var useCount: Int
    public var lastUsed: Date?
    public var created: Date

    public init(id: UUID = UUID(),
                phrase: String,
                replacement: String,
                mode: Mode = .anywhere,
                isEnabled: Bool = true,
                useCount: Int = 0,
                lastUsed: Date? = nil,
                created: Date = Date()) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
        self.mode = mode
        self.isEnabled = isEnabled
        self.useCount = useCount
        self.lastUsed = lastUsed
        self.created = created
    }

    /// Characters this snippet has saved: every firing typed the replacement
    /// instead of the phrase. The one honest measure of whether it earns its
    /// place in the list.
    public var charactersSaved: Int {
        useCount * max(0, replacement.count - phrase.count)
    }

    /// The replacement on one line, for a list row. A snippet whose value is
    /// three paragraphs still has to be recognisable in 40 characters.
    public var previewLine: String {
        replacement
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isBlank: Bool {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Store

/// Snippets on disk, plus the usage counters.
///
/// Same shape as `HistoryStore` on purpose — one persistence idiom in the app,
/// serialised through a queue, written atomically, and injectable with a URL so
/// a test never touches the real file.
public final class SnippetStore: @unchecked Sendable {

    public static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quill/snippets.json")
    }()

    /// The instance the dictation path uses.
    public static let shared = SnippetStore()

    private let url: URL?
    private let queue = DispatchQueue(label: "com.romangigliotti.quill.snippets")
    private var items: [Snippet] = []

    /// Disk-backed. Seeds on first run for the same reason `Vocabulary` does:
    /// an empty snippet list teaches nobody what a snippet is, and the starters
    /// here are text Roman actually retypes.
    public init(url: URL = SnippetStore.defaultURL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch StoreFile.read([Snippet].self, from: url, decoder: decoder) {
        case .missing:            items = SnippetStore.seed
        case .decoded(let read):  items = read
        case .unreadable:
            // Deliberately NOT the seed. Shipping starter snippets over the top
            // of a damaged file would look like a factory reset the user asked
            // for, and would take their own snippets with it.
            items = []
            loadFailed = true
        }
    }

    /// Memory only — for tests and for the dashboard preview renderer, neither
    /// of which may write to a real user's file.
    public init(inMemory items: [Snippet]) {
        self.url = nil
        self.items = items
    }

    public var all: [Snippet] {
        queue.sync { items }
    }

    public var isEmpty: Bool { queue.sync { items.isEmpty } }

    /// Newest-used first, then most-used, then newest. What a list of snippets
    /// should be ordered by: the one you reach for is the one at the top.
    public var ordered: [Snippet] {
        all.sorted { a, b in
            switch (a.lastUsed, b.lastUsed) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            if a.useCount != b.useCount { return a.useCount > b.useCount }
            return a.created > b.created
        }
    }

    @discardableResult
    public func upsert(_ snippet: Snippet) -> Snippet {
        queue.sync {
            if let index = items.firstIndex(where: { $0.id == snippet.id }) {
                // The editor's copy of the counters is a snapshot from whenever
                // the row was loaded, and a dictation may have fired the snippet
                // since. Writing it back whole rolls the count backwards — so the
                // editor owns the text and the store owns the counters, which is
                // what `TransformStore.upsert` already does.
                var merged = snippet
                merged.useCount = max(items[index].useCount, snippet.useCount)
                merged.lastUsed = [items[index].lastUsed, snippet.lastUsed].compactMap { $0 }.max()
                items[index] = merged
                persist()
                return merged
            }
            items.append(snippet)
            persist()
            return snippet
        }
    }

    public func remove(id: UUID) {
        queue.sync {
            items.removeAll { $0.id == id }
            persist()
        }
    }

    public func snippet(id: UUID) -> Snippet? {
        queue.sync { items.first { $0.id == id } }
    }

    /// Bumps the counters for everything that fired. Separate from `upsert` so
    /// a dictation never races an open editor into overwriting an edit.
    public func recordUses(_ ids: [UUID], at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        queue.sync {
            for id in Set(ids) {
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                items[index].useCount += ids.filter { $0 == id }.count
                items[index].lastUsed = date
            }
            persist()
        }
    }

    /// The dictation path's one entry point: expand, count what fired, return
    /// the text to insert.
    public func expand(_ text: String) -> String {
        let result = SnippetExpander().expand(text, using: all)
        guard result.didFire else { return text }
        recordUses(result.firings.map(\.id))
        return result.text
    }

    /// Every trigger phrase. Offered to the recogniser alongside the dictionary
    /// so an unusual trigger is at least *heard* — a phrase that never survives
    /// transcription can never fire.
    public var phrases: [String] {
        all.filter(\.isEnabled).map(\.phrase)
    }

    public var totalCharactersSaved: Int {
        all.reduce(0) { $0 + $1.charactersSaved }
    }

    /// See StoreFile. A snippets file that will not decode is not zero snippets.
    private var loadFailed = false

    private func persist() {
        guard !loadFailed else { return }
        guard let url else { return }
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

// MARK: - Seed

public extension SnippetStore {

    /// Nothing. A new install has no snippets.
    ///
    /// Two rounds of this. It was the author's actual week — his email address,
    /// his studio URL, his sign-off, his pricing — shipped to everybody, so the
    /// first thing any other user had to do was delete somebody else's contact
    /// details out of their own app. That was cut back to three generic
    /// examples, which was better and still the wrong shape.
    ///
    /// A snippet fires on words you SAY. Anything shipped is therefore a phrase
    /// lying in wait to expand into somebody else's text the first time you
    /// happen to say "my email" or "sign off" in a sentence — before you have
    /// read the screen that would have told you it was there. The demonstration
    /// is worth one glance; being surprised by your own keyboard is not.
    ///
    /// Kept as a property rather than deleted, because the store still has to
    /// tell `.missing` from `.unreadable`: those are different facts, and only
    /// one of them is allowed to write.
    static var seed: [Snippet] { [] }

    /// A store for the screenshot renderer and for previews — never a file.
    ///
    /// Its own list rather than `seed`, and the separation is the point — the
    /// same argument as `VocabularyFixture`. A renderer needs rows on screen to
    /// prove the layout holds; a new user needs nothing at all. Tying the two
    /// together is what made "ship no starter snippets" look like "the section
    /// no longer draws".
    static func preview() -> SnippetStore { SnippetStore(inMemory: demonstration) }

    /// Three snippets that show the three shapes one can take — a block of
    /// prose, a single line, and a template with gaps to fill.
    static var demonstration: [Snippet] {
        let now = Date()
        return [
            Snippet(phrase: "my email",
                    replacement: "you@example.com",
                    useCount: 12, lastUsed: now, created: now),
            Snippet(phrase: "sign off",
                    replacement: "Thanks,\nYour name",
                    useCount: 31, lastUsed: now, created: now),
            // `.alone` because "standup" is one ordinary word: matched anywhere
            // in a sentence it would fire on someone saying "the standup is at
            // nine" and eat their words. The trigger test below catches exactly
            // this, and caught it here.
            Snippet(phrase: "standup",
                    replacement: """
                    Yesterday:
                    Today:
                    Blocked on:
                    """,
                    mode: .alone,
                    useCount: 4, lastUsed: now, created: now),
        ]
    }
}
