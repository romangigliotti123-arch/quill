import Foundation

/// Which model Quill talks to, how it is asked, and how long it is allowed to take.
///
/// Everything here was measured, not chosen. The benchmark is below and it is
/// kept in the file rather than a document because the numbers are the argument:
/// change the model and you are claiming these numbers no longer apply.
///
/// # Benchmark — 2026-08-09, Melbourne, MacBook Air M5, home wifi
///
/// Method: one keep-alive HTTPS connection per model (what URLSession gives the
/// app after the first call), 4 real Quill transcripts × 5–10 reps each,
/// temperature 0, max_tokens 120, wall-clock from request write to full body
/// read. Candidates were drawn from the live `/v1/models` list, not from memory.
///
/// ## Pass 1 — raw recogniser output straight to the model
///
///     model                              p50      p90     verdict
///     ─────────────────────────────────────────────────────────────────────────
///     meta/llama-3.1-8b-instruct        328ms    512ms    best latency, clean output
///     nvidia/nemotron-mini-4b-instruct  600ms    719ms    wraps output in quotes, splits sentences
///     mistralai/mistral-nemotron        614ms    751ms    HALLUCINATED: "neglify" → "Nebula"
///     google/gemma-4-31b-it            1184ms   2920ms    best accuracy, 3.6× the latency
///     openai/gpt-oss-20b               1250ms   2866ms    UNUSABLE: content is null, all 120
///                                                         tokens go to reasoning_content
///     deepseek-ai/deepseek-v4-flash    5073ms   6796ms    good output, far too slow
///     meta/llama-3.2-3b-instruct      17043ms  24093ms    slowest and worst; also timed out 4/20
///     minimaxai/minimax-m3                  —        —    429 rate-limited before p50 was meaningful
///
/// Models present in `/v1/models` but 404 for this account — the list is a
/// catalogue, not an entitlement: mistral-7b-instruct-v0.3, gemma-3-4b-it,
/// gemma-3-12b-it, mistral-nemo-12b-instruct, granite-3.0-8b-instruct,
/// zamba2-7b-instruct, nemotron-51b-instruct, kimi-k2.6, phi-3.5-moe-instruct.
/// llama-3.3-70b-instruct returned 503 "Worker local total request limit
/// reached". This is why `NIMError` has a distinct `.modelUnavailable`.
///
/// ## Pass 2 — FastCleaner output to the model, which is the real pipeline
///
/// FastCleaner already repairs the proper nouns better than any model did:
/// "the graph if I build to neglify" → "the graphify build to Netlify" in under
/// 2ms, offline. What it cannot do is spoken self-correction — "send it to Noah
/// no wait send it to Carlo" comes out untouched. So the model's job is only the
/// part rules cannot express, and it is handed already-corrected text.
///
///     model                              p50      p90     self-corrections right
///     ─────────────────────────────────────────────────────────────────────────
///     meta/llama-3.1-8b-instruct         306ms    381ms   2/2  — identical text to gemma, 5.5× faster
///     google/gemma-4-31b-it             1678ms   4271ms   2/2  — no better, and p90 is 11× llama's
///     nvidia/nemotron-mini-4b-instruct   594ms    656ms   1/2  — rewrote a sentence and re-added quotes
///
/// ## The 250ms question
///
/// No. Not this model, and not any model on this endpoint.
///
/// The floor is the network, not the GPU. On a warm keep-alive connection from
/// Melbourne, a bare `GET /v1/models` round-trips in 146–197ms and a completion
/// capped at ONE token costs 195–223ms. That is the price of asking, before a
/// single useful token is generated. A cold connection adds a 294ms TLS
/// handshake on top.
///
/// Against llama-3.1-8b-instruct, share of real calls finishing inside a given
/// deadline (n=37, warm connection):
///
///     250ms → 11%      350ms → 78%      450ms → 97%
///     300ms → 46%      400ms → 89%      500ms → 97%
///
/// At the coordinator's current 250ms the model pass wins about one dictation in
/// nine, and the other eight pay the full 250ms wait to throw the answer away.
/// That is the worst of both: slower than no AI at all, and almost never AI.
///
/// 450ms is the smallest deadline at which the pass is worth having — 97% of
/// calls land, and the pause between releasing the key and seeing text stays
/// under half a second. Below ~400ms the arithmetic stops working.
///
/// Better still, and cheap: only spend the deadline when the model has something
/// to add. FastCleaner handles disfluency, punctuation and vocabulary offline in
/// under 2ms; the one thing it cannot do is spoken self-correction. Gate the AI
/// call on a retraction cue in the transcript ("no wait", "actually", "make that",
/// "scratch that", "I mean") and most dictations pay nothing at all, while the
/// ones that need it get the full 450ms. That is a DictationCoordinator change,
/// not a client one, so it is recorded here rather than done here.
public struct AIConfig: Sendable, Equatable {

    /// OpenAI-compatible endpoint. Kept as a base so a self-hosted NIM container
    /// can be pointed at without touching the client.
    public var baseURL: URL
    public var model: String
    public var systemPrompt: String
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double

    /// Per-attempt ceiling. Distinct from the caller's deadline: the deadline is
    /// a promise to the user, this is a promise to the socket. Whichever is
    /// shorter wins.
    public var requestTimeout: Duration
    /// Total attempts including the first. Retries are still bounded by the
    /// caller's deadline, so on the dictation path this is usually academic.
    public var maxAttempts: Int
    public var initialBackoff: Duration
    /// After this many consecutive network failures the client stops trying
    /// until `breakerCooldown` has passed. Roman dictates on trains; without
    /// this, every single dictation in a tunnel pays the full deadline in dead
    /// waiting before falling back to text it could have had immediately.
    public var breakerThreshold: Int
    public var breakerCooldown: Duration

    public static let defaultBaseURL = URL(string: "https://integrate.api.nvidia.com/v1")!

    /// There is deliberately no vocabulary list in here, and that took four
    /// measured variants to arrive at. 20 runs per variant per transcript,
    /// llama-3.1-8b, sequential so rate limiting could not skew it:
    ///
    ///     variant                          self-correction   keeps "nxt"   p50
    ///     ────────────────────────────────────────────────────────────────────
    ///     A  list of proper nouns             16/20            20/20      494ms
    ///     B  no list, no protection rule      20/20             0/20      291ms
    ///     C  list + "do not introduce these"   0/20            20/20      317ms
    ///     D  protection rule, no list         20/20             0/20      302ms
    ///     E  terse protection rule            13/20             0/20      323ms
    ///
    /// The list is a word bank, and the model spends from it. With variant A,
    /// "send it to Noah no wait send it to Carlo instead and tell him the bed
    /// frames are ready" came back four different ways across 20 runs, including
    /// "Carlo, the Builda Bed frames are ready" — a brand lifted out of the
    /// prompt and pasted into a sentence that never mentioned it. Variant C, the
    /// obvious fix, was the worst of the lot: 0/20.
    ///
    /// So the list comes out, and the thing the list was protecting — Roman's
    /// vocabulary surviving the round trip — is enforced deterministically after
    /// the fact by `AIOutputGuard`, which can do it perfectly and for free.
    /// Prompting is not the right tool for a constraint that is checkable.
    ///
    /// Note the second column is also why the guard is needed rather than
    /// optional: every list-free variant turns "nxt" into "next".
    ///
    /// Length is a cost, not a style question — every token here is prefill on
    /// the critical path, and A was 190ms slower than B for that reason alone.
    public static let cleanupSystemPrompt = """
        You clean up raw speech-to-text dictation. Return ONLY the cleaned text, no preamble, no quotes, no explanation.
        Rules:
        - Fix punctuation, capitalisation and obvious mis-hearings.
        - Remove filler words (um, uh, so, like) and stutters.
        - Apply spoken self-corrections: keep what the speaker settled on and delete what they retracted, including the retraction phrase itself.
        - Never add, answer, summarise or invent content. Same meaning, same words where possible.
        - The text contains product, project and place names that are not ordinary English. Keep every such word exactly as written; never delete one and never replace it with a similar English word.
        """

    public static let `default` = AIConfig(
        baseURL: defaultBaseURL,
        // See the benchmark above. On the real pipeline it produced character-
        // identical output to the largest model tested, 5.5× faster at p50 and
        // 11× faster at p90. There is no accuracy being traded away here.
        model: "meta/llama-3.1-8b-instruct",
        systemPrompt: cleanupSystemPrompt,
        // A cleanup is never longer than what went in. Capping low also caps the
        // damage a model does when it decides to answer the dictation instead of
        // tidying it, and caps the time it can spend doing so.
        maxTokens: 160,
        temperature: 0,
        topP: 1,
        requestTimeout: .seconds(8),
        maxAttempts: 3,
        initialBackoff: .milliseconds(250),
        breakerThreshold: 2,
        breakerCooldown: .seconds(60)
    )

    public init(
        baseURL: URL = AIConfig.defaultBaseURL,
        model: String,
        systemPrompt: String,
        maxTokens: Int,
        temperature: Double,
        topP: Double,
        requestTimeout: Duration,
        maxAttempts: Int,
        initialBackoff: Duration,
        breakerThreshold: Int,
        breakerCooldown: Duration
    ) {
        self.baseURL = baseURL
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.requestTimeout = requestTimeout
        self.maxAttempts = maxAttempts
        self.initialBackoff = initialBackoff
        self.breakerThreshold = breakerThreshold
        self.breakerCooldown = breakerCooldown
    }

    var chatCompletionsURL: URL { baseURL.appendingPathComponent("chat/completions") }
    var modelsURL: URL { baseURL.appendingPathComponent("models") }
}

// MARK: - Deadlines

public extension AIConfig {

    /// DictationCoordinator's current deadline. Named so the number below can be
    /// compared against it in one place instead of being restated.
    static let currentCoordinatorDeadline: Duration = .milliseconds(250)

    /// What the deadline should be if the model pass is ever to fire.
    ///
    /// 450ms. Measured: 97% of llama-3.1-8b-instruct calls finish inside it,
    /// against 11% inside the current 250ms. See the benchmark on AIConfig.
    static let recommendedCleanupDeadline: Duration = .milliseconds(450)
}

// MARK: - Output sanitising

/// The guard between a language model and Roman's keyboard.
///
/// Everything here exists because the paste target is an app we do not control,
/// and text is inserted without review. A model that answers the dictation
/// instead of tidying it, or wraps the result in quotes, or emits its own
/// reasoning, must fail closed to the deterministic pass — not paste.
public enum AIOutputGuard {

    /// Returns cleaned text, or nil if the response cannot be trusted. Nil means
    /// "use the fast pass", never "show an error".
    ///
    /// `preserving` is Roman's vocabulary. Any term that went into the model and
    /// did not come back out means the model normalised one of his words, and
    /// the whole response is rejected — see `droppedVocabulary`.
    public static func sanitise(
        _ raw: String, against input: String, preserving terms: [String] = []
    ) -> String? {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }

        out = stripCodeFence(out)
        out = stripLeadingLabel(out)
        out = stripWrappingQuotes(out)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }

        // A model that starts explaining has stopped cleaning. Multi-paragraph
        // output for a single dictated sentence is the tell.
        if out.contains("\n\n"), !input.contains("\n\n") { return nil }

        // Length bounds, on characters rather than tokens because the check has
        // to be as cheap as the thing it is protecting. The ceiling catches the
        // model answering the dictation instead of tidying it; the floor catches
        // it summarising.
        //
        // Both were sized against real transcripts. The heaviest legitimate
        // shrink measured is the self-correction case — "send it to Noah no wait
        // send it to Carlo instead and tell him the bed frames are ready" keeps
        // 72% of its characters — and the worst observed failure kept 45%
        // ("Carlo, the Builda Bed frames are ready"). The floor sits at 0.5,
        // above the failure and well below the legitimate case.
        //
        // It is asymmetric on purpose. A false reject costs the fast pass, which
        // is decent text Roman can see is unedited. A false accept pastes a
        // sentence he did not say into an app we do not control, and he may not
        // notice — the same reasoning as VocabularyCorrector's over-correction
        // guards. Be clear about the limit though: this is a length check, not a
        // meaning check. It cannot catch a model that rewrites a sentence to the
        // same length. The prompt is the real defence; this is the backstop.
        let n = Double(input.count), m = Double(out.count)
        guard m <= n * 1.6 + 24, m >= n * 0.5 else { return nil }

        guard droppedVocabulary(from: input, to: out, terms: terms).isEmpty else { return nil }

        return out
    }

    /// Terms that were in the input and are not in the output.
    ///
    /// This is the whole reason the system prompt can afford to leave the
    /// vocabulary out. Measured: every prompt variant without an explicit word
    /// list turned "nxt" into "next" or deleted it, 20 times out of 20 — and
    /// every variant *with* the list started injecting words from it into
    /// sentences that never contained them. Prompting cannot win that; a string
    /// comparison can, exactly and for nothing.
    ///
    /// Case-sensitive, because the casing is the point: "nxt" is not "Nxt",
    /// "graphify" is not "Graphify", and FastCleaner has already decided which
    /// is right. The known cost is a term that legitimately starts a sentence
    /// and gets capitalised — that rejects, and the fast pass ships, which is
    /// the safe direction.
    public static func droppedVocabulary(from input: String, to output: String, terms: [String]) -> [String] {
        terms.filter { input.contains($0) && !output.contains($0) }
    }

    static func stripCodeFence(_ s: String) -> String {
        guard s.hasPrefix("```") else { return s }
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// "Cleaned text: foo" → "foo". Only labels, never a real sentence: the
    /// prefix must be short and must not itself contain sentence punctuation.
    static func stripLeadingLabel(_ s: String) -> String {
        guard let colon = s.firstIndex(of: ":") else { return s }
        let head = s[s.startIndex ..< colon]
        guard head.count <= 24, !head.contains(where: { ".!?,".contains($0) }) else { return s }
        let lowered = head.lowercased()
        let labels = ["clean", "output", "result", "corrected", "here", "text"]
        guard labels.contains(where: { lowered.contains($0) }) else { return s }
        return String(s[s.index(after: colon)...])
    }

    static func stripWrappingQuotes(_ s: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}")]
        for (open, close) in pairs where s.count >= 2 && s.first == open && s.last == close {
            // Only unwrap when the quotes really do wrap the whole thing —
            // 'send "this" and "that"' must survive intact.
            let inner = String(s.dropFirst().dropLast())
            if !inner.contains(close) { return inner }
        }
        return s
    }
}
