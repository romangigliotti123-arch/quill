import Foundation

/// Checks a homophone pass's output, and rebuilds the result from the INPUT.
///
/// The pattern is `CleanupProjection`'s: state the contract in the prompt, then
/// enforce it in code afterwards, because a prompt is a request and a check is a
/// guarantee. What differs is how little of the model's answer is kept.
///
/// `CleanupProjection` returns the model's own text once it has been proved to
/// be the input with words removed. This does not. It reads the model's answer
/// only to learn *which listed word it chose at each position*, and then rebuilds
/// the sentence from the input, substituting exactly those words and nothing
/// else. Punctuation, capitalisation, spacing, every unlisted word — all come
/// from the input verbatim and are not the model's to change.
///
/// That makes the blast radius exactly the pair list, by construction rather than
/// by inspection. A model that returns a beautifully rewritten sentence gets the
/// same treatment as one that returns the input: only its choices between
/// `flour` and `flower` survive.
public enum HomophoneProjection {

    /// A word of the input, with whatever followed it.
    struct Token {
        var word: String        // letters and apostrophes only
        var trailing: String    // punctuation and whitespace, kept verbatim
        var leading: String     // whitespace before, kept verbatim
    }

    /// Splits into words plus the exact characters around them, so the input can
    /// be reassembled byte-for-byte when nothing is substituted.
    static func tokenise(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var leading = "", word = "", trailing = ""
        func flush() {
            guard !word.isEmpty else { return }
            tokens.append(Token(word: word, trailing: trailing, leading: leading))
            leading = ""; word = ""; trailing = ""
        }
        for ch in text {
            let isWord = ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}"
            if isWord {
                if !trailing.isEmpty { flush(); leading = trailing; trailing = "" }
                word.append(ch)
            } else if word.isEmpty {
                leading.append(ch)
            } else {
                trailing.append(ch)
            }
        }
        flush()
        if !leading.isEmpty || !trailing.isEmpty, var last = tokens.popLast() {
            last.trailing += trailing + leading
            tokens.append(last)
        }
        return tokens
    }

    /// Returns the corrected text, or nil meaning "keep the input".
    ///
    /// Never throws and never reports an error: the caller already holds a good
    /// answer, and this is only ever allowed to improve it.
    /// - Parameters:
    ///   - permitting: whether a given substitution is allowed. The default is
    ///     the hand-written pair list, which is what the offer-a-choice pass
    ///     uses. `ContextProjection` passes the generated pronunciation table
    ///     instead, because there the model proposes freely and this is the only
    ///     thing standing between a proposal and the user's document.
    ///   - maximumSubstitutions: how many words may change at once. One is the
    ///     honest answer for a mishearing; a model returning five swaps has
    ///     started rewriting, and the fact that all five happen to be homophones
    ///     does not make that the user's sentence any more.
    public static func project(
        _ raw: String,
        onto input: String,
        permitting mayReplace: (String, String) -> Bool = HomophonePairs.mayReplace,
        maximumSubstitutions: Int = .max,
        keepWhatIsAllowed: Bool = false
    ) -> String? {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }

        // Same three shapes the other pass sees from this endpoint.
        out = AIOutputGuard.stripCodeFence(out)
        out = AIOutputGuard.stripLeadingLabel(out)
        out = AIOutputGuard.stripWrappingQuotes(out)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }

        // A model that starts explaining has stopped choosing.
        if out.contains("\n\n"), !input.contains("\n\n") { return nil }

        var inTokens = tokenise(input)
        let outTokens = tokenise(out)
        guard !inTokens.isEmpty else { return nil }

        // This pass may not insert or delete a single word, so a length change is
        // a refusal on its own — no alignment, no repair, no benefit of the
        // doubt. It is the cheapest possible check and it catches a rewritten
        // sentence outright.
        guard outTokens.count == inTokens.count else { return nil }

        var substitutions = 0
        for index in inTokens.indices {
            let original = inTokens[index].word
            let proposed = outTokens[index].word
            if HomophonePairs.normalise(original) == HomophonePairs.normalise(proposed) { continue }
            // Different word. It survives only if the caller's rule permits it.
            guard mayReplace(original, proposed) else {
                // Refusing the whole answer over one bad word throws away the
                // good ones with it. Measured on Roman's own dictation: the model
                // returned "I moved the whole front end to type scripts" for
                // "I move ... to type scoops" — the dropped ending repaired, which
                // is exactly what he asked for, and "scoops" turned into
                // "scripts", which is not. All-or-nothing lost both.
                //
                // Reverting just the disallowed word is not a weaker guarantee.
                // Every surviving change is still individually verified, the word
                // count still has to match exactly, so a rewritten sentence is
                // still refused outright — only a same-shape answer with a mix of
                // good and bad swaps gets taken apart like this.
                guard keepWhatIsAllowed else { return nil }
                continue
            }
            inTokens[index].word = matchCase(of: original, applying: proposed)
            substitutions += 1
            // Refuse the whole answer rather than keeping the first N. A model
            // that changed too much was not doing this job, and taking half of
            // its output would be keeping the half we happened to look at first.
            guard substitutions <= maximumSubstitutions else { return nil }
        }

        // Nothing changed: say so, rather than handing back an identical string
        // the caller would have to compare anyway.
        guard substitutions > 0 else { return nil }

        return inTokens.map { $0.leading + $0.word + $0.trailing }.joined()
    }

    /// "Flower" -> "Flour", "FLOWER" -> "FLOUR", "flower" -> "flour".
    ///
    /// The model is told to preserve capitalisation and mostly does; relying on
    /// that would still put a lowercase word at the start of a sentence the first
    /// time it forgot. The input's casing is the input's to keep.
    static func matchCase(of original: String, applying replacement: String) -> String {
        guard let first = original.first else { return replacement }
        if original.count > 1, original.allSatisfy({ !$0.isLetter || $0.isUppercase }) {
            return replacement.uppercased()
        }
        if first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
