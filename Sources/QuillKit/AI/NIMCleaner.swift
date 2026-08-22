import Foundation

// The AI cleanup pass, wired as `cleanThorough` and racing inside
// DictationCoordinator's existing deadline. Nothing in this file is allowed to
// make a dictation slower than it already is, and nothing in it is allowed to
// paste a sentence Roman did not say.

// MARK: - Seam

/// The one thing the cleaner needs from a language-model client.
///
/// A protocol rather than a direct dependency on NIMClient because the
/// interesting tests are the miserable ones — the model hangs, the model returns
/// an essay, the model quietly rewrites a sentence to the same length — and none
/// of those can be provoked against a real endpoint on demand.
public protocol AICompleting: Sendable {
    var isConfigured: Bool { get }
    /// False when the client has already decided the network is gone. Checking
    /// costs nothing and saves the whole deadline on every dictation in a tunnel.
    var isReadyToTry: Bool { get }
    func complete(system: String, user: String, model: String?, deadline: Duration) async throws -> String
}

public extension AICompleting {
    var isReadyToTry: Bool { true }
}

extension NIMClient: AICompleting {
    public var isReadyToTry: Bool { !isBreakerOpen }
}

// MARK: - Cleaner

/// `cleanThorough` for the real app: FastCleaner, then spoken self-correction.
///
/// The order of operations is the design, and each step exists because the one
/// before it cannot do the job:
///
///   1. **FastCleaner** — punctuation, disfluency, Roman's vocabulary. Under 2ms,
///      offline, and better at proper nouns than any model measured. Its output,
///      not the raw transcript, is what everything downstream sees.
///   2. **The gate** — no retraction cue and no stutter means there is nothing a
///      model can add, so no request is made. Most dictations stop here and pay
///      nothing. This is also a safety property: a sentence that was already
///      right is never handed to something that might improve it.
///   3. **The offline resolver** — repairs the unambiguous corrections with no
///      network, in microseconds. Roman dictates on trains. It is also the answer
///      whenever the model misses its deadline, and how often that is depends
///      entirely on the budget the caller passes: measured, 95% of calls land
///      inside 450ms and 23% inside 250ms.
///   4. **The model** — the general case, on the remaining budget minus a safety
///      margin, so this method always answers before the coordinator stops
///      waiting. Its answer is checked, not trusted.
///
/// Every failure at every step falls through to the step before it. There is no
/// path out of `cleanThorough` that throws, blocks past the deadline, or returns
/// text that is not either the model's checked output or a deterministic result.
public struct NIMCleaner: TranscriptCleaning, Sendable {

    private let fast: FastCleaner
    private let client: AICompleting
    private let prompt: CleanupPrompt
    /// Read at call time, not captured at launch. The Style screen writes
    /// style.json on a click and the profile is meant to affect the very next
    /// dictation — a snapshot taken in `init` would apply the tone the app
    /// started with, forever.
    private let style: @Sendable () -> StyleProfile

    /// The cleanup prompt with the user's style rules appended.
    ///
    /// `StyleProfile.promptRules` has existed, been measured — line by line,
    /// against live transcripts — and been rendered on its own dashboard screen
    /// for the whole life of this feature, and nothing ever called it. Picking
    /// "Professional" wrote style.json, moved the tick, and changed not one
    /// character of any dictation that followed.
    ///
    /// Appended rather than woven in, and capped, because the base prompt is the
    /// part that was measured to 10/10 and must not be diluted: every rule below
    /// is additive, and the tail is dropped when the budget runs out.
    static func systemPrompt(_ base: CleanupPrompt, style: StyleProfile) -> String {
        let rules = style.promptRules()
        guard !rules.isEmpty else { return base.system }
        var appended = ""
        for rule in rules {
            let next = appended.isEmpty ? rule : appended + "\n" + rule
            guard next.count <= StyleProfile.maximumPromptCharacters else { break }
            appended = next
        }
        guard !appended.isEmpty else { return base.system }
        return base.system + "\n\nHow this person writes:\n" + appended
    }
    /// Set only by tests, which inject a fixed list.
    private let fixedVocabulary: [String]?
    /// The shipping path. `VocabularyBook.shared` stats the file on access and
    /// refreshes, so a word added in the Dictionary reaches the very next
    /// dictation.
    private let book: VocabularyBook?

    /// Read once per call, never captured.
    ///
    /// This was `Vocabulary.load().contextualStrings` evaluated in `init`, and
    /// the cleaner is built once at launch — so every word added to the
    /// Dictionary after that was invisible to the AI pass for the rest of the
    /// session. It is the list that protects the user's own terms from being
    /// rewritten, so a fresh word was not merely unprotected, it was the one most
    /// likely to be "corrected" into something else.
    private var vocabulary: [String] { fixedVocabulary ?? book?.terms ?? [] }
    private let safetyMargin: Duration
    private let minimumBudget: Duration
    private let homophones: Bool
    /// Propose-then-verify instead of choose-from-a-list. See ContextProjection.
    /// Asked, not remembered. The switch in Settings had no effect until the app
    /// was relaunched, because this was a Bool captured when the cleaner was
    /// built. Read once at the top of a pass so one dictation cannot see it flip
    /// halfway through.
    private let contextRecovery: @Sendable () -> Bool

    /// - Parameters:
    ///   - safetyMargin: taken off the caller's deadline before the request is
    ///     made, so the deterministic answer is returned *inside* the race rather
    ///     than arriving after the coordinator has already given up and shipped
    ///     the fast text. 30ms covers response decoding, the guard, and the hop
    ///     back to the main actor, measured at 3–8ms in practice.
    ///   - minimumBudget: below this there is no point asking. The floor for a
    ///     completion on this endpoint is a measured 195–223ms of pure network on
    ///     a warm connection, so anything under 120ms is guaranteed to be a wasted
    ///     wait, and the deterministic answer should just ship.
    ///   - homophones: whether to spend a request choosing between listed
    ///     homophones. On by default, which it had to earn twice.
    ///
    ///     Benched against the real endpoint with half the corpus deliberately
    ///     correct: 3 of 6 fixed, 0 of 6 damaged. Zero damage was the bar —
    ///     a miss costs a correction, a wrong swap costs a sentence he meant and
    ///     he will not notice.
    ///
    ///     Then measured for cost against 263 of his real dictations. The first
    ///     list woke the model on 12% of them, almost entirely on past, through,
    ///     whether, course and week — words that were already right every time.
    ///     Trimming those left 21 groups that fire on **1%**, and the words still
    ///     triggering it are the ones that were actually wrong: cashed, principle,
    ///     effect, discreet, losing.
    ///
    ///     One request on one dictation in a hundred, for a class of error
    ///     nothing else in the app can reach. `QUILL_HOMOPHONES=0` turns it off.
    public init(
        client: AICompleting = NIMClient(),
        fast: FastCleaner = FastCleaner(),
        prompt: CleanupPrompt = .current,
        style: @escaping @Sendable () -> StyleProfile = { StyleStore.shared.profile },
        vocabulary: [String]? = nil,
        book: VocabularyBook = .shared,
        safetyMargin: Duration = .milliseconds(30),
        minimumBudget: Duration = .milliseconds(120),
        homophones: Bool = ProcessInfo.processInfo.environment["QUILL_HOMOPHONES"] != "0",
        contextRecovery: @escaping @Sendable () -> Bool = { QuillSettings.shared.contextRecovery }
    ) {
        self.client = client
        self.fast = fast
        self.prompt = prompt
        self.style = style
        self.fixedVocabulary = vocabulary
        self.book = vocabulary == nil ? book : nil
        self.safetyMargin = safetyMargin
        self.minimumBudget = minimumBudget
        self.homophones = homophones
        self.contextRecovery = contextRecovery
    }

    public func cleanFast(_ raw: String) -> String { fast.cleanFast(raw) }

    /// One request, then the projection. Returns nil for every failure — no key,
    /// no network, a rewritten sentence, a refused swap — because the caller
    /// already holds the deterministic answer and this may only improve it.
    private func correctHomophones(in text: String, budget: Duration) async -> String? {
        guard let homophonePrompt = HomophonePrompt.make(for: text) else { return nil }
        do {
            let completion = try await Self.withDeadline(budget) {
                try await client.complete(
                    system: homophonePrompt.system, user: text, model: nil, deadline: budget
                )
            }
            return HomophoneProjection.project(completion, onto: text)
        } catch {
            return nil
        }
    }

    /// The context pass: the model reads the sentence and proposes a fix of its
    /// own, and `ContextProjection` refuses anything that is not a same-sounding
    /// word swapped for the one that was heard.
    ///
    /// Same request budget as the pass it replaces, and the same gate decides
    /// whether to spend it — so this costs nothing extra on the 89% of his
    /// dictations that contain no confusable word at all.
    private func recoverFromContext(in text: String, budget: Duration) async -> String? {
        do {
            let completion = try await Self.withDeadline(budget) {
                try await client.complete(
                    system: ContextPrompt.current.system, user: text, model: nil, deadline: budget
                )
            }
            return ContextProjection.project(completion, onto: text)
        } catch {
            return nil
        }
    }

    public func cleanThorough(_ raw: String, deadline: Duration) async -> String? {
        let tidy = fast.cleanFast(raw)
        guard !tidy.isEmpty else { return nil }

        // Computed before anything can go wrong, so there is always an answer to
        // fall back to — including the case where the model returns garbage after
        // 200ms and there is no budget left to think about it.
        let offline = SelfCorrection.resolve(tidy, protecting: vocabulary)

        let needsSelfCorrection = SelfCorrection.needsModelPass(tidy)
        // The homophone pass is the second reason to spend a request, and until
        // it existed `needsModelPass` was the only gate — which meant ordinary
        // dictation never reached the model at all, and homophones are not in
        // the sentences that contain a retraction cue. See HomophonePairs.
        // `offline` is the deterministic answer and may be nil when there was
        // nothing to resolve; the text to correct is then the tidied input.
        let base = offline ?? tidy
        // A long dictation almost always contains a stumble, and a stumble sets
        // needsSelfCorrection — so "one or the other" quietly meant homophones
        // never ran on his longest dictations. Measured on a real one: a phone
        // call in the tail contained "mum told me mum told me", the repetition
        // gate fired, and "cashing" stayed wrong all the way into the document.
        //
        // But the offline resolver handles repetitions deterministically, for
        // free, before any of this. When it has already changed the text the
        // retraction is dealt with and the model pass is only a refinement — so
        // the request is better spent on the homophone, which nothing else can
        // reach. The original premise, that a sentence needing a retraction is
        // never also one where flour and flower are in play, was simply wrong.
        let offlineHandledIt = offline != nil && offline != tidy
        // Each pass gets the gate that matches its reach. The closed-list pass
        // can only fix a word on its 44-word list, so asking about anything else
        // is a request spent on a question it cannot answer. The context pass
        // verifies against 2,281 words, and gating it on the small list would
        // mean shipping a table it almost never gets to use.
        // Once, at the top, so the two branches below cannot disagree about it
        // within a single pass.
        let usesContext = contextRecovery()
        let hasCandidate = usesContext
            ? ContextProjection.hasCandidate(in: base)
            : HomophonePairs.hasCandidate(in: base)
        let needsHomophones = homophones
            && (!needsSelfCorrection || offlineHandledIt)
            && hasCandidate
        guard needsSelfCorrection || needsHomophones else { return offline }
        guard client.isConfigured, client.isReadyToTry else { return offline }

        let budget = deadline - safetyMargin
        guard budget >= minimumBudget else { return offline }

        // Deliberately one request or the other, never both. They are both on the
        // critical path and the budget is one round trip wide; a sentence that
        // needs a retraction resolved is not also the sentence where flour and
        // flower are in play, and if it ever is, the retraction matters more.
        if needsHomophones {
            // Two shapes of the same request, and only one is sent. The context
            // pass lets the model propose freely and refuses anything that is not
            // a same-sounding swap; the older pass hands it a closed list to
            // choose from. The first covers 2,281 words against 44 and is the
            // default; the second stays reachable because its list carries pairs
            // CMUdict does not know this recogniser confuses.
            if usesContext {
                return await recoverFromContext(in: base, budget: budget) ?? offline
            }
            return await correctHomophones(in: base, budget: budget) ?? offline
        }

        do {
            let completion = try await Self.withDeadline(budget) {
                try await client.complete(
                    system: Self.systemPrompt(prompt, style: style()),
                    user: tidy, model: nil, deadline: budget
                )
            }
            guard let checked = CleanupProjection.project(completion, onto: tidy, protecting: vocabulary),
                  checked != tidy
            else { return offline }
            return checked
        } catch {
            // Every NIMError ends here: no key, no network, rate limited, the
            // model 404ing, the deadline expiring. The caller asked for cleaner
            // text and gets the best available, never an error.
            return offline
        }
    }

    /// The deadline is enforced here as well as inside the client.
    ///
    /// Belt and braces on purpose. `AICompleting` is a protocol, so the thing on
    /// the other side of it is whatever was injected — and "never blocks, never
    /// hangs" is a promise this type makes to DictationCoordinator, not one it
    /// gets to pass on to a dependency. The loser is cancelled rather than left
    /// running: it holds a socket and a rate-limit slot against a key that is
    /// already 429-prone.
    private static func withDeadline<T: Sendable>(
        _ duration: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let result { return result }
                throw NIMError.deadlineExceeded(milliseconds: duration.milliseconds)
            }
            throw NIMError.deadlineExceeded(milliseconds: duration.milliseconds)
        }
    }
}

// MARK: - Output check

/// What comes back from the model, checked against what went in.
///
/// `AIOutputGuard` already does the shape checks — fences, labels, quotes,
/// runaway essays — and this uses them. What it adds is the check that matters
/// for self-correction and that a length ratio cannot express: the output must be
/// the *input with words deleted*, and every deletion must have a reason.
///
/// `AIOutputGuard`'s own 0.5 length floor is deliberately not applied. It was
/// sized for a long transcript, and the headline case of this feature breaks it:
/// "Send it to Noah no wait send it to Carlo" → "Send it to Carlo" keeps 40% of
/// its characters, which is a correct answer the guard would reject. Deletion is
/// the point here, so the ratio is replaced with a rule about *what* may be
/// deleted rather than *how much*.
public enum CleanupProjection {

    /// How far past a retraction cue a deletion may reach: three words.
    ///
    /// A retraction may eat unlimited material *before* the cue — that is the
    /// whole point, and "send it to Noah and tell him the frames are ready and
    /// the invoice is paid, no wait, send it to Carlo" correctly reduces to five
    /// words out of twenty-one. What it may not do is eat the version the speaker
    /// settled on. That asymmetry is the guard; a percentage of the whole
    /// sentence cannot express it, which is what an earlier 35% floor got wrong.
    ///
    /// It is not zero because a restart overlaps. Measured 5 times out of 5,
    /// "Send the nxt invoice to Noah no wait send it to Carlo" comes back as
    /// "Send the next invoice to Carlo" — the model merges, keeping the noun
    /// phrase from before the cue and the recipient from after it, and drops the
    /// redundant "send it". That is the right answer and it costs two words of
    /// the tail.
    ///
    /// Three separates it from the failure it is aimed at with room to spare. The
    /// worst summary in the corpus — "the bed frames are ready" out of "Send it
    /// to Noah no wait send it to Carlo and tell him the bed frames are ready" —
    /// reaches seven words past the cue.
    static let maximumTailOverreach = 3

    /// Returns the checked text, or nil to mean "use the deterministic answer".
    /// Never an error: the caller has something good already.
    public static func project(_ raw: String, onto input: String, protecting terms: [String]) -> String? {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }

        // Shape first, and reuse rather than reimplement: these three were all
        // observed from real models on this endpoint.
        out = AIOutputGuard.stripCodeFence(out)
        out = AIOutputGuard.stripLeadingLabel(out)
        out = AIOutputGuard.stripWrappingQuotes(out)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }

        // A model that starts explaining has stopped editing.
        if out.contains("\n\n"), !input.contains("\n\n") { return nil }
        // Deleting words cannot make the text longer. The slack is for
        // punctuation and apostrophes, which it is allowed to add.
        guard out.count <= input.count + 24 else { return nil }

        let inTokens = SpeechToken.tokenise(input)
        let outTokens = SpeechToken.tokenise(out)
        guard !inTokens.isEmpty, !outTokens.isEmpty else { return nil }

        let protectedWords = Set(terms.flatMap { $0.split(separator: " ").map { String($0).lowercased() } })

        guard let mapping = align(outTokens, to: inTokens, protectedWords: protectedWords) else { return nil }
        guard deletionsAreJustified(mapping: mapping, inTokens: inTokens) else { return nil }

        // Over-deletion is the one failure the alignment cannot see: a summary is
        // still a subsequence of what it summarises.
        guard mapping.count >= min(2, inTokens.count) else { return nil }
        let start = settledStart(mapping: mapping, inTokens: inTokens)
        let kept = Set(mapping)
        let overreach = (start ..< inTokens.count).filter { !kept.contains($0) }.count
        guard overreach <= maximumTailOverreach else { return nil }

        return rebuild(outTokens, mapping: mapping, inTokens: inTokens, protectedWords: protectedWords, verbatim: out)
    }

    // MARK: Alignment

    /// Maps each output token to the input token it came from, or nil if some
    /// output token came from nowhere.
    ///
    /// This is the whole "cleanup, not rewriting" contract expressed as a check.
    /// A model that adds a pleasantry, invents a detail, reorders a clause or
    /// swaps a word for a nicer one produces an output that is not a subsequence
    /// of its input, and lands here rather than in Roman's editor. Measured: it
    /// is what catches "For the barber site I'd like the booking form to be on
    /// the home page..." — same length, same meaning, not his words.
    ///
    /// Matched from the right. Either direction answers "is this a subsequence"
    /// identically, but the direction decides *which* copy a repeated phrase is
    /// credited to, and that changes what the guards downstream see. "Send it to
    /// Noah no wait send it to Carlo" → "Send it to Carlo" credits the surviving
    /// words to the second "send it to" going right-to-left and to the first one
    /// going left-to-right — and only the first reading matches what the speaker
    /// did, which is finish the sentence the second time. Left-to-right made the
    /// deletion straddle the cue and every positional rule below meaningless.
    static func align(
        _ outTokens: [SpeechToken], to inTokens: [SpeechToken], protectedWords: Set<String>
    ) -> [Int]? {
        var reversed: [Int] = []
        var cursor = inTokens.count - 1
        for out in outTokens.reversed() {
            var matched: Int?
            var index = cursor
            while index >= 0 {
                if matches(out, inTokens[index], protectedWords: protectedWords) {
                    matched = index
                    break
                }
                index -= 1
            }
            guard let matched else { return nil }
            reversed.append(matched)
            cursor = matched - 1
        }
        return reversed.reversed()
    }

    /// Where the version the speaker settled on begins: just past the last
    /// retraction cue that licensed a deletion. Zero when nothing was retracted,
    /// which makes the floor above a whole-sentence one — correct, because
    /// without a retraction the only licensed deletions are stutters and opening
    /// preamble, and those are small by construction.
    static func settledStart(mapping: [Int], inTokens: [SpeechToken]) -> Int {
        let kept = Set(mapping)
        let deleted = (0 ..< inTokens.count).filter { !kept.contains($0) }
        guard !deleted.isEmpty else { return 0 }
        let cues = SelfCorrection.cues(in: inTokens).filter(\.isRetraction)
        return cues.filter { cue in deleted.contains(where: cue.range.contains) }
            .map(\.range.upperBound)
            .max() ?? 0
    }

    /// Equal ignoring case, punctuation and apostrophes — so the model is free to
    /// turn "lets" into "Let's", which is a spelling repair, and not free to turn
    /// "want" into "would like", which is a rewrite.
    ///
    /// The second clause is the vocabulary escape hatch. Measured 10 times out of
    /// 10: the model turns "nxt" into "next". Rejecting the whole response for it
    /// would mean self-correction never works in a sentence containing one of
    /// Roman's words, which is most of them. Instead the near-miss is allowed to
    /// align and `rebuild` puts his spelling back — and because the substitution
    /// only ever reads from the input, this cannot introduce a word he did not
    /// say. The 0.6 bar admits nxt→next (0.75) and rejects unrelated words.
    static func matches(_ out: SpeechToken, _ input: SpeechToken, protectedWords: Set<String>) -> Bool {
        if out.normalised == input.normalised { return true }
        guard protectedWords.contains(input.normalised) else { return false }
        return VocabularyCorrector.similarity(out.normalised, input.normalised) >= 0.6
    }

    // MARK: Deletions

    /// Every run of deleted input tokens has to be one of three things. Anything
    /// else and the response is discarded.
    ///
    /// This is what stops the model acting on a retraction phrase that was
    /// literal content. The gate in `SelfCorrection` already refuses to send a
    /// transcript whose only cues are literal; this catches the mixed case, where
    /// one real correction gets the transcript sent and the model then also eats
    /// the quoted one.
    static func deletionsAreJustified(mapping: [Int], inTokens: [SpeechToken]) -> Bool {
        let kept = Set(mapping)
        let cues = SelfCorrection.cues(in: inTokens).filter(\.isRetraction)

        var start = 0
        while start < inTokens.count {
            guard !kept.contains(start) else { start += 1; continue }
            var end = start
            while end < inTokens.count, !kept.contains(end) { end += 1 }
            let run = start ..< end

            if let cue = cues.first(where: { $0.range.overlaps(run) }) {
                guard retractionIsFullyApplied(run: run, cue: cue, inTokens: inTokens) else { return false }
            } else if !isRepetition(run, in: inTokens),
                      !isAllFiller(run, in: inTokens),
                      !isOpeningPreamble(run, in: inTokens) {
                return false
            }
            start = end
        }
        return true
    }

    /// A correction has to actually be applied, in the right direction.
    ///
    /// Both halves of this came from the live suite, and both are the user's
    /// original complaint wearing a disguise — the model touched the sentence and
    /// still left the wrong words in it.
    ///
    ///   "call the plumber no wait ring the electrician instead"
    ///     → "Call the plumber ring the electrician instead"
    ///   The model deleted the cue and nothing else, so both versions survive and
    ///   the signal that one of them was wrong is gone. Worse than untouched.
    ///
    ///   "push the nxt build to Netlify no wait push it to Firestore"
    ///     → "Push the nxt build to Netlify."
    ///   The model applied the correction backwards: it kept what he retracted
    ///   and deleted what he settled on.
    ///
    /// The rule that catches both: a *replacement* cue ("no wait", "actually",
    /// "I mean") retracts what came before it, so the deletion must reach back
    /// past the cue. Only an *abandonment* ("never mind", "forget it") retracts
    /// forwards, and only at the very end of the utterance, because there is
    /// nothing after it to keep.
    static func retractionIsFullyApplied(
        run: Range<Int>, cue: SelfCorrection.Cue, inTokens: [SpeechToken]
    ) -> Bool {
        if run.lowerBound < cue.range.lowerBound { return true }
        return run.upperBound == inTokens.count
            && SelfCorrection.isAbandonment(cue.range, in: inTokens)
    }

    /// The deleted run is a stutter or a false start: the same words appear
    /// immediately before or immediately after it. "The the build", "we should we
    /// should probably ship it".
    static func isRepetition(_ run: Range<Int>, in tokens: [SpeechToken]) -> Bool {
        let length = run.count
        let deleted = tokens[run].map(\.normalised)
        if run.lowerBound >= length {
            let before = tokens[run.lowerBound - length ..< run.lowerBound].map(\.normalised)
            if before == deleted { return true }
        }
        if run.upperBound + length <= tokens.count {
            let after = tokens[run.upperBound ..< run.upperBound + length].map(\.normalised)
            if after == deleted { return true }
        }
        return false
    }

    /// The deleted run is nothing but discourse noise — "um", "like", "so".
    /// Measured: the model drops these and the result reads better for it, which
    /// is the one kind of unprompted deletion worth allowing.
    static func isAllFiller(_ run: Range<Int>, in tokens: [SpeechToken]) -> Bool {
        !run.isEmpty && tokens[run].allSatisfy { SelfCorrection.fillers.contains($0.normalised) }
    }

    /// Words that only mean "I am starting to talk now" when they are the first
    /// thing said. "Right", "now", "like" and "so" are ordinary content
    /// everywhere else, which is why this is anchored to position zero rather
    /// than added to `SelfCorrection.fillers`.
    static let openers: Set<String> = [
        "ok", "okay", "right", "now", "alright", "anyway", "yeah", "so", "well", "like", "basically",
    ]

    /// The deleted run is the throat-clearing at the very start of a dictation.
    ///
    /// Measured: "Ok so for the barber site I want the booking form on the home
    /// page no wait on its own page" comes back without the "Ok so", 5 times out
    /// of 5. Refusing that response means refusing the correction with it, which
    /// trades the headline feature for two words of preamble — the wrong way
    /// round.
    ///
    /// Confined to the run of opener words the utterance actually starts with,
    /// rather than to index 0, because the model may drop "Ok so" or just the
    /// "so". Either way the licence stops at the first real word, so "do it right
    /// now" cannot lose its ending and "I like the blue one" cannot lose its verb.
    ///
    /// Note that "yeah" is in `openers` but the gate usually settles that case
    /// first: a transcript with no retraction and no stutter never reaches the
    /// model at all, so "yeah just push it and we'll see what breaks" is never
    /// at risk in the first place.
    static func isOpeningPreamble(_ run: Range<Int>, in tokens: [SpeechToken]) -> Bool {
        guard !run.isEmpty else { return false }
        var preamble = 0
        while preamble < min(3, tokens.count),
              openers.contains(tokens[preamble].normalised)
                  || SelfCorrection.fillers.contains(tokens[preamble].normalised) {
            preamble += 1
        }
        return run.upperBound <= preamble
    }

    // MARK: Rebuild

    /// Emits the model's text, with Roman's spelling restored wherever the model
    /// normalised one of his words.
    ///
    /// When nothing needed restoring — the overwhelmingly common case — the
    /// model's own string is returned byte for byte, so the join below can never
    /// introduce a spacing artefact into text that was already fine.
    static func rebuild(
        _ outTokens: [SpeechToken], mapping: [Int], inTokens: [SpeechToken],
        protectedWords: Set<String>, verbatim: String
    ) -> String {
        var restored = false
        var pieces: [String] = []
        pieces.reserveCapacity(outTokens.count)

        for (position, out) in outTokens.enumerated() {
            let input = inTokens[mapping[position]]
            let useInputSpelling = protectedWords.contains(input.normalised) && input.word != out.word
            if useInputSpelling { restored = true }
            pieces.append(out.lead + (useInputSpelling ? input.word : out.word) + out.trail)
        }

        return restored ? pieces.joined(separator: " ") : verbatim
    }
}
