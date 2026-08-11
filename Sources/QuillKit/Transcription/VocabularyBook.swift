import Foundation

/// The vocabulary, live.
///
/// `Vocabulary.load()` reads the file once. Everything that corrects a
/// transcript was built from one of those reads at launch, so a word added in
/// the Dictionary went to disk and then did nothing — not to the next dictation,
/// not to the one after that, only to the next launch of the app. The screen
/// said the word was in the dictionary and the dictionary behaved as though it
/// were not, which is the worst of the three possible outcomes: it is a silent
/// failure that looks like a success.
///
/// So reads go through here. The file's modification date is checked on access
/// and the cache is refreshed when it moves. One `stat` per dictation is free
/// against a gap measured in seconds, and it means the file stays what its own
/// documentation promises — the source of truth, editable by hand, without the
/// app needing to be told.
public final class VocabularyBook: @unchecked Sendable {

    public static let shared = VocabularyBook()

    private let url: URL
    private let lock = NSLock()
    private var cached: Vocabulary
    private var stamp: Date?

    public init(url: URL = Vocabulary.defaultURL) {
        self.url = url
        cached = Vocabulary.load(from: url)
        stamp = Self.modified(url)
    }

    /// The vocabulary as it is on disk right now.
    public var current: Vocabulary {
        lock.lock()
        defer { lock.unlock() }
        let latest = Self.modified(url)
        // Both nil (no file, still no file) counts as unchanged, so a machine
        // with no vocabulary file does not re-read on every single call.
        if latest != stamp {
            cached = Vocabulary.load(from: url)
            stamp = latest
        }
        return cached
    }

    public var terms: [String] { current.contextualStrings }

    /// Adds a term, refusing duplicates and blanks. Returns false when nothing
    /// changed, so a caller can say "already there" rather than pretending.
    @discardableResult
    public func add(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        lock.lock()
        defer { lock.unlock() }
        // Re-read before writing: the Dictionary screen and a hand edit can both
        // be in flight, and a stale in-memory copy written back would silently
        // delete whatever the other one added.
        let (loaded, damaged) = Vocabulary.loadOutcome(from: url)
        // Adding one word must never be the act that replaces the whole file
        // with the shipped seed.
        guard !damaged else { return false }
        var vocabulary = loaded
        guard !vocabulary.contextualStrings.contains(where: {
            $0.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) else { return false }

        vocabulary.terms.append(trimmed)
        guard vocabulary.save(to: url) else { return false }
        cached = vocabulary
        stamp = Self.modified(url)
        return true
    }

    @discardableResult
    public func remove(_ term: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let (loaded, damaged) = Vocabulary.loadOutcome(from: url)
        guard !damaged else { return false }
        var vocabulary = loaded
        let before = vocabulary.terms.count
        vocabulary.terms.removeAll { $0.compare(term, options: .caseInsensitive) == .orderedSame }
        guard vocabulary.terms.count != before, vocabulary.save(to: url) else { return false }
        cached = vocabulary
        stamp = Self.modified(url)
        return true
    }

    /// Deliberately `FileManager` and not `url.resourceValues`.
    ///
    /// `URL` caches resource values, so asking the same URL for its modification
    /// date returns the value from the first ask, forever. The book looked like it
    /// was checking the file on every access and was in fact checking a number it
    /// had memorised at launch — the exact bug it exists to prevent, one level
    /// down. Caught by the test that edits the file behind it.
    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
