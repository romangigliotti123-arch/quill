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
    /// Two-word spans whose split form is ordinary English, and whose letters
    /// happen to spell a tool name.
    ///
    /// The anchored entries in `corrections` exist because the bare pair rewrites
    /// sentences the user meant — "type script tags by hand", "a tail wind helped
    /// the flight". But anchoring here only stops THIS pass. The vocabulary
    /// corrector runs a step later, and its exact-letters branch fires on the
    /// bare pair regardless: `normalise("type script") == "typescript"`, which is
    /// the strongest evidence it has, so it returned before any of its own guards
    /// could look at the sentence.
    ///
    /// So the two layers now share one list. A pair in here can only become a
    /// tool name through an anchor above — never on its own — which is what the
    /// comment inside `corrections` has always claimed the design was.
    ///
    /// Adding an anchor above and adding the pair here is one edit, deliberately.
    static let ambiguousSplits: Set<String> = [
        "typescript",   // "type script tags by hand"
        "tailwind",     // "a tail wind helped the flight"
        "airtable",     // "the air table was covered in dust"
        "syncthing",    // "sync thing up later"
        "github",       // "get hub caps for the car"
        "youtube",      // "you tube of toothpaste"
        "linkedin",     // "linked in the email"
        "blackhole",    // "the black hole in the data"
        "homebrew",     // "a home brew kit"
    ]

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
        // would rewrite sentences he meant. See `FastCleaner.ambiguousSplits`
        // below: the same list also has to stop the VOCABULARY pass from firing
        // on the bare pair a step later, or the anchor here is decoration. Each of these was caught firing on
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
        // After the spacing rules, so a domain the recogniser dotted correctly has
        // survived them; before the sentence casing, which knows to leave an
        // address lowercase.
        //
        // The number style is deliberately NOT here. It is a presentation choice
        // and the destination gets a vote, so it lives in AppContextFormatter
        // alongside the other two — a terminal keeps its digits.
        text = Self.formatSpokenEmails(in: text)
        text = Self.capitaliseSentences(in: text)
        return text
    }

    /// No model here. Callers race this against the real one.
    public func cleanThorough(_ raw: String, deadline: Duration) async -> String? {
        cleanFast(raw)
    }

    // MARK: - Spoken email addresses

    /// Turns an address he said out loud into an address.
    ///
    ///     send it to roman gigliotti 123 at gmail dot com
    ///     -> send it to romangigliotti123@gmail.com
    ///
    /// The real failure, from his history on 20 Aug: "send it to the Gmail Grace
    /// Kingston 20 at gmail.com" reached the document as prose, with the domain
    /// broken into "gmail. Com" on top. The broken domain is fixed elsewhere;
    /// this is the rest of it.
    ///
    /// **It anchors on the domain, never on the word "at".** That is the whole
    /// safety argument. "Meet me at the shop at four" has no domain and is never
    /// even considered. Only once a domain is found does it look left for a local
    /// part, and it refuses outright when the word in front of "at" is one that
    /// ordinary English puts there — "I'll look at netlify.com later" must not
    /// become "I'll look@netlify.com later".
    ///
    /// Deleting or gluing words the user actually said is the failure mode this
    /// whole file is scarred by (see VocabularyCorrector's notes on "Roman design
    /// cost"), so every rule here is a refusal rather than a guess.
    static func formatSpokenEmails(in text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count >= 3 else { return text }

        var i = 0
        while i < tokens.count {
            guard Self.bareWord(tokens[i]).lowercased() == "at",
                  // An address the recogniser already assembled is finished.
                  !tokens[i].contains("@"),
                  let domain = Self.readDomain(tokens, from: i + 1)
            else { i += 1; continue }

            guard let local = Self.readLocalPart(tokens, endingBefore: i),
                  Self.looksLikeAnAddress(local: local.text, words: local.words,
                                          stoppedOn: local.stoppedOn,
                                          domain: domain.text)
            else {
                i += 1
                continue
            }

            // Whatever punctuation closed the last domain token closes the address.
            let trailing = Self.trailingPunctuation(tokens[domain.lastIndex])
            tokens.replaceSubrange(local.firstIndex ... domain.lastIndex,
                                   with: ["\(local.text)@\(domain.text)\(trailing)"])
            i = local.firstIndex + 1
        }
        return tokens.joined(separator: " ")
    }

    /// A domain starting at `start`, either already dotted ("gmail.com") or spoken
    /// ("gmail dot com", "kass barbers dot com dot au"). Nil when there is none,
    /// which is the answer for almost every "at" in ordinary speech.
    private static func readDomain(_ tokens: [String], from start: Int)
    -> (text: String, lastIndex: Int)? {
        guard start < tokens.count else { return nil }

        // Already dotted. Requires a real-looking suffix so that "node.js" and
        // "1.4" cannot pass as somewhere to send mail.
        let first = bareWord(tokens[start])
        if first.contains("."), isDottedDomain(first) {
            return (first.lowercased(), start)
        }

        // Spoken. Words up to the first "dot" are one label glued together — the
        // recogniser splits "kassbarbers" into "kass barbers" as readily as it
        // splits a name.
        var label = ""
        var index = start
        while index < tokens.count, bareWord(tokens[index]).lowercased() != "dot" {
            let word = bareWord(tokens[index])
            guard isNameLike(word), label.count < 40 else { return nil }
            label += word
            index += 1
            // A label that runs on with no "dot" behind it is a sentence.
            if index - start > 3 { return nil }
        }
        guard !label.isEmpty, index < tokens.count else { return nil }

        var parts = [label]
        var last = index
        while index < tokens.count, bareWord(tokens[index]).lowercased() == "dot" {
            guard index + 1 < tokens.count else { return nil }
            let next = bareWord(tokens[index + 1])
            guard isTopLevelDomain(next) else { return nil }
            parts.append(next)
            last = index + 1
            index += 2
        }
        guard parts.count >= 2 else { return nil }
        return (parts.joined(separator: ".").lowercased(), last)
    }

    /// The address's local part, read backwards from the token before "at".
    ///
    /// Bounded at six tokens, but the bound is a safety net rather than the rule
    /// — the stop words are what actually decide. "send it to the Gmail Grace
    /// Kingston 20 at gmail.com" stops at "Gmail", because there the provider's
    /// name describes the service rather than forming part of the address.
    ///
    /// Six because spelling an address out digit by digit is a real thing people
    /// do — "roman gigliotti one two three" is five tokens before the digits are
    /// even folded — and because the bound is the backstop, not the rule. What
    /// actually decides is the stop-word list, which was checked by replaying
    /// every transcript on this machine and fixed where it was wrong.
    private static func readLocalPart(_ tokens: [String], endingBefore at: Int)
    -> (text: String, firstIndex: Int, stoppedOn: String?, words: [String])? {
        var collected: [String] = []
        var index = at - 1
        var firstIndex = at
        /// What ended the scan. `nil` means it ran off the start of the text.
        /// This is the evidence the caller weighs: a local part that ends at
        /// "to" or "email" was introduced as an address; one that ends at "the"
        /// is a noun standing in front of an ordinary "at".
        var stoppedOn: String?

        while index >= 0, collected.count < 6 {
            let raw = tokens[index]
            // A full stop, question mark or exclamation ends the sentence and so
            // ends any address inside it. A comma is only a spoken pause.
            if raw.hasSuffix(".") || raw.hasSuffix("?") || raw.hasSuffix("!") {
                stoppedOn = "."
                break
            }
            let word = bareWord(raw)
            if word.isEmpty { stoppedOn = ""; break }
            if localPartStopWords.contains(word.lowercased()) {
                stoppedOn = word.lowercased()
                break
            }
            guard isNameLike(word) || word.lowercased() == "dot" else {
                stoppedOn = word.lowercased()
                break
            }
            collected.append(word)
            firstIndex = index
            index -= 1
        }

        guard !collected.isEmpty else { return nil }

        var out = ""
        for word in collected.reversed() {
            if word.lowercased() == "dot" {
                // A leading or doubled dot is not something anyone said.
                guard !out.isEmpty, !out.hasSuffix(".") else { return nil }
                out += "."
            } else {
                out += spokenDigits[word.lowercased()] ?? word.lowercased()
            }
        }
        guard out.count >= 2, !out.hasSuffix("."), out.contains(where: { $0.isLetter || $0.isNumber })
        else { return nil }
        return (out, firstIndex, stoppedOn, collected.reversed().map { $0.lowercased() })
    }

    /// Tokens that introduce an address. A local part that ends at one of these
    /// was announced as an address; one that ends at "the" is a noun standing in
    /// front of an ordinary English "at".
    private static let addressIntroducers: Set<String> = [
        "to", "send", "sent", "sends", "sending", "email", "emailed", "mail",
        "mailed", "invoice", "invoiced", "forward", "forwarded", "cc", "bcc",
        "contact", "reach", "ping", "message", "messaged", "write", "wrote",
        "address", "addresses", ".", "",
    ]

    /// Domains that are only ever mail hosts. Nobody reads documentation at
    /// gmail.com, so the host alone is enough evidence.
    private static let mailHosts: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "yahoo.com",
        "icloud.com", "me.com", "mac.com", "proton.me", "protonmail.com",
        "live.com", "aol.com", "yandex.com", "fastmail.com", "gmx.com", "zoho.com",
    ]

    /// Whether "<local> at <domain>" is an address rather than a noun in front of
    /// an ordinary "at".
    ///
    /// The step used to join whenever the words either side were shaped right,
    /// and the stop-word list — determiners, pronouns, verbs — has no entry for
    /// the commonest English shape there is: NOUN + "at" + DOMAIN. So
    /// "read the docs at netlify.com" came out "read the docs@netlify.com", and
    /// "the booking form at kassbarbers.com.au" came out
    /// "the bookingform@kassbarbers.com.au" — two ordinary words glued together
    /// into a fake address, in a sentence about a website.
    ///
    /// One piece of positive evidence is now required. Refusing costs a spoken
    /// address the user can fix; joining wrongly puts a fabricated email address
    /// into their document.
    private static func looksLikeAnAddress(local: String, words: [String],
                                          stoppedOn: String?, domain: String) -> Bool {
        // 1. It was introduced as one — "send it to noah at gmail dot com", or it
        //    began the sentence.
        if addressIntroducers.contains(stoppedOn ?? "") { return true }
        // 2. The domain is a mail host and nothing else.
        if mailHosts.contains(domain.lowercased()) { return true }
        // 3. The local part is not ordinary English: a digit, an internal dot, or
        //    a word the spell checker does not know. "docs" and "form" are words;
        //    "romangigliotti" and "nkass" are not.
        if local.contains(where: \.isNumber) || local.dropLast().contains(".") { return true }
        // Checked WORD BY WORD, not on the joined result. "booking form" joins to
        // "bookingform", which no dictionary knows — so testing the joined string
        // called every two-word noun phrase an address, which is the bug wearing a
        // different hat. If every word the scan collected is ordinary English,
        // this is prose about a website.
        let spoken = words.filter { $0 != "dot" }
        guard !spoken.isEmpty else { return false }
        return spoken.contains { !VocabularyCorrector.isRealEnglishWord($0) }
    }

    /// Words that end a local part when read backwards.
    ///
    /// Two kinds, and both are needed. The verbs and prepositions are what stop
    /// "I'll look at netlify.com" becoming an address — English puts them in front
    /// of "at" constantly and an address never does. The provider names are what
    /// stop his own sentence, "send it to the Gmail Grace Kingston 20 at
    /// gmail.com", from swallowing the word Gmail into the name.
    static let localPartStopWords: Set<String> = [
        // Determiners, pronouns and prepositions. "at" is in here because a
        // sentence can hold two of them — "email me at roman dot gigliotti at
        // outlook dot com" — and without it the first one is read as a name.
        "the", "a", "an", "to", "my", "your", "his", "her", "their", "our", "its",
        "this", "that", "these", "those", "it", "them", "us", "me", "him",
        "and", "or", "but", "of", "in", "on", "for", "with", "from", "by", "at",
        // The verbs that introduce a recipient. These are the ones that sit
        // directly in front of a name, so without them "invoice noah at
        // kassbarbers.com.au" addresses mail to invoicenoah.
        "send", "sent", "sends", "sending", "invoice", "invoiced", "forward",
        "forwarded", "cc", "bcc", "contact", "reach", "ping", "message", "messaged",
        "write", "wrote", "text", "texted", "call", "called", "add", "invite",
        "invited", "notify", "notified", "tell", "told", "ask", "asked", "give",
        // Talking ABOUT an address rather than giving one. Found by replaying his
        // own history: "for example, if I say Roman Gigliotti, 123, at gmail.com"
        // came out as "if isayromangigliotti123@gmail.com" — the verb and the
        // pronoun glued onto the front of the name.
        "i", "we", "you", "he", "she", "they", "who",
        "say", "says", "said", "saying", "mention", "mentions", "mentioned",
        "spell", "spells", "spelled", "spelt", "type", "typed", "hear", "heard",
        "put", "puts", "read", "reads", "example", "like",
        // Verbs English puts in front of "at". Without these the step reads the
        // verb as a name and glues it to the domain.
        "look", "looks", "looked", "looking", "meet", "meets", "met", "meeting",
        "stay", "stayed", "staying", "arrive", "arrived", "arriving",
        "work", "works", "worked", "working", "live", "lives", "lived", "living",
        "sit", "sits", "sat", "stand", "stood", "stop", "stopped", "wait", "waited",
        "start", "started", "point", "pointed", "glance", "glanced", "stare", "stared",
        "laugh", "laughed", "shout", "shouted", "aim", "aimed", "host", "hosted",
        "hosts", "hosting", "is", "was", "are", "were", "be", "been", "am",
        "available", "here", "there", "home", "back", "again", "now", "later",
        // The service, not the address.
        "email", "e-mail", "mail", "gmail", "googlemail", "outlook", "hotmail",
        "yahoo", "icloud", "proton", "protonmail", "inbox", "address",
    ]

    /// Number words that mean a digit when they sit inside an address. "roman
    /// gigliotti one two three" is a person spelling out their own email.
    static let spokenDigits: [String: String] = [
        "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    /// Letters, digits, and nothing else. Deliberately excludes anything already
    /// carrying punctuation, because that is a sentence doing something else.
    private static func isNameLike(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// A suffix that could be a real top-level domain: two to six letters. Rules
    /// out "dot 4" and "dot something-with-punctuation".
    private static func isTopLevelDomain(_ word: String) -> Bool {
        (2...6).contains(word.count) && word.allSatisfy { $0.isLetter }
    }

    /// "gmail.com" and "kassbarbers.com.au" yes; "node.js" and "1.4" no.
    ///
    /// The ".js" exclusion is why this is a list rather than a shape test: three.js
    /// and node.js are exactly the shape of a domain, they are named in his
    /// dictation constantly, and nobody sends mail to them.
    private static func isDottedDomain(_ word: String) -> Bool {
        let labels = word.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        guard labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } })
        else { return false }
        // Every label but the last must contain a letter, so "1.4" is not a domain.
        guard labels.dropLast().allSatisfy({ $0.contains(where: \.isLetter) }) else { return false }
        guard let tld = labels.last.map(String.init), isTopLevelDomain(tld) else { return false }
        return !nonMailSuffixes.contains(tld)
    }

    /// Dotted names that are not places you can send mail.
    static let nonMailSuffixes: Set<String> = ["js", "ts", "py", "rb", "sh", "md", "json", "swift"]

    private static func bareWord(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"'()[]“”‘’"))
    }

    private static func trailingPunctuation(_ token: String) -> String {
        var out = ""
        for character in token.reversed() {
            guard ",.;:!?\"')]".contains(character) else { break }
            out.insert(character, at: out.startIndex)
        }
        return out
    }

    // MARK: - How numbers are written down

    /// Applies the chosen number style, and refuses on everything structural.
    ///
    /// The recogniser is already good at this — "I'm 15 years old" and "6th of
    /// April, 1830" come back as digits, "one of you" and "the two parties" as
    /// words — so the job here is a light rule on top, not an override.
    ///
    /// The refusals are the substance. Checked against his own corpus, where
    /// "On 6 April 1830, the church was organised" would otherwise have shipped as
    /// "On six April 1830", and where 20 of 299 recorded transcripts contain a
    /// bare small digit at all. A number touching a month, a colon, a dollar sign,
    /// a decimal point, an "@" or a hyphen is part of something, and the something
    /// is never prose.
    static func applyNumberStyle(to text: String, style: QuillSettings.Values.NumberStyle) -> String {
        guard style != .asHeard else { return text }

        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out = tokens
        var spelledOut: Set<Int> = []

        for i in tokens.indices {
            let token = tokens[i]
            guard !isStructural(token) else { continue }
            // The style guards belong to the writing convention, so they apply to
            // the mode that IS the writing convention. "Always words" is the blunt
            // mode by definition — someone who picks it has asked for every number
            // spelled out and should get it.
            if style == .spellOutSmall {
                let before = i > 0 ? bareWord(tokens[i - 1]).lowercased() : ""
                let after = i + 1 < tokens.count ? bareWord(tokens[i + 1]).lowercased() : ""
                guard !numberKeepsItsDigits(before: before, after: after) else { continue }
            }

            let word = bareWord(token)

            switch style {
            case .asHeard:
                continue
            case .spellOutSmall:
                // One to nine only. Ten and up read better as digits, which is
                // also what he already gets.
                guard let value = Int(word), (1...9).contains(value) else { continue }
                out[i] = replacingWord(token, with: englishNumber(value))
            case .alwaysWords:
                guard let value = Int(word), (0...9999).contains(value) else { continue }
                out[i] = replacingWord(token, with: englishNumber(value))
            case .alwaysDigits:
                guard let value = numberFromWords(word) else { continue }
                out[i] = replacingWord(token, with: String(value))
                spelledOut.insert(i)
            }
        }

        if style == .alwaysDigits { out = collapseSpokenTens(in: out, writtenBy: spelledOut) }
        return out.joined(separator: " ")
    }

    /// Anything carrying structure — an address, a version, a time, money, a URL,
    /// an identifier. Never prose, so never restyled, in any mode.
    private static func isStructural(_ token: String) -> Bool {
        token.contains("@") || token.contains("/") || token.contains(":")
            || token.contains("$") || token.contains("%") || token.contains("_")
            // A hyphen between digits is a phone number or a range, not two words.
            || (token.contains("-") && token.contains(where: \.isNumber))
            // A dot with a digit on either side is a decimal or a version.
            || hasInternalDot(token)
    }

    private static func hasInternalDot(_ token: String) -> Bool {
        let chars = Array(token)
        for (i, c) in chars.enumerated() where c == "." {
            let previous = i > 0 ? chars[i - 1] : " "
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if previous.isNumber || next.isNumber { return true }
            if previous.isLetter && next.isLetter { return true }
        }
        return false
    }

    /// Whether the words either side say "this number is a date, an age, or a
    /// numbered thing" — all of which keep their digits whatever the mode.
    private static func numberKeepsItsDigits(before: String, after: String) -> Bool {
        if monthNames.contains(before) || monthNames.contains(after) { return true }
        if ageWords.contains(after) || before == "aged" { return true }
        if numberedReferenceWords.contains(before) { return true }
        return false
    }

    static let monthNames: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    /// "5 years old" is an age and stays a numeral; "5 minutes" is a count and
    /// does not.
    static let ageWords: Set<String> = ["years", "year", "yo", "y/o"]

    /// A numbered reference is a label, not a quantity. "See chapter 3", not
    /// "see chapter three".
    static let numberedReferenceWords: Set<String> = [
        "chapter", "version", "page", "step", "part", "figure", "table", "number",
        "no", "item", "level", "round", "phase", "question", "task", "line", "row",
        "column", "section", "room", "unit", "model", "size", "grade", "track",
        "episode", "season", "volume", "issue", "week", "day", "apartment", "suite",
        "build", "rev", "revision", "port", "channel", "tier",
    ]

    /// Replaces the word inside a token, keeping whatever punctuation was attached.
    private static func replacingWord(_ token: String, with replacement: String) -> String {
        let word = bareWord(token)
        guard let range = token.range(of: word) else { return replacement }
        return token.replacingCharacters(in: range, with: replacement)
    }

    /// Spelled English for 0…9999. Beyond that a number is a year or an amount and
    /// spelling it out helps nobody, so `applyNumberStyle` does not ask.
    static func englishNumber(_ value: Int) -> String {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven",
                    "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
                    "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
                    "eighty", "ninety"]
        if value < 20 { return ones[value] }
        if value < 100 {
            let unit = value % 10
            return unit == 0 ? tens[value / 10] : "\(tens[value / 10])-\(ones[unit])"
        }
        if value < 1000 {
            let rest = value % 100
            let head = "\(ones[value / 100]) hundred"
            return rest == 0 ? head : "\(head) and \(englishNumber(rest))"
        }
        let rest = value % 1000
        let head = "\(englishNumber(value / 1000)) thousand"
        return rest == 0 ? head : "\(head) \(englishNumber(rest))"
    }

    /// The single words that mean a number, for the always-digits direction.
    static func numberFromWords(_ word: String) -> Int? {
        let table: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
            "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
            "seventy": 70, "eighty": 80, "ninety": 90,
        ]
        return table[word.lowercased()]
    }

    /// "20 5 people" back into "25 people", after always-digits turned each word of
    /// "twenty five" into its own numeral. Only joins a round ten to a single unit,
    /// which is the only pair that is one spoken number rather than two.
    ///
    /// Works on the tokens, and only on the two this pass just wrote itself.
    ///
    /// It used to run `\b([2-9])0 ([1-9])\b` over the joined sentence, after the
    /// loop above had carefully skipped every structural token — which put it
    /// outside the only guard in this function. A word boundary sits after a colon
    /// and after a dot, so "the 10:30 5 minutes early" became "the 10:35 minutes
    /// early", and "1.20 5 times" became "1.25 times": his own times and version
    /// numbers, the exact tokens `isStructural` exists to protect, silently
    /// rewritten one step after being protected.
    ///
    /// Requiring both halves to be ones this pass spelled out is the tighter
    /// statement of the same intent — the split it repairs is one it caused, so
    /// digits that were already digits in the transcript are left as dictated.
    private static func collapseSpokenTens(in tokens: [String], writtenBy spelledOut: Set<Int>) -> [String] {
        guard !spelledOut.isEmpty else { return tokens }
        var out: [String] = []
        out.reserveCapacity(tokens.count)
        var i = 0
        while i < tokens.count {
            let next = i + 1
            if spelledOut.contains(i), spelledOut.contains(next),
               let tens = Int(tokens[i]), tens >= 20, tens <= 90, tens % 10 == 0,
               let unit = Int(bareWord(tokens[next])), (1...9).contains(unit) {
                out.append(replacingWord(tokens[next], with: "\(tens + unit)"))
                i += 2
                continue
            }
            out.append(tokens[i])
            i += 1
        }
        return out
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
        // "word.Next" -> "word. Next", but not "node.js" -> "node. js".
        //
        // The recogniser writes node.js, three.js and roman-design-co.web.app
        // correctly, and this rule was pulling them apart — after which sentence
        // casing capitalised the fragment, so a correct "node.js" reached the
        // document as "node. Js". Seen on a real dictation, 21 Aug.
        //
        // The test is the shape around the dot rather than a list of known
        // suffixes: a LOWERCASE letter directly after it. A dotted name is
        // lowercase on both sides; a sentence break is followed by a capital,
        // because the recogniser capitalises the sentences it emits. A suffix
        // list was tried first and immediately missed "web.app".
        out = out.replacingOccurrences(
            of: "([.!?])([A-Z])", with: "$1 $2", options: .regularExpression
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
            if capitaliseNext, c.isLetter, startsAnEmailAddress(chars, at: i) {
                // "roman@gmail.com is the address" must not open with a capital R.
                // An address is case-insensitive but it is written lowercase, and
                // a capitalised one reads as a mistake because it is one.
                capitaliseNext = false
            } else if capitaliseNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitaliseNext = false
            } else if capitaliseNext, c.isNumber {
                // The sentence has started; it just started with a number.
                capitaliseNext = false
            } else if c == "." || c == "!" || c == "?" {
                let previous = i > 0 ? chars[i - 1] : " "
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                let isDecimalPoint = c == "." && previous.isNumber && next.isNumber
                // A dot inside a name is not a sentence break either. Same bug
                // as the decimal, found the same way: "the node.js version bump"
                // reached the document as "the node.Js version bump", because
                // the dot armed a capital and the next letter took it. The test
                // is the shape around the dot — letter, dot, lowercase letter,
                // with no space — which is what node.js, three.js and web.app
                // look like and what the end of a sentence never does.
                let isInsideAName = c == "." && previous.isLetter && next.isLowercase
                if !isDecimalPoint, !isInsideAName { capitaliseNext = true }
            }
        }
        return String(chars)
    }

    /// Whether the word beginning at `i` is an email address.
    private static func startsAnEmailAddress(_ chars: [Character], at i: Int) -> Bool {
        var j = i
        while j < chars.count, !chars[j].isWhitespace {
            if chars[j] == "@" { return true }
            j += 1
        }
        return false
    }
}
