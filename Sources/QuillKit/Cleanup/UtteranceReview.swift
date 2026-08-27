import Foundation

/// The last look at the whole sentence before it leaves for the document.
///
/// Everything upstream of here reasons about a *span*: a word, a pair, a run
/// between two cues. That is the right shape for the work they each do, and it
/// is also their shared blind spot — a rule that is locally correct on the span
/// it examined can still hand back an utterance that, read end to end, has lost
/// something the speaker said.
///
/// This is the case that made the file exist. Roman's own history, 24 Aug 2026,
/// offline, no model anywhere near it:
///
///     said:     "...They all look bad. They don't look realistic. I want the
///                photos of the clothes to actually look realistic. Not just
///                like cartoons..."
///     inserted: "...They all look bad. They don't look realistic. Not just
///                like cartoons..."
///
/// `resolveParallelRestarts` matched two words across a full stop and deleted the
/// eleven-word sentence between them. That specific rule has since been given a
/// sentence-boundary guard, and the guard is the real fix — but the reason this
/// type exists is that *nothing was watching*. The pass was trusted, it was
/// wrong, and the only record that eleven words had gone was a `rawText` field
/// in a JSON file nobody reads.
///
/// So this does not try to be clever. It re-reads the finished utterance against
/// what was actually said and asks one question — **did we lose anything we
/// cannot account for?** — and when the answer is yes it throws away the clever
/// answer and ships the plain one. It is a backstop over every cleanup pass that
/// exists now and every one added later, which is worth more than a second
/// implementation of any single rule.
///
/// The bar it enforces is the one the app already states about itself in
/// `DictationCoordinator`: losing words is the one thing this app may never do.
public enum UtteranceReview {

    /// What the review decided, and why.
    ///
    /// The reason is carried rather than logged in here so the caller owns the
    /// logging — this type is pure, which is what makes it testable without a
    /// data directory. See `test-harness-data-isolation` for why that matters in
    /// this project.
    public struct Verdict: Sendable, Equatable {
        /// The text to insert.
        public var text: String
        /// True when a cleanup pass was overruled and the plain text shipped.
        public var revertedUnjustifiedDeletion: Bool
        /// Human-readable, for the log line and for history. Nil when the
        /// candidate passed untouched.
        public var note: String?

        public init(text: String, revertedUnjustifiedDeletion: Bool = false, note: String? = nil) {
            self.text = text
            self.revertedUnjustifiedDeletion = revertedUnjustifiedDeletion
            self.note = note
        }
    }

    /// Reads `candidate` against `plain` and returns whichever should be typed.
    ///
    /// - Parameters:
    ///   - candidate: what the cleanup chain produced — possibly rewritten by the
    ///     offline resolver or by the model pass.
    ///   - plain: the deterministic text from `FastCleaner`. It is the baseline
    ///     because it only ever removes standalone filler and exact adjacent
    ///     repeats; it has no rule that can delete a clause.
    ///   - terms: vocabulary that must survive verbatim, passed through to the
    ///     alignment so a protected word is never treated as a free deletion.
    public static func review(
        _ candidate: String, against plain: String, protecting terms: [String] = []
    ) -> Verdict {
        let candidateTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let plainTrimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing was rewritten, so there is nothing to second-guess. Still worth
        // the punctuation sweep below: an orphaned bracket comes from the
        // recogniser, not from a cleanup pass, so it is present on this path too.
        guard candidateTrimmed != plainTrimmed else {
            return Verdict(text: repairOrphanedPunctuation(in: candidateTrimmed))
        }

        // An empty rewrite is always wrong. A cleanup pass reducing a sentence to
        // nothing is not a cleaner sentence, it is a lost one.
        guard !candidateTrimmed.isEmpty else {
            return Verdict(text: repairOrphanedPunctuation(in: plainTrimmed),
                           revertedUnjustifiedDeletion: true,
                           note: "cleanup emptied the utterance")
        }

        if let lost = unjustifiedLoss(in: candidateTrimmed, from: plainTrimmed, protecting: terms) {
            return Verdict(text: repairOrphanedPunctuation(in: plainTrimmed),
                           revertedUnjustifiedDeletion: true,
                           note: "cleanup dropped \(lost) with no filler, repeat or retraction to justify it")
        }

        return Verdict(text: repairOrphanedPunctuation(in: candidateTrimmed))
    }

    // MARK: - Did we lose anything we cannot account for?

    /// Returns a short description of the first unjustified deletion, or nil when
    /// every word that went missing has a reason.
    ///
    /// Reuses `CleanupProjection`'s alignment and its notion of a justified
    /// deletion rather than restating either. That type was written to check a
    /// *model's* output and the rules it encodes — filler, exact repetition,
    /// opening preamble, a retraction that was actually applied — are the same
    /// rules that make a deletion legitimate whoever performed it. A second
    /// implementation here would drift from it within a release.
    static func unjustifiedLoss(
        in candidate: String, from plain: String, protecting terms: [String]
    ) -> String? {
        let inTokens = SpeechToken.tokenise(plain)
        let outTokens = SpeechToken.tokenise(candidate)
        guard !inTokens.isEmpty, !outTokens.isEmpty else { return nil }

        // Cleanup that ADDED words is not this check's business and must not be
        // blocked by it: snippet expansion and the number style both legitimately
        // make the text longer, and a homophone repair swaps one word for
        // another. Alignment returns nil for anything that is not a pure
        // subsequence, and the honest answer there is "cannot judge, allow it"
        // rather than a false accusation.
        //
        // This is a deliberate hole. The check is aimed squarely at silent
        // deletion, which is the failure that actually happened and the one the
        // user cannot see. A pass that both adds and removes escapes it.
        let protectedWords = Set(terms.flatMap { $0.split(separator: " ").map { String($0).lowercased() } })
        guard let mapping = CleanupProjection.align(
            outTokens, to: inTokens, protectedWords: protectedWords
        ) else { return nil }

        guard !CleanupProjection.deletionsAreJustified(mapping: mapping, inTokens: inTokens) else {
            return nil
        }

        // Name the longest missing run rather than counting words. "dropped 11
        // words" in a log tells you something is wrong; "dropped 'I want the
        // photos of the clothes to actually look realistic'" tells you what.
        let kept = Set(mapping)
        var longest: Range<Int>?
        var start = 0
        while start < inTokens.count {
            guard !kept.contains(start) else { start += 1; continue }
            var end = start
            while end < inTokens.count, !kept.contains(end) { end += 1 }
            if end - start > (longest.map { $0.count } ?? 0) { longest = start ..< end }
            start = end
        }
        guard let run = longest else { return nil }

        let words = inTokens[run].map(\.word).joined(separator: " ")
        let shown = words.count > 60 ? String(words.prefix(57)) + "..." : words
        return "\"\(shown)\""
    }

    // MARK: - Punctuation the recogniser opened and never closed

    /// Drops a bracket or quotation mark that has no partner in the utterance.
    ///
    /// Whole-utterance by nature, which is why it lives here and not in
    /// `FastCleaner`: whether an opening bracket is orphaned is not knowable from
    /// the span it sits in, only from the end of the sentence. The recogniser
    /// emits these on dictated asides — an opening parenthesis it hears in the
    /// pause before a subordinate clause, with nothing ever closing it.
    ///
    /// Only punctuation is touched, never a word, so the worst case is a
    /// character the user would have deleted anyway. Anything balanced is left
    /// exactly as it is, including nested pairs.
    static func repairOrphanedPunctuation(in text: String) -> String {
        guard text.contains(where: { "()[]{}\"".contains($0) }) else { return text }

        var drop = Set<String.Index>()

        // Brackets: a stack per kind, so "(a [b] c" drops only the parenthesis.
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
            var stack: [String.Index] = []
            var i = text.startIndex
            while i < text.endIndex {
                let c = String(text[i])
                if c == open {
                    stack.append(i)
                } else if c == close {
                    if stack.isEmpty { drop.insert(i) } else { stack.removeLast() }
                }
                i = text.index(after: i)
            }
            drop.formUnion(stack)
        }

        // Straight double quotes have no direction, so the only safe rule is
        // parity: an odd count means one of them is not doing anything. The last
        // one goes — an unclosed quote at the end is the shape the recogniser
        // actually produces, and dropping the first would silently re-scope a
        // quotation that was opened correctly.
        let quotes = text.indices.filter { text[$0] == "\"" }
        if quotes.count % 2 == 1, let last = quotes.last { drop.insert(last) }

        guard !drop.isEmpty else { return text }

        var out = ""
        for i in text.indices where !drop.contains(i) { out.append(text[i]) }
        // Removing a bracket can leave the space that sat beside it doubled.
        return FastCleaner.collapseWhitespace(in: out).trimmingCharacters(in: .whitespaces)
    }
}
