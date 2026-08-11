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
                // A name does not begin or end with a function word.
                //
                // Without this, "until Craig Eburn is done" matched the span
                // "Craig Eburn is" against "Craigieburn" — close enough by sound
                // once the trailing "is" is folded into the skeleton — and the
                // replacement swallowed the verb: "Until Craigieburn done".
                // Deleting a word the user said is precisely the failure this
                // whole pass is supposed to be too careful to commit.
                guard !Self.isBoundaryWord(window.first?.word),
                      !Self.isBoundaryWord(window.last?.word) || span == 1
                else { continue }
                let candidate = window.map(\.word).joined(separator: " ")
                guard let match = bestMatch(for: candidate, spanCount: span,
                                            phoneticAllowed: allowsPhoneticMatch(window))
                else { continue }

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

    private func bestMatch(for candidate: String, spanCount: Int,
                           phoneticAllowed: Bool) -> String? {
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
            // Letters first, then sound.
            //
            // Spelling distance is the wrong instrument for a speech error and
            // measurably so. Recorded on Roman's own voice: "Netlify" came back
            // as "net a fly" (0.57 by letters, against a 0.85 bar) and as
            // "Netterfly" (0.67, against 0.80). Both are within a whisker of the
            // target phonetically and nowhere near it alphabetically, so the
            // corrector sat on its hands for exactly the words it exists to fix.
            //
            // The recogniser is not a bad speller. It heard the sounds correctly
            // and assembled the wrong letters out of them, so the comparison that
            // matches its failure mode is the one done on sound.
            let score = Self.similarity(normalised, target)
            if score >= threshold, score > (best?.score ?? 0) {
                best = (term, score)
            } else if phoneticAllowed,
                      Self.phoneticSimilarity(normalised, target) >= Self.phoneticThreshold,
                      Self.phoneticSimilarity(normalised, target) > (best?.score ?? 0) {
                best = (term, Self.phoneticSimilarity(normalised, target))
            }
        }

        guard let best else { return nil }
        // A correctly spelled English word is presumed intentional.
        if spanCount == 1, Self.isRealEnglishWord(candidate) { return nil }
        return best.term
    }

    /// Words that can never be the first or last part of a name.
    ///
    /// Short, and only the ones that actually turn up glued to a proper noun by
    /// the recogniser. A longer list would start rejecting real multi-word terms.
    static func isBoundaryWord(_ word: String?) -> Bool {
        guard let word = word?.lowercased(), !word.isEmpty else { return false }
        return boundaryWords.contains(word)
    }

    static let boundaryWords: Set<String> = [
        "is", "was", "are", "were", "be", "been", "the", "a", "an", "to", "of",
        "and", "or", "but", "if", "in", "on", "at", "it", "its", "this", "that",
        "for", "from", "with", "by", "as", "so", "then", "than", "do", "does",
        "did", "has", "have", "had", "will", "would", "can", "could", "not",
    ]

    /// Whether the sound-based route may fire for this span at all.
    ///
    /// It may not, unless at least one word in the span is not English. This is
    /// the guard that keeps a useful feature from becoming a destructive one.
    ///
    /// Sound matching is powerful precisely because it ignores spelling, and that
    /// is also how it gets you killed: "net a fly" and "not a fly" have the same
    /// consonant skeleton, so the rule that rescues "Netlify" from the first would
    /// silently plant "Netlify" in the middle of the second. Nothing in the audio
    /// distinguishes them — only the surrounding sentence does, and this pass does
    /// not read the sentence.
    ///
    /// So the route is restricted to spans containing something that is not a
    /// word: "Netterfly", "grapify", "Craig Eburn", "Noah Kess". Those cannot be
    /// what anybody meant to say, so replacing them risks nothing. A span of
    /// entirely ordinary English is left alone even when it scores well, which
    /// means "net a fly" survives uncorrected — a miss this design accepts on
    /// purpose, because the alternative is rewriting sentences the user meant.
    private func allowsPhoneticMatch(_ window: [Token]) -> Bool {
        window.contains { !$0.word.isEmpty && !Self.isRealEnglishWord($0.word) }
    }

    /// How close two strings are as *sounds* rather than as spellings.
    ///
    /// A deliberately small phonetic model — the classic consonant-skeleton
    /// approach, which is all that is needed here because the candidates are
    /// already known to be near-misses of a short list of proper nouns, not
    /// arbitrary English.
    ///
    /// Distance is Damerau-Levenshtein rather than plain Levenshtein because
    /// transposition is the characteristic speech error: "net a fly" against
    /// "Netlify" is NTFL against NTLF, one swap apart and two substitutions apart
    /// if you cannot see the swap.
    static let phoneticThreshold = 0.72

    /// Below this, a sound key is too small to mean anything.
    ///
    /// "quill" reduces to "kl" and so does "colour". A two-character skeleton
    /// collides with half the language, and matching on one is not evidence of
    /// anything — it is a coin flip that silently rewrites a word. Short terms
    /// are still reachable by spelling, which is the right instrument for them.
    static let minimumPhoneticKeyLength = 4

    static func phoneticSimilarity(_ a: String, _ b: String) -> Double {
        let ka = phoneticKey(a), kb = phoneticKey(b)
        guard ka.count >= minimumPhoneticKeyLength,
              kb.count >= minimumPhoneticKeyLength else { return 0 }
        if ka == kb { return 1 }
        let distance = damerauLevenshtein(Array(ka), Array(kb))
        return 1.0 - Double(distance) / Double(max(ka.count, kb.count))
    }

    /// Consonant skeleton with the sounds English confuses folded together.
    ///
    /// Vowels go entirely after the first character: they are the least reliable
    /// thing a recogniser produces and the first thing it gets wrong in an
    /// unfamiliar word. What survives is the consonant frame, which is what makes
    /// "graph if I", "grapify" and "graphify" the same key.
    static func phoneticKey(_ s: String) -> String {
        let lower = Array(s.lowercased().filter { $0.isLetter })
        guard !lower.isEmpty else { return "" }
        var out: [Character] = []
        var i = 0
        while i < lower.count {
            let c = lower[i]
            // Digraphs first, or "ph" becomes P and F and never matches.
            if i + 1 < lower.count {
                let pair = String([c, lower[i + 1]])
                let mapped: Character?
                switch pair {
                case "ph": mapped = "f"
                case "gh": mapped = "f"       // "laugh"; silent in "night" but harmless here
                case "ck": mapped = "k"
                case "sh", "ch": mapped = "x"
                case "th": mapped = "0"
                case "qu": mapped = "k"
                default:   mapped = nil
                }
                if let mapped {
                    if out.last != mapped { out.append(mapped) }
                    i += 2
                    continue
                }
            }
            let folded: Character?
            switch c {
            case "a", "e", "i", "o", "u", "y", "h", "w":
                // Keep a leading vowel: "iOS" and "OS" must not collide.
                folded = out.isEmpty ? c : nil
            case "b", "p", "v", "f": folded = "f"   // voiced/unvoiced pairs are
            case "c", "k", "g", "q", "j": folded = "k"  // routinely swapped by ASR
            case "d", "t": folded = "t"
            case "s", "z", "x": folded = "s"
            case "m", "n": folded = "n"
            case "l", "r": folded = "l"
            default: folded = c
            }
            if let folded, out.last != folded { out.append(folded) }
            i += 1
        }
        return String(out)
    }

    /// Levenshtein plus transposition. A swap costs one, not two.
    static func damerauLevenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
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

    /// A word in ANY English this user might write, not just American.
    ///
    /// This asked "en" alone, which is US English, so "colour", "realise",
    /// "organised" and "metre" were all reported as non-words — and a non-word is
    /// exactly what unlocks the sound-based repair. On an Australian user's
    /// machine that turned the guard inside out: the spellings he uses every day
    /// became the ones most eligible to be silently rewritten. Measured on his
    /// own voice, "The colour on the second panel" came out "The Quill on the
    /// second panel".
    ///
    /// Asking every variant costs a few microseconds against a decision that
    /// otherwise damages text nobody will re-read closely enough to catch.
    static func isRealEnglishWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
        guard !trimmed.isEmpty else { return false }
        for language in englishVariants {
            let range = NSSpellChecker.shared.checkSpelling(
                of: trimmed, startingAt: 0, language: language,
                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            )
            // location == NSNotFound means the spell checker found nothing wrong.
            if range.location == NSNotFound { return true }
        }
        return false
    }

    /// The user's own English first, so the common case answers on one call.
    static let englishVariants: [String] = {
        var out: [String] = []
        if let preferred = Locale.preferredLanguages.first(where: { $0.hasPrefix("en") }) {
            out.append(preferred.replacingOccurrences(of: "-", with: "_"))
        }
        for fallback in ["en_AU", "en_GB", "en_US", "en"] where !out.contains(fallback) {
            out.append(fallback)
        }
        return out
    }()

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
