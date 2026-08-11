import Foundation

/// Words the recogniser has no reason to know.
///
/// A general model has never seen "graphify" or "Craigieburn", and a dictation
/// app that mangles the nouns you use every day is worse than useless — you
/// spend longer fixing it than typing would have taken. Apple's recogniser
/// accepts contextual strings as a bias, which is why this is fed to the
/// analyzer rather than fixed up afterwards: biasing changes what the model
/// *hears*, while find-and-replace can only repair what it already got wrong,
/// and cannot recover a word it split into two.
///
/// Verified need, not speculation: the first harness run transcribed "Netlify"
/// as "neglify" with no biasing in place.
public struct Vocabulary: Codable, Sendable, Equatable {

    public var terms: [String]

    public static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quill/vocabulary.json")
    }()

    /// Seeded from the names that actually appear in Roman's dictation. Editable
    /// on disk; the file is the source of truth once it exists.
    public static let seed = Vocabulary(terms: [
        // Projects and tools
        "Quill", "graphify", "Nebula", "Vesper", "blockcraft", "murmur",
        "Firestore", "Netlify", "Supabase", "SwiftUI", "SwiftPM", "Xcode",
        "TypeScript", "Playwright", "Obsidian", "Ghostty",
        // Added after the voice corpus showed them failing in his own speech:
        // "Wispr Flow" came back "Whisperflow" and "SQLite" came back "SQ light".
        // Both are one edit from the term once spaces are dropped, so the
        // corrector repairs them the moment it knows the words exist.
        "Wispr Flow", "SQLite",
        // Business
        "nxt", "Next Fulfilment", "Roman Design Co", "Builda Bed",
        // Places and people
        "Craigieburn", "Melbourne", "Rosehill", "Noah Kass", "Carlo",
    ])

    public init(terms: [String]) {
        self.terms = terms
    }

    public static func load(from url: URL = Vocabulary.defaultURL) -> Vocabulary {
        loadOutcome(from: url).vocabulary
    }

    /// The same read, with the one bit callers need before they write.
    ///
    /// `load` cannot distinguish "no file yet" from "a file I could not read",
    /// and both returned the shipped seed. Every writer does load → mutate →
    /// save, so one unreadable byte meant the next word added to the dictionary
    /// wrote thirty stock terms over everything the user had put there.
    public static func loadOutcome(from url: URL = Vocabulary.defaultURL)
        -> (vocabulary: Vocabulary, isDamaged: Bool) {
        switch StoreFile.read(Vocabulary.self, from: url) {
        case .missing:           return (seed, false)
        case .decoded(let read): return (read, false)
        case .unreadable:        return (seed, true)
        }
    }

    @discardableResult
    public func save(to url: URL = Vocabulary.defaultURL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Multi-word entries are kept whole. The API takes phrases, and splitting
    /// "Next Fulfilment" into two tokens would bias toward the common word
    /// "next" rather than the company.
    public var contextualStrings: [String] {
        terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
