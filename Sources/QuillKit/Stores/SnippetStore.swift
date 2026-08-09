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
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = (try? decoder.decode([Snippet].self, from: data)) ?? []
        } else {
            items = SnippetStore.seed
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
                items[index] = snippet
            } else {
                items.append(snippet)
            }
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

    private func persist() {
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

    /// First-run contents. Real text from Roman's actual week — client quotes,
    /// deposit terms, the sign-off he types twenty times a day — because a
    /// starter set of "example one / example two" gets deleted unread.
    static var seed: [Snippet] {
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

        return [
            Snippet(phrase: "quote intro",
                    replacement: """
                    Hey — thanks for sending that through.

                    Here's how I'd approach it: one page, built by hand, live in about a week. \
                    Fixed price, no retainer, and you own everything at the end.

                    Happy to jump on a call if that's easier.
                    """,
                    useCount: 46, lastUsed: ago(3), created: ago(2_160)),

            Snippet(phrase: "deposit terms",
                    replacement: "50% to start, the rest when it goes live. The invoice comes as a PDF the same day and is due within 7 days.",
                    useCount: 61, lastUsed: ago(20), created: ago(2_880)),

            Snippet(phrase: "my email address",
                    replacement: "romangigliotti123@gmail.com",
                    useCount: 184, lastUsed: ago(27), created: ago(4_320)),

            Snippet(phrase: "studio link",
                    replacement: "https://roman-design-co.web.app",
                    useCount: 72, lastUsed: ago(49), created: ago(1_680)),

            Snippet(phrase: "sign off",
                    replacement: "Cheers,\nRoman",
                    mode: .alone,
                    useCount: 233, lastUsed: ago(51), created: ago(4_320)),

            Snippet(phrase: "booking blurb",
                    replacement: "Book a cut in about fifteen seconds — pick a barber, pick a time, and you're done. No app, no account, no phone call.",
                    useCount: 18, lastUsed: ago(96), created: ago(960)),

            Snippet(phrase: "handover note",
                    replacement: """
                    Everything's live. You've got the logins in the doc I sent, and the site \
                    deploys itself whenever you edit the content file — nothing to install.

                    Anything breaks, message me and I'll look the same day.
                    """,
                    useCount: 11, lastUsed: ago(140), created: ago(720)),

            Snippet(phrase: "standup",
                    replacement: """
                    Yesterday:
                    Today:
                    Blocked on:
                    """,
                    mode: .alone,
                    useCount: 39, lastUsed: ago(196), created: ago(1_440)),
        ]
    }

    /// A store the dashboard can render without touching disk.
    static func preview() -> SnippetStore { SnippetStore(inMemory: seed) }
}
