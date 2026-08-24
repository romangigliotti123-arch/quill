import Foundation

/// What one correction should teach.
///
/// # Why this is the part that makes the app get better
///
/// Three separate measurements said there is nothing to mine from a dictation
/// history on its own. Harvesting jargon from Roman's 85 dictations proposed
/// exactly one word, and it was his own pronunciation rather than a missing
/// term. Looking for retraction cues found two genuine self-corrections in 85,
/// both already handled, while the cue words themselves — "actually", "I mean" —
/// were ordinary speech five times out of seven. Looking for repeated phrases
/// worth a snippet found four, all of them connectives like "and then they can".
///
/// A transcript records what the recogniser *did*. It cannot say what was wrong
/// with it. Only the user can, and the only moment they do is when they correct
/// something — which is why that moment has to be worth as much as possible.
///
/// So a correction feeds two things, not one:
///
///  1. **The style profile**, through `StyleLearner` — spelling, contractions,
///     tone, the phrasings pairs. This changes how the model cleanup writes.
///  2. **The Dictionary**, which is the one that changes what is *heard*. The
///     terms in it are handed to `SpeechAnalyzer` as contextual strings, so they
///     bias recognition itself. A word learned here does not get corrected after
///     the fact next time — it comes out right.
///
/// Only (2) makes recognition better, and nothing in the app was feeding it from
/// use. `VocabularyHarvest` reads the filesystem — project folders, git remotes —
/// which is a good source and a fixed one: it knows the same words on day 400 as
/// on day 1.
///
/// # Proposed, never applied
///
/// Same rule `VocabularyHarvest` already follows, and for a stronger reason here.
/// A Dictionary entry biases every future dictation towards that word, so a
/// wrong one does not sit inertly — it actively pulls speech towards a mistake.
/// One typed correction is not evidence enough to do that silently.
public enum CorrectionLearning {

    /// Whether a word is already ordinary English. Behind a seam because the real
    /// one asks `NSSpellChecker`, whose answer depends on the languages installed
    /// on the machine running it.
    public typealias KnownWord = @Sendable (String) -> Bool

    public struct Outcome: Equatable, Sendable {
        /// Words worth offering for the Dictionary: they appear in what the user
        /// wrote, not in what Quill produced, and no dictionary knows them.
        public let dictionaryCandidates: [String]
    }

    /// What changed, and what to do about it.
    ///
    /// - Parameter existingTerms: the Dictionary as it stands, so a word already
    ///   in it is not offered twice.
    public static func learn(
        was: String,
        now: String,
        existingTerms: [String],
        isKnownWord: KnownWord
    ) -> Outcome {
        let before = Set(words(in: was).map { $0.lowercased() })
        let known = Set(existingTerms.flatMap { $0.split(separator: " ").map { $0.lowercased() } })

        var candidates: [String] = []
        var seen = Set<String>()
        for word in words(in: now) {
            let key = word.lowercased()
            // Only words the correction introduced. A word that was already there
            // was not what the user was fixing.
            if before.contains(key) { continue }
            if known.contains(key) { continue }
            if seen.contains(key) { continue }
            // Two letters is an abbreviation or a typo, and the recogniser does
            // not mishear those into something a dictionary would fix.
            guard word.count >= 3 else { continue }
            if isKnownWord(word) { continue }
            seen.insert(key)
            candidates.append(word)
        }
        return Outcome(dictionaryCandidates: candidates)
    }

    /// Letters, apostrophes and internal hyphens. Punctuation and digits are not
    /// words a dictionary can bias towards.
    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-'")) }
            .filter { !$0.isEmpty }
    }
}

public extension Notification.Name {
    /// A dictation was corrected, so anything showing the history should redraw.
    static let quillHistoryChanged = Notification.Name("com.romangigliotti.quill.historyChanged")
    /// A correction introduced words no dictionary knows. The object is
    /// `[String]`. Proposed to the user, never added on their behalf — a
    /// Dictionary term biases every future dictation towards that word, so a
    /// wrong one does not sit inertly, it pulls speech towards a mistake.
    static let quillDictionaryCandidates = Notification.Name("com.romangigliotti.quill.dictionaryCandidates")
}
