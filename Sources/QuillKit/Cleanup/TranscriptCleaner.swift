import Foundation

/// Turning raw speech into text someone would have typed.
///
/// The bar here is Wispr Flow, which runs a fine-tuned Llama on a server GPU and
/// still returns in under 250ms. We cannot match that locally — a local model
/// inference on this Mac was measured at ~3.2s — so the design is different on
/// purpose: a deterministic pass that is effectively free always runs, and a
/// model pass runs only if it can beat a deadline. Whatever is ready when the
/// deadline expires is what gets inserted.
///
/// The alternative designs were both worse. Waiting for the model would put
/// seconds between releasing the key and seeing text, which loses the latency
/// piece outright. Inserting raw text and rewriting it afterwards means visibly
/// mutating text the user is already looking at, in an app we do not control.
public protocol TranscriptCleaning: Sendable {
    /// Must be fast enough to be invisible. Called on every dictation.
    func cleanFast(_ raw: String) -> String
    /// May be slow and may return nil if it could not finish in time.
    func cleanThorough(_ raw: String, deadline: Duration) async -> String?
}

/// Rule-based cleanup. Runs in microseconds, needs no model, and handles the
/// things that actually make raw dictation look like dictation.
public struct FastCleaner: TranscriptCleaning, Sendable {

    /// Words people say while thinking. Removed only when they stand alone —
    /// "um" as a whole word goes, "umbrella" obviously does not.
    private static let disfluencies: Set<String> = [
        "um", "uh", "erm", "uhm", "ah", "eh", "mm", "hmm",
    ]

    /// Roman's vocabulary. Apple's recogniser is given these as contextual
    /// strings too, but biasing is a hint and not a guarantee, so the common
    /// mishearings get corrected here as well. Keys are compared lowercased.
    private static let corrections: [String: String] = [
        "next fulfilment": "nxt fulfilment",
        "graphite": "graphify",
        "nebula": "Nebula",
        "vesper": "Vesper",
        "block craft": "blockcraft",
        "fire store": "Firestore",
        // Heard from Roman's own voice, 21 Aug: "a Firestore backend" came back
        // as "a fire stall back end". "fire store" was already here; the vowel
        // moves depending on how fast he says it, and neither "fire stall" nor
        // "fire store" is a phrase with an ordinary meaning to protect.
        "fire stall": "Firestore",
        // Second real-voice run, same paragraph, different manglings — which is
        // itself the finding: the recogniser does not fail the same way twice.
        //   "Syncthing is finally"  -> "Sing thinking is finally"
        //   "in TypeScript over"    -> "in Types Group over"
        // Neither split form is a phrase anyone says, so neither needs an anchor.
        //
        // Netlify is NOT here, and that is the interesting omission. It came back
        // as "not a fly" and then as "going to fly", and "not a fly" is ordinary
        // English — measured firing inside "there is a fly in the kitchen and it
        // will not leave". An entry for it would rewrite that sentence. It is the
        // one mangling in this paragraph that no table can safely fix; see the
        // note in VocabularyCorrector about why the model-detector idea does not
        // rescue it either.
        "sing thinking": "Syncthing",
        "types group": "TypeScript",
        "note js version": "Node.js version",
        "note. js version": "Node.js version",
        // Same dictation: "the old Node.js version" -> "the old no.JS version".
        // The recogniser writes the spoken "node" as the abbreviation "no.".
        // Anchored on "version" and "server" because a bare "no js" could be
        // someone answering a question about JavaScript.
        "no. js version": "Node.js version",
        "no js version": "Node.js version",
        "no. js server": "Node.js server",
        "no js server": "Node.js server",
        "net lify": "Netlify",
        "craigie burn": "Craigieburn",
        "swift ui": "SwiftUI",
        "mac os": "macOS",
        "i os": "iOS",

        // Observed manglings of his own speech that the fuzzy corrector CANNOT
        // reach, and why each is unreachable rather than merely missed:
        //
        //   "course"    for CORS   — "course" is real English, so the guard that
        //                            stops the corrector rewriting words he meant
        //                            refuses it, correctly.
        //   "vespa"     for Vesper — same; "vespa" is a word.
        //   "sq light"  for SQLite — scores 0.57 against the term, far below the
        //                            0.85 bar, and lowering that bar is exactly
        //                            what let "build a bed" become "Builda Bed".
        //   "neglified" for Netlify — 0.56 by letters and no closer by sound.
        //
        // A literal table can fix all four because it asks a different question:
        // not "is this span near a term" but "is this exact string one I have
        // watched the recogniser produce for him". The two that are real English
        // are anchored on the word that followed them in his actual dictation, so
        // they cannot fire on the ordinary meaning — "of course" and "a Vespa"
        // are untouched, only "course headers" and "vespa is the" move.
        "course headers": "CORS headers",
        "no course policy": "no CORS policy",
        "vespa is the": "Vesper is the",
        "sq light": "SQLite",
        "sq lite": "SQLite",
        "neglified": "Netlify",
        "netterfly": "Netlify",

        // Compound tool names the recogniser splits into two ordinary words.
        //
        // The fuzzy corrector cannot reach these: every piece is real English, so
        // the single-word guard refuses them, and a two-word span of ordinary
        // English is held to a near-exact bar that "get hub" does not clear
        // against "github" by letters alone.
        //
        // Split into two groups, because the two halves are not equally safe.
        //
        // SAFE UNANCHORED — the split form is not a phrase anyone says with its
        // ordinary meaning. "git hub" and "gethub" are not English; "post gres",
        // "cloud flare", "chat gpt", "web pack", "vs code", "node js" do not
        // occur outside the tool name.
        "git hub": "GitHub",
        "gethub": "GitHub",
        "post gres": "Postgres",
        "cloud flare": "Cloudflare",
        "chat gpt": "ChatGPT",
        "chat g p t": "ChatGPT",
        "web pack": "webpack",
        "vs code": "VS Code",
        "node js": "Node.js",
        "next js": "Next.js",
        "three js": "Three.js",

        // NEEDS AN ANCHOR — the split form IS ordinary English, so the bare pair
        // would rewrite sentences he meant. Each of these was caught firing on
        // real prose before the anchor was added:
        //
        //     "I need to get hub caps for the car" -> "I need to GitHub caps…"
        //     "you tube of toothpaste"             -> "YouTube of toothpaste"
        //     "a tail wind helped the flight"      -> "a Tailwind helped…"
        //     "the air table was covered in dust"  -> "the Airtable was covered…"
        //     "type script tags by hand"           -> "TypeScript tags by hand"
        //     "sync thing up later"                -> "Syncthing up later"
        //
        // The anchor is the word he actually says next when he means the tool.
        // A miss costs a correction; a false fire costs a sentence.
        // "to get hub" is deliberately absent: it fires inside "I need to get
        // hub caps for the car". The anchors below are the ones that cannot.
        "on get hub": "on GitHub",
        "get hub repo": "GitHub repo",
        "get hub actions": "GitHub actions",
        "get hub pages": "GitHub pages",
        "push to get hub": "push to GitHub",
        "pushed to get hub": "pushed to GitHub",
        "it to get hub": "it to GitHub",
        "up to get hub": "up to GitHub",
        "in type script": "in TypeScript",
        "type script file": "TypeScript file",
        "to you tube": "to YouTube",
        "you tube video": "YouTube video",
        "linked in profile": "LinkedIn profile",
        "sink thing": "Syncthing",
        "sync thing is": "Syncthing is",
        "with tail wind": "with Tailwind",
        "tail wind css": "Tailwind CSS",
        "in air table": "in Airtable",
        "air table base": "Airtable base",

        // Homophones, but only where the phrase decides the answer.
        //
        // Homophones are the largest single error class in the eval corpus —
        // seven of twenty-seven word errors — and nothing downstream can fix
        // them: VocabularyCorrector presumes a correctly spelled English word is
        // intentional, and the model pass may only delete, never swap. See
        // ACCURACY_ANALYSIS.md.
        //
        // Two rules for what may go in here, both learned the hard way.
        //
        // First, ANCHORED ONLY. A bare "flower" -> "flour" would rewrite every
        // sentence about flowers. Each key below is a fixed phrase where one
        // spelling is simply wrong: nobody writes "hey fever" or "principle
        // developer". Where the phrase does not decide it, it does not belong
        // here — that is what the gated model pass in ACCURACY_ANALYSIS.md is
        // for.
        //
        // Second, PHRASES HE SAYS. The corpus's own failures are not eligible:
        // "peppered flower" -> "peppered flour" and "the dues were" -> "the dews
        // were" would move the benchmark and change nothing for anyone who is not
        // dictating nineteenth-century prose about mutton. The entries below are
        // ordinary English or the vocabulary of a developer quoting jobs.
        "hey fever": "hay fever",
        "principle developer": "principal developer",
        "principle engineer": "principal engineer",
        "principle amount": "principal amount",
        "in principal": "in principle",
        "discrete about": "discreet about",
        "stationary shop": "stationery shop",
        "complimentary colours": "complementary colours",
        "complimentary colors": "complementary colors",
        "compliments each other": "complements each other",
        "affect on the": "effect on the",
        "affect of the": "effect of the",
        "the affect was": "the effect was",
        "no affect on": "no effect on",
        "side affects": "side effects",
        "your welcome": "you're welcome",
        "loosing the": "losing the",
        // Deliberately absent, and each for a reason:
        //   "loose the" -> "lose the"      — "loose the reins" is correct English.
        //   "peace/piece of mind"          — both are real phrases with different
        //                                    meanings; the audio cannot tell them
        //                                    apart and neither can a table.
        //   "led"/"lead", "its"/"it's"     — decided by grammar, not by a fixed
        //                                    phrase. That is the model pass's job.
    ]

    private let vocabulary: VocabularyCorrector

    public init(vocabulary: VocabularyCorrector = VocabularyCorrector()) {
        self.vocabulary = vocabulary
    }

    public func cleanFast(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // Before anything that treats a full stop as a sentence boundary.
        text = Self.joinSpokenDecimals(in: text)
        text = Self.applyCorrections(to: text)
        // Fuzzy pass second: the literal table above handles known phrasings
        // cheaply, this catches the ones where the recogniser split a word.
        text = vocabulary.correct(text)
        text = Self.stripStandaloneDisfluencies(from: text)
        text = Self.collapseWhitespace(in: text)
        text = Self.tightenPunctuationSpacing(in: text)
        text = Self.capitaliseSentences(in: text)
        return text
    }

    /// No model here. Callers race this against the real one.
    public func cleanThorough(_ raw: String, deadline: Duration) async -> String? {
        cleanFast(raw)
    }

    // MARK: - Steps, each independently testable

    /// Turns "one. 4 seconds" back into "1.4 seconds".
    ///
    /// The recogniser writes the spoken word "point" as a full stop. So "the page
    /// loads in about one point four seconds" arrives as "one. 4 seconds", and
    /// then sentence-casing sees a full stop and produces:
    ///
    ///     The page loads in about one. 4 Seconds on a cold cache.
    ///
    /// Two errors and a capital letter in the middle of a sentence, from one
    /// spoken decimal. Measured on Roman's voice corpus it hit both clips that
    /// contained a version number or a timing — and he says version numbers
    /// constantly.
    ///
    /// Deliberately narrow. It only fires when the thing before the full stop is
    /// a spelled-out number word, because that is what the recogniser actually
    /// produces here, and because a DIGIT before a full stop is far more likely
    /// to be a real sentence ending — "it shipped in 2020. 3 people worked on it"
    /// must not become "2020.3". Whatever follows may itself be dotted, so
    /// "one. 2.7" comes out "1.2.7" rather than "1.2" with an orphan.
    static func joinSpokenDecimals(in text: String) -> String {
        let pattern = "\\b(" + numberWords.keys.joined(separator: "|") + ")\\.\\s+(\\d+(?:\\.\\d+)*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }

        var out = text
        var searched = NSRange(out.startIndex..., in: out)
        while let match = regex.firstMatch(in: out, range: searched),
              let wordRange = Range(match.range(at: 1), in: out),
              let digitsRange = Range(match.range(at: 2), in: out),
              let whole = Range(match.range, in: out) {
            guard let leading = numberWords[String(out[wordRange]).lowercased()] else { break }
            let replacement = "\(leading).\(out[digitsRange])"
            out.replaceSubrange(whole, with: replacement)
            guard let resume = out.range(of: replacement)?.upperBound else { break }
            searched = NSRange(resume ..< out.endIndex, in: out)
        }
        return out
    }

    /// Only the numbers anyone says before a decimal point. A version is "one
    /// point two", a load time is "one point four" — nobody dictates "seventeen
    /// point three" often enough to justify the extra surface for a wrong match.
    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12",
    ]

    static func applyCorrections(to text: String) -> String {
        var out = text
        for (wrong, right) in corrections {
            out = out.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b",
                with: right,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }

    static func stripStandaloneDisfluencies(from text: String) -> String {
        let pattern = "\\b(" + disfluencies.joined(separator: "|") + ")\\b[,.]?"
        return text.replacingOccurrences(
            of: pattern, with: "", options: [.regularExpression, .caseInsensitive]
        )
    }

    static func collapseWhitespace(in text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// " ,"  ->  ","   and   "word.Next"  ->  "word. Next"
    static func tightenPunctuationSpacing(in text: String) -> String {
        var out = text.replacingOccurrences(
            of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "([.!?])([A-Za-z])", with: "$1 $2", options: .regularExpression
        )
        return out
    }

    /// Sentence casing that knows a decimal point is not a full stop.
    ///
    /// Every full stop used to arm the next capital, and the "next capital" was
    /// simply the next letter — however far away, and across any number of
    /// digits. So a decimal armed it and the digits could not absorb it, and the
    /// capital landed on the following word:
    ///
    ///     The page loads in about 1.4 Seconds on a cold cache.
    ///     We cut version 2.0 Last night.
    ///     It shipped in 2020. 3 People worked on it.
    ///
    /// Two rules fix all three. A full stop between two digits is a decimal and
    /// ends nothing. And a pending capital expires when it meets a digit — after
    /// a genuine sentence break the number itself opens the sentence, and a
    /// number cannot be capitalised, so nothing further should be.
    static func capitaliseSentences(in text: String) -> String {
        var chars = Array(text)
        var capitaliseNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitaliseNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitaliseNext = false
            } else if capitaliseNext, c.isNumber {
                // The sentence has started; it just started with a number.
                capitaliseNext = false
            } else if c == "." || c == "!" || c == "?" {
                let previous = i > 0 ? chars[i - 1] : " "
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                let isDecimalPoint = c == "." && previous.isNumber && next.isNumber
                if !isDecimalPoint { capitaliseNext = true }
            }
        }
        return String(chars)
    }
}
