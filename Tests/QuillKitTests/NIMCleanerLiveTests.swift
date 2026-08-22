import Foundation
import Testing
@testable import QuillKit

/// The self-correction feature against the real NVIDIA endpoint.
///
/// Skipped, not failed, when no key is configured. A suite that goes red on a
/// train is a suite people stop running, and the whole app is built so that a
/// missing network costs nothing — the test suite has to hold itself to the same
/// rule. The offline behaviour these tests shadow is covered exhaustively by
/// `NIMCleanerTests` and `SelfCorrectionTests`, which need no key at all.
///
/// Serialized because the endpoint 429s this key at about three concurrent
/// requests, and a rate-limit failure would read as a correctness failure.
///
/// The deadline here is deliberately generous. Whether the model answers inside
/// 250ms is a latency question, measured in `rig/prompt_d_stability.py` and
/// recorded on `CleanupPrompt`; what these tests ask is whether the answer is
/// right when it does arrive.
enum LiveTests {
    /// Two ways to be off, and both of them are legitimate.
    ///
    /// No key is the train case: the suite skips rather than fails, because the
    /// app itself treats a missing key as a state and not an error.
    /// `QUILL_SKIP_LIVE_TESTS` is the deliberate case — a machine with a key that
    /// still wants a network-free run, which is also how the skip path itself
    /// gets exercised. `.applicationSupportDirectory` resolves through the
    /// password database rather than `$HOME`, so overriding HOME does not hide
    /// the key file and this flag is the only way to reach the other branch.
    static var areEnabled: Bool {
        ProcessInfo.processInfo.environment["QUILL_SKIP_LIVE_TESTS"] == nil && NIMKey.load() != nil
    }
}

@Suite(.serialized, .enabled(if: LiveTests.areEnabled, "no NVIDIA NIM key, or QUILL_SKIP_LIVE_TESTS is set"))
struct NIMCleanerLiveTests {

    let client: NIMClient
    let cleaner: NIMCleaner
    let deadline = Duration.seconds(10)

    /// Spaces the suite out. This key 429s at roughly three requests a second,
    /// and a rate-limit failure reads as a correctness failure — the assertion
    /// says "the model got it wrong" when what happened is that it was never
    /// asked. `.serialized` alone is not enough; the tests run back to back.
    init() async throws {
        let client = NIMClient()
        self.client = client
        self.cleaner = NIMCleaner(client: client, vocabulary: VocabularyFixture.terms)
        try await Task.sleep(for: .seconds(1))
    }

    /// Runs the cleaner, retrying only when it produced nothing at all.
    ///
    /// Not a weakened assertion. A guard rejection and a rate limit both surface
    /// as nil, and only one of them is worth another go — but the two cannot be
    /// told apart from here, so both get retried and a genuine rejection still
    /// fails three times over. What this buys is that a busy endpoint does not
    /// report itself as a broken feature.
    ///
    /// The breaker is reset between attempts. Two 429s latch it open for a minute,
    /// which is exactly right in the app — Roman should not pay a deadline per
    /// dictation while NVIDIA is refusing — and exactly wrong here, where it turns
    /// one rate limit into three silent nils.
    func clean(_ raw: String) async -> String? {
        for attempt in 0 ..< 3 {
            client.resetBreaker()
            if let out = await cleaner.cleanThorough(raw, deadline: deadline) { return out }
            try? await Task.sleep(for: .seconds(3 * (attempt + 1)))
        }
        return nil
    }

    /// Compares ignoring a trailing full stop.
    ///
    /// Not laziness. Measured across 5 identical calls at temperature 0, the
    /// model returns "Let's meet at 4." four times and "Let's meet at 4" once —
    /// terminal punctuation is the one thing it is not deterministic about, and
    /// an exact-match assertion here would be a test that fails one run in five
    /// for a difference nobody can see. The words are what these tests are for.
    func expectWords(_ actual: String?, _ expected: String, _ label: String) {
        let trim = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: ".!")) }
        #expect(actual.map(trim) == trim(expected), "\(label): got \(actual ?? "nil")")
    }

    @Test func theModelIsActuallyReachable() async {
        // Without this, every test below could be silently passing on the offline
        // resolver and the "live" suite would prove nothing.
        var status = await NIMClient().status()
        for _ in 0 ..< 3 {
            if case .serviceBusy = status {
                try? await Task.sleep(for: .seconds(3))
                status = await NIMClient().status()
            } else { break }
        }
        #expect(status.isUsable, "\(status.headline) — \(status.detail)")
    }

    @Test func somethingOnlyTheModelCanDo() async {
        // No repeated run to anchor on and no type-compatible swap, so the
        // deterministic resolver declines. If this passes, the model ran — without
        // it the whole live suite could be green on the offline path.
        let raw = "ring the plumber I mean the electrician"
        #expect(SelfCorrection.resolve(FastCleaner().cleanFast(raw)) == nil)

        let out = await clean(raw)
        print("[live] only-model: \(out ?? "nil")")
        expectWords(out, "Ring the electrician", "only-model")
    }

    @Test func aHalfAppliedCorrectionIsRefusedRatherThanPasted() async {
        // Measured 4 times out of 5: handed "call the plumber no wait ring the
        // electrician instead", the model deletes only the words "no wait" and
        // leaves both versions in the sentence — the user's original complaint,
        // with the one clue that something was wrong now removed. nil here means
        // the untouched fast text ships instead, which is the safe direction.
        let out = await cleaner.cleanThorough(
            "call the plumber no wait ring the electrician instead", deadline: deadline)
        print("[live] half-applied: \(out ?? "nil (refused)")")
        #expect(out?.lowercased().contains("plumber") != true, "pasted a half-applied correction: \(out ?? "")")
    }

    // MARK: - The cases from the bug report

    @Test func replacesARetractedName() async {
        let out = await clean("send it to Noah no wait send it to Carlo")
        print("[live] swap-name: \(out ?? "nil")")
        expectWords(out, "Send it to Carlo", "swap-name")
    }

    @Test func replacesARetractedTime() async {
        let out = await clean("lets meet at 3 actually make that 4")
        print("[live] swap-time: \(out ?? "nil")")
        // The apostrophe is the model's, not FastCleaner's, and the projection
        // allows it: same word, repaired spelling. Offline the same transcript
        // resolves to "Lets meet at 4" — correction applied, contraction not.
        expectWords(out, "Let's meet at 4", "swap-time")
    }

    @Test func replacesARetractedNumber() async {
        let out = await clean("the invoice is for 500 sorry 1500 dollars")
        print("[live] swap-number: \(out ?? "nil")")
        expectWords(out, "The invoice is for 1500 dollars", "swap-number")
    }

    @Test func dropsARestartedSentence() async throws {
        let out = await clean("I was going to the I mean I went to the shop")
        print("[live] restart: \(out ?? "nil")")
        let text = try #require(out, "the model returned nothing")
        let lower = text.lowercased()

        // The cue itself is reliably removed. This part holds every run.
        #expect(!lower.contains("i mean"), "left the correction cue in: \(text)")

        // The rest is a known limitation, recorded rather than hidden.
        //
        // Roughly half the time the model rewrites this to "I went to the shop"
        // and roughly half it keeps both halves — "I was going to the shop, I
        // went to the shop" — which is the abandoned clause surviving with only
        // the clue that something was wrong taken out. Every other case in this
        // file is stable; this one is not, and pinning it green by loosening the
        // assertion would turn a real reliability gap into a passing test.
        //
        // `withKnownIssue` is the honest shape: the suite stays green, the gap
        // stays visible in the run output, and the day it starts passing
        // consistently the framework says so.
        withKnownIssue("the model does not reliably drop a restarted clause", isIntermittent: true) {
            #expect(lower.contains("went to the shop"), "lost the intended clause: \(text)")
            #expect(!lower.contains("was going to"), "kept the abandoned clause: \(text)")
        }
    }

    @Test func dropsAFalseStart() async {
        let out = await clean("we should we should probably ship it tomorrow")
        print("[live] false-start: \(out ?? "nil")")
        expectWords(out, "We should probably ship it tomorrow", "false-start")
    }

    @Test func collapsesRepeatedWords() async {
        let out = await clean("the the build is is failing on CI")
        print("[live] repeat-word: \(out ?? "nil")")
        expectWords(out, "The build is failing on CI", "repeat-word")
    }

    @Test func stripsATrailingAbandonment() async {
        let out = await clean("send Carlo the invoice you know what never mind")
        print("[live] abandon: \(out ?? "nil")")
        expectWords(out, "Send Carlo the invoice", "abandon")
    }

    // MARK: - The cases it must not mangle

    @Test func leavesQuotedCueLanguageAlone() async {
        // nil means "the fast pass is already right", which is what the
        // coordinator wants to hear. Measured: handed these, llama-3.1-8b returns
        // "He walked off." and "Actually, I'm not going to do that." 10 times out
        // of 10 — so it is never handed them.
        for raw in [
            "he said no wait and then walked off",
            "tell them actually is spelled with two Ls",
            "she said sorry and I said sorry back",
        ] {
            let out = await cleaner.cleanThorough(raw, deadline: deadline)
            print("[live] literal \(raw.prefix(20))…: \(out ?? "nil (unchanged)")")
            #expect(out == nil, "mangled: \(raw) -> \(out ?? "nil")")
        }
    }

    // MARK: - It is cleanup, not rewriting

    @Test func doesNotImproveHisProse() async {
        // A transcript with a real correction in it, so it goes to the model, but
        // whose surrounding prose must come back untouched. Earlier prompt
        // variants returned "For the barber shop I'd like the booking form to
        // be..." for text very like this.
        let raw = "ok so for the barber site I want the booking form on the home page "
                + "no wait on its own page and the gallery underneath"
        let out = await clean(raw)
        print("[live] prose: \(out ?? "nil")")
        // Not `if let` — nil would pass every assertion below without testing one
        // of them, and this case is meant to prove the model's answer was *kept*.
        #expect(out != nil, "the answer was refused; the correction is not applied")
        if let out {
            #expect(out.contains("I want"), "tone was changed: \(out)")
            #expect(out.contains("barber site"), "words were changed: \(out)")
            #expect(!out.lowercased().contains("home page"), "the retraction was not applied: \(out)")
            #expect(out.contains("gallery underneath"), "content was dropped: \(out)")
        }
    }

    @Test func keepsRomansOwnWords() async {
        // Measured 3 times out of 3: the model returns "Ship the next build on
        // Tuesday". The projection puts his spelling back rather than throwing
        // the answer away, which is what rejecting on dropped vocabulary would do
        // — and it would do it for most of his sentences.
        let raw = "ship the nxt build on Monday I mean on Tuesday"
        let out = await clean(raw)
        print("[live] vocab: \(out ?? "nil")")
        expectWords(out, "Ship the nxt build on Tuesday", "vocab")
    }

    @Test func neverAddsAPleasantry() async {
        let raw = "send it to Noah no wait send it to Carlo"
        let out = await clean(raw)
        print("[live] pleasantry: \(out ?? "nil")")
        #expect(out != nil)
        for word in ["please", "thanks", "hi ", "hello", "regards", "kind"] {
            #expect(out?.lowercased().contains(word) != true, "added \(word): \(out ?? "")")
        }
    }
}

// MARK: - Homophone pass, against the real endpoint

// Half of these are sentences where the spelling is ALREADY RIGHT. That is the
// point: a pass that fixes every error and also rewrites one correct sentence in
// five is not shippable, and a corpus of only errors cannot tell you which you
// have. Same method as the cleanup bench in CleanupPrompt.swift.
//
// Deliberately excludes anything FastCleaner.corrections already settles for
// free — "principle developer", "no affect on", "loosing the", "stationary
// shop". Benching the model on cases it never sees measures nothing.
/// Both benches sit outside the live SUITE, so they carry their own guard — and
/// `isConfigured` alone was not enough. A machine with a key that has set
/// QUILL_SKIP_LIVE_TESTS still ran them, and a throttled or offline endpoint then
/// reported "fixed 0/6" as a correctness failure rather than as a test that
/// should never have run. `LiveTests.areEnabled` is the same condition the suite
/// uses, and it is the honest one.
@Test(.enabled(if: LiveTests.areEnabled, "no NVIDIA NIM key, or QUILL_SKIP_LIVE_TESTS is set"))
func theHomophonePassOnTheRealModel() async throws {
    // contextRecovery off: this test measures the closed-list pass, and the
    // context pass is benched separately below. Without pinning it, whichever one
    // is currently the default would silently take over this test's numbers.
    let cleaner = NIMCleaner(vocabulary: VocabularyFixture.terms,
                             homophones: true, contextRecovery: { false })
    guard NIMClient().isConfigured else { return }

    // (sentence, the word that must come out) — nil means "must not change".
    let corpus: [(String, String?)] = [
        // Wrong, and only the sentence decides it.
        ("every time Cloudflare cashed something stale", "cached"),
        ("the response is cashed for an hour", "cached"),
        ("the dues were still on the grass", "dews"),
        ("she is the principle architect", "principal"),
        ("a discrete word with the client first", "discreet"),
        ("the flower in the bread recipe", "flour"),
        // Already right. Must survive untouched.
        ("I cashed the cheque on Friday", nil),
        ("the principle of least surprise", nil),
        ("keep the modules discrete and separate", nil),
        ("a compliment from a client is rare", nil),
        ("the flower shop on the corner", nil),
        ("the invoice is past due", nil),
    ]

    var fixed = 0, broke = 0, missed = 0
    for (sentence, expected) in corpus {
        // nil means "nothing better than the fast text", so that is the baseline
        // to compare against — not the raw sentence.
        let baseline = cleaner.cleanFast(sentence)
        let out = await cleaner.cleanThorough(sentence, deadline: .milliseconds(2500)) ?? baseline
        if let expected {
            if out.lowercased().contains(expected) { fixed += 1 }
            else { missed += 1; print("[homophone] MISS  \(sentence) -> \(out)") }
        } else {
            if out.lowercased() == baseline.lowercased() { /* untouched, good */ }
            else { broke += 1; print("[homophone] BROKE \(baseline) -> \(out)") }
        }
    }
    print("[homophone] fixed \(fixed)/6, missed \(missed), damaged \(broke)/6")
    // Measured 21 Aug 2026, meta/llama-3.1-8b-instruct: fixed 3/6, damaged 0/6.
    //
    // The damage bound is the one that has to hold, and it is why the pass is
    // still off by default. A miss costs a correction; a break costs a sentence
    // he meant, silently. Both numbers are pinned so a prompt or list change
    // that trades damage for hits shows up here rather than in his documents.
    //
    // The three it still misses — "cashed for an hour", "dues on the grass",
    // "a discrete word" — are the ones where the deciding context is a single
    // adjacent word. That is what a larger model would buy, if it is ever worth
    // the latency.
    #expect(broke == 0, "rewrote \(broke) sentences that were already correct")
    #expect(fixed >= 3, "fixed \(fixed)/6, was 3/6 when this was written")
}

/// The context pass on the same corpus, so the two are comparable.
///
/// Same twelve sentences, half of them deliberately already correct, because the
/// number that decides this is the damage column and a hit-rate-only corpus
/// cannot see it. That is the discipline `CleanupPrompt.swift` established and it
/// is what caught the first version of this pass rewriting three correct
/// sentences out of six.
@Test(.enabled(if: LiveTests.areEnabled, "no NVIDIA NIM key, or QUILL_SKIP_LIVE_TESTS is set"))
func theContextPassOnTheRealModel() async throws {
    let cleaner = NIMCleaner(vocabulary: VocabularyFixture.terms,
                             homophones: true, contextRecovery: { true })
    guard NIMClient().isConfigured else { return }

    // Sentences of a realistic length, because the pass has a twelve-word floor —
    // a six-word command is not worth most of a second and does not reach the
    // model at all. His own dictations run to a median of eighteen words, so this
    // is also closer to what it will actually see than the short fragments the
    // closed-list bench uses.
    let corpus: [(String, String?)] = [
        ("okay so every time Cloudflare cashed something stale we had to clear it by hand again", "cached"),
        ("the response is cashed for an hour which is why the second load feels instant", "cached"),
        ("the dues were still on the grass when we walked out to the shed that morning", "dews"),
        ("she is the principle architect on the job and she signed off the drawings already", "principal"),
        ("I need to have a discrete word with the client first before anyone else hears about it", "discreet"),
        ("you want about two cups of the flower in the bread recipe or it comes out heavy", "flour"),
        ("the sealing was cracked and stained right through and it needs doing before Friday", "ceiling"),
        ("the doctor put him on a coarse of antibiotics from the chemist for the whole week", "course"),
        ("he rowed the horse along the ridge for an hour before the weather turned on him", "rode"),
        ("she red the letter twice over before answering because she could not believe it", "read"),
        ("I cashed the cheque on Friday afternoon and the money landed in the account overnight", nil),
        ("the principle of least surprise is the one thing I keep coming back to in this design", nil),
        ("keep the modules discrete and separate so that changing one never breaks another", nil),
        ("a compliment from a client is rare enough that I write it down when it happens", nil),
        ("the flower shop on the corner does the arrangements for most of the weddings around here", nil),
        ("the invoice is past due and I still have not heard anything back from their office", nil),
        ("the sealing of the envelope was neat enough that nobody noticed it had been opened", nil),
        ("he rowed the boat across the lake in the dark without a torch or a life jacket", nil),

        // The half that matters for THIS pass. Not one of these pairs is on
        // HomophonePairs, so the closed-list pass cannot reach them at any
        // prompt or any model — it would never even be offered the choice. This
        // is what the generated table is for, and if it fixes none of them the
        // table is not earning its 13 KB.
        ("the sealing was cracked and stained", "ceiling"),
        ("a coarse of antibiotics from the chemist", "course"),
        ("he rowed the horse along the ridge", "rode"),
        ("she red the letter twice before answering", "read"),
        // And the other half, again: already right, must survive.
        ("the sealing of the envelope was neat", nil),
        ("a coarse woollen blanket", nil),
        ("he rowed the boat across the lake", nil),
        ("the ceiling fan needs cleaning", nil),
    ]

    var fixed = 0, broke = 0, missed = 0
    var wanted = 0, correct = 0
    for (sentence, expected) in corpus {
        let baseline = cleaner.cleanFast(sentence)
        let out = await cleaner.cleanThorough(sentence, deadline: .milliseconds(2500)) ?? baseline
        if let expected {
            wanted += 1
            if out.lowercased().contains(expected) { fixed += 1 }
            else { missed += 1; print("[context] MISS  \(sentence) -> \(out)") }
        } else {
            correct += 1
            if out.lowercased() == baseline.lowercased() { /* untouched, good */ }
            else { broke += 1; print("[context] BROKE \(baseline) -> \(out)") }
        }
    }
    print("[context] fixed \(fixed)/\(wanted), missed \(missed), damaged \(broke)/\(correct)")

    // The damage bound is the one that has to hold. Prompt v1 scored 3/6 fixed
    // and 3/6 damaged — it read "change at most one word" as "change one word" —
    // and v2 moves the burden of proof: return it unchanged unless the sentence
    // is impossible as written. The regional-spelling refusal in
    // `ContextProjection` handles the cheque/check case in code, because no
    // amount of context makes Australian spelling the wrong answer.
    #expect(broke == 0, "rewrote \(broke) sentences that were already correct")
}
