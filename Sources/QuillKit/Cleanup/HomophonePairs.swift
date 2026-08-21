import Foundation

/// The closed list of words the homophone pass is allowed to touch.
///
/// Homophones are the largest single error class in the eval corpus — seven of
/// twenty-seven word errors — and the one class nothing else in the app can
/// reach. `VocabularyCorrector` refuses any single word the system spell checker
/// accepts, and both halves of a pair are real English by definition. The model
/// cleanup pass is contractually delete-only. So the audio is ambiguous, the
/// sentence is not, and every layer we have declines to look at the sentence.
///
/// `FastCleaner.corrections` already handles the ones a FIXED PHRASE decides —
/// "hey fever" is never right. This is for the rest, where only the sentence
/// decides, measured in Roman's own voice:
///
///     "every time Cloudflare cached something stale"
///       -> "every time Cloudflare cashed something stale"      (twice, both readings)
///
/// No table can fix that: "cashed a cheque" is correct English.
///
/// # Why a closed list rather than "fix any wrong words"
///
/// It bounds the blast radius to something checkable. A model told to fix wrong
/// words will eventually rewrite a word Roman meant, and he will not notice —
/// the failure `VocabularyCorrector` calls "worse than leaving a wrong one".
/// A model asked "is this *flour* or *flower*?" cannot do that, because those
/// are the only two answers it is permitted to give, and
/// `HomophoneProjection` enforces it afterwards rather than trusting it.
///
/// # What is deliberately not here
///
/// **Function words.** to/too/two, their/there/they're, your/you're, its/it's.
/// They are in half of all sentences, so including them means the gate below
/// fires on nearly every dictation and the pass stops being cheap. They are also
/// the ones a recogniser gets right most of the time, because the grammar around
/// them is strong. Cost is high, yield is low.
///
/// **Anything already decided by a fixed phrase.** If `FastCleaner.corrections`
/// can settle it for free, it should, and this list should not compete.
public enum HomophonePairs {

    /// Groups of words that sound alike and that only context separates.
    ///
    /// Membership is what the projection checks: a word may be replaced only by
    /// another member of its own group. Groups, not pairs, because some are
    /// three-way (`peak`/`peek`/`pique`).
    public static let groups: [[String]] = [
        // Found in Roman's own dictation, 21 Aug 2026.
        ["cached", "cashed"],
        ["caching", "cashing"],

        // Found in the frozen eval corpus.
        ["flour", "flower"],
        ["flours", "flowers"],
        ["dew", "due", "dews", "dues"],
        ["read", "red"],
        ["formally", "formerly"],
        ["emigration", "immigration"],
        ["emigrant", "immigrant"],

        // The classic confusables that survive a spell checker, restricted to
        // ones plausible in what he actually dictates — client work, invoices,
        // build notes, briefs.
        ["principal", "principle"],
        ["principals", "principles"],
        // complement/compliment is deliberately absent. Benched against the real
        // endpoint it was the only pair that caused damage, and it did so twice
        // — turning a correct "A compliment from a client is rare" into
        // "A complement from a client is rare", with and without a gloss telling
        // it that compliment means praise. A pair the model cannot decide does
        // not belong on a list of decisions we hand it; the loss is that those
        // stay wrong, which is what they already were.
        // "complementary colours" is still fixed for free by
        // FastCleaner.corrections, where a fixed phrase settles it.
        ["discreet", "discrete"],
        ["stationary", "stationery"],
        ["affect", "effect"],
        ["affects", "effects"],
        ["affected", "effected"],
        ["elicit", "illicit"],
        ["eminent", "imminent"],
        ["allude", "elude"],
        ["ensure", "insure"],
        ["loose", "lose"],
        ["loosing", "losing"],
        ["past", "passed"],
        ["lead", "led"],
        ["cite", "site", "sight"],
        ["cites", "sites", "sights"],
        ["council", "counsel"],
        ["coarse", "course"],
        ["capital", "capitol"],
        ["desert", "dessert"],
        ["peace", "piece"],
        ["peaces", "pieces"],
        ["peak", "peek", "pique"],
        ["plain", "plane"],
        ["role", "roll"],
        ["sole", "soul"],
        ["stake", "steak"],
        ["waist", "waste"],
        ["weather", "whether"],
        ["weak", "week"],
        ["brake", "break"],
        ["bare", "bear"],
        ["board", "bored"],
        ["fair", "fare"],
        ["foreword", "forward"],
        ["hoard", "horde"],
        ["pedal", "peddle"],
        ["pore", "pour"],
        ["review", "revue"],
        ["summary", "summery"],
        ["through", "threw"],
        ["whose", "who's"],
        ["aloud", "allowed"],
        ["altar", "alter"],
        ["assent", "ascent"],
        ["born", "borne"],
        ["canvas", "canvass"],
        ["censor", "sensor"],
        ["chord", "cord"],
        ["current", "currant"],
        ["premier", "premiere"],
        ["straight", "strait"],
        ["tail", "tale"],
        ["team", "teem"],
        ["tide", "tied"],
        ["vain", "vane", "vein"],
        ["wave", "waive"],
    ]

    /// What each word means, for the prompt.
    ///
    /// Added after the first bench against the real endpoint scored 2/6 fixed
    /// and 1/6 damaged with the options listed bare. The failures read like a
    /// model that does not know which word is which rather than one that cannot
    /// read the sentence — it left four real errors alone and then confidently
    /// turned a correct "compliment" into "complement". Naming the meaning is
    /// the cheapest thing that could fix that, and it costs a handful of prefill
    /// tokens on a request that only fires when a listed word is present.
    ///
    /// Only the groups that are genuinely easy to confuse carry a gloss; the
    /// prompt falls back to the bare spellings for the rest.
    static let gloss: [String: String] = [
        "cached": "stored for reuse", "cashed": "exchanged for money",
        "caching": "storing for reuse", "cashing": "exchanging for money",
        "flour": "the baking ingredient", "flower": "the plant",
        "dew": "morning moisture", "dews": "morning moisture",
        "due": "owed or expected", "dues": "fees owed",
        "principal": "main, or the head of something", "principle": "a rule or belief",
        "principals": "main people", "principles": "rules or beliefs",
        "complement": "something that completes or goes well with",
        "compliment": "a piece of praise",
        "complements": "completes or goes well with", "compliments": "praises",
        "complementary": "going well together", "complimentary": "free, or praising",
        "discreet": "careful not to attract attention", "discrete": "separate and distinct",
        "stationary": "not moving", "stationery": "paper and writing supplies",
        "affect": "to influence (verb)", "effect": "a result (noun)",
        "affects": "influences (verb)", "effects": "results (noun)",
        "elicit": "to draw out", "illicit": "illegal",
        "eminent": "distinguished", "imminent": "about to happen",
        "loose": "not tight", "lose": "to misplace or be beaten",
        "loosing": "releasing", "losing": "misplacing or being beaten",
        "past": "an earlier time, or beyond", "passed": "went by or handed over",
        "lead": "to go first, or the metal", "led": "past tense of lead",
        "peace": "absence of conflict", "piece": "a part of something",
        "coarse": "rough", "course": "a route, or a class",
        "council": "a group that governs", "counsel": "advice, or a lawyer",
        "formally": "officially", "formerly": "previously",
        "emigration": "leaving a country", "immigration": "entering a country",
        "aloud": "out loud", "allowed": "permitted",
        "weather": "rain and sun", "whether": "if",
        "waist": "the middle of the body", "waste": "squander, or rubbish",
        "brake": "to slow down", "break": "to snap, or a pause",
        "role": "a part played", "roll": "to turn over, or a bread roll",
        "site": "a place or website", "sight": "vision", "cite": "to quote a source",
    ]

    /// word -> the group it belongs to, lowercased. Built once.
    static let groupOf: [String: Set<String>] = {
        var out: [String: Set<String>] = [:]
        for group in groups {
            let set = Set(group.map { $0.lowercased() })
            for word in set { out[word] = set }
        }
        return out
    }()

    /// Every word on the list, for the gate.
    static let all: Set<String> = Set(groupOf.keys)

    /// May `replacement` stand in for `original`?
    ///
    /// True only when both are in the same group. Identical words are allowed —
    /// the model leaving a word alone is the common case and must not be read as
    /// a violation.
    public static func mayReplace(_ original: String, with replacement: String) -> Bool {
        let a = normalise(original), b = normalise(replacement)
        if a == b { return true }
        guard let group = groupOf[a] else { return false }
        return group.contains(b)
    }

    /// The gate. Does this text contain anything worth spending a model call on?
    ///
    /// A plain set lookup over the tokens. If nothing on the list appears there
    /// is nothing this pass could legally change, so it must not run — that is
    /// what keeps it off the critical path for most dictations.
    public static func hasCandidate(in text: String) -> Bool {
        !candidates(in: text).isEmpty
    }

    /// The list words actually present, in order, deduplicated. Used to build a
    /// prompt that names only the choices that are live for this sentence.
    public static func candidates(in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" }) {
            let word = normalise(String(token))
            guard all.contains(word), seen.insert(word).inserted else { continue }
            out.append(word)
        }
        return out
    }

    static func normalise(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"()[]"))
    }
}
