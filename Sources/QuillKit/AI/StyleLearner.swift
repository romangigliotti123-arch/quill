import Foundation

/// Reading a style out of the difference between what Quill wrote and what the
/// user kept.
///
/// Every function here is pure: strings in, values out, no clock, no disk, no
/// model, no network. That is not tidiness — it is the only way this is testable
/// at all. The alternative shape, a learner that reaches into a store and a
/// model and a date, can only be checked by running the whole app and reading
/// the output, which is how a learning feature ends up shipping with a detector
/// that has never once fired.
///
/// `StyleStore.recordCorrection` is the impure edge, and it is three lines long.
///
/// # The rule every detector follows
///
/// **One correction, one vote per trait.** A paragraph containing "colour" four
/// times is one piece of evidence about spelling, not four. Without that rule a
/// single long email settles the entire profile, and the tally in `StyleTrait`
/// stops meaning what it says.
public enum StyleLearner {

    // MARK: - Entry points

    /// What one correction says about how the user writes.
    ///
    /// `dictated` is the text Quill inserted; `edited` is what the user changed
    /// it to. Returns an observation with a field set only where the evidence is
    /// unambiguous — most corrections say one or two things, and a detector that
    /// always has an opinion is a detector that is usually wrong.
    public static func observe(dictated: String, edited: String) -> StyleObservation {
        let before = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !after.isEmpty, before != after else { return .none }

        let segments = StyleDiff.segments(tokens(of: before), tokens(of: after))

        return StyleObservation(
            spelling: spelling(segments: segments, edited: after),
            contractions: contractions(segments: segments, edited: after),
            formality: formality(segments: segments),
            oxfordComma: oxfordComma(in: after),
            exclamations: exclamations(dictated: before, edited: after),
            sentenceWords: sentenceWords(in: after),
            phrasings: phrasings(segments: segments)
        )
    }

    /// Fold an observation into a profile. Pure — the date is passed in.
    public static func apply(
        _ observation: StyleObservation,
        to profile: StyleProfile,
        at date: Date
    ) -> StyleProfile {
        guard profile.isLearningEnabled, !observation.isEmpty else { return profile }
        var updated = profile

        if let value = observation.spelling { updated.spelling.record(value, at: date) }
        if let value = observation.contractions { updated.contractions.record(value, at: date) }
        if let value = observation.formality { updated.formality.record(value, at: date) }
        if let value = observation.oxfordComma { updated.oxfordComma.record(value, at: date) }
        if let value = observation.exclamations { updated.exclamations.record(value, at: date) }
        if let words = observation.sentenceWords { updated.sentenceLength.add(words) }

        for phrasing in observation.phrasings {
            if let index = updated.phrasings.firstIndex(where: { $0.id == phrasing.id }) {
                updated.phrasings[index].count += 1
                updated.phrasings[index].lastObserved = date
            } else {
                updated.phrasings.append(StylePhrasing(from: phrasing.from, to: phrasing.to, count: 1, lastObserved: date))
            }
        }
        // Strongest and most recent survive. The tail is one-off edits, and a
        // list that only grows is a file that only grows.
        if updated.phrasings.count > StyleProfile.maximumPhrasings {
            updated.phrasings.sort {
                $0.count == $1.count
                    ? ($0.lastObserved ?? .distantPast) > ($1.lastObserved ?? .distantPast)
                    : $0.count > $1.count
            }
            updated.phrasings.removeLast(updated.phrasings.count - StyleProfile.maximumPhrasings)
        }

        // Counts corrections it actually learned something from, not corrections
        // seen. "Learned from 12 edits" has to mean twelve edits moved a number.
        updated.correctionCount += 1
        updated.lastLearned = date
        return updated
    }

    public static func learn(
        dictated: String,
        edited: String,
        into profile: StyleProfile,
        at date: Date = Date()
    ) -> StyleProfile {
        apply(observe(dictated: dictated, edited: edited), to: profile, at: date)
    }

    // MARK: - Detectors

    /// Spelling convention, from the correction if it shows one and from the
    /// approved text otherwise.
    ///
    /// The diff is the stronger signal — "capitalization" corrected to
    /// "capitalisation" is a statement of preference — but it only fires when
    /// Quill got it wrong in the first place. Scanning the text he kept catches
    /// the far commoner case where he wrote "colour" himself and left it alone.
    static func spelling(segments: [StyleDiff.Segment], edited: String) -> SpellingConvention? {
        for segment in segments where segment.from.count == 1 && segment.to.count == 1 {
            guard
                let before = Orthography.convention(of: segment.from[0]),
                let after = Orthography.convention(of: segment.to[0]),
                before != after
            else { continue }
            return after
        }

        var british = 0, american = 0
        for token in tokens(of: edited) {
            switch Orthography.convention(of: token) {
            case .british?:  british += 1
            case .american?: american += 1
            case nil:        break
            }
        }
        guard british != american else { return nil }
        return british > american ? .british : .american
    }

    /// Whether he writes "don't" or "do not".
    static func contractions(segments: [StyleDiff.Segment], edited: String) -> Bool? {
        let removed = segments.map { $0.from.joined(separator: " ") }.joined(separator: " ")
        let added = segments.map { $0.to.joined(separator: " ") }.joined(separator: " ")

        let contractionDelta = contractionCount(added) - contractionCount(removed)
        let expansionDelta = expansionCount(added) - expansionCount(removed)
        if contractionDelta > 0, expansionDelta <= 0 { return true }
        if contractionDelta < 0, expansionDelta > 0 { return false }

        // No signal in the edit. Fall back to the text he approved — but only
        // when it is one-sided. Two expanded forms and no contractions is a
        // habit; one "it is" in a paragraph is a sentence.
        let contractions = contractionCount(edited)
        let expansions = expansionCount(edited)
        if contractions > 0, expansions == 0 { return true }
        if expansions >= 2, contractions == 0 { return false }
        return nil
    }

    /// Register, from greeting and sign-off swaps only.
    ///
    /// Deliberately narrow. Formality is the trait most tempting to infer from
    /// vibes — word length, sentence structure, an exclamation mark — and the
    /// one where being wrong is most obvious, because it changes how every
    /// dictation sounds rather than how one word is spelled. So it is learned
    /// only from a swap the user actually made: he replaced "Hello" with "hey",
    /// or the other way. Anything less than that is a guess.
    static func formality(segments: [StyleDiff.Segment]) -> Formality? {
        for segment in segments {
            let before = segment.from.joined(separator: " ").lowercased()
            let after = segment.to.joined(separator: " ").lowercased()
            let wasCasual = casualMarkers.contains { before.contains($0) }
            let wasFormal = formalMarkers.contains { before.contains($0) }
            let isCasual = casualMarkers.contains { after.contains($0) }
            let isFormal = formalMarkers.contains { after.contains($0) }
            if wasCasual, isFormal, !isCasual { return .formal }
            if wasFormal, isCasual, !isFormal { return .casual }
        }
        return nil
    }

    /// Serial comma, read off the text he kept.
    ///
    /// Only lists are counted, and a list is recognised by there being a comma
    /// somewhere before the "and" that is not the one under examination. That
    /// test exists to keep "I called Noah, and he said yes" — a joined clause,
    /// not a list — from voting. Returns nil unless every list in the text
    /// agrees, because someone who does both has no preference to learn.
    static func oxfordComma(in text: String) -> Bool? {
        var verdicts: Set<Bool> = []
        for sentence in sentences(of: text) {
            let words = tokens(of: sentence)
            guard words.count >= 4 else { continue }
            for (index, word) in words.enumerated() where index > 1 && index < words.count - 1 {
                let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                guard bare == "and" || bare == "or" else { continue }

                let preceding = words[..<index]
                let commasBefore = preceding.filter { $0.hasSuffix(",") }.count
                if words[index - 1].hasSuffix(",") {
                    // "a, b, and c" — needs a second comma to prove it is a list.
                    if commasBefore >= 2 { verdicts.insert(true) }
                } else if commasBefore >= 1 {
                    verdicts.insert(false)
                }
            }
        }
        return verdicts.count == 1 ? verdicts.first : nil
    }

    /// Exclamation marks, counted on whole texts rather than on the diff —
    /// deleting a "!" changes no word, so it never shows up as a replacement.
    static func exclamations(dictated: String, edited: String) -> Bool? {
        let before = dictated.filter { $0 == "!" }.count
        let after = edited.filter { $0 == "!" }.count
        if after > before { return true }
        if after < before { return false }
        return nil
    }

    /// Mean words per sentence of the text he approved.
    static func sentenceWords(in text: String) -> Double? {
        let parts = sentences(of: text).filter { !tokens(of: $0).isEmpty }
        guard !parts.isEmpty else { return nil }
        let words = parts.reduce(0) { $0 + tokens(of: $1).count }
        // Under five words there is no sentence-length habit to measure, only a
        // fragment: "yep", "on it", "sounds good".
        guard words >= 5 else { return nil }
        return Double(words) / Double(parts.count)
    }

    /// Rewrites worth remembering: he replaced these words with those words.
    ///
    /// Everything explained by another trait is filtered out — a spelling
    /// change, a contraction, or a near-identical respelling of the same word
    /// (which is a vocabulary repair, and `VocabularyCorrector`'s job). What is
    /// left is a genuine choice of words.
    static func phrasings(segments: [StyleDiff.Segment]) -> [StylePhrasing] {
        var out: [StylePhrasing] = []
        for segment in segments {
            guard !segment.from.isEmpty, !segment.to.isEmpty,
                  segment.from.count <= 4, segment.to.count <= 4
            else { continue }

            let from = bare(segment.from.joined(separator: " "))
            let to = bare(segment.to.joined(separator: " "))
            guard !from.isEmpty, !to.isEmpty, from.lowercased() != to.lowercased() else { continue }

            if Orthography.toBritish(from).lowercased() == Orthography.toBritish(to).lowercased() { continue }
            if expandContractions(from).lowercased() == expandContractions(to).lowercased() { continue }

            // A near-identical respelling is a typo fix, not a phrasing. 0.85 is
            // VocabularyCorrector's multi-word bar, borrowed for the same reason:
            // above it the two strings are the same word.
            let similarity = VocabularyCorrector.similarity(
                VocabularyCorrector.normalise(from), VocabularyCorrector.normalise(to)
            )
            if similarity >= 0.85 { continue }

            out.append(StylePhrasing(from: from, to: to))
            // Three per correction. One heavily rewritten paragraph should not
            // be able to fill the table on its own.
            if out.count == 3 { break }
        }
        return out
    }

    // MARK: - Lexicons

    /// Contraction to expansion. Used three ways: to spot a contraction, to spot
    /// an expansion, and to tell whether a diff segment is a contraction change
    /// rather than a change of words.
    static let contractionExpansions: [String: String] = [
        "don't": "do not", "doesn't": "does not", "didn't": "did not",
        "isn't": "is not", "aren't": "are not", "wasn't": "was not",
        "weren't": "were not", "won't": "will not", "wouldn't": "would not",
        "shouldn't": "should not", "couldn't": "could not", "can't": "cannot",
        "haven't": "have not", "hasn't": "has not", "hadn't": "had not",
        "it's": "it is", "that's": "that is", "there's": "there is",
        "here's": "here is", "what's": "what is", "let's": "let us",
        "i'm": "i am", "i'll": "i will", "i've": "i have", "i'd": "i would",
        "you're": "you are", "you'll": "you will", "you've": "you have",
        "we're": "we are", "we'll": "we will", "we've": "we have",
        "they're": "they are", "they'll": "they will", "they've": "they have",
        "he's": "he is", "she's": "she is", "who's": "who is",
    ]

    private static let expansionForms: Set<String> = Set(contractionExpansions.values)

    /// Register markers. Short lists, and only ever consulted on both sides of
    /// an actual swap — see `formality`.
    static let casualMarkers: Set<String> = [
        "hey", "hi", "yeah", "yep", "nah", "cheers", "thanks", "no worries",
        "cool", "sure thing", "catch you", "talk soon",
    ]

    static let formalMarkers: Set<String> = [
        "dear", "hello", "greetings", "thank you", "regards", "kind regards",
        "sincerely", "certainly", "apologies", "please find", "best wishes",
        "yours faithfully",
    ]

    // MARK: - Text helpers

    static func tokens(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Sentence-ish. Splits on terminal punctuation and on line breaks, which
    /// matters more than it sounds: a bullet list has no full stops and is not
    /// one forty-word sentence.
    static func sentences(of text: String) -> [String] {
        text.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Trims punctuation off the ends of a phrase and squeezes inner runs of
    /// whitespace, so "hi team," and "hi team" are the same phrasing.
    static func bare(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Both apostrophes. The recogniser emits a straight quote and macOS
    /// substitutes a curly one as you type, so a correction routinely contains
    /// one of each and a check that knows only about "'" sees no contractions at
    /// all in half the text it is given.
    static func normaliseApostrophes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
    }

    static func contractionCount(_ text: String) -> Int {
        let lower = normaliseApostrophes(text).lowercased()
        return tokens(of: lower)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'"))) }
            .filter { contractionExpansions[$0] != nil }
            .count
    }

    static func expansionCount(_ text: String) -> Int {
        let lower = " " + normaliseApostrophes(text).lowercased() + " "
        return expansionForms.reduce(0) { total, form in
            total + lower.components(separatedBy: " \(form) ").count - 1
        }
    }

    static func expandContractions(_ text: String) -> String {
        var out = normaliseApostrophes(text)
        for (contraction, expansion) in contractionExpansions {
            out = out.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: contraction))\\b",
                with: expansion,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }
}

// MARK: - Observation

/// What a single correction says. Every field optional, because most
/// corrections are silent about most traits.
public struct StyleObservation: Sendable, Equatable {

    public let spelling: SpellingConvention?
    public let contractions: Bool?
    public let formality: Formality?
    public let oxfordComma: Bool?
    public let exclamations: Bool?
    public let sentenceWords: Double?
    public let phrasings: [StylePhrasing]

    public static let none = StyleObservation(
        spelling: nil, contractions: nil, formality: nil, oxfordComma: nil,
        exclamations: nil, sentenceWords: nil, phrasings: []
    )

    public var isEmpty: Bool {
        spelling == nil && contractions == nil && formality == nil
            && oxfordComma == nil && exclamations == nil && sentenceWords == nil
            && phrasings.isEmpty
    }

    public init(
        spelling: SpellingConvention?,
        contractions: Bool?,
        formality: Formality?,
        oxfordComma: Bool?,
        exclamations: Bool?,
        sentenceWords: Double?,
        phrasings: [StylePhrasing]
    ) {
        self.spelling = spelling
        self.contractions = contractions
        self.formality = formality
        self.oxfordComma = oxfordComma
        self.exclamations = exclamations
        self.sentenceWords = sentenceWords
        self.phrasings = phrasings
    }
}

// MARK: - Diff

/// Word-level diff, only as much of one as the detectors need.
///
/// Tokens are matched on a normalised form — lowercased, outer punctuation
/// stripped — so "team," and "team" are the same word. That is what keeps the
/// diff reporting changes of *wording* rather than changes of typography;
/// punctuation habits are read off the whole text instead, where they belong.
public enum StyleDiff {

    /// A run that differs. Either side may be empty: an insertion has no `from`,
    /// a deletion has no `to`.
    public struct Segment: Sendable, Equatable {
        public let from: [String]
        public let to: [String]
    }

    /// Longest common subsequence, backtracked into runs.
    ///
    /// O(n·m) in time and space, which is fine for a dictation — a long one is
    /// 200 words. Past `maximumTokens` it bails to a single whole-text segment
    /// rather than allocating a million-cell table for a pasted document; that
    /// segment is too long to become a phrasing, so the effect is that a giant
    /// paste teaches nothing rather than that it hangs.
    public static let maximumTokens = 400

    public static func segments(_ before: [String], _ after: [String]) -> [Segment] {
        guard before != after else { return [] }
        guard before.count <= maximumTokens, after.count <= maximumTokens else {
            return [Segment(from: before, to: after)]
        }

        let a = before.map(key), b = after.map(key)
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty, !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lengths[i][j] = a[i] == b[j]
                        ? lengths[i + 1][j + 1] + 1
                        : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }

        var out: [Segment] = []
        var pendingFrom: [String] = [], pendingTo: [String] = []
        func flush() {
            if !pendingFrom.isEmpty || !pendingTo.isEmpty {
                out.append(Segment(from: pendingFrom, to: pendingTo))
                pendingFrom = []; pendingTo = []
            }
        }

        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                flush()
                i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                pendingFrom.append(before[i]); i += 1
            } else {
                pendingTo.append(after[j]); j += 1
            }
        }
        while i < a.count { pendingFrom.append(before[i]); i += 1 }
        while j < b.count { pendingTo.append(after[j]); j += 1 }
        flush()
        return out
    }

    /// The form two tokens are considered equal by.
    static func key(_ token: String) -> String {
        StyleLearner.normaliseApostrophes(token)
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
    }
}
