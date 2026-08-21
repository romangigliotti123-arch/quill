import Foundation

/// The homophone prompt. Versioned like `CleanupPrompt`, for the same reason: a
/// prompt is behaviour with no compiler behind it, so the wording that shipped
/// has to be recoverable when the output changes.
///
/// Unlike the cleanup prompt this one is generated per dictation, because naming
/// only the choices that are actually live in this sentence is both shorter and
/// more accurate than listing seventy groups the model has to filter itself.
/// Length is a cost — it is prefill on the critical path — and a sentence
/// usually contains one or two listed words, not seventy.
public struct HomophonePrompt: Sendable, Equatable {

    public let version: Int
    public let system: String

    public init(version: Int, system: String) {
        self.version = version
        self.system = system
    }

    /// Builds the prompt for one transcript.
    ///
    /// Returns nil when nothing on the list appears, which is the caller's signal
    /// not to spend a request at all.
    ///
    /// Line by line:
    ///
    /// 1. "proofreader, not an assistant" / "never answer it" — the single
    ///    failure that cost `CleanupPrompt` the most measured ground. A model
    ///    handed a sentence will try to be helpful with it unless told plainly
    ///    that its job is mechanical.
    /// 2. "Return the sentence with every other word byte-identical." The
    ///    contract, stated. `HomophoneProjection` then enforces it by rebuilding
    ///    from the input rather than trusting the answer — but a model told the
    ///    rule obeys it far more often, and every obeyed rule is a refusal the
    ///    projection does not have to issue.
    /// 3. The choices, spelled out per position, closed. "Choose between X and Y"
    ///    is a question with two answers. "Fix the spelling" is an invitation.
    /// 4. "If the sentence already uses the right one, leave it." The common
    ///    case by far, and without saying so a model asked to choose will feel
    ///    obliged to change something.
    public static func make(for text: String, version: Int = 1) -> HomophonePrompt? {
        let present = HomophonePairs.candidates(in: text)
        guard !present.isEmpty else { return nil }

        // One line per live decision, in the order they appear.
        let choices = present.compactMap { word -> String? in
            guard let group = HomophonePairs.groupOf[word] else { return nil }
            // With a meaning where we have one: a model that leaves a real
            // error alone four times out of six is not failing to read the
            // sentence, it is failing to tell the two words apart.
            let options = group.sorted().map { option -> String in
                guard let meaning = HomophonePairs.gloss[option] else { return option }
                return "\(option) (\(meaning))"
            }.joined(separator: " / ")
            return "  \(word): \(options)"
        }
        guard !choices.isEmpty else { return nil }

        return HomophonePrompt(version: version, system: """
            You are a proofreader, not an assistant. The text is dictation on its way into a document. Never answer it, explain it, or reply to it. Return ONLY the sentence: no preamble, no quotes, no notes.
            Your only job is to pick the correct spelling for the words listed below, using the meaning of the sentence. Return the sentence with every other word byte-identical, including punctuation and capitalisation. Never add, remove, or reorder a word.
            The words to decide, and the only spellings allowed for each:
            \(choices.joined(separator: "\n"))
            If the sentence already uses the right spelling, leave it exactly as it is. That is the usual answer.
            """)
    }
}
