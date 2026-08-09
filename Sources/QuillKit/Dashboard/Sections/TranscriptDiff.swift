import Foundation

/// What the recogniser heard, against what Quill actually typed.
///
/// `DictationRecord` keeps both columns on purpose (see `HistoryStore`), and
/// until now nothing read the raw one. Wispr Flow stores the same split and
/// shows only the formatted side, so the one question a dictation user actually
/// has — *did it mishear me, or did it just tidy me up?* — has no answer in
/// their UI. This is that answer.
///
/// The alignment is a word-level LCS rather than a character diff. Character
/// diffs on prose produce shrapnel: "Netlify" against "net lify" comes back as
/// four fragments of a word, which is technically the smallest edit and
/// completely unreadable. Whole words are the unit a person compares in.
///
/// Words are matched on a *normalised* key — lowercased, outer punctuation
/// stripped — so recasing and repunctuation do not detonate the diff. Nearly
/// every word in a cleaned transcript differs from the raw one by a comma or a
/// capital; highlighting all of them would leave nothing highlighted. Those
/// survive as `unchanged` and are counted separately, in `reshapedWords`.
public struct TranscriptDiff: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// Survived cleanup. Rendered with the *inserted* spelling, because that
        /// is the text that exists in the document.
        case unchanged
        /// Heard, then dropped.
        case removed
        /// Typed, but never said in that form.
        case added
    }

    public struct Segment: Sendable, Equatable {
        public let text: String
        public let kind: Kind

        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// A removed run standing immediately beside an added one — a substitution
    /// rather than a deletion, and the shape every vocabulary fix takes.
    public struct Replacement: Sendable, Equatable {
        public let from: String
        public let to: String
    }

    /// One line of "here is what changed", for the summary block.
    public struct Note: Sendable, Equatable {
        public let tag: String
        public let text: String
    }

    public let segments: [Segment]
    public let removedWords: Int
    public let addedWords: Int
    /// Words that survived but came out recased or repunctuated.
    public let reshapedWords: Int
    public let replacements: [Replacement]
    /// Removed words that are known filler, in the order they were said.
    public let filler: [String]
    /// Removed words that are neither filler nor part of a substitution —
    /// repeats, false starts, the "the the" of real speech.
    public let trimmedWords: Int

    /// The number of distinct places the text was touched. Not a word count:
    /// "net lify" becoming "Netlify" is one edit, not three.
    public var editCount: Int {
        var count = 0
        var index = 0
        while index < segments.count {
            guard segments[index].kind != .unchanged else { index += 1; continue }
            // A removed run followed by an added run is one edit, not two.
            var run = index
            while run < segments.count && segments[run].kind != .unchanged { run += 1 }
            count += 1
            index = run
        }
        return count
    }

    public var isClean: Bool { editCount == 0 && reshapedWords == 0 }

    // MARK: - Notes

    /// The change summary, most consequential first. Vocabulary fixes matter
    /// most — they are the ones that would have been *wrong* in the document.
    /// Punctuation comes last because it is the one nobody has to check.
    public var notes: [Note] {
        var out: [Note] = []

        if !replacements.isEmpty {
            let shown = replacements.prefix(2)
                .map { "\u{201C}\($0.from)\u{201D} \u{2192} \u{201C}\($0.to)\u{201D}" }
                .joined(separator: "   \u{00B7}   ")
            let hidden = replacements.count - 2
            out.append(Note(tag: "Terms",
                            text: shown + (hidden > 0 ? "   \u{00B7}   +\(hidden) more" : "")))
        }
        if !filler.isEmpty {
            let unique = filler.reduce(into: [String]()) { acc, word in
                if !acc.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { acc.append(word) }
            }
            let quoted = unique.prefix(3).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            out.append(Note(tag: "Filler",
                            text: "\(quoted) dropped \u{00B7} \(filler.count) word\(filler.count == 1 ? "" : "s")"))
        }
        if trimmedWords > 0 {
            out.append(Note(tag: "Trimmed",
                            text: "\(trimmedWords) repeated word\(trimmedWords == 1 ? "" : "s") removed"))
        }
        if reshapedWords > 0 {
            out.append(Note(tag: "Format",
                            text: "\(reshapedWords) word\(reshapedWords == 1 ? "" : "s") recased or repunctuated"))
        }
        return out
    }

    // MARK: - Building

    /// Words people say while thinking. Deliberately the same list
    /// `FastCleaner` strips, plus the multi-word ones it cannot: the summary
    /// should describe the cleanup that actually ran, not a second opinion.
    static let fillerWords: Set<String> = [
        "um", "uh", "erm", "uhm", "ah", "eh", "mm", "hmm",
        "like", "okay", "so", "well", "you", "know", "i", "mean", "just", "sort", "kind", "of", "basically", "actually",
    ]

    /// Only these are *reported* as filler. The set above is too greedy to show
    /// a user — "so" and "just" are real words most of the time — so a removed
    /// word is only called filler if it is unambiguous.
    static let reportableFiller: Set<String> = [
        "um", "uh", "erm", "uhm", "ah", "eh", "mm", "hmm", "basically", "actually", "literally",
    ]

    /// Multi-word phrases worth naming in the summary when their words are all
    /// removed together.
    static let fillerPhrases: [[String]] = [
        ["you", "know"], ["i", "mean"], ["sort", "of"], ["kind", "of"],
    ]

    public static func between(raw: String, inserted: String) -> TranscriptDiff {
        let rawTokens = tokens(raw)
        let insertedTokens = tokens(inserted)

        // Degenerate cases are worth short-circuiting: a record whose raw text
        // was never captured must not render as "every word was invented".
        if rawTokens.isEmpty || insertedTokens.isEmpty {
            let text = insertedTokens.isEmpty ? raw : inserted
            return TranscriptDiff(segments: text.isEmpty ? [] : [Segment(text: text, kind: .unchanged)],
                                  removedWords: 0, addedWords: 0, reshapedWords: 0,
                                  replacements: [], filler: [], trimmedWords: 0)
        }

        let ops = align(rawTokens, insertedTokens)

        var segments: [Segment] = []
        var pending: [String] = []
        var pendingKind: Kind?

        func flush() {
            guard let kind = pendingKind, !pending.isEmpty else { pending = []; pendingKind = nil; return }
            segments.append(Segment(text: pending.joined(separator: " "), kind: kind))
            pending = []
            pendingKind = nil
        }

        var removedWords = 0
        var addedWords = 0
        var reshapedWords = 0
        var filler: [String] = []
        var trimmedWords = 0
        var replacements: [Replacement] = []

        // Removed runs are held until the next op is known, because whether a
        // run is a deletion or half of a substitution depends on what follows.
        var heldRemoved: [String] = []

        func settleHeldRemoved(followedByAdded added: [String]) {
            guard !heldRemoved.isEmpty else { return }
            if !added.isEmpty {
                replacements.append(Replacement(from: heldRemoved.joined(separator: " "),
                                                to: added.joined(separator: " ")))
            } else {
                let keys = heldRemoved.map(key)
                var matchedPhrase = false
                for phrase in fillerPhrases where keys == phrase {
                    filler.append(heldRemoved.joined(separator: " "))
                    matchedPhrase = true
                }
                if !matchedPhrase {
                    for (index, k) in keys.enumerated() {
                        if reportableFiller.contains(k) { filler.append(heldRemoved[index]) }
                        else { trimmedWords += 1 }
                    }
                }
            }
            heldRemoved = []
        }

        var index = 0
        while index < ops.count {
            switch ops[index] {
            case .equal(let rawIndex, let insertedIndex):
                settleHeldRemoved(followedByAdded: [])
                if rawTokens[rawIndex] != insertedTokens[insertedIndex] { reshapedWords += 1 }
                if pendingKind != .unchanged { flush(); pendingKind = .unchanged }
                pending.append(insertedTokens[insertedIndex])
                index += 1

            case .remove:
                // Consume the whole removed run, then look at what follows.
                var run: [String] = []
                while index < ops.count, case .remove(let i) = ops[index] {
                    run.append(rawTokens[i])
                    index += 1
                }
                removedWords += run.count
                var following: [String] = []
                var peek = index
                while peek < ops.count, case .add(let i) = ops[peek] {
                    following.append(insertedTokens[i])
                    peek += 1
                }
                heldRemoved = run
                settleHeldRemoved(followedByAdded: following)
                if pendingKind != .removed { flush(); pendingKind = .removed }
                pending.append(contentsOf: run)

            case .add:
                var run: [String] = []
                while index < ops.count, case .add(let i) = ops[index] {
                    run.append(insertedTokens[i])
                    index += 1
                }
                addedWords += run.count
                // An added run with no removed run before it is a pure
                // insertion; nothing to settle, but it must not be mistaken for
                // a substitution on the next pass either.
                heldRemoved = []
                if pendingKind != .added { flush(); pendingKind = .added }
                pending.append(contentsOf: run)
            }
        }
        settleHeldRemoved(followedByAdded: [])
        flush()

        return TranscriptDiff(segments: segments,
                              removedWords: removedWords,
                              addedWords: addedWords,
                              reshapedWords: reshapedWords,
                              replacements: replacements,
                              filler: filler,
                              trimmedWords: trimmedWords)
    }

    // MARK: - Alignment

    private enum Op {
        case equal(Int, Int)
        case remove(Int)
        case add(Int)
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Lowercased, outer punctuation stripped. `Netlify.` and `netlify` are the
    /// same word; `Netlify` and `net lify` are not.
    static func key(_ token: String) -> String {
        let strippable = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(CharacterSet(charactersIn: "\u{2018}\u{2019}\u{201C}\u{201D}\u{2014}\u{2013}"))
        return token.lowercased().trimmingCharacters(in: strippable)
    }

    private static func align(_ a: [String], _ b: [String]) -> [Op] {
        let ka = a.map(key), kb = b.map(key)
        let n = ka.count, m = kb.count

        // Plain LCS. Both sides are one utterance — tens of words, not tens of
        // thousands — so the quadratic table is a rounding error and the
        // banded/Myers alternatives only add ways to be wrong.
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = ka[i] == kb[j]
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var ops: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if ka[i] == kb[j] {
                ops.append(.equal(i, j)); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append(.remove(i)); i += 1
            } else {
                ops.append(.add(j)); j += 1
            }
        }
        while i < n { ops.append(.remove(i)); i += 1 }
        while j < m { ops.append(.add(j)); j += 1 }
        return ops
    }
}
