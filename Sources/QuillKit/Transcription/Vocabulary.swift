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
    /// `QUILL_VOCABULARY_FILE` narrows further, to an exact file rather than a
    /// directory. Everything else, including plain `QUILL_DATA_DIR`, is
    /// `QuillData.directory` — the same source `QuillData.erase()` reads, so the
    /// two can never disagree about which file is real.
    public static let defaultURL: URL = {
        if let override = ProcessInfo.processInfo.environment["QUILL_VOCABULARY_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return QuillData.directory.appendingPathComponent("vocabulary.json")
    }()

    /// Nothing. A new install has an empty Dictionary.
    ///
    /// The list started as the author's life: his suburb, his school, his
    /// family, and eleven clients by full name. It shipped in the binary, so
    /// every stranger who installed Quill got a Dictionary of people they have
    /// never met — and those people never agreed to be in it. That was replaced
    /// with sixty-odd general developer terms, which was better and still
    /// wrong: the Dictionary is not a starter kit, it is the list of words THIS
    /// person says that a general model gets wrong, and nobody can guess that
    /// from outside.
    ///
    /// It is not cosmetic either. Every term is fed to the recogniser as
    /// biasing on every dictation and is what the vocabulary corrector matches
    /// against, so a shipped list is a standing instruction to hear words the
    /// user may never say.
    ///
    /// The empty state on the Dictionary screen does the job the seed was
    /// doing: it says what the feature is for, and offers the words Quill has
    /// already misheard — harvested from real dictations, so they are guesses
    /// about THEM.
    public static let seed = Vocabulary(terms: [])

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
