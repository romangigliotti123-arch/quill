import Foundation

/// Decides whether an utterance is something to type or something to do.
///
/// # Why this is the most conservative file in the app
///
/// The two failure modes are not symmetric, and nothing else about the design
/// makes sense until that is agreed.
///
/// Treating a command as content types "make that shorter" into a document. The
/// user sees it immediately, deletes five words, and is mildly annoyed.
///
/// Treating content as a command *deletes what they said*. The sentence never
/// arrives, a transform runs on some unrelated earlier text, and the user is left
/// looking at a document that changed in a way they did not ask for, with no
/// record of the words they lost. They may not even notice until later.
///
/// So this router is precision-first to the point of being obtuse. It fires only
/// when the *entire* utterance is an instruction, and it would rather miss a real
/// command ten times than eat one sentence. Every guard below exists because of a
/// specific sentence it must not swallow, and the sentence is named.
///
/// # The three ways to run a transform, in order of how much they are trusted
///
/// 1. **A hotkey.** Unambiguous — the user pressed a key. `CommandRouter` is not
///    involved at all.
/// 2. **The wake word.** "Quill, make that shorter." A word nobody dictates by
///    accident, so everything after it is an instruction, including instructions
///    Quill has no transform for.
/// 3. **A bare spoken instruction.** "Make that shorter." This is the convenient
///    one and the dangerous one, and it is the only path the guards apply to.
///    It fires only for transforms that already exist — a bare utterance is never
///    allowed to become a free-form instruction, because that path has no
///    matching step left to be wrong about.
///
/// # What the caller must still do
///
/// A routing decision is not permission to throw the words away. `Routing`
/// carries `spokenText` in every case, and `TransformEngine` never destroys the
/// target text until it has a result in hand. If a transform cannot run, the
/// document is exactly as it was.
public struct CommandRouter: Sendable {

    // MARK: - Types

    public enum Mode: Sendable, Equatable {
        /// The utterance arrived as ordinary dictation. Full guards.
        case automatic
        /// The user held the command key, or said the wake word. They have
        /// already told us this is an instruction, so the guards — which exist
        /// only to answer "is this an instruction?" — have nothing left to do.
        case explicit
    }

    public enum Decision: Sendable, Equatable {
        /// Type it. The overwhelmingly common answer, and the safe one.
        case content
        case transform(Transform)
        /// An instruction with no matching transform, reachable only from
        /// `.explicit`. The engine runs it as a one-off with no offline recipe.
        case freeform(instruction: String)
    }

    /// Why the router decided what it decided.
    ///
    /// A case per rule rather than a string, so tests can assert on the *reason*
    /// and not just the answer. A router that returns `.content` for the wrong
    /// reason is one edit away from returning `.transform`.
    public enum Reason: Sendable, Equatable {
        case empty
        case exactTrigger(String)
        case wakeWord
        case explicitMode
        case containsQuotedOrLiteralText
        case moreThanOneSentence
        case compoundInstruction(String)
        case narrativeMarker(String)
        case tooLong(words: Int, limit: Int)
        case noCommandVerb
        case noReferent
        case noMatchingTransform
        case leftoverContent(words: [String])
        case grammarMatch

        public var description: String {
            switch self {
            case .empty:                        return "nothing was said"
            case .exactTrigger(let phrase):     return "the whole utterance is the trigger \"\(phrase)\""
            case .wakeWord:                     return "it started with the wake word"
            case .explicitMode:                 return "the command key was held"
            case .containsQuotedOrLiteralText:  return "it contains quoted or literal text"
            case .moreThanOneSentence:          return "it is more than one sentence"
            case .compoundInstruction(let w):   return "it joins two clauses with \"\(w)\""
            case .narrativeMarker(let w):       return "it reads as narration — \"\(w)\""
            case .tooLong(let n, let limit):    return "\(n) words, over the \(limit)-word limit for a command"
            case .noCommandVerb:                return "it does not start with a command verb"
            case .noReferent:                   return "it never refers to existing text"
            case .noMatchingTransform:          return "no transform matches it"
            case .leftoverContent(let words):   return "it carries content beyond the instruction — \(words.joined(separator: " "))"
            case .grammarMatch:                 return "verb, referent and a matching transform, and nothing else"
            }
        }
    }

    public struct Routing: Sendable, Equatable {
        public let decision: Decision
        /// Always the utterance as spoken. The caller keeps this whatever the
        /// decision, so a wrong answer here is recoverable rather than lossy.
        public let spokenText: String
        public let reason: Reason

        public var isCommand: Bool {
            if case .content = decision { return false }
            return true
        }
    }

    // MARK: - Tuning

    /// Above this, it is prose. Measured against the built-in triggers: the
    /// longest is "turn that into bullet points" at five words, and the longest
    /// plausible spoken instruction — "make that a numbered list instead" — is
    /// six. Twelve is double the real ceiling, which is the right kind of slack:
    /// generous enough that no real command is refused for length, tight enough
    /// that a dictated sentence almost never fits.
    public var wordLimit: Int
    /// How much unaccounted-for content an utterance may carry and still be an
    /// instruction.
    ///
    /// Zero. Every word must be explained by the verb, a referent, a function
    /// word or the transform's own keywords, or the utterance is typed.
    ///
    /// One was tried and is wrong. "Make it the last one on the list" is a
    /// sentence a person dictates; it has the verb, the referent and the keyword
    /// "list", and only "on" is left over. At a limit of one it fires the bullet
    /// transform and the sentence is gone. The forgiveness that a limit was
    /// meant to provide belongs in `functionWords`, where it is a named,
    /// reviewable list rather than a budget any word can spend.
    public var leftoverLimit: Int
    /// Said before an instruction to make it unambiguous.
    public var wakeWord: String

    public init(wordLimit: Int = 12, leftoverLimit: Int = 0, wakeWord: String = "quill") {
        self.wordLimit = wordLimit
        self.leftoverLimit = leftoverLimit
        self.wakeWord = wakeWord
    }

    // MARK: - Routing

    public func route(_ utterance: String,
                      transforms: [Transform],
                      mode: Mode = .automatic) -> Routing {

        let spoken = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            return Routing(decision: .content, spokenText: utterance, reason: .empty)
        }

        let usable = transforms.filter { $0.isEnabled && !$0.instruction.isEmpty }
        var tokens = Self.tokenise(spoken)
        var mode = mode
        var wakeReason: Reason?

        // 1. Wake word. Checked before anything else because it is the user
        //    explicitly overriding every heuristic below, and because it is the
        //    only way to reach a free-form instruction by voice.
        if let stripped = Self.stripWakeWord(wakeWord, from: tokens) {
            tokens = stripped
            mode = .explicit
            wakeReason = .wakeWord
            guard !tokens.isEmpty else {
                // "Quill." on its own. Nothing to do, and typing the word back
                // would be worse than doing nothing.
                return Routing(decision: .content, spokenText: spoken, reason: .empty)
            }
        }

        // 2. An exact whole-utterance trigger, which is the strongest signal
        //    available and the only one that is trusted before the guards.
        //
        //    Trusted first because the trigger list is authored, not inferred:
        //    a built-in trigger was written to be unmistakable, and a
        //    user-defined one is a phrase they typed into a box specifically so
        //    that saying it would run this transform. Matching the *whole*
        //    utterance is what keeps it safe — "no wait, make that Carlo"
        //    contains "make that" and is not an exact match for anything.
        let polite = Self.stripPoliteness(tokens)
        if let hit = Self.exactTriggerMatch(polite, in: usable) {
            return Routing(decision: .transform(hit.transform),
                           spokenText: spoken,
                           reason: wakeReason ?? .exactTrigger(hit.phrase))
        }

        // 3. Explicit mode skips the guards entirely — they answer a question
        //    the user has already answered.
        if mode == .explicit {
            if let match = Self.bestKeywordMatch(polite, in: usable) {
                return Routing(decision: .transform(match.transform),
                               spokenText: spoken,
                               reason: wakeReason ?? .explicitMode)
            }
            return Routing(decision: .freeform(instruction: Self.rebuild(polite, from: spoken)),
                           spokenText: spoken,
                           reason: wakeReason ?? .explicitMode)
        }

        // 4. Hard content guards. Each one is a shape that an instruction never
        //    has and dictated prose regularly does.
        if let guardReason = Self.contentGuard(spoken, tokens: tokens) {
            return Routing(decision: .content, spokenText: spoken, reason: guardReason)
        }

        if tokens.count > wordLimit {
            return Routing(decision: .content, spokenText: spoken,
                           reason: .tooLong(words: tokens.count, limit: wordLimit))
        }

        // 5. The grammar: a command verb at the front, and a referent to the
        //    text it acts on. Both are required, and the verb must be *first*.
        //
        //    Anchoring the verb is what separates "make that a bullet list" from
        //    "send it to Noah, no wait, make that Carlo" — the self-correction
        //    idiom and the command idiom are the same three words, and their
        //    position in the utterance is the only thing that tells them apart.
        guard let verb = polite.first, Self.commandVerbs.contains(verb) else {
            return Routing(decision: .content, spokenText: spoken, reason: .noCommandVerb)
        }
        guard polite.contains(where: { Self.referents.contains($0) }) else {
            return Routing(decision: .content, spokenText: spoken, reason: .noReferent)
        }

        guard let match = Self.bestKeywordMatch(polite, in: usable) else {
            // An instruction Quill has no transform for. It does not become a
            // free-form request, because at this point the only evidence that it
            // is an instruction at all is the heuristic that just failed to find
            // a match. Say it instead.
            return Routing(decision: .content, spokenText: spoken, reason: .noMatchingTransform)
        }

        // 6. Everything left over after the verb, the referent, the function
        //    words and the transform's own keywords have been accounted for.
        //
        //    This is the guard for "make it more formal and mention the deposit",
        //    where the instruction is real but is carrying content that would be
        //    silently dropped. Refusing costs the user a retry; accepting costs
        //    them the words "mention the deposit".
        let leftover = polite.filter {
            $0 != verb && !Self.referents.contains($0)
                && !Self.functionWords.contains($0) && !match.matched.contains($0)
        }
        guard leftover.count <= leftoverLimit else {
            return Routing(decision: .content, spokenText: spoken,
                           reason: .leftoverContent(words: leftover))
        }

        return Routing(decision: .transform(match.transform), spokenText: spoken, reason: .grammarMatch)
    }

    // MARK: - Guards

    /// Shapes that an instruction does not have.
    static func contentGuard(_ spoken: String, tokens: [String]) -> Reason? {
        // Quoted text, an address or a link. Someone is dictating a literal.
        if spoken.contains("\"") || spoken.contains("\u{201C}")
            || spoken.contains("@") || spoken.lowercased().contains("http") {
            return .containsQuotedOrLiteralText
        }

        // Two sentences. A spoken command is one clause; the moment there is a
        // full stop with words after it, something is being narrated.
        if hasInteriorSentenceBreak(spoken) { return .moreThanOneSentence }

        // A conjunction joins the instruction to something else, and that
        // something else is content this router would throw away.
        for word in ["and", "then", "also", "plus", "but", "because", "so"]
        where tokens.contains(word) {
            return .compoundInstruction(word)
        }

        // Reported speech. "Tell him to make it more formal" is a sentence about
        // an instruction, not an instruction.
        for word in ["said", "says", "told", "asked", "tell", "ask", "wrote", "think", "thinks"]
        where tokens.contains(word) {
            return .narrativeMarker(word)
        }

        return nil
    }

    /// A sentence terminator with a word after it. Abbreviations do not count —
    /// "e.g." and "9 a.m." are not sentence breaks, and a naive scan for "." is
    /// wrong often enough in dictation to matter.
    static func hasInteriorSentenceBreak(_ text: String) -> Bool {
        let pattern = "[.!?]\\s+\\S"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return false }
        // Ignore a terminator that is part of an abbreviation like "e.g. this".
        let head = text[text.startIndex ..< range.lowerBound]
        let lastWord = head.split(separator: " ").last.map(String.init) ?? ""
        return !lastWord.contains(".") || lastWord.count > 3
    }

    // MARK: - Matching

    struct KeywordMatch {
        let transform: Transform
        /// The tokens this transform's keywords accounted for.
        let matched: Set<String>
    }

    struct TriggerMatch {
        let transform: Transform
        let phrase: String
    }

    /// The whole utterance, word for word, is one of the transform's triggers.
    static func exactTriggerMatch(_ tokens: [String], in transforms: [Transform]) -> TriggerMatch? {
        guard !tokens.isEmpty else { return nil }
        for transform in transforms {
            for phrase in transform.triggers
            where stripPoliteness(tokenise(phrase)) == tokens {
                return TriggerMatch(transform: transform, phrase: phrase)
            }
        }
        return nil
    }

    /// The transform whose keywords appear in the utterance.
    ///
    /// Ordered by how much of the utterance each explains, then by how often the
    /// transform is used, then by name — so the answer is stable across runs and
    /// a test cannot pass by accident of dictionary ordering.
    static func bestKeywordMatch(_ tokens: [String], in transforms: [Transform]) -> KeywordMatch? {
        let set = Set(tokens)
        let scored: [KeywordMatch] = transforms.compactMap { transform in
            let hit = Set(transform.keywords.map(normalise).filter { !$0.isEmpty }).intersection(set)
            guard !hit.isEmpty else { return nil }
            return KeywordMatch(transform: transform, matched: hit)
        }
        return scored.max { a, b in
            if a.matched.count != b.matched.count { return a.matched.count < b.matched.count }
            if a.transform.useCount != b.transform.useCount { return a.transform.useCount < b.transform.useCount }
            return a.transform.name > b.transform.name
        }
    }

    // MARK: - Lexicons

    /// Verbs that can start an instruction.
    ///
    /// Closed and short on purpose. Every entry is a word that, at the *front* of
    /// a whole utterance and followed by a referent, is an order rather than a
    /// statement. "Send", "add", "write" and "say" are all missing and all stay
    /// missing — "send it to Carlo" and "add that to the invoice" are things
    /// people dictate.
    static let commandVerbs: Set<String> = [
        "make", "turn", "change", "convert", "rewrite", "reword", "rephrase",
        "format", "reformat", "shorten", "summarise", "summarize", "condense",
        "tidy", "clean", "fix", "correct", "proofread", "polish", "punctuate",
        "capitalise", "capitalize", "bullet", "number", "sum", "trim", "tighten",
        "formalise", "formalize", "expand",
    ]

    /// Words that point at text that already exists. Without one of these the
    /// utterance is not about anything, which means it is content.
    static let referents: Set<String> = [
        "that", "this", "it", "these", "those", "them", "above", "last", "previous",
    ]

    /// Words that carry no content and so are not counted as leftovers.
    ///
    /// This list is the *only* forgiveness the grammar path has, which is why it
    /// is a list and not a threshold: every word in it is a word someone
    /// deliberately decided cannot change what an instruction means. Adding a
    /// word here widens what fires. "On", "at" and "from" are absent for that
    /// reason — they attach an instruction to something else, and something else
    /// is content.
    static let functionWords: Set<String> = [
        "a", "an", "the", "to", "into", "as", "of", "more", "less", "much",
        "very", "bit", "lot", "far", "way", "slightly", "somewhat", "little",
        "up", "down", "please", "instead", "one", "sound", "sounds", "look",
        "looks", "reads", "be", "all", "just", "my", "me", "its",
    ]

    /// Stripped from the front of an utterance before the verb check.
    ///
    /// Only from the front, and only in a run. "You" is here so "can you make
    /// that shorter" reaches the verb, and stripping it only at the front is
    /// what keeps "you said make it shorter" as content — there the run stops at
    /// "said", which is not a verb, so the utterance is typed.
    static let politeness: Set<String> = [
        "please", "can", "could", "would", "will", "you", "hey", "ok", "okay",
        "now", "just", "quickly", "actually", "maybe", "lets", "let", "us",
    ]

    static func stripPoliteness(_ tokens: [String]) -> [String] {
        var out = tokens[...]
        while let first = out.first, politeness.contains(first), out.count > 1 {
            out = out.dropFirst()
        }
        return Array(out)
    }

    static func stripWakeWord(_ wake: String, from tokens: [String]) -> [String]? {
        let wake = normalise(wake)
        guard !wake.isEmpty else { return nil }
        var index = 0
        // "Hey Quill, …" as well as "Quill, …".
        if tokens.first == "hey", tokens.count > 1 { index = 1 }
        guard tokens.indices.contains(index), tokens[index] == wake else { return nil }
        return Array(tokens.dropFirst(index + 1))
    }

    // MARK: - Tokens

    /// Lowercased words, punctuation discarded.
    ///
    /// Punctuation is discarded rather than respected because the recogniser
    /// invents it: the same spoken instruction arrives as "Make that shorter.",
    /// "make that shorter" and "Make that, shorter" across three dictations, and
    /// a router that treats those differently is a router that works
    /// intermittently.
    static func tokenise(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { normalise(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Lowercased, letters and digits only. Apostrophes are dropped rather than
    /// kept, so "let's" and "lets" are one token.
    static func normalise(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.lowercased().unicodeScalars
        where CharacterSet.alphanumerics.contains(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    /// The instruction to send to the model, in the user's own words.
    ///
    /// Rebuilt from the original string rather than from the tokens, because the
    /// tokens have lost their punctuation and capitalisation and the model reads
    /// better prose than "make that a bullet list but keep the names". The
    /// tokens are only used to find where the instruction starts.
    static func rebuild(_ tokens: [String], from spoken: String) -> String {
        guard let first = tokens.first else { return spoken }
        // Find the first word of the surviving token run in the original text,
        // so a stripped wake word or politeness prefix does not travel with it.
        let words = spoken.split(whereSeparator: { $0.isWhitespace })
        for (index, word) in words.enumerated() where normalise(String(word)) == first {
            return words[index...].joined(separator: " ")
        }
        return spoken
    }
}
