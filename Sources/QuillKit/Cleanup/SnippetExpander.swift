import Foundation

/// Swaps trigger phrases for the blocks of text they stand for.
///
/// Runs *after* cleanup and *before* insertion. Both halves of that are
/// deliberate. After cleanup, because the cleaner capitalises sentences and
/// repairs vocabulary, and a replacement that has already been dropped in would
/// be rewritten by it — "romangigliotti123@gmail.com" is not a sentence and must
/// not be sentence-cased. Before insertion, because the alternative is typing
/// the phrase into someone's document and then mutating text they are already
/// reading.
///
/// MATCHING IS EXACT, AND THAT IS THE WHOLE DESIGN. `VocabularyCorrector` next
/// door matches fuzzily on purpose — the worst case there is one wrong noun.
/// Here the worst case is four hundred characters of a client quote landing in
/// the middle of a message to someone else, and the user does not notice until
/// after they hit send. So: words are compared after case and punctuation are
/// stripped, and nothing else. No edit distance, no stemming, no "close enough".
///
/// What the comparison *does* forgive is everything the recogniser adds on its
/// own — capitalisation at a sentence start, a comma the user never said, a
/// hyphen in "e-mail". Those are transcription artefacts, not different words.
public struct SnippetExpander: Sendable {

    /// One firing, with enough range information to show it to a human. The
    /// dashboard's "how it fires" preview draws these; the store uses the ids.
    public struct Firing: Sendable, Equatable {
        public let id: UUID
        public let phrase: String
        /// Where the trigger sat in the input, in UTF-16 units.
        public let sourceRange: NSRange
        /// Where the replacement sits in the output, in UTF-16 units.
        public let outputRange: NSRange
    }

    public struct Result: Sendable, Equatable {
        public let text: String
        public let firings: [Firing]
        public var didFire: Bool { !firings.isEmpty }
    }

    public init() {}

    public func expand(_ text: String, using snippets: [Snippet]) -> Result {
        let usable = snippets.filter {
            $0.isEnabled
                && !$0.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.replacement.isEmpty
        }
        guard !usable.isEmpty, !text.isEmpty else { return Result(text: text, firings: []) }

        let source = text as NSString
        let tokens = Self.tokenise(text)
        guard !tokens.isEmpty else { return Result(text: text, firings: []) }

        // Whole-utterance rules get first refusal: if the entire dictation is
        // the phrase, that is unambiguous and beats any partial match.
        let whole = tokens.map(\.normalised)
        for snippet in usable where snippet.mode == .alone {
            guard Self.words(of: snippet.phrase) == whole else { continue }
            let outputLength = (snippet.replacement as NSString).length
            return Result(
                text: snippet.replacement,
                firings: [Firing(id: snippet.id,
                                 phrase: snippet.phrase,
                                 sourceRange: NSRange(location: 0, length: source.length),
                                 outputRange: NSRange(location: 0, length: outputLength))])
        }

        // Longest phrase first, so "my email address" wins over a hypothetical
        // "email" rather than losing to whichever was created first.
        let candidates = usable
            .filter { $0.mode == .anywhere }
            .map { (snippet: $0, words: Self.words(of: $0.phrase)) }
            .filter { !$0.words.isEmpty }
            .sorted { $0.words.count > $1.words.count }
        guard !candidates.isEmpty else { return Result(text: text, firings: []) }

        var matches: [(range: NSRange, snippet: Snippet)] = []
        var index = 0
        while index < tokens.count {
            var matched = false
            for candidate in candidates {
                let span = candidate.words.count
                guard index + span <= tokens.count else { continue }
                guard Array(tokens[index ..< index + span]).map(\.normalised) == candidate.words else { continue }
                // The replaced range covers the *words* only. Trailing
                // punctuation belongs to the sentence, not to the trigger, and
                // eating the comma after a phrase is the kind of bug that makes
                // a feature feel unfinished.
                let start = tokens[index].range.location
                let end = NSMaxRange(tokens[index + span - 1].range)
                matches.append((NSRange(location: start, length: end - start), candidate.snippet))
                index += span
                matched = true
                break
            }
            if !matched { index += 1 }
        }
        guard !matches.isEmpty else { return Result(text: text, firings: []) }

        // Rebuilt left to right, which hands us the output ranges for free.
        let output = NSMutableString()
        var firings: [Firing] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                output.append(source.substring(with: NSRange(location: cursor,
                                                             length: match.range.location - cursor)))
            }
            let location = output.length
            output.append(match.snippet.replacement)
            firings.append(Firing(id: match.snippet.id,
                                  phrase: match.snippet.phrase,
                                  sourceRange: match.range,
                                  outputRange: NSRange(location: location, length: output.length - location)))
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length {
            output.append(source.substring(from: cursor))
        }
        Self.capitaliseAfterFirings(output, firings: firings)
        return Result(text: output as String, firings: firings)
    }

    /// Re-capitalises the word immediately after a replacement that ended a
    /// sentence.
    ///
    /// The cleaner has already run by this point — it must, or it would
    /// sentence-case an email address — so a replacement ending in a full stop
    /// leaves "…the rest on launch. and I'll follow up." behind it. This is the
    /// one thing the ordering costs, and it is one character to fix.
    ///
    /// Only ever changes case, so every range handed back stays valid.
    private static func capitaliseAfterFirings(_ output: NSMutableString, firings: [Firing]) {
        let sentenceEnders: Set<Character> = [".", "!", "?"]
        for firing in firings {
            let end = NSMaxRange(firing.outputRange)
            guard end > 0, end < output.length else { continue }
            guard let last = (output.substring(with: firing.outputRange)).last,
                  sentenceEnders.contains(last) else { continue }

            var index = end
            while index < output.length,
                  let scalar = UnicodeScalar(output.character(at: index)),
                  CharacterSet.whitespaces.contains(scalar) {
                index += 1
            }
            guard index < output.length else { continue }
            let letter = output.substring(with: NSRange(location: index, length: 1))
            let upper = letter.uppercased()
            // "ß".uppercased() is "SS". A one-for-one swap keeps every range
            // valid; anything else would silently slide the highlights.
            guard upper != letter, (upper as NSString).length == 1 else { continue }
            output.replaceCharacters(in: NSRange(location: index, length: 1), with: upper)
        }
    }

    // MARK: - Tokens

    struct Token {
        let normalised: String
        /// The word's own range, with any surrounding punctuation excluded.
        let range: NSRange
    }

    /// Splits on whitespace, then trims non-word characters off each end and
    /// records where the word itself sits.
    ///
    /// Whitespace rather than `enumerateSubstrings(.byWords)` on purpose, and
    /// the difference is not academic: ICU's word breaker splits "e-mail" into
    /// two words, so a phrase saved as "my e-mail" would be three tokens and
    /// could never match the two the recogniser produces for the same spoken
    /// sound. What a person hears as one word has to be one token here.
    ///
    /// Chunks that are nothing but punctuation drop out entirely — an em dash
    /// the recogniser inserted must not break a phrase in half, and must not
    /// count as a word either.
    static func tokenise(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            let chunkStart = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }

            var start = chunkStart
            while start < index, !Self.isWordCharacter(text[start]) {
                start = text.index(after: start)
            }
            var end = index
            while end > start, !Self.isWordCharacter(text[text.index(before: end)]) {
                end = text.index(before: end)
            }
            guard start < end else { continue }

            let normalised = Self.normalise(String(text[start ..< end]))
            guard !normalised.isEmpty else { continue }
            tokens.append(Token(normalised: normalised, range: NSRange(start ..< end, in: text)))
        }
        return tokens
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Lowercased, letters and digits only. This is what forgives the comma the
    /// recogniser invented and the capital it added at a sentence start, while
    /// still refusing anything that is a genuinely different word.
    static func normalise(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.lowercased().unicodeScalars
        where CharacterSet.alphanumerics.contains(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    static func words(of phrase: String) -> [String] {
        tokenise(phrase).map(\.normalised)
    }
}
