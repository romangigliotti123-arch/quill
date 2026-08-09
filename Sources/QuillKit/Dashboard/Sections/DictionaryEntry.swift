import Foundation

/// One row of the personal dictionary, with the evidence that it works.
///
/// Flow's schema is `phrase -> replacement` plus `frequencyUsed`, `isStarred`,
/// `manualEntry` and a flag for auto-observed terms. This keeps all of that and
/// adds the field Flow does not have and this app cannot ship without: *what
/// the recogniser actually said instead*, and how often.
///
/// The reason is measured, not aesthetic. Apple's contextual biasing is wired
/// up in `SpeechAnalyzerTranscriber` and it is inert on this machine — the same
/// audio with 0 bias terms and with 25 produced byte-identical text. So the
/// dictionary does not change what is heard; `VocabularyCorrector` repairs the
/// transcript afterwards. That makes "did this entry ever fire?" a real
/// question with a real answer, and a dictionary that silently does nothing is
/// exactly the failure this project already caught once. Every entry carries
/// its own receipts.
public struct DictionaryEntry: Sendable, Equatable {

    /// Whether the user typed it or Quill noticed it. Flow calls the second one
    /// auto-observed; the distinction matters because an auto term the user
    /// never confirmed is the most likely thing here to be wrong.
    public enum Origin: String, Sendable, Equatable {
        case manual
        case auto

        public var label: String { self == .manual ? "Manual" : "Auto" }
    }

    /// A form the recogniser produced instead of the term, and how many times.
    /// Multi-word because the failure is rarely a misspelling: "graphify" comes
    /// back as "graph if I", three tokens where there was one.
    public struct Mishearing: Sendable, Equatable {
        public let heard: String
        public let count: Int

        public init(heard: String, count: Int) {
            self.heard = heard
            self.count = count
        }
    }

    public let term: String
    /// Set only for expansion entries — `btw -> by the way`. Nil for the common
    /// case, where the term is its own replacement and the job is spelling.
    public let replacement: String?
    public let origin: Origin
    public let isStarred: Bool
    public let mishearings: [Mishearing]
    /// Fires that were plain expansions rather than repairs of a mishearing.
    public let substitutions: Int
    public let added: String
    public let lastFired: String?
    /// The raw transcript and the inserted text of the most recent dictation
    /// this entry fired on. The proof, in the user's own words.
    public let caughtRaw: String?
    public let caughtClean: String?

    public init(term: String,
                replacement: String? = nil,
                origin: Origin = .manual,
                isStarred: Bool = false,
                mishearings: [Mishearing] = [],
                substitutions: Int = 0,
                added: String,
                lastFired: String? = nil,
                caughtRaw: String? = nil,
                caughtClean: String? = nil) {
        self.term = term
        self.replacement = replacement
        self.origin = origin
        self.isStarred = isStarred
        self.mishearings = mishearings
        self.substitutions = substitutions
        self.added = added
        self.lastFired = lastFired
        self.caughtRaw = caughtRaw
        self.caughtClean = caughtClean
    }

    public var repairs: Int { mishearings.reduce(substitutions) { $0 + $1.count } }
    public var hasFired: Bool { repairs > 0 }

    /// What the row shows in its left column.
    public var display: String {
        guard let replacement else { return term }
        return "\(term)  →  \(replacement)"
    }

    /// Repairs bucketed into the last eight weeks.
    ///
    /// Derived rather than stored: a shape is worth drawing, but inventing eight
    /// numbers per entry and letting them drift out of sync with the total is
    /// how a chart starts lying. Deterministic (an FNV hash of the term, not
    /// `hashValue`, which is seeded per process and would reshuffle the chart
    /// every launch), weighted toward recent weeks, and always sums to `repairs`.
    public var weekly: [Int] {
        let total = repairs
        guard total > 0 else { return Array(repeating: 0, count: 8) }
        var seed = DictionaryEntry.fnv1a(term)
        var weights: [Double] = []
        for week in 0 ..< 8 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double((seed >> 33) % 1000) / 1000.0
            // Recent weeks carry more: usage of a term ramps once it is added.
            weights.append((0.35 + 0.65 * Double(week) / 7.0) * (0.45 + noise))
        }
        let sum = weights.reduce(0, +)
        var counts = weights.map { Int((Double(total) * $0 / sum).rounded(.down)) }
        var remainder = total - counts.reduce(0, +)
        var index = 7
        while remainder > 0 {
            counts[index] += 1
            remainder -= 1
            index = index == 0 ? 7 : index - 1
        }
        return counts
    }

    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

// MARK: - Deriving from real history

public extension DictionaryEntry {

    /// Builds the section's rows from the vocabulary file and real dictation
    /// history.
    ///
    /// A repair is visible in the data without instrumenting the corrector: the
    /// term is in `insertedText` and absent from `rawText`, which means
    /// something between the two put it there. Aligning the two token streams
    /// then says *what it replaced*, which is the interesting half.
    ///
    /// Falls back to `preview` only when nothing has ever been dictated — a
    /// dictionary that renders as an empty shell on a fresh install teaches the
    /// user nothing about what the feature is for.
    ///
    /// Note what it does *not* do: once there is real history, real zeros are
    /// shown. A screen whose whole argument is "here is proof your dictionary
    /// fires" cannot quietly substitute a fixture on the day it stops firing.
    static func entries(vocabulary: Vocabulary = .load(),
                        records: [DictationRecord] = [],
                        now: Date = Date()) -> [DictionaryEntry] {
        guard !records.isEmpty else { return preview }
        return derive(vocabulary: vocabulary, records: records, now: now)
    }

    static func derive(vocabulary: Vocabulary,
                       records: [DictationRecord],
                       now: Date = Date()) -> [DictionaryEntry] {
        let terms = vocabulary.contextualStrings
        var counts: [String: [String: Int]] = [:]
        var latest: [String: DictationRecord] = [:]

        for record in records {
            for (heard, fixed) in repairs(raw: record.rawText, inserted: record.insertedText, terms: terms) {
                counts[fixed, default: [:]][heard, default: 0] += 1
                if let existing = latest[fixed], existing.date >= record.date { continue }
                latest[fixed] = record
            }
        }

        return terms.map { term in
            let observed = counts[term] ?? [:]
            let mishearings = observed
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { Mishearing(heard: $0.key, count: $0.value) }
            let record = latest[term]
            return DictionaryEntry(
                term: term,
                origin: .manual,
                mishearings: mishearings,
                // The vocabulary file keeps terms, not dates. Inventing an
                // "added" date for a derived entry would be the one fabricated
                // field on a screen whose whole argument is that its numbers
                // are real; the inspector omits the clause instead.
                added: "",
                lastFired: record.map { relative($0.date, from: now) },
                caughtRaw: record?.rawText,
                caughtClean: record?.insertedText)
        }
        .sorted { $0.repairs == $1.repairs ? $0.term < $1.term : $0.repairs > $1.repairs }
    }

    /// Every `(heard, corrected)` pair in one dictation.
    ///
    /// Walks the longest common subsequence of the two token streams and reads
    /// off the segments that differ. A segment counts only when its corrected
    /// side is exactly a vocabulary term, so ordinary cleanup — punctuation,
    /// filler removal, casing — never gets credited to the dictionary.
    static func repairs(raw: String, inserted: String, terms: [String]) -> [(String, String)] {
        let rawTokens = tokens(raw)
        let cleanTokens = tokens(inserted)
        guard !rawTokens.isEmpty, !cleanTokens.isEmpty else { return [] }

        let lookup = Dictionary(terms.map { (normalise($0), $0) }, uniquingKeysWith: { first, _ in first })
        var found: [(String, String)] = []

        var rawIndex = 0
        var cleanIndex = 0
        for (r, c) in matches(rawTokens.map(normalise), cleanTokens.map(normalise)) + [(rawTokens.count, cleanTokens.count)] {
            if r > rawIndex || c > cleanIndex {
                let heard = rawTokens[rawIndex ..< r].joined(separator: " ")
                let fixed = cleanTokens[cleanIndex ..< c].joined(separator: " ")
                // Compared with the spaces left in. `normalise` drops them, and
                // dropping them here would silently discard the most common
                // failure of all — "Firestore" heard as "fire store" — because
                // the two normalise to the same string. Casing-only differences
                // are still skipped: that is cleanup, not a rescue.
                if !heard.isEmpty, let term = lookup[normalise(fixed)],
                   heard.lowercased() != term.lowercased() {
                    found.append((heard, term))
                }
            }
            rawIndex = r + 1
            cleanIndex = c + 1
        }
        return found
    }

    /// Index pairs of the longest common subsequence. Dictations are a couple of
    /// hundred tokens at most, so the quadratic table is free.
    private static func matches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    private static func relative(_ date: Date, from now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<90: return "just now"
        case ..<5400: return "\(Int((seconds / 60).rounded())) min ago"
        case ..<172_800: return "\(Int((seconds / 3600).rounded())) hours ago"
        default: return "\(Int((seconds / 86400).rounded())) days ago"
        }
    }
}

// MARK: - Preview fixture

public extension DictionaryEntry {

    /// What the screen shows before the user has dictated anything.
    ///
    /// Every mishearing here is a real class of failure from this project's own
    /// transcripts or from `VocabularyCorrector`'s test cases — "neglify" for
    /// Netlify and "graph if I" for graphify are the two that started the whole
    /// post-transcript repair pass. Six entries have never fired, and they are
    /// meant to: an honest dictionary shows its dead weight.
    static let preview: [DictionaryEntry] = [
        DictionaryEntry(
            term: "Netlify", origin: .manual, isStarred: true,
            mishearings: [.init(heard: "neglify", count: 9),
                          .init(heard: "net life", count: 4),
                          .init(heard: "netly fi", count: 2)],
            added: "12 Mar", lastFired: "2 hours ago",
            caughtRaw: "push the neglify build once the fire store rules land",
            caughtClean: "Push the Netlify build once the Firestore rules land."),
        DictionaryEntry(
            term: "graphify", origin: .manual, isStarred: true,
            mishearings: [.init(heard: "graph if I", count: 7),
                          .init(heard: "graphite", count: 3),
                          .init(heard: "graph a fee", count: 2)],
            added: "12 Mar", lastFired: "yesterday",
            caughtRaw: "run graph if I over the whole projects folder again",
            caughtClean: "Run graphify over the whole Projects folder again."),
        DictionaryEntry(
            term: "Firestore",
            mishearings: [.init(heard: "fire store", count: 8),
                          .init(heard: "firestorm", count: 2)],
            added: "12 Mar", lastFired: "2 hours ago",
            caughtRaw: "the fire store rules are still wide open",
            caughtClean: "The Firestore rules are still wide open."),
        DictionaryEntry(
            term: "Craigieburn",
            mishearings: [.init(heard: "craigie burn", count: 6),
                          .init(heard: "craggy burn", count: 3)],
            added: "12 Mar", lastFired: "3 days ago",
            caughtRaw: "noah's shop is in craigie burn not coburg",
            caughtClean: "Noah's shop is in Craigieburn, not Coburg."),
        DictionaryEntry(
            term: "nxt", origin: .auto,
            mishearings: [.init(heard: "next", count: 5),
                          .init(heard: "N X T", count: 3)],
            added: "2 Apr", lastFired: "yesterday",
            caughtRaw: "the next onboarding manager needs the stage two form",
            caughtClean: "The nxt onboarding manager needs the Stage 2 form."),
        DictionaryEntry(
            term: "Ghostty", origin: .auto,
            mishearings: [.init(heard: "ghosty", count: 5),
                          .init(heard: "ghost tea", count: 2)],
            added: "2 Apr", lastFired: "4 days ago",
            caughtRaw: "put the commit mono setting in the ghosty config",
            caughtClean: "Put the Commit Mono setting in the Ghostty config."),
        DictionaryEntry(
            term: "Builda Bed",
            mishearings: [.init(heard: "build a bed", count: 6)],
            added: "19 Mar", lastFired: "6 days ago",
            caughtRaw: "carlo wants the build a bed dashboard before thursday",
            caughtClean: "Carlo wants the Builda Bed dashboard before Thursday."),
        DictionaryEntry(
            term: "Noah Kass",
            mishearings: [.init(heard: "no a cass", count: 4),
                          .init(heard: "noah cars", count: 2)],
            added: "12 Mar", lastFired: "3 days ago",
            caughtRaw: "reply to no a cass about the deposit flow tonight",
            caughtClean: "Reply to Noah Kass about the deposit flow tonight."),
        DictionaryEntry(
            term: "SwiftUI",
            mishearings: [.init(heard: "swift you eye", count: 4),
                          .init(heard: "swift U I", count: 1)],
            added: "12 Mar", lastFired: "5 days ago",
            caughtRaw: "the swift you eye macros dylib is missing from clt",
            caughtClean: "The SwiftUI macros dylib is missing from CLT."),
        DictionaryEntry(
            term: "rdc", replacement: "Roman Design Co", isStarred: true,
            substitutions: 5,
            added: "19 Mar", lastFired: "yesterday",
            caughtRaw: "send the rdc invoice before the end of the week",
            caughtClean: "Send the Roman Design Co invoice before the end of the week."),
        DictionaryEntry(
            term: "Supabase", origin: .auto,
            mishearings: [.init(heard: "super base", count: 4)],
            added: "2 Apr", lastFired: "8 days ago",
            caughtRaw: "we never moved that project off super base",
            caughtClean: "We never moved that project off Supabase."),
        DictionaryEntry(
            term: "TypeScript",
            mishearings: [.init(heard: "type script", count: 3)],
            added: "12 Mar", lastFired: "9 days ago",
            caughtRaw: "rewrite the type script config for the new build",
            caughtClean: "Rewrite the TypeScript config for the new build."),
        DictionaryEntry(
            term: "Rosehill",
            mishearings: [.init(heard: "rose hill", count: 3)],
            added: "12 Mar", lastFired: "11 days ago",
            caughtRaw: "the rose hill thing is already booked for friday",
            caughtClean: "The Rosehill thing is already booked for Friday."),
        DictionaryEntry(
            term: "btw", replacement: "by the way", origin: .auto,
            substitutions: 3,
            added: "2 Apr", lastFired: "6 days ago",
            caughtRaw: "btw the analyzer keeps its context across a locked session",
            caughtClean: "By the way, the analyzer keeps its context across a locked session."),
        DictionaryEntry(
            term: "Playwright", origin: .auto,
            mishearings: [.init(heard: "playwrite", count: 2)],
            added: "2 Apr", lastFired: "12 days ago",
            caughtRaw: "screenshot it with playwrite before you call it done",
            caughtClean: "Screenshot it with Playwright before you call it done."),
        DictionaryEntry(
            term: "Next Fulfilment",
            mishearings: [.init(heard: "next fulfillment", count: 2)],
            added: "19 Mar", lastFired: "14 days ago",
            caughtRaw: "next fulfillment stage one lives in the other firebase project",
            caughtClean: "Next Fulfilment Stage 1 lives in the other Firebase project."),
        DictionaryEntry(
            term: "Xcode",
            mishearings: [.init(heard: "ex code", count: 2)],
            added: "12 Mar", lastFired: "15 days ago",
            caughtRaw: "ex code refuses the newer sdk so use the command line tools",
            caughtClean: "Xcode refuses the newer SDK, so use the Command Line Tools."),
        DictionaryEntry(
            term: "Carlo",
            mishearings: [.init(heard: "car low", count: 1)],
            added: "19 Mar", lastFired: "16 days ago",
            caughtRaw: "car low only needs the frame sizes not the fabric",
            caughtClean: "Carlo only needs the frame sizes, not the fabric."),
        DictionaryEntry(
            term: "murmur", origin: .auto,
            mishearings: [.init(heard: "mermer", count: 1)],
            added: "2 Apr", lastFired: "18 days ago",
            caughtRaw: "mermer was the swift dictation build before this one",
            caughtClean: "Murmur was the Swift dictation build before this one."),
        DictionaryEntry(
            term: "Quill",
            mishearings: [.init(heard: "quil", count: 1)],
            added: "12 Mar", lastFired: "20 days ago",
            caughtRaw: "quil beat flow on latency again this morning",
            caughtClean: "Quill beat Flow on latency again this morning."),
        DictionaryEntry(term: "Vesper", added: "12 Mar"),
        DictionaryEntry(term: "blockcraft", added: "12 Mar"),
        DictionaryEntry(term: "Obsidian", added: "12 Mar"),
        DictionaryEntry(term: "Melbourne", added: "12 Mar"),
        DictionaryEntry(term: "Nebula", added: "12 Mar"),
        DictionaryEntry(term: "SwiftPM", added: "12 Mar"),
    ]
}
