import AppKit
import Foundation

/// Repairs proper nouns the recogniser has never heard.
///
/// The intended solution was Apple's contextual-strings biasing, and it is wired
/// up in SpeechAnalyzerTranscriber. It does nothing. Measured on this machine:
/// the same audio, transcribed with 0 biasing terms and with 25, produced
/// byte-identical text — "graphify" came out "graph if I" and "Netlify" came out
/// "neglify" either way. The API accepts the terms and ignores them.
///
/// So correction happens after the fact, and it cannot be find-and-replace: the
/// recogniser does not merely mis-spell a word, it splits one word into three.
/// Matching therefore runs over sliding windows of one to three words, comparing
/// a letters-only normalisation by edit distance.
///
/// The danger is over-correction — silently rewriting a word the user meant is
/// worse than leaving a wrong one, because they will not notice it. Two guards:
/// single words must clear a high bar AND not be real English (checked against
/// the system dictionary), and multi-word spans must clear a higher bar still.
public struct VocabularyCorrector: Sendable {

    private let terms: [String]
    /// Tuned against real failures rather than picked round: "craigeburn" vs
    /// "craigieburn" scores 0.91 and must pass; "graphifi" vs "graphify" scores
    /// 0.875 and must pass; ordinary English near-misses must not.
    private let singleWordThreshold: Double
    private let multiWordThreshold: Double

    public init(
        vocabulary: Vocabulary = .load(),
        singleWordThreshold: Double = 0.80,
        multiWordThreshold: Double = 0.85
    ) {
        self.terms = vocabulary.contextualStrings
        self.singleWordThreshold = singleWordThreshold
        self.multiWordThreshold = multiWordThreshold
    }

    public func correct(_ text: String) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }

        var tokens = Self.tokenise(text)
        guard !tokens.isEmpty else { return text }

        var index = 0
        while index < tokens.count {
            var replaced = false
            // Longest span first: "next fulfilment" must win over "next" alone.
            for span in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let window = Array(tokens[index ..< index + span])
                let candidate = window.map(\.word).joined(separator: " ")
                guard let match = bestMatch(for: candidate, spanCount: span) else { continue }

                // Keep the trailing punctuation of the last token in the span.
                tokens[index] = Token(word: match, trailing: window[span - 1].trailing)
                if span > 1 {
                    tokens.removeSubrange(index + 1 ..< index + span)
                }
                index += 1
                replaced = true
                break
            }
            if !replaced { index += 1 }
        }

        return tokens.map { $0.word + $0.trailing }.joined(separator: " ")
            .replacingOccurrences(of: " \n", with: "\n")
    }

    // MARK: - Matching

    private func bestMatch(for candidate: String, spanCount: Int) -> String? {
        let normalised = Self.normalise(candidate)
        guard normalised.count >= 3 else { return nil }

        let threshold = spanCount == 1 ? singleWordThreshold : multiWordThreshold

        var best: (term: String, score: Double)?
        for term in terms {
            let target = Self.normalise(term)
            guard !target.isEmpty else { continue }
            // Cheap length prefilter: nothing this far apart can clear the bar.
            let ratio = Double(min(normalised.count, target.count)) / Double(max(normalised.count, target.count))
            guard ratio >= threshold - 0.15 else { continue }

            if normalised == target {
                // Already right apart from casing — fix the casing only.
                return candidate == term ? nil : term
            }
            let score = Self.similarity(normalised, target)
            if score >= threshold, score > (best?.score ?? 0) {
                best = (term, score)
            }
        }

        guard let best else { return nil }
        // A correctly spelled English word is presumed intentional.
        if spanCount == 1, Self.isRealEnglishWord(candidate) { return nil }
        return best.term
    }

    /// 1.0 is identical. Levenshtein normalised by the longer string.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let distance = levenshtein(Array(a), Array(b))
        return 1.0 - Double(distance) / Double(max(a.count, b.count))
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0 ... b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            current[0] = i
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Letters only, lowercased. Spaces go too, which is the point — it is what
    /// lets "graph if I" and "graphify" be compared at all.
    static func normalise(_ s: String) -> String {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.letters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    static func isRealEnglishWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
        guard !trimmed.isEmpty else { return false }
        let range = NSSpellChecker.shared.checkSpelling(
            of: trimmed, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        )
        // location == NSNotFound means the spell checker found nothing wrong.
        return range.location == NSNotFound
    }

    // MARK: - Tokens

    struct Token {
        var word: String
        /// Punctuation that followed the word, preserved so correcting a term
        /// never eats the comma after it.
        var trailing: String
    }

    static func tokenise(_ text: String) -> [Token] {
        text.split(separator: " ", omittingEmptySubsequences: true).map { chunk in
            let s = String(chunk)
            let trailing = s.suffix(while: { $0.isPunctuation || $0.isSymbol })
            return Token(word: String(s.dropLast(trailing.count)), trailing: String(trailing))
        }.filter { !$0.word.isEmpty || !$0.trailing.isEmpty }
    }
}

private extension String {
    func suffix(while predicate: (Character) -> Bool) -> String {
        var result = ""
        for ch in reversed() {
            guard predicate(ch) else { break }
            result.insert(ch, at: result.startIndex)
        }
        return result
    }
}
