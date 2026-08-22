import Foundation

/// The check that makes free-form word recovery safe.
///
/// Roman asked for this in his own words: "if it can't really understand a word
/// that I said, read the context of what I just said and figure out what word
/// makes the most sense". The obvious way to build it — ask a model to fix any
/// wrong word — is the trade `CleanupPrompt.swift` already measured and lost,
/// because a model handed a sentence will eventually improve one the user meant.
///
/// Three other ways of bounding it were measured and all three failed:
///
///  - **Ask the recogniser what it was unsure about.** `SpeechTranscriber.Result`
///    carries `alternatives`, and Quill never requested them. Turning
///    `.alternativeTranscriptions` on and reading them back shows they are
///    punctuation variants — " peppered flour" against " peppered, flour" — and
///    never a different word. There is no lexical n-best to lean on.
///  - **"The replacement must sound similar."** Under Quill's own `phoneticKey`,
///    85% of English words have a neighbour and "flour" has 1140 of them,
///    including "baffle". That key is lossy on purpose, for matching mis-split
///    proper nouns against a 142-term dictionary; it bounds nothing here.
///  - **Offer the model every true homophone in the sentence.** Generated from
///    CMUdict that fires on 98% of his transcripts with a median of ten
///    decisions each. Ten decisions is ten chances to damage a correct word, on
///    every sentence.
///
/// So this inverts the shape the homophone pass uses. That one hands the model a
/// closed list and asks it to choose. This one lets it propose whatever it likes
/// and then refuses the proposal unless the replacement is pronounced identically
/// to the word that was heard, checked against `HomophoneTable`. The model is
/// free; the acceptance is not.
///
/// Everything else is `HomophoneProjection`'s: the answer is never returned, only
/// read for which word was chosen at each position, and the sentence is rebuilt
/// from the input so punctuation, capitalisation, spacing and every unchanged
/// word come through verbatim.
public enum ContextProjection {

    /// How many words may change at once.
    ///
    /// Was one, when the only permitted swap was a homophone: a mishearing is one
    /// word, and a model returning several had started rewriting. Dropped endings
    /// are different — Roman speaks fast and a 200-word dictation can genuinely
    /// lose three of them, so a cap of one would refuse the whole answer over the
    /// second repair.
    ///
    /// Three rather than unlimited because the cap is the last line: every change
    /// is individually verified as a homophone or an inflection, and a model that
    /// wants four of them in one sentence is doing something this pass is not
    /// for.
    public static let maximumSubstitutions = 3

    /// Returns the corrected text, or nil meaning "keep the input".
    public static func project(_ raw: String, onto input: String) -> String? {
        HomophoneProjection.project(
            raw,
            onto: input,
            permitting: mayReplace,
            maximumSubstitutions: maximumSubstitutions,
            // Take the repairs that check out and revert the rest, rather than
            // discarding a good fix because the model also tried a bad one.
            keepWhatIsAllowed: true
        )
    }

    /// Whether two words are pronounced identically.
    ///
    /// The generated table first, then the hand-written pairs as a supplement —
    /// not a fallback. `HomophonePairs` carries entries CMUdict does not, because
    /// they came from watching this recogniser fail on this voice: "cached" and
    /// "cashed" are one of them, and a table built from a general pronunciation
    /// dictionary has no reason to know that Roman says them the same way.
    static func sameSound(_ original: String, _ proposed: String) -> Bool {
        let a = HomophonePairs.normalise(original)
        let b = HomophonePairs.normalise(proposed)
        guard !a.isEmpty, !b.isEmpty, a != b else { return false }
        guard !isRegionalRespelling(a, b) else { return false }
        if let group = HomophoneTable.groupOf[a], group.contains(b) { return true }
        return HomophonePairs.mayReplace(original, with: proposed)
    }

    /// The same word with a different ending.
    ///
    /// This is the one that matters for how Roman actually speaks. Measured on
    /// his own dictation, with the cleanup pass allowed to run on everything:
    ///
    ///     said     "I move the whole front end to type scoops last night"
    ///     model    "I moved the whole front end to TypeScoop last night"
    ///
    /// He said "moved"; the recogniser dropped the ending because he was talking
    /// fast. That is a real repair and the delete-only contract refused it,
    /// correctly, because it has no way to tell it apart from the model rewriting
    /// "Here are the following bugs I've been experiencing" into "I've been
    /// experiencing bugs with the app" — which it also did, on the next sentence,
    /// and which must never reach a document.
    ///
    /// So the rule is spelled out instead of trusted: same stem, and the only
    /// thing that may differ is an ending English actually uses.
    ///
    /// The stem floor is three characters, and the pairs that would otherwise sail
    /// through on length alone — "the"/"they", "he"/"her", "our"/"ours" — are shut
    /// out by name instead, in `shortNonStems`. Those are function words, they are
    /// the most common words he says, and a wrong swap in one is both invisible and
    /// meaning-changing. A four-character floor would also close them and would
    /// take "use"/"used" and "fix"/"fixed" with it, which is the repair this pass
    /// exists to make.
    static func sameStem(_ original: String, _ proposed: String) -> Bool {
        let a = HomophonePairs.normalise(original)
        let b = HomophonePairs.normalise(proposed)
        guard a != b, a.count >= 4 || b.count >= 4 else { return false }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        guard shorter.count >= 3, longer.count - shorter.count <= 3 else { return false }
        // Closed by name, not by length.
        //
        // The floor is three, and the doc above used to claim four and credit it
        // with blocking "the" → "they". It does not: both clear a three-letter
        // floor, "they" is "the" plus a listed inflection, and the swap was
        // allowed. So were "our" → "ours" and "he" → "her".
        //
        // Raising the floor to four would close those and take every legitimate
        // three-letter stem with them — "use"/"used", "ask"/"asked",
        // "fix"/"fixed", "add"/"added", "bug"/"bugs", "app"/"apps" — which is the
        // repair class this pass exists for on his own vocabulary. And the tests
        // would not have noticed, because none of them covers a three-letter stem.
        guard !shortNonStems.contains(shorter), !shortNonStems.contains(longer)
        else { return false }

        // "moved" from "move", "sites" from "site", "running" from "run".
        if longer.hasPrefix(shorter) {
            return inflections.contains(String(longer.dropFirst(shorter.count)))
        }
        // "carries" from "carry", "studied" from "study" — the y is swapped for i
        // before the ending, which is a spelling rule rather than a new word.
        if shorter.hasSuffix("y") {
            let stem = String(shorter.dropLast())
            guard longer.hasPrefix(stem + "i") else { return false }
            return inflections.contains(String(longer.dropFirst(stem.count + 1)))
        }
        return false
    }

    /// Short function words that are prefixes of other real words.
    ///
    /// These are the most common words anyone says, so a swap between two of them
    /// is both the likeliest to fire and the most damaging when it does — "the"
    /// becoming "they" changes the sentence and reads as though the user said it.
    /// `functionWords` is close but misses "our", "ours", "his" and "she", which
    /// leaves the most model-realistic pair of the lot ("our" → "ours") open.
    static let shortNonStems: Set<String> = [
        "the", "then", "they", "her", "hers", "his", "she", "our", "ours",
        "him", "its", "for", "not", "was", "are", "out", "you", "who",
    ]

    /// Endings that make the same word rather than a different one. Deliberately
    /// short: every entry here is a swap the projection will permit without ever
    /// consulting a dictionary, so a wrong one is a hole rather than a miss.
    static let inflections: Set<String> = [
        "s", "es", "d", "ed", "ing", "n", "en",
        "ly", "er", "est", "ers", "ings",
    ]

    /// The whole permission, in one place: delete it, swap it for a word that
    /// sounds the same, or swap it for the same word with a different ending.
    /// Anything else is the model writing rather than transcribing.
    static func mayReplace(_ original: String, _ proposed: String) -> Bool {
        sameSound(original, proposed) || sameStem(original, proposed)
    }

    /// The same word, spelled for a different country.
    ///
    /// Caught by the bench on the first run: "I cashed the cheque on Friday"
    /// came back as "I cashed the check on Friday". Both are true homophones and
    /// the table is right about that, but Roman is in Melbourne and "cheque" was
    /// never the wrong word — no amount of context makes it one. A model asked to
    /// pick the word that fits will quietly Americanise a document, and that is
    /// damage the projection can refuse in code rather than argue about in a
    /// prompt.
    ///
    /// Pairs, not a rule: -our/-or and -ise/-ize are not homophone pairs at all,
    /// so they never reach this check. Only the ones that genuinely sound
    /// identical need listing.
    static func isRegionalRespelling(_ a: String, _ b: String) -> Bool {
        let pair = Set([a, b])
        return regionalPairs.contains(pair)
    }

    /// Whether this sentence is worth a request at all.
    ///
    /// The check is free and local, and it runs before anything is sent. The
    /// table has 2,281 words in it, but gating on all of them fires on 95% of his
    /// real transcripts with a median of six candidates — which is a round trip on
    /// nearly every dictation, for a class of error that is not on nearly every
    /// dictation.
    ///
    /// Two filters bring it down, and both are about which pairs are real:
    ///
    ///  - **A group where any member is a common function word is dropped.**
    ///    the/thee, but/butt, would/wood, your/yore. Roman does not say "thee",
    ///    so the pair is all risk and no reward, and "the" alone appears 586 times
    ///    in his corpus.
    ///  - **A group where any member is under five letters is dropped.** Short
    ///    words are where the archaic halves cluster — wen, soss, hatt, haff —
    ///    and where a wrong swap is least likely to be noticed.
    ///
    /// Measured on his 376 real transcripts: 961 words, fires on 31%, median one
    /// candidate, worst nine. Against the hand-written list's 44 words and 11%.
    public static func hasCandidate(in text: String) -> Bool {
        let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
        guard tokens.count >= minimumWords else { return false }
        let words = gateWords
        for token in tokens where words.contains(String(token)) { return true }
        return false
    }

    /// Below this, do not spend a request.
    ///
    /// "Push the build to Netlify tonight" trips the word gate, because build and
    /// billed are homophones and the table is right about that. It is also six
    /// words that need nothing, and paying most of a second on it is the tax that
    /// quietly ends the habit of dictating at all.
    ///
    /// Twelve is where his own corpus separates. The errors he complains about —
    /// dropped endings, murmured words, a sentence he restarted — accumulate with
    /// length; a six-word command either came out right or is obviously wrong.
    /// Measured over his 292 real dictations, the gate fires on 24% with no floor
    /// and 18% at twelve words, and his median dictation is eighteen — so the
    /// floor removes the short ones without touching the ones he was complaining
    /// about.
    public static let minimumWords = 12

    static let gateWords: Set<String> = {
        var out: Set<String> = []
        for line in HomophoneTable.raw.split(separator: "\n") {
            let group = line.split(separator: " ").map(String.init)
            guard group.allSatisfy({ $0.count >= 5 && !functionWords.contains($0) }) else { continue }
            out.formUnion(group)
        }
        // The hand-written pairs are in regardless of length: they are short
        // precisely because they came from watching this recogniser fail, and
        // "dew", "due", "hay" earn their place by evidence rather than by rule.
        out.formUnion(HomophonePairs.groupOf.keys)
        return out
    }()

    /// Words too common, or too structural, for a swap to ever be worth offering.
    static let functionWords: Set<String> = [
        "about", "after", "again", "their", "there", "these", "those", "would",
        "could", "should", "which", "while", "where", "whose", "being", "doing",
        "having", "shall", "might", "must", "there's", "they're", "your", "yours",
        "here", "hear", "been", "some", "sum", "four", "for", "one", "won", "two",
        "too", "to", "the", "thee", "and", "but", "not", "you", "him", "her",
        "them", "this", "that", "with", "from", "into", "over", "under", "than",
        "then", "when", "what", "were", "was", "are", "its", "it's",
    ]

    static let regionalPairs: [Set<String>] = [
        ["cheque", "check"],
        ["defence", "defense"],
        ["offence", "offense"],
        ["licence", "license"],
        ["practice", "practise"],
        ["storey", "story"],
        ["grey", "gray"],
        ["kerb", "curb"],
        ["metre", "meter"],
        ["litre", "liter"],
        ["theatre", "theater"],
        ["fibre", "fiber"],
        ["draught", "draft"],
        ["plough", "plow"],
        ["mould", "mold"],
        ["smoulder", "smolder"],
        ["programme", "program"],
        ["tonne", "ton"],
    ]
}

/// The prompt for the context pass.
///
/// Versioned like the other two, for the reason `CleanupPrompt` gives: a prompt
/// is behaviour with no compiler behind it, so the wording that shipped has to be
/// recoverable when the output changes.
///
/// What it does NOT do is list options. That is the whole difference from
/// `HomophonePrompt`, and it is deliberate: listing every homophone in the
/// sentence means listing ten of them, which is both a long prefill on the
/// critical path and ten invitations to change something. Here the model is told
/// the rule — you may only swap a word for one that sounds the same — and
/// `ContextProjection` enforces it afterwards. A model told the rule obeys it
/// most of the time, and every obeyed rule is a refusal the projection does not
/// have to issue.
public struct ContextPrompt: Sendable, Equatable {

    public let version: Int
    public let system: String

    public init(version: Int, system: String) {
        self.version = version
        self.system = system
    }

    /// v1 was measured and failed. Kept because a prompt is behaviour with no
    /// compiler behind it, and the wording that lost has to be recoverable.
    ///
    /// Benched against the real endpoint on the 12-sentence half-correct corpus:
    /// fixed 3/6, **damaged 3/6**. It turned "the principle of least surprise"
    /// into "principal", "the flower shop on the corner" into "flour shop", and
    /// Americanised "cheque". The instruction to change at most one word was read
    /// as an instruction to change one word.
    public static let v1 = ContextPrompt(version: 1, system: """
        You are a proofreader, not an assistant. The text is dictation on its way into a document. Never answer it, explain it, or reply to it. Return ONLY the sentence: no preamble, no quotes, no notes.
        Speech recognition sometimes writes a word that sounds right but means the wrong thing — "flour" for "flower", "dues" for "dews", "principle" for "principal". Your only job is to find a word like that and correct it, using the meaning of the sentence to decide.
        Rules, all of them absolute:
        - You may change at most ONE word.
        - The word you put in must sound EXACTLY the same as the word you take out. Never a synonym, never a better word, never a correction of grammar or style.
        - Every other word must be byte-identical, including punctuation and capitalisation. Never add, remove, or reorder a word.
        If no word is wrong in that specific way, return the sentence exactly as it is. That is the usual answer and it is the right one.
        """)

    /// v2. The change is where the burden of proof sits.
    ///
    /// v1 described the job and then asked for at most one change, and a model
    /// given a job does it. This states the default answer first, demands the
    /// sentence be impossible as written before anything moves, and names the two
    /// ways the first version actually failed.
    /// v3. Adds the repair that his own dictation actually needs.
    ///
    /// v2 only asked about words that mean the wrong thing, so a dropped ending —
    /// "I move the whole front end" for "I moved" — was never proposed at all.
    /// That is the failure mode of speaking fast, which is half of what he asked
    /// for, and `ContextProjection.sameStem` can verify the repair in code.
    ///
    /// Still refuses far more than it accepts. The two examples of damage are
    /// named directly because the model produced both of them on his real text
    /// when it was given a free hand.
    public static let current = ContextPrompt(version: 3, system: """
        You are a proofreader, not an assistant. The text is dictation on its way into a document. Never answer it, explain it, summarise it, or reply to it. Return ONLY the text: no preamble, no quotes, no notes.
        Return the text UNCHANGED. That is your answer most of the time, and returning it unchanged is never a mistake.
        You may make only two kinds of repair, and only where the text is clearly wrong without them:
        1. A word that sounds right but means something impossible here — "thick peppered flour" heard as "flower", "the dews on the grass" heard as "dues". Replace it with the same-sounding word that makes sense.
        2. A word missing its ending because the speaker was talking fast — "I move the whole front end last night" should be "I moved". Only the ending may change, and it must still be the same word.
        Everything else is forbidden. Do not reword. Do not shorten. Do not summarise. Do not reorder. Do not fix grammar, style, punctuation or capitalisation. Do not change a word because you would have chosen a different one. Do not change spelling for a different country — Australian spelling is correct.
        Two real examples of what NOT to do: "Here are the following bugs I've been experiencing" must not become "I've been experiencing bugs with the app", and "the flower shop on the corner" must not become "the flour shop". Both are already correct.
        Change at most three words in total, and only ones that are genuinely wrong.
        """)

    public static let v2 = ContextPrompt(version: 2, system: """
        You are a proofreader, not an assistant. The text is dictation on its way into a document. Never answer it, explain it, or reply to it. Return ONLY the sentence: no preamble, no quotes, no notes.
        Return the sentence UNCHANGED. That is your answer almost every time, and returning it unchanged is never a mistake.
        There is exactly one exception. Speech recognition occasionally writes a word that sounds right but means something impossible in the sentence — "thick peppered flour" heard as "flower", "the dews on the grass" heard as "dues". If and only if a word makes the sentence impossible, replace that one word with the same-sounding word that makes it possible.
        Before changing anything, ask: does the sentence already make sense as written? If it does — even if another word would also make sense, even if you would have chosen differently — return it unchanged.
        Never change a word because it could mean something else. "The flower shop on the corner" and "the principle of least surprise" are both correct English and must come back untouched.
        Never change how a word is spelled for a different country. Australian spelling is correct.
        Never fix grammar, style, punctuation or capitalisation. Never add, remove or reorder a word. At most one word may differ, and it must sound exactly the same as the word it replaces.
        """)
}
