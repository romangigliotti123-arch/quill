import AppKit
import Foundation

/// Repairs proper nouns the recogniser has never heard.
///
/// The intended solution was Apple's contextual-strings biasing, and it is wired
/// up in SpeechAnalyzerTranscriber. It does nothing. Measured on this machine:
/// the same audio, transcribed with 0 biasing terms and with 25, produced
/// byte-identical text — "graphify" came out "graph if I" and "Netlify" came out
/// "neglify" either way. The API accepts the terms and ignores them.
///
/// So correction happens after the fact, and it cannot be find-and-replace: the
/// recogniser does not merely mis-spell a word, it splits one word into three.
/// Matching therefore runs over sliding windows of one to three words, comparing
/// a letters-only normalisation by edit distance.
///
/// The danger is over-correction — silently rewriting a word the user meant is
/// worse than leaving a wrong one, because they will not notice it. Two guards:
/// single words must clear a high bar AND not be real English (checked against
/// the system dictionary), and multi-word spans must clear a higher bar still.
public struct VocabularyCorrector: Sendable {

    /// Fixed for tests and for anything scoring a corpus, where the list must not
    /// move underneath the run. Nil in the app, where it comes from the book.
    private let fixedTerms: [String]?
    private let book: VocabularyBook?

    /// Read per call, not per instance.
    ///
    /// The cleaner is built once at launch and lives for the life of the process,
    /// so a corrector holding a snapshot meant a word added in the Dictionary did
    /// nothing at all until the app was relaunched — with the screen reporting it
    /// as added the whole time.
    var terms: [String] { fixedTerms ?? book?.terms ?? [] }

    /// Remembers what each span matched, so re-reading the same sentence is not
    /// re-deciding it. See `MatchMemo` for why this exists.
    private let memo = MatchMemo()

    /// Spans this corrector has actually had to match, as opposed to recognise.
    /// The incremental behaviour is asserted by counting this rather than by
    /// timing, because a clock on a shared machine measures the machine.
    var spansMatchedForTesting: Int { memo.misses }
    func resetTestingCountersForTesting() { memo.resetCounters() }
    /// Tuned against real failures rather than picked round: "craigeburn" vs
    /// "craigieburn" scores 0.91 and must pass; "graphifi" vs "graphify" scores
    /// 0.875 and must pass; ordinary English near-misses must not.
    private let singleWordThreshold: Double
    private let multiWordThreshold: Double

    /// A corrector over a fixed list.
    public init(
        vocabulary: Vocabulary,
        singleWordThreshold: Double = 0.80,
        multiWordThreshold: Double = 0.85
    ) {
        self.fixedTerms = vocabulary.contextualStrings
        self.book = nil
        self.singleWordThreshold = singleWordThreshold
        self.multiWordThreshold = multiWordThreshold
    }

    /// The shipping corrector: follows the vocabulary file as it changes.
    public init(
        book: VocabularyBook = .shared,
        singleWordThreshold: Double = 0.80,
        multiWordThreshold: Double = 0.85
    ) {
        self.fixedTerms = nil
        self.book = book
        self.singleWordThreshold = singleWordThreshold
        self.multiWordThreshold = multiWordThreshold
    }

    public func correct(_ text: String) -> String {
        // Once, at the top: the list must not change between two windows of the
        // same sentence.
        let terms = self.terms
        guard !terms.isEmpty, !text.isEmpty else { return text }

        var tokens = Self.tokenise(text)
        guard !tokens.isEmpty else { return text }

        // Per-term work done once for the whole sentence rather than once per
        // candidate span, and dropped if the Dictionary changed under us.
        let prepared = memo.prepare(terms)

        var index = 0
        while index < tokens.count {
            var replaced = false
            // Longest span first: "next fulfilment" must win over "next" alone.
            for span in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let window = Array(tokens[index ..< index + span])
                // A name does not begin or end with a function word.
                //
                // Without this, "until Craig Eburn is done" matched the span
                // "Craig Eburn is" against "Craigieburn" — close enough by sound
                // once the trailing "is" is folded into the skeleton — and the
                // replacement swallowed the verb: "Until Craigieburn done".
                // Deleting a word the user said is precisely the failure this
                // whole pass is supposed to be too careful to commit.
                guard !Self.isBoundaryWord(window.first?.word),
                      !Self.isBoundaryWord(window.last?.word) || span == 1
                else { continue }
                // A name is split across adjacent WORDS, never across a clause
                // boundary or around a stray mark.
                //
                // Nothing looked at `trailing` when building the candidate, so a
                // full stop inside the span was invisible to matching and then
                // deleted by the replacement, which keeps only the LAST token's
                // trailing:
                //
                //     "Ship the code. Sign the release"  ->  "Ship the codesign the release"
                //     "pushed the code, sign off"        ->  "pushed the codesign off"
                //
                // Two sentences merged into one, and a full stop gone. The comma
                // is in the set for the same reason — carrying it forward instead
                // would produce "the codesign, off", which is no better.
                //
                // A punctuation-only token is a hard boundary too: it contributes
                // nothing to the candidate and would be swallowed by the range
                // that gets replaced, so "I checked - netlify was down" lost its
                // dash.
                //
                // `continue` rather than `break`, so the shorter span is still
                // tried — that is what keeps the legitimate repair in shapes like
                // "Air Tasker. He's".
                guard window.dropLast().allSatisfy({ !$0.trailing.contains(where: { ".,!?;:".contains($0) }) }),
                      window.allSatisfy({ !$0.word.isEmpty })
                else { continue }
                let candidate = window.map(\.word).joined(separator: " ")
                // An email address is not a misheard name. Its local part is
                // whatever the person chose to call themselves, and fuzzy-matching
                // it against the Dictionary would rewrite someone's address —
                // which looks correct and silently mails the wrong person.
                guard !candidate.contains("@") else { continue }
                let key = MatchMemo.Key(candidate: candidate, spanCount: span,
                                        phoneticAllowed: allowsPhoneticMatch(window))
                let resolved: String?
                if let remembered = memo.cached(key) {
                    resolved = remembered
                } else {
                    resolved = bestMatch(for: candidate, spanCount: span,
                                         phoneticAllowed: key.phoneticAllowed,
                                         terms: prepared)
                    memo.remember(key, resolved)
                }
                guard let match = resolved else { continue }

                // Keep the trailing punctuation of the last token in the span.
                // The opening quote or bracket the user said comes back too.
                tokens[index] = Token(leading: window[0].leading, word: match,
                                      trailing: window[span - 1].trailing)
                if span > 1 {
                    tokens.removeSubrange(index + 1 ..< index + span)
                }
                index += 1
                replaced = true
                break
            }
            if !replaced { index += 1 }
        }

        return tokens.map { $0.leading + $0.word + $0.trailing }.joined(separator: " ")
            .replacingOccurrences(of: " \n", with: "\n")
    }

    // MARK: - Matching

    /// `terms` is passed in rather than read from `self` so a sentence is matched
    /// against one list from first window to last, and so the file is stat-ed once
    /// per dictation instead of once per candidate span.
    ///
    /// Prepared rather than raw: `normalise` and `wordCount` of a TERM do not
    /// depend on the candidate, and recomputing them per span was 142 needless
    /// normalisations for every window in the sentence.
    private func bestMatch(for candidate: String, spanCount: Int,
                           phoneticAllowed: Bool, terms: [MatchMemo.Prepared]) -> String? {
        let normalised = Self.normalise(candidate)
        guard normalised.count >= 3 else { return nil }

        let threshold = spanCount == 1 ? singleWordThreshold : multiWordThreshold

        // Depends on the candidate alone, so it is worked out at most once per
        // span instead of once per term. Still lazy: the guard that needs it is
        // reached for a minority of terms, and it is the expensive one — a
        // spell-checker round trip per word.
        var ordinaryCandidate: Bool?
        func candidateIsOrdinaryEnglish() -> Bool {
            if let known = ordinaryCandidate { return known }
            let answer = everyWordIsOrdinaryEnglish(candidate)
            ordinaryCandidate = answer
            return answer
        }

        var best: (term: String, score: Double)?
        for entry in terms {
            let term = entry.term
            let target = entry.normalised
            guard !target.isEmpty else { continue }
            // Cheap length prefilter: nothing this far apart can clear the bar.
            let ratio = Double(min(normalised.count, target.count)) / Double(max(normalised.count, target.count))
            guard ratio >= threshold - 0.15 else { continue }

            if normalised == target {
                // An exact letter match is normally the strongest evidence there
                // is — "fire store" IS "Firestore". But it used to return here
                // before any guard ran, and the letters of a name are not unique
                // to that name. "Builda Bed" normalises to "buildabed" and so
                // does "build a bed", so the shipping seed list turned
                //
                //     "I need to build a bed for the spare room"
                //
                // into "I need to Builda Bed for the spare room" — a sentence of
                // ordinary English, rewritten into a brand, with every guard the
                // corrector owns sitting downstream of the return that did it.
                guard Self.spanCanBe(wordCount: entry.wordCount, spanCount: spanCount)
                else { continue }
                // And the split form must not be a pair that FastCleaner already
                // decided needs an anchor.
                //
                // Those pairs are ordinary English whose letters spell a tool
                // name, so the exact-letters branch — the strongest evidence this
                // corrector has — is exactly wrong for them. "type script tags by
                // hand" became "TypeScript tags by hand" one step after the
                // anchored table had deliberately declined to touch it. The two
                // layers were contradicting each other; they share the list now.
                if spanCount > 1, FastCleaner.ambiguousSplits.contains(normalised) { continue }
                // One word, spelled correctly, whose letters equal a one-word
                // term. The only thing this branch can change about it is its
                // case, and the pass's own rule is that a correctly spelled
                // English word is presumed intentional — so "codesign" said as a
                // word, or "sync", is left as the user wrote it.
                //
                // Scoped to one-word terms so the glued-name repair stays
                // reachable: "whisperflow" → "Wispr Flow" has wordCount 2 and is
                // untouched. `continue`, not `return nil`, so a longer term later
                // in the list can still match this span.
                if spanCount == 1, entry.wordCount == 1, Self.isRealEnglishWord(candidate) { continue }
                return candidate == term ? nil : term
            }
            // Letters first, then sound.
            //
            // Spelling distance is the wrong instrument for a speech error and
            // measurably so. Recorded on Roman's own voice: "Netlify" came back
            // as "net a fly" (0.57 by letters, against a 0.85 bar) and as
            // "Netterfly" (0.67, against 0.80). Both are within a whisker of the
            // target phonetically and nowhere near it alphabetically, so the
            // corrector sat on its hands for exactly the words it exists to fix.
            //
            // The recogniser is not a bad speller. It heard the sounds correctly
            // and assembled the wrong letters out of them, so the comparison that
            // matches its failure mode is the one done on sound.
            let score = Self.similarity(normalised, target)
            guard Self.spanCanBe(wordCount: entry.wordCount, spanCount: spanCount)
            else { continue }
            // A span of entirely ordinary English matched against a multi-word
            // term has to be near-exact, not merely close.
            //
            // "Roman design cost" scores 0.867 against "Roman Design Co" and
            // cleared the 0.85 bar, so "the Roman design cost a lot more than I
            // thought" became "the Roman Design Co a lot more than I thought" —
            // the verb deleted, mid-sentence, silently. Every word in that span
            // is a word he meant. The single-word route has refused real English
            // since the start (below); the multi-word route had no such check at
            // all, which is the harder half, because that is where words get
            // deleted rather than merely respelled.
            let ordinaryPhrase = spanCount > 1 && entry.wordCount > 1
                && candidateIsOrdinaryEnglish()
            let bar = ordinaryPhrase ? Self.ordinaryPhraseThreshold : threshold
            if score >= bar, score > (best?.score ?? 0) {
                best = (term, score)
            } else if phoneticAllowed,
                      // Sound is only evidence when the spelling is at least in
                      // the same neighbourhood.
                      //
                      // "y t dlp" — the recogniser spelling out yt-dlp — was
                      // being replaced by "Netlify". They share 0.143 of their
                      // letters. A genuine mishearing of a name still LOOKS
                      // something like the name: the cases this route exists for
                      // score 0.57 ("net a fly"), 0.67 ("Netterfly") and 0.73
                      // ("Craigie Bear"). Nothing real lands near zero, so a
                      // floor well below every observed repair costs nothing and
                      // stops sound alone carrying a match it cannot support.
                      //
                      // `score` IS similarity(normalised, target), computed just
                      // above; it was being recomputed here and the phonetic key
                      // built three times over for a single term.
                      score >= Self.phoneticLettersFloor {
                let sound = Self.phoneticSimilarity(normalised, target)
                if sound >= Self.phoneticThreshold, sound > (best?.score ?? 0) {
                    best = (term, sound)
                }
            }
        }

        guard let best else { return nil }
        // A correctly spelled English word is presumed intentional.
        if spanCount == 1, isRealEnglishWord(candidate) { return nil }
        return best.term
    }

    // MARK: - Spell checking, remembered

    /// `NSSpellChecker` is a cross-process call, up to four of them per word, and
    /// the same words recur on every pass over a growing transcript. The answer
    /// for a given word cannot change within a run.
    func isRealEnglishWord(_ word: String) -> Bool {
        memo.isEnglish(word) { Self.isRealEnglishWord($0) }
    }

    func everyWordIsOrdinaryEnglish(_ span: String) -> Bool {
        let words = span.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard !words.isEmpty else { return false }
        return words.allSatisfy { isRealEnglishWord($0) }
    }

    /// A multi-word term can only be spoken as that many words.
    ///
    /// "Builda Bed" is two words. A three-word span collapsing into it is not the
    /// recogniser mis-hearing a name, it is a sentence. Single-word terms are
    /// exempt, because a name arriving as several words is the exact failure this
    /// whole pass exists for: "graphify" comes back as "graph if I", "Firestore"
    /// as "fire store", "blockcraft" as "block craft".
    static func spanCanBe(_ term: String, spanCount: Int) -> Bool {
        spanCanBe(wordCount: wordCount(term), spanCount: spanCount)
    }

    /// The same rule, given the term's word count already worked out. The hot
    /// loop has it to hand; recounting the words of all 142 terms for every
    /// candidate span was pure repetition.
    static func spanCanBe(wordCount words: Int, spanCount: Int) -> Bool {
        // A single-word span is the recogniser having GLUED the name together —
        // "Wispr Flow" heard as "Whisperflow" — which is the same failure as
        // splitting one, and must stay reachable.
        return words <= 1 || spanCount == 1 || words == spanCount
    }

    static func wordCount(_ term: String) -> Int {
        term.split(whereSeparator: { $0 == " " || $0 == "-" }).count
    }

    /// Near-exact, for spans where nothing looks misheard.
    static let ordinaryPhraseThreshold = 0.95

    /// How alike two strings must LOOK before their sounds are allowed to decide.
    /// Set below every repair this route has ever made (the lowest is 0.57) and
    /// far above the collisions it has caused (0.143).
    static let phoneticLettersFloor = 0.45

    static func everyWordIsOrdinaryEnglish(_ span: String) -> Bool {
        let words = span.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard !words.isEmpty else { return false }
        return words.allSatisfy { isRealEnglishWord($0) }
    }

    /// Words that can never be the first or last part of a name.
    ///
    /// Short, and only the ones that actually turn up glued to a proper noun by
    /// the recogniser. A longer list would start rejecting real multi-word terms.
    static func isBoundaryWord(_ word: String?) -> Bool {
        guard var word = word?.lowercased(), !word.isEmpty else { return false }
        // A contraction is its pronoun for this purpose: "he's" ends a span just
        // as surely as "he" does, and listing every contracted form would go
        // stale the first time the recogniser picked a different apostrophe.
        if let cut = word.firstIndex(where: { $0 == "'" || $0 == "\u{2019}" }) {
            word = String(word[word.startIndex ..< cut])
        }
        word = word.trimmingCharacters(in: .punctuationCharacters)
        guard !word.isEmpty else { return false }
        return boundaryWords.contains(word)
    }

    static let boundaryWords: Set<String> = [
        "is", "was", "are", "were", "be", "been", "the", "a", "an", "to", "of",
        "and", "or", "but", "if", "in", "on", "at", "it", "its", "this", "that",
        "for", "from", "with", "by", "as", "so", "then", "than", "do", "does",
        "did", "has", "have", "had", "will", "would", "can", "could", "not",
        // Pronouns, added 21 Aug 2026 after a real dictation lost one.
        //
        //     recogniser:  "The client found me on Air Tasker. He's been discreet"
        //     inserted:    "The client found me on Airtasker been discreet"
        //
        // "Air Tasker He's" is a three-word span, it did not end in any of the
        // closed-class words above, so the guard let it through and the match
        // collapsed all three into "Airtasker" — taking the pronoun with it.
        // Same shape as the "Until Craigieburn done" case this guard exists for;
        // the list simply did not go far enough. Measured on the shipping
        // corrector, "she", "we" and "you" were being eaten the same way.
        //
        // "I" is deliberately NOT here, and that is not an oversight. The
        // canonical repair this whole pass exists for is
        //
        //     "Push the graph if I build"  ->  "Push the graphify build"
        //
        // which is a three-word span ending in "I". Listing "i" blocks it, as
        // the test suite says immediately. A pronoun that turns up INSIDE a
        // misheard name has to stay matchable, and "I" is the only one that
        // does — every other pronoun in this list was observed being deleted
        // from a sentence, never spelling part of a word.
        "he", "she", "we", "they", "you", "him", "her", "them", "us",
        "my", "your", "his", "our", "their",
    ]

    /// # Why there is no "ask a model about the near-misses" pass
    ///
    /// The tempting design, after watching "The site's on Netlify" come back as
    /// "The sites are not a fly": use this scorer as a cheap DETECTOR — flag any
    /// span that sounds like a term even when the guard refuses to act — and let
    /// a model decide. The guard stays strict; the model does the judging.
    ///
    /// Measured before building it, 21 Aug 2026, and it does not work. The
    /// phonetic skeleton at a 0.70 floor flags **11 of 12 ordinary sentences**
    /// against the shipped seed vocabulary:
    ///
    ///     "not leave"      -> Netlify          1.00
    ///     "Friday and"     -> Builda Bed       0.80
    ///     "colour looked"  -> Carlo Gigliotti  0.80
    ///     "caps for"       -> Vesper           0.80
    ///     "second"         -> subagent         0.80
    ///
    /// The real manglings score 0.75 ("not a fly" -> Netlify), 0.75 ("sing
    /// thinking" -> Syncthing) and 0.86 ("types group" -> TypeScript). Ordinary
    /// English reaches 1.00. There is no threshold between them, so the detector
    /// would fire on nearly every dictation — a request on the critical path,
    /// every time, asking a model whether ordinary words are product names.
    /// That is the setup that produces damage, not the one that avoids it.
    ///
    /// This is why `allowsPhoneticMatch` requires a non-word in the span. The
    /// restriction is not conservatism, it is the only thing separating signal
    /// from noise, and the numbers above are what that looks like without it.
    ///
    /// Whether the sound-based route may fire for this span at all.
    ///
    /// It may not, unless at least one word in the span is not English. This is
    /// the guard that keeps a useful feature from becoming a destructive one.
    ///
    /// Sound matching is powerful precisely because it ignores spelling, and that
    /// is also how it gets you killed: "net a fly" and "not a fly" have the same
    /// consonant skeleton, so the rule that rescues "Netlify" from the first would
    /// silently plant "Netlify" in the middle of the second. Nothing in the audio
    /// distinguishes them — only the surrounding sentence does, and this pass does
    /// not read the sentence.
    ///
    /// So the route is restricted to spans containing something that is not a
    /// word: "Netterfly", "grapify", "Craig Eburn", "Noah Kess". Those cannot be
    /// what anybody meant to say, so replacing them risks nothing. A span of
    /// entirely ordinary English is left alone even when it scores well, which
    /// means "net a fly" survives uncorrected — a miss this design accepts on
    /// purpose, because the alternative is rewriting sentences the user meant.
    private func allowsPhoneticMatch(_ window: [Token]) -> Bool {
        window.contains { !$0.word.isEmpty && !Self.isRealEnglishWord($0.word) }
    }

    /// How close two strings are as *sounds* rather than as spellings.
    ///
    /// A deliberately small phonetic model — the classic consonant-skeleton
    /// approach, which is all that is needed here because the candidates are
    /// already known to be near-misses of a short list of proper nouns, not
    /// arbitrary English.
    ///
    /// Distance is Damerau-Levenshtein rather than plain Levenshtein because
    /// transposition is the characteristic speech error: "net a fly" against
    /// "Netlify" is NTFL against NTLF, one swap apart and two substitutions apart
    /// if you cannot see the swap.
    static let phoneticThreshold = 0.72

    /// Below this, a sound key is too small to mean anything.
    ///
    /// "quill" reduces to "kl" and so does "colour". A two-character skeleton
    /// collides with half the language, and matching on one is not evidence of
    /// anything — it is a coin flip that silently rewrites a word. Short terms
    /// are still reachable by spelling, which is the right instrument for them.
    static let minimumPhoneticKeyLength = 4

    static func phoneticSimilarity(_ a: String, _ b: String) -> Double {
        let ka = phoneticKey(a), kb = phoneticKey(b)
        guard ka.count >= minimumPhoneticKeyLength,
              kb.count >= minimumPhoneticKeyLength else { return 0 }
        if ka == kb { return 1 }
        let distance = damerauLevenshtein(Array(ka), Array(kb))
        return 1.0 - Double(distance) / Double(max(ka.count, kb.count))
    }

    /// Consonant skeleton with the sounds English confuses folded together.
    ///
    /// Vowels go entirely after the first character: they are the least reliable
    /// thing a recogniser produces and the first thing it gets wrong in an
    /// unfamiliar word. What survives is the consonant frame, which is what makes
    /// "graph if I", "grapify" and "graphify" the same key.
    static func phoneticKey(_ s: String) -> String {
        let lower = Array(s.lowercased().filter { $0.isLetter })
        guard !lower.isEmpty else { return "" }
        var out: [Character] = []
        var i = 0
        while i < lower.count {
            let c = lower[i]
            // Digraphs first, or "ph" becomes P and F and never matches.
            if i + 1 < lower.count {
                let pair = String([c, lower[i + 1]])
                let mapped: Character?
                switch pair {
                case "ph": mapped = "f"
                case "gh": mapped = "f"       // "laugh"; silent in "night" but harmless here
                case "ck": mapped = "k"
                case "sh", "ch": mapped = "x"
                case "th": mapped = "0"
                case "qu": mapped = "k"
                default:   mapped = nil
                }
                if let mapped {
                    if out.last != mapped { out.append(mapped) }
                    i += 2
                    continue
                }
            }
            let folded: Character?
            switch c {
            case "a", "e", "i", "o", "u", "y", "h", "w":
                // Keep a leading vowel: "iOS" and "OS" must not collide.
                folded = out.isEmpty ? c : nil
            case "b", "p", "v", "f": folded = "f"   // voiced/unvoiced pairs are
            case "c", "k", "g", "q", "j": folded = "k"  // routinely swapped by ASR
            case "d", "t": folded = "t"
            case "s", "z", "x": folded = "s"
            case "m", "n": folded = "n"
            case "l", "r": folded = "l"
            default: folded = c
            }
            if let folded, out.last != folded { out.append(folded) }
            i += 1
        }
        return String(out)
    }

    /// Levenshtein plus transposition. A swap costs one, not two.
    static func damerauLevenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    /// 1.0 is identical. Levenshtein normalised by the longer string.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let distance = levenshtein(Array(a), Array(b))
        return 1.0 - Double(distance) / Double(max(a.count, b.count))
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0 ... b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            current[0] = i
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Letters only, lowercased. Spaces go too, which is the point — it is what
    /// lets "graph if I" and "graphify" be compared at all.
    static func normalise(_ s: String) -> String {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.letters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// A word in ANY English this user might write, not just American.
    ///
    /// This asked "en" alone, which is US English, so "colour", "realise",
    /// "organised" and "metre" were all reported as non-words — and a non-word is
    /// exactly what unlocks the sound-based repair. On an Australian user's
    /// machine that turned the guard inside out: the spellings he uses every day
    /// became the ones most eligible to be silently rewritten. Measured on his
    /// own voice, "The colour on the second panel" came out "The Quill on the
    /// second panel".
    ///
    /// Asking every variant costs a few microseconds against a decision that
    /// otherwise damages text nobody will re-read closely enough to catch.
    static func isRealEnglishWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
        guard !trimmed.isEmpty else { return false }
        for language in englishVariants {
            let range = NSSpellChecker.shared.checkSpelling(
                of: trimmed, startingAt: 0, language: language,
                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            )
            // location == NSNotFound means the spell checker found nothing wrong.
            if range.location == NSNotFound { return true }
        }
        return false
    }

    /// The user's own English first, so the common case answers on one call.
    static let englishVariants: [String] = {
        var out: [String] = []
        if let preferred = Locale.preferredLanguages.first(where: { $0.hasPrefix("en") }) {
            out.append(preferred.replacingOccurrences(of: "-", with: "_"))
        }
        for fallback in ["en_AU", "en_GB", "en_US", "en"] where !out.contains(fallback) {
            out.append(fallback)
        }
        return out
    }()

    // MARK: - Tokens

    struct Token {
        /// Punctuation that came before the word — an opening quote, a bracket,
        /// a bullet. It used to be left inside `word`, and a match rebuilt the
        /// token as `Token(word: match, …)`, so it was silently deleted:
        ///
        ///     he said "Netlify" was down   ->   he said Netlify" was down
        var leading: String = ""
        var word: String
        /// Punctuation that followed the word, preserved so correcting a term
        /// never eats the comma after it.
        var trailing: String
    }

    static func tokenise(_ text: String) -> [Token] {
        text.split(separator: " ", omittingEmptySubsequences: true).map { chunk in
            let s = String(chunk)
            // Trailing first, then leading off what is left. The other order
            // makes a chunk that is entirely punctuation — a lone quote, a dash —
            // land in both fields and get emitted twice.
            let trailing = s.suffix(while: { $0.isPunctuation || $0.isSymbol })
            let core = String(s.dropLast(trailing.count))
            let leading = core.prefix(while: { $0.isPunctuation || $0.isSymbol })
            return Token(leading: String(leading),
                         word: String(core.dropFirst(leading.count)),
                         trailing: String(trailing))
        }.filter { !$0.word.isEmpty || !$0.trailing.isEmpty || !$0.leading.isEmpty }
    }
}

private extension String {
    func suffix(while predicate: (Character) -> Bool) -> String {
        var result = ""
        for ch in reversed() {
            guard predicate(ch) else { break }
            result.insert(ch, at: result.startIndex)
        }
        return result
    }
}

/// What each span matched last time, so a growing transcript is not re-decided
/// from scratch on every keystroke.
///
/// Live typing calls `cleanFast` on the WHOLE transcript so far, once per
/// partial, on the main thread. That is the right thing for correctness — the
/// text on screen has to agree with the text that will be inserted — but it
/// means a dictation of N characters runs the matcher over a growing prefix
/// N/20-ish times, and the matcher is the expensive part: measured at 0.67ms per
/// character, so 543ms for one pass over 800 characters and 1.1s over 1600.
/// Quadratic in the length of what you said, all of it on the thread that draws
/// the waveform and services the key release.
///
/// The matcher is a pure function of (span, span length, whether sound is
/// allowed to decide) and the term list, so the second pass over a sentence can
/// only reach the same answers as the first. This remembers them.
///
/// The normalised form and word count of each TERM are hoisted here too. They
/// were being recomputed inside the term loop — 142 terms re-normalised for
/// every candidate span in the sentence — which is most of the cost of the
/// misses that are left.
final class MatchMemo: @unchecked Sendable {

    struct Key: Hashable {
        let candidate: String
        let spanCount: Int
        let phoneticAllowed: Bool
    }

    /// A term with the two things the matcher asks of it already worked out.
    struct Prepared {
        let term: String
        let normalised: String
        let wordCount: Int
    }

    /// Past this the cache is dropped rather than grown. A long session has no
    /// business holding every span anyone ever said, and rebuilding it costs one
    /// slow sentence, not a slow app.
    private static let capacity = 20_000

    private let lock = NSLock()
    private var termsFingerprint: [String] = []
    private var prepared: [Prepared] = []
    private var entries: [Key: String?] = [:]
    /// Spell-checker answers. Each miss is up to four cross-process calls, and
    /// the same handful of words recur on every pass over the same sentence.
    private var englishWords: [String: Bool] = [:]
    private var _misses = 0

    var misses: Int { lock.lock(); defer { lock.unlock() }; return _misses }
    func resetCounters() { lock.lock(); _misses = 0; lock.unlock() }

    /// Returns the term list with its per-term work already done, dropping
    /// everything remembered if the list itself has changed — a word added in the
    /// Dictionary has to take effect on the next sentence, which is the whole
    /// reason `terms` is read per call rather than held.
    func prepare(_ terms: [String]) -> [Prepared] {
        lock.lock(); defer { lock.unlock() }
        if terms != termsFingerprint {
            termsFingerprint = terms
            prepared = terms.map {
                Prepared(term: $0,
                         normalised: VocabularyCorrector.normalise($0),
                         wordCount: VocabularyCorrector.wordCount($0))
            }
            entries.removeAll(keepingCapacity: true)
        }
        return prepared
    }

    /// The remembered answer, or nil if this span has not been decided yet.
    /// The value is itself optional — "decided, and the answer was no match" is a
    /// result worth remembering, and it is by far the most common one.
    func cached(_ key: Key) -> String?? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    func remember(_ key: Key, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        _misses += 1
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = value
    }

    func isEnglish(_ word: String, _ compute: (String) -> Bool) -> Bool {
        lock.lock()
        if let known = englishWords[word] { lock.unlock(); return known }
        lock.unlock()
        let answer = compute(word)
        lock.lock()
        if englishWords.count >= Self.capacity { englishWords.removeAll(keepingCapacity: true) }
        englishWords[word] = answer
        lock.unlock()
        return answer
    }
}
