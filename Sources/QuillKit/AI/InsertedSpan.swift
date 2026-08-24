import Foundation

/// Finding what happened to the sentence Quill inserted, after the user had a
/// go at it.
///
/// This is the pure half of watching an edit, and it is pure for the same reason
/// `StyleLearner` is: the impure version can only be checked by dictating into a
/// real app and reading the profile afterwards, which is how a learning feature
/// ships with a detector that has never once fired. Strings in, a verdict out,
/// no Accessibility, no clock, no store.
///
/// # Why it works by anchors rather than by diffing
///
/// The field holds a whole document. Quill's sentence is somewhere inside it, and
/// after an edit it is somewhere slightly different, a slightly different length,
/// with the user's cursor having moved around in between. Diffing the two whole
/// documents finds every change in all of them — including the paragraph they
/// wrote afterwards, which says nothing about how they correct dictation.
///
/// So: remember the few characters either side of where the sentence landed, find
/// those again, and read out what is now between them. What that returns is only
/// ever the span Quill itself produced.
///
/// # Only the span, deliberately
///
/// Nothing here keeps the document. The anchors are short and the verdict carries
/// the edited sentence and nothing else, because the alternative — holding a
/// user's whole email in memory to compare it later, in an app whose entire pitch
/// is that nothing leaves the machine — is not a trade worth making for a
/// spelling preference.
public enum InsertedSpan {

    /// How much context either side is enough to find the sentence again.
    ///
    /// Long enough to be unique in an ordinary document; short enough that it is
    /// not a copy of the surrounding text. 24 characters of the preceding
    /// sentence is not a document.
    static let anchorLength = 24

    public struct Anchors: Equatable, Sendable {
        /// The text immediately before where the sentence landed, truncated.
        public let left: String
        /// The text immediately after it, truncated. Empty when the sentence
        /// landed at the very end of the field, which is the common case.
        public let right: String
        /// What Quill actually inserted.
        public let inserted: String
    }

    public enum Verdict: Equatable, Sendable {
        /// The sentence is still exactly as Quill wrote it. Includes the case
        /// where the user kept it and carried on writing after it.
        case unchanged
        /// The sentence is now this. The only case that teaches anything.
        case corrected(String)
        /// Cannot tell, and saying so is the whole point. A guess here does not
        /// fail visibly — it quietly teaches the profile something the user
        /// never did.
        case notComparable(Reason)

        public enum Reason: String, Equatable, Sendable {
            /// The field never contained the sentence — the insertion did not
            /// land where we thought, or the app rewrote it on arrival.
            case notFound
            /// It appears more than once. Which copy did they edit?
            case ambiguous
            /// The anchors no longer locate anything. The user moved or deleted
            /// the surrounding text.
            case anchorsLost
            /// The sentence is gone. Deleting a dictation is not a style
            /// preference — it usually means Quill misheard entirely, or `⌥⌫`.
            case deleted
            /// What is there now is a different sentence rather than a corrected
            /// one. Learning from a rewrite teaches the tone of whatever they
            /// wrote next.
            case rewritten
        }
    }

    /// Remember where the sentence landed. Nil when the field does not contain
    /// it exactly once, in which case there is nothing to watch.
    public static func anchors(inserted: String, in field: String) -> Anchors? {
        guard !inserted.isEmpty else { return nil }
        var ranges: [Range<String.Index>] = []
        var searchFrom = field.startIndex
        while let found = field.range(of: inserted, range: searchFrom..<field.endIndex) {
            ranges.append(found)
            if ranges.count > 1 { return nil }   // ambiguous; see Reason.ambiguous
            searchFrom = found.upperBound
        }
        guard let range = ranges.first else { return nil }
        return Anchors(left: String(field[field.startIndex..<range.lowerBound].suffix(anchorLength)),
                       right: String(field[range.upperBound..<field.endIndex].prefix(anchorLength)),
                       inserted: inserted)
    }

    /// What the sentence has become in `field` now.
    public static func verdict(for anchors: Anchors, in field: String) -> Verdict {
        // Still there, untouched, wherever it has moved to. Checked first and
        // cheaply: it is the answer almost every time.
        if field.contains(anchors.inserted) { return .unchanged }

        // Anchors are matched with their inner whitespace trimmed off, because
        // deleting or replacing the text between them usually takes one of the
        // adjacent spaces with it. Anchored on the literal " Cheers." with its
        // leading space, deleting the sentence out of "Morning. <it> Cheers."
        // leaves "Morning. Cheers." — where that space no longer exists — and the
        // whole thing reads as anchors lost rather than as the deletion it is.
        // Found by writing the deletion test and watching it fail.
        let left = anchors.left.replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression)
        let right = anchors.right.replacingOccurrences(
            of: "^\\s+", with: "", options: .regularExpression)

        guard let start = onlyRange(of: left, in: field, allowEmpty: true)
        else { return .notComparable(.anchorsLost) }

        let after = field[start...]
        let candidate: Substring
        if right.isEmpty {
            // The sentence ran to the end of the field. Anything after the left
            // anchor is either the edited sentence or the edited sentence plus
            // whatever they wrote next — and there is no marker between the two,
            // so the tail is all we have.
            candidate = after
        } else {
            // First match, deliberately. If the edited sentence happens to
            // contain the anchor text the candidate comes out short, which fails
            // the ratio guard below — the conservative direction. A last match
            // would instead swallow whatever came after it.
            guard let end = after.range(of: right) else {
                return .notComparable(.anchorsLost)
            }
            candidate = after[after.startIndex..<end.lowerBound]
        }

        let edited = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if edited.isEmpty { return .notComparable(.deleted) }
        if edited == anchors.inserted.trimmingCharacters(in: .whitespacesAndNewlines) {
            return .unchanged
        }

        // A correction is a version of the same sentence. Anything far longer or
        // far shorter is a different one, and the ratio is the only signal here
        // that does not need to understand the language.
        let originalLength = Double(anchors.inserted.count)
        let ratio = Double(edited.count) / max(originalLength, 1)
        guard ratio >= 0.4, ratio <= 2.5 else { return .notComparable(.rewritten) }

        return .corrected(edited)
    }

    /// A range that occurs exactly once, or nil. Ambiguity is a refusal, not a
    /// coin toss — the wrong copy teaches the wrong lesson silently.
    private static func onlyRange(of needle: String, in haystack: String,
                                  allowEmpty: Bool) -> String.Index? {
        if needle.isEmpty { return allowEmpty ? haystack.startIndex : nil }
        var found: String.Index?
        var searchFrom = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchFrom..<haystack.endIndex) {
            if found != nil { return nil }
            found = range.upperBound
            searchFrom = range.upperBound
        }
        return found
    }
}
