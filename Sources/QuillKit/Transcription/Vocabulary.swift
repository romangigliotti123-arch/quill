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

    /// Overridable, so a candidate dictionary can be scored against the corpus
    /// without being installed over the user's real one.
    ///
    /// Adding terms is not free: every entry is a standing chance to rewrite a
    /// word he meant, which is how "build a bed" became "Builda Bed". A change to
    /// this list has to be measured in both directions before it ships, and that
    /// is impossible if the only list the app can read is the live one.
    public static let defaultURL: URL = {
        if let override = ProcessInfo.processInfo.environment["QUILL_VOCABULARY_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quill/vocabulary.json")
    }()

    /// Seeded from the names that actually appear in Roman's dictation. Editable
    /// on disk; the file is the source of truth once it exists.
    public static let seed = Vocabulary(terms: [
        // General technical vocabulary only.
        //
        // This list used to be the author's life: his suburb, his school, his
        // family, and eleven clients by full name. It shipped in the binary, so
        // every stranger who installed Quill got a Dictionary of people they have
        // never met — and those people never agreed to be in it. A seed is a
        // guess at what ANY user says; anything narrower belongs in the file on
        // their own machine, which is what the Dictionary tab is for.
        //
        // What survives is what a general speech model reliably mishears and any
        // developer is likely to say out loud.
        "Firebase", "Firestore", "Netlify", "Supabase", "SQLite", "Postgres",
        "Redis", "Docker", "Kubernetes", "nginx", "GraphQL", "OAuth", "JWT",
        "SwiftUI", "SwiftPM", "Xcode", "TypeScript", "JavaScript", "Playwright",
        "PyTorch", "NumPy", "pandas", "pytest", "venv", "CPython", "codesign",
        "npm", "pnpm", "webpack", "Vite", "ESLint", "Prettier", "Tailwind",
        "React", "Next.js", "Node.js", "Deno", "Rust", "Kotlin", "Golang",
        "tmux", "xterm", "ssh", "sudo", "cron", "regex", "stdout", "stderr",
        "API", "CLI", "SDK", "UUID", "JSON", "YAML", "CSV", "HTTP", "HTTPS",
        "CI", "CD", "repo", "monorepo", "changelog", "hotfix", "linting",
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
