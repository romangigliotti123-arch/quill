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
        self.cleaner = NIMCleaner(client: client, vocabulary: Vocabulary.seed.contextualStrings)
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
        // Asserted as a property rather than as one exact string.
        //
        // Every other case in this file pins the whole sentence, and that works
        // because there is only one sensible way to write them. This one has two
        // — "I went to the shop" and "I went to the shop instead" both drop the
        // abandoned clause correctly — so pinning the string tests the model's
        // choice of phrasing rather than the behaviour the feature promises. What
        // the feature promises is that the restarted half is gone and the
        // intended half survives, and that is what is checked.
        let text = try #require(out, "the model returned nothing")
        let lower = text.lowercased()
        #expect(lower.contains("went to the shop"), "lost the intended clause: \(out ?? "nil")")
        #expect(!lower.contains("i mean"), "left the correction cue in: \(out ?? "nil")")
        #expect(!lower.contains("was going to"), "kept the abandoned clause: \(out ?? "nil")")
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
