import Foundation

/// Spoken self-correction: the thing Roman actually complained about.
///
/// "Sometimes it doesn't pick up what I say if I make a mistake." What happens is
/// that both halves survive — "send it to Noah no wait send it to Carlo" arrives
/// with Noah still in it, and he has to go and delete the first half by hand,
/// which is the exact work dictation was supposed to save.
///
/// This file is the deterministic half of the answer. It does three jobs, and
/// they are deliberately different jobs:
///
///  1. `cues(in:)` finds retraction phrases and, critically, decides which ones
///     are *retractions* and which are ordinary English. "no wait" in "he said no
///     wait and then walked off" is content, not a correction, and anything that
///     cannot tell those apart will quietly eat words Roman said on purpose.
///  2. `needsModelPass(_:)` is the gate. A transcript with no retraction cue and
///     no stutter has nothing for a language model to contribute, so it never
///     pays the network round trip. Measured on the live endpoint, that call
///     costs p50 284ms — more than the entire dictation budget — so not making it
///     is worth more than making it fast.
///  3. `resolve(_:)` repairs the clear cases with no network at all. Roman
///     dictates on trains. Without this, the headline feature is a feature that
///     works at his desk, and the offline story is "your correction survives into
///     the text and you delete it by hand", which is where we started.
///
/// Everything here is conservative in the same direction as VocabularyCorrector:
/// when the evidence is weak it does nothing and lets the untouched FastCleaner
/// text ship. A missed correction costs one manual edit. A wrong deletion silently
/// removes something he said, into an app we do not control, and he may not notice.
public enum SelfCorrection {

    // MARK: - Cues

    /// Phrases people say when they are taking something back.
    ///
    /// Ordered longest-first because the longer phrase is the more specific
    /// signal: "no wait" must win over a bare "no", and "or rather" over "rather".
    ///
    /// Bare "no" and bare "rather" are deliberately absent. Both are far more
    /// often ordinary speech than retraction ("no I don't think so", "rather than
    /// that"), and a cue that fires on ordinary speech does not merely miss — it
    /// hands the model licence to delete a clause.
    static let cuePhrases: [[String]] = [
        ["you", "know", "what"],
        ["let", "me", "rephrase"],
        ["no", "wait"], ["wait", "no"], ["no", "sorry"], ["sorry", "no"],
        ["i", "mean"], ["i", "meant"], ["make", "that"], ["scratch", "that"],
        ["strike", "that"], ["never", "mind"], ["or", "rather"],
        ["forget", "it"], ["forget", "that"], ["hang", "on"], ["hold", "on"],
        ["actually"], ["sorry"], ["nevermind"], ["correction"],
    ].sorted { $0.count > $1.count }

    /// Verbs of reported speech. A cue that follows one is being quoted, not
    /// used: "he said no wait", "she said sorry", "I told him actually".
    ///
    /// Measured, and the reason this list exists: on the live endpoint,
    /// llama-3.1-8b turned "He said no wait and then walked off" into "He walked
    /// off." 10 times out of 10, on every prompt variant tried. The model cannot
    /// be talked out of it, so it never gets asked.
    private static let reportingVerbs: Set<String> = [
        "said", "says", "say", "saying", "told", "tell", "tells", "telling",
        "asked", "asks", "ask", "asking", "replied", "replies", "reply",
        "wrote", "writes", "goes", "went", "yelled", "shouted", "screamed",
        "whispered", "answered", "answers", "mentioned", "mentions", "added",
    ]

    /// Words that turn the cue in front of them into the subject of a sentence:
    /// "actually IS spelled with two Ls" is a sentence *about* the word.
    ///
    /// Also measured: the same model returned "Actually, I'm not going to do
    /// that." for that transcript, 6 times out of 10 — it stopped cleaning and
    /// started replying.
    private static let subjectMarkers: Set<String> = [
        "is", "isnt", "was", "wasnt", "are", "arent", "were", "means", "meant",
        "spells", "spelled", "spelt", "has", "had", "sounds", "looks", "starts",
        "ends", "comes", "means", "would", "should",
    ]

    /// Nouns that quote the next word rather than use it: "the word sorry".
    private static let quotingNouns: Set<String> = ["word", "words", "phrase", "spelling", "term"]

    /// Cues that throw away what is *still to come* rather than what was just
    /// said. "Never mind" ends an utterance; "no wait" turns one around. The
    /// distinction decides which side of the cue a deletion is allowed to eat,
    /// and getting it wrong means keeping the half Roman retracted.
    private static let abandonmentPhrases: [[String]] = [
        ["never", "mind"], ["nevermind"], ["forget", "it"], ["forget", "that"],
        ["scratch", "that"], ["strike", "that"],
    ]

    /// Whether a cue span is an abandonment. Takes a span rather than a phrase
    /// because adjacent cues are merged — "you know what never mind" arrives as
    /// one range, and only the tail of it identifies the kind.
    static func isAbandonment(_ range: Range<Int>, in tokens: [SpeechToken]) -> Bool {
        let words = tokens[range].map(\.normalised)
        return abandonmentPhrases.contains { firstIndex(of: $0, in: words) != nil }
    }

    /// One retraction phrase, located in the token stream.
    struct Cue {
        /// Half-open token range covering the phrase.
        let range: Range<Int>
        /// False when the phrase is being used as ordinary content.
        let isRetraction: Bool
    }

    /// Every cue phrase in the token stream, longest match first, non-overlapping,
    /// with adjacent phrases merged.
    ///
    /// Merging matters for "at 3 actually make that 4": "actually" and "make that"
    /// are two cues back to back, and treating them separately puts "actually"
    /// between the number being replaced and the number replacing it, so neither
    /// rule below can see the swap.
    static func cues(in tokens: [SpeechToken]) -> [Cue] {
        var found: [Range<Int>] = []
        var index = 0
        outer: while index < tokens.count {
            for phrase in cuePhrases where index + phrase.count <= tokens.count {
                let window = tokens[index ..< index + phrase.count].map(\.normalised)
                if window == phrase {
                    found.append(index ..< index + phrase.count)
                    index += phrase.count
                    continue outer
                }
            }
            index += 1
        }

        var merged: [Range<Int>] = []
        for range in found {
            if let last = merged.last, last.upperBound == range.lowerBound {
                merged[merged.count - 1] = last.lowerBound ..< range.upperBound
            } else {
                merged.append(range)
            }
        }

        return merged.map { Cue(range: $0, isRetraction: isRetraction($0, in: tokens)) }
    }

    /// The whole difficulty of this feature in one function.
    private static func isRetraction(_ range: Range<Int>, in tokens: [SpeechToken]) -> Bool {
        if range.lowerBound > 0 {
            let before = tokens[range.lowerBound - 1].normalised
            if reportingVerbs.contains(before) || quotingNouns.contains(before) { return false }
        }
        if range.upperBound < tokens.count {
            if subjectMarkers.contains(tokens[range.upperBound].normalised) { return false }
        }
        // A cue with nothing after it can only be an abandonment ("...never
        // mind"), and a cue with nothing before it cannot be taking anything
        // back — there is nothing behind it to take back.
        if range.lowerBound == 0 { return false }
        return true
    }

    // MARK: - The gate

    /// Noises, not words. Deliberately short: this set is what licenses the model
    /// to delete something with no retraction behind it, so every entry has to be
    /// a sound nobody ever means.
    ///
    /// "like", "so", "well" and "basically" were in here and came out. Each is an
    /// ordinary word in the middle of a sentence — "I like the blue one", "so it
    /// works" — and licensing their deletion anywhere means licensing it there.
    /// As sentence openers they are still deletable, via
    /// `CleanupProjection.isOpeningPreamble`, which is anchored to the first word
    /// and cannot reach into a sentence.
    ///
    /// Note what is also not here: "yeah" and "nah". Those carry Roman's tone,
    /// and stripping them is the "model improved my prose" bug in miniature.
    static let fillers: Set<String> = ["um", "uh", "er", "erm", "uhm", "mm", "hmm"]

    /// Words that repeat legitimately in English. "had had" is a tense, "very
    /// very" is emphasis; collapsing them would be a correction Roman did not ask
    /// for.
    private static let legitimateDoubles: Set<String> = ["had", "that", "very", "really", "no"]

    /// Whether a language model has anything to add to this transcript.
    ///
    /// This is a latency decision and a safety decision at once. FastCleaner
    /// already handles punctuation, disfluency and vocabulary offline in under
    /// 2ms; the only thing it cannot do is self-correction. So unless the
    /// transcript shows a retraction or a stutter, the model pass is skipped
    /// entirely — no round trip, and no opportunity for the model to "improve"
    /// a sentence that was already right.
    public static func needsModelPass(_ text: String) -> Bool {
        let tokens = SpeechToken.tokenise(text)
        guard tokens.count > 1 else { return false }
        if cues(in: tokens).contains(where: \.isRetraction) { return true }
        return firstRepetition(in: tokens) != nil
    }

    /// A run of tokens immediately repeated: "the the", "we should we should".
    /// Returns the start index and the run length.
    static func firstRepetition(in tokens: [SpeechToken]) -> (start: Int, length: Int)? {
        var index = 0
        while index < tokens.count {
            // Longest run first: "we should we should" is one 2-token repeat, not
            // two coincidental 1-token ones.
            for length in stride(from: min(3, (tokens.count - index) / 2), through: 1, by: -1) {
                let a = tokens[index ..< index + length].map(\.normalised)
                let b = tokens[index + length ..< index + 2 * length].map(\.normalised)
                guard a == b, !a.contains(where: \.isEmpty) else { continue }
                if length == 1, legitimateDoubles.contains(a[0]) { continue }
                return (index, length)
            }
            index += 1
        }
        return nil
    }

    // MARK: - Offline repair

    /// Repairs the unambiguous cases with no network. Returns nil when it is not
    /// confident, which means the untouched FastCleaner text ships.
    ///
    /// Only four rules, each requiring evidence beyond the cue word itself. The
    /// cue alone is never enough — that is what makes "he said no wait and then
    /// walked off" survive intact.
    public static func resolve(_ text: String, protecting terms: [String] = []) -> String? {
        var tokens = SpeechToken.tokenise(text)
        guard tokens.count > 1 else { return nil }

        var changed = collapseRepetitions(&tokens)
        // Bounded rather than "until nothing changes": one utterance can carry
        // two corrections, but this runs on the dictation path inside a deadline
        // and a rule engine that can spin is a rule engine that can hang it.
        for _ in 0 ..< 4 {
            if resolveParallelRestarts(&tokens) { changed = true; continue }
            if resolveSwaps(&tokens) { changed = true; continue }
            break
        }
        changed = stripTrailingAbandonment(&tokens) || changed
        guard changed, !tokens.isEmpty else { return nil }

        let rebuilt = SpeechToken.join(tokens)
        let tidied = FastCleaner.tightenPunctuationSpacing(in: FastCleaner.collapseWhitespace(in: rebuilt))
        let out = capitaliseUnlessProtected(tidied, terms: terms)
        return out == text ? nil : out
    }

    /// "The the build is is failing" → "The build is failing".
    static func collapseRepetitions(_ tokens: inout [SpeechToken]) -> Bool {
        var changed = false
        // Bounded rather than `while true`: a rule that can loop is a rule that
        // can hang the dictation path, and this one runs inside a deadline.
        for _ in 0 ..< 8 {
            guard let (start, length) = firstRepetition(in: tokens) else { break }
            // Drop the first copy and keep the second, so the punctuation that
            // followed the phrase the speaker actually finished survives.
            tokens.removeSubrange(start ..< start + length)
            changed = true
        }
        return changed
    }

    /// "send it to Noah no wait send it to Carlo" → "send it to Carlo".
    ///
    /// The evidence is the repeat: the words after the cue restart a run of words
    /// from before it. Without that repeat this rule does nothing, which is
    /// exactly why "he said no wait and then walked off" is safe — "and then
    /// walked off" restarts nothing.
    static func resolveParallelRestarts(_ tokens: inout [SpeechToken]) -> Bool {
        for cue in cues(in: tokens).reversed() where cue.isRetraction {
            let after = tokens[cue.range.upperBound...].map(\.normalised)
            guard !after.isEmpty else { continue }
            let before = tokens[..<cue.range.lowerBound].map(\.normalised)

            // Longest restart wins: matching three words is strong evidence,
            // matching one is weak.
            for length in stride(from: min(4, after.count), through: 1, by: -1) {
                let head = Array(after[0 ..< length])
                guard let start = firstIndex(of: head, in: before) else { continue }
                // One word only counts when it restarts the whole utterance —
                // "I was going to the I mean I went to the shop". Anywhere else a
                // single shared word is coincidence, not a restart.
                guard length >= 2 || start == 0 else { continue }
                tokens.removeSubrange(start ..< cue.range.upperBound)
                return true
            }
        }
        return false
    }

    /// "at 3 actually make that 4" → "at 4"; "for 500 sorry 1500 dollars" → "for 1500 dollars".
    ///
    /// The evidence is that the token before the cue and the token after it are
    /// the same *kind* of thing — two numbers, or two mid-sentence proper nouns.
    /// A swap between things of different kinds is not a swap, it is a sentence.
    static func resolveSwaps(_ tokens: inout [SpeechToken]) -> Bool {
        for cue in cues(in: tokens).reversed() where cue.isRetraction {
            let replacedIndex = cue.range.lowerBound - 1
            let replacementIndex = cue.range.upperBound
            guard replacedIndex >= 0, replacementIndex < tokens.count else { continue }
            guard areSwapCompatible(tokens, replacedIndex, replacementIndex) else { continue }
            // Carry the replaced token's leading punctuation forward so "(500
            // sorry 1500" does not lose its bracket.
            let lead = tokens[replacedIndex].lead
            tokens.removeSubrange(replacedIndex ..< replacementIndex)
            if !lead.isEmpty { tokens[replacedIndex].lead = lead + tokens[replacedIndex].lead }
            return true
        }
        return false
    }

    private static func areSwapCompatible(_ tokens: [SpeechToken], _ a: Int, _ b: Int) -> Bool {
        let left = tokens[a], right = tokens[b]
        if left.isNumber, right.isNumber { return true }
        // Mid-sentence capitals only. A capital in first position is just the
        // start of a sentence and says nothing about the word.
        let leftIsName = a > 0 && left.isCapitalised && !tokens[a - 1].endsSentence
        let rightIsName = right.isCapitalised
        return leftIsName && rightIsName && left.normalised != right.normalised
    }

    /// "send Carlo the invoice you know what never mind" → "send Carlo the invoice".
    ///
    /// Strips the abandonment, not the sentence. Deleting what he actually said
    /// would be the literal reading, and it would insert nothing at all after a
    /// dictation — indistinguishable from the app being broken.
    static func stripTrailingAbandonment(_ tokens: inout [SpeechToken]) -> Bool {
        let endings: [[String]] = [
            ["you", "know", "what", "never", "mind"], ["you", "know", "what", "forget", "it"],
            ["never", "mind"], ["nevermind"], ["forget", "it"], ["forget", "that"],
            ["scratch", "that"], ["actually", "never", "mind"],
        ].sorted { $0.count > $1.count }

        for phrase in endings where tokens.count > phrase.count {
            let tail = tokens.suffix(phrase.count).map(\.normalised)
            guard tail == phrase else { continue }
            // Never strip down to a fragment; two surviving words is the floor.
            guard tokens.count - phrase.count >= 2 else { continue }
            let punctuation = tokens[tokens.count - 1].trail
            tokens.removeLast(phrase.count)
            if tokens[tokens.count - 1].trail.isEmpty { tokens[tokens.count - 1].trail = punctuation }
            return true
        }
        return false
    }

    // MARK: - Helpers

    static func firstIndex(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0 ... (haystack.count - needle.count)
        where Array(haystack[start ..< start + needle.count]) == needle {
            return start
        }
        return nil
    }

    /// Sentence-cases the result, except when the first word is one of Roman's
    /// terms. Deleting a false start can promote "graphify" to the front of the
    /// sentence, and "Graphify" is a different word as far as he is concerned —
    /// AIOutputGuard rejects an AI response for exactly that, so doing it here
    /// would be the offline path committing the sin the online path guards against.
    private static func capitaliseUnlessProtected(_ text: String, terms: [String]) -> String {
        let protectedWords = Set(terms.flatMap { $0.split(separator: " ").map(String.init) })
        let first = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let bare = first.trimmingCharacters(in: .punctuationCharacters)
        if protectedWords.contains(bare) { return text }
        return FastCleaner.capitaliseSentences(in: text)
    }
}

// MARK: - Tokens

/// A word with its punctuation kept beside it rather than glued to it.
///
/// Every rule in this file and in NIMCleaner reasons about words; every rule also
/// has to put the commas back afterwards. Splitting them once, here, is what
/// stops "send it to Noah, no wait, send it to Carlo." from losing its full stop.
public struct SpeechToken: Equatable, Sendable {
    public var lead: String
    public var word: String
    public var trail: String
    /// Lowercased, letters and digits only. Apostrophes go too, which is what
    /// lets "lets" and "Let's" compare equal — the model is allowed to add the
    /// apostrophe, and that must not read as a changed word.
    public let normalised: String

    init(lead: String, word: String, trail: String) {
        self.lead = lead
        self.word = word
        self.trail = trail
        self.normalised = word.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    var isNumber: Bool {
        if !normalised.isEmpty, normalised.allSatisfy(\.isNumber) { return true }
        return SpeechToken.spelledNumbers.contains(normalised)
    }

    var isCapitalised: Bool { word.first?.isUppercase == true && normalised != "i" }

    var endsSentence: Bool { trail.contains(where: { ".!?".contains($0) }) }

    private static let spelledNumbers: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
    ]

    public static func tokenise(_ text: String) -> [SpeechToken] {
        var tokens: [SpeechToken] = []
        for chunk in text.split(whereSeparator: \.isWhitespace) {
            let s = String(chunk)
            let lead = String(s.prefix(while: { !$0.isLetter && !$0.isNumber }))
            var rest = String(s.dropFirst(lead.count))
            var trail = ""
            while let last = rest.last, !last.isLetter, !last.isNumber {
                trail.insert(last, at: trail.startIndex)
                rest.removeLast()
            }
            let word = rest
            if word.isEmpty {
                // Stray punctuation. Glue it to whatever came before rather than
                // carrying an empty token that every rule would have to skip.
                if !tokens.isEmpty { tokens[tokens.count - 1].trail += lead + trail } else if !s.isEmpty {
                    tokens.append(SpeechToken(lead: "", word: "", trail: s))
                }
                continue
            }
            tokens.append(SpeechToken(lead: lead, word: word, trail: trail))
        }
        return tokens
    }

    public static func join(_ tokens: [SpeechToken]) -> String {
        tokens.map { $0.lead + $0.word + $0.trail }.joined(separator: " ")
    }
}
