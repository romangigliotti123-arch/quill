import AppKit
import Foundation

/// How Roman writes, learned and chosen, in a form the cleanup pass can use.
///
/// Wispr Flow's history table is the design document for this feature: alongside
/// the transcript it stores `editedText`, `numWordsCorrected`,
/// `editDistanceToDictated` and `hasRevertedAI`. It is not storing your text, it
/// is storing your *corrections* — the diff between what it wrote and what you
/// kept is the training signal.
///
/// # What Quill can actually observe
///
/// Being precise about this decides the whole design, so it is written down
/// rather than assumed:
///
/// 1. **Corrections made in Quill's own dashboard.** A dictation record, edited
///    and saved. Rare, deliberate, and unambiguous — the best signal available
///    and the one the learner is built around.
/// 2. **The app that was frontmost when the dictation fired.** Free, always
///    available, and genuinely predictive: a Slack message is not an email. This
///    drives tone rather than the learned traits, because it is a fact about the
///    destination, not about the writer.
/// 3. **Whether the model's rewrite was kept or reverted.** A counter, not a
///    diff — see `recordModelOutcome`.
///
/// And what it cannot observe: edits the user makes *after* insertion, inside
/// Slack or Mail or Xcode. Quill inserts text and loses sight of it. Reading it
/// back would mean an Accessibility observer sitting on every focused text field
/// in every app — which is to say, reading everything Roman types anywhere,
/// forever, to learn that he prefers "hey" to "hi". That trade is not worth
/// making, and it does not work in Electron apps (Slack, Notion, Discord)
/// anyway. So the feature is built on signals 1–3 and says so, rather than
/// claiming to learn from something it never sees.
///
/// # Bootstrapping
///
/// Learning from deliberate corrections is slow — a dozen edits is a good week.
/// So the presets exist and are the primary control: pick one and the cleanup
/// sounds right immediately, then learning refines it. A feature that only works
/// after a hundred samples does not work.
public struct StyleProfile: Codable, Sendable, Equatable {

    // MARK: Chosen

    /// The base voice. Chosen, not learned — see `StylePreset`.
    public var preset: StylePreset

    /// Per-app overrides, keyed by bundle identifier. Empty by default; the
    /// suggestions in `StylePreset.suggested(forBundleID:)` fill the gap without
    /// being written to disk, so a user who never opens this pane still gets a
    /// sensible Slack-vs-Mail difference and a user who does gets the last word.
    public var appTones: [String: StylePreset]

    /// Off means the profile is frozen at whatever it holds — presets still
    /// apply, corrections stop changing anything.
    public var isLearningEnabled: Bool

    // MARK: Learned

    /// en-AU is British-convention: "capitalisation", "colour", "analyse".
    /// Learned rather than assumed from the locale, because the locale is the
    /// machine's and the habit is the writer's.
    public var spelling: StyleTrait<SpellingConvention>
    /// True when he writes "don't" rather than "do not".
    public var contractions: StyleTrait<Bool>
    /// The register of his greetings and sign-offs, learned only from swaps that
    /// actually appear in a correction — never inferred from a word merely being
    /// present. See `StyleLearner.formality`.
    public var formality: StyleTrait<Formality>
    /// Serial comma: "a, b, and c" against "a, b and c".
    public var oxfordComma: StyleTrait<Bool>
    /// Whether exclamation marks survive his edits.
    public var exclamations: StyleTrait<Bool>
    /// Mean words per sentence of text he has approved. A measurement of his
    /// finished writing rather than a judgement about it.
    public var sentenceLength: RunningMean

    /// Rewrites he has made more than once: "Hi team" → "hey". Applied
    /// deterministically, never put in the prompt — see `applyDeterministically`.
    public var phrasings: [StylePhrasing]

    // MARK: Counters

    /// Corrections folded in. The dashboard's honest "learned from N edits".
    public var correctionCount: Int
    /// Model rewrites kept, and model rewrites the user undid.
    public var modelAccepted: Int
    public var modelReverted: Int

    public var lastLearned: Date?

    // MARK: Policy

    /// How much agreement a binary trait needs before it reaches the prompt.
    /// Two, not one: a single correction is as likely to be a typo fix as a
    /// preference, and a trait that flips on one sample makes the cleanup feel
    /// random. Two is still fast — a fortnight, not a quarter.
    public static let minimumSupport = 2
    /// And the winning value must hold this share of the votes. Guards the case
    /// where he genuinely does both.
    public static let minimumConfidence = 0.6
    /// A phrasing rewrites text without asking, so its bar is higher than a
    /// prompt hint's. Same reasoning as VocabularyCorrector's over-correction
    /// guards: silently changing a word the user meant is worse than leaving one
    /// he didn't, because he will not notice it.
    public static let minimumPhrasingCount = 3
    /// Cap on what is kept on disk. Phrasings past this are the long tail of
    /// one-off edits, and an unbounded list is a file that grows forever.
    public static let maximumPhrasings = 24

    public static let `default` = StyleProfile()

    /// Roman's starting point, from what he has said he wants everywhere else:
    /// casual peer-to-peer, never salesy, never sounding AI-written. Australian
    /// spelling is seeded rather than learned because it is the one thing here
    /// that is a fact about him rather than a guess — but it is seeded as a
    /// *vote*, so two corrections the other way would still overturn it.
    public static let romanDefault: StyleProfile = {
        var p = StyleProfile(preset: .casual)
        p.spelling = StyleTrait(seeding: .british, votes: StyleProfile.minimumSupport)
        p.contractions = StyleTrait(seeding: true, votes: StyleProfile.minimumSupport)
        return p
    }()

    public init(
        preset: StylePreset = .casual,
        appTones: [String: StylePreset] = [:],
        isLearningEnabled: Bool = true
    ) {
        self.preset = preset
        self.appTones = appTones
        self.isLearningEnabled = isLearningEnabled
        self.spelling = StyleTrait()
        self.contractions = StyleTrait()
        self.formality = StyleTrait()
        self.oxfordComma = StyleTrait()
        self.exclamations = StyleTrait()
        self.sentenceLength = RunningMean()
        self.phrasings = []
        self.correctionCount = 0
        self.modelAccepted = 0
        self.modelReverted = 0
        self.lastLearned = nil
    }

    // MARK: - Tone

    /// The voice to use for a given destination app.
    ///
    /// Explicit override first, then the built-in suggestion, then the base
    /// preset. Unknown apps fall through to the base rather than being guessed
    /// at — a wrong tone is worse than a generic one.
    public func tone(forBundleID bundleID: String?) -> StylePreset {
        guard let bundleID else { return preset }
        if let chosen = appTones[bundleID] { return chosen }
        return StylePreset.suggested(forBundleID: bundleID) ?? preset
    }

    // MARK: - The prompt

    /// Prefill is on the critical path, so this is a budget, not a style guide.
    /// AIConfig measured a 190ms p50 difference between two prompt variants that
    /// differed only in length. Rules are emitted most-valuable first and the
    /// tail is dropped when the budget runs out.
    public static let maximumPromptCharacters = 420

    /// The style rules, one per line, ready to append to the cleanup prompt.
    /// Empty when there is nothing worth saying — which is a real outcome, and
    /// costs nothing.
    public func promptRules(forAppBundleID bundleID: String? = nil) -> [String] {
        var rules: [String] = [tone(forBundleID: bundleID).promptLine]

        if let spelling = settled(spelling) {
            rules.append(spelling.promptLine)
        }
        if let contractions = settled(contractions) {
            rules.append(contractions
                ? "Use contractions."
                : "Do not contract words; write them out in full.")
        }
        // One direction only, and the asymmetry is measured.
        //
        // "Keep sentences short, around 6 words" asks the model to restructure,
        // which is the same shape as the two preset lines that had to be
        // rewritten above — and it cost the same way: 19/20 kept all the
        // content against 20/20 without it, live, on the same transcripts. One
        // dictation in twenty losing a clause is not a price worth paying for a
        // rule whose result cannot be checked afterwards.
        //
        // "Do not split them up" is the opposite instruction: it forbids
        // restructuring rather than requesting it, so it cannot cause that
        // failure. It stays. Short sentences are still learned and still shown
        // in the summary — they are a real fact about how he writes, they just
        // are not something worth asking a model for.
        if let words = sentenceLength.average, words > 24 {
            rules.append("Long sentences are fine; do not split them up.")
        }
        if let oxford = settled(oxfordComma) {
            rules.append(oxford
                ? "Put a comma before the final \"and\" in a list."
                : "No comma before the final \"and\" in a list.")
        }
        if settled(exclamations) == false {
            rules.append("No exclamation marks.")
        }

        // Trim from the bottom: the list is already in value order.
        var out: [String] = []
        var budget = Self.maximumPromptCharacters
        for rule in rules {
            let cost = rule.count + 3   // "- " and a newline
            guard cost <= budget else { break }
            budget -= cost
            out.append(rule)
        }
        return out
    }

    /// The full system prompt for a dictation: the cleanup rules, then the voice.
    ///
    /// Note what is *not* here. Learned phrasings are applied deterministically
    /// instead of being described to the model, and there is no list of words to
    /// avoid, because AIConfig measured both hazards on this exact endpoint: a
    /// word list in the prompt gets spent from (a brand name appeared in a
    /// sentence that never mentioned it), and a negative list — "do not use
    /// these" — was the worst variant tested, dropping spoken self-correction
    /// from 20/20 to 0/20. Anything checkable is checked after the fact instead.
    /// See `StyleGuard`.
    public func systemPrompt(
        base: String = AIConfig.cleanupSystemPrompt,
        forAppBundleID bundleID: String? = nil
    ) -> String {
        let rules = promptRules(forAppBundleID: bundleID)
        guard !rules.isEmpty else { return base }
        return base + "\nStyle:\n" + rules.map { "- \($0)" }.joined(separator: "\n")
    }

    // MARK: - Applied without a model

    /// The part of the profile that needs no network and no model.
    ///
    /// Roman dictates on trains, so a style feature that only works online is a
    /// style feature that does not work. Two things survive offline because both
    /// are exact string operations rather than judgement calls: learned
    /// phrasings, and spelling convention. Sentence length, formality and tone
    /// cannot be done this way — enforcing them means paraphrasing, and a rule
    /// that paraphrases is a rule that changes meaning.
    ///
    /// Safe to run on the fast pass and on model output alike, and it is run on
    /// both: it is the last thing between the profile and the keyboard.
    public func applyDeterministically(_ text: String) -> String {
        var out = applyPhrasings(text)
        if settled(spelling) == .british {
            out = Orthography.toBritish(out)
        }
        return out
    }

    /// Literal, word-boundary substitutions for phrasings he has made stick.
    ///
    /// Gated hard. Three sightings, and single-word rewrites must be a
    /// distinctive word — rewriting "and" or "the" on the strength of three
    /// coincidences would be a disaster with no upper bound on the damage.
    func applyPhrasings(_ text: String) -> String {
        var out = text
        for phrasing in phrasings where phrasing.isApplicable {
            out = out.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: phrasing.from))\\b",
                // escapedTemplate, not the raw string: in regex mode the
                // replacement is a template, so a phrasing he taught it by
                // dictating a price — "$100" — would be read as capture group 1
                // and vanish. The trigger is escaped as a pattern and the
                // replacement as a template; they are different escapings and
                // using one for both is silent corruption.
                with: NSRegularExpression.escapedTemplate(for: phrasing.to),
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }

    // MARK: - Model trust

    /// Flow stores `hasRevertedAI` per dictation, and it is the only feedback on
    /// the cleanup itself rather than on the words. Quill's version is a pair of
    /// counters fed by the dashboard's revert affordance.
    ///
    /// Honest caveat: until that affordance ships, `modelReverted` stays at zero
    /// and `trustsModel` is always true. The gate is inert, not wrong.
    public mutating func recordModelOutcome(accepted: Bool) {
        if accepted { modelAccepted += 1 } else { modelReverted += 1 }
    }

    /// False when the user keeps undoing the model's rewrites. At that point the
    /// model pass is costing a deadline per dictation to produce text that gets
    /// thrown away, and the deterministic pass is simply better for this user.
    /// Requires a real sample first — two reverts on a Tuesday is not a verdict.
    public var trustsModel: Bool {
        let total = modelAccepted + modelReverted
        guard total >= 5 else { return true }
        return Double(modelReverted) / Double(total) <= 0.5
    }

    // MARK: - Summary

    /// One line for the dashboard. Says what has been learned, or says plainly
    /// that nothing has — never implies a personalisation that is not there.
    public var summaryLine: String {
        var parts: [String] = [preset.title]
        if let s = settled(spelling) { parts.append(s.shortName) }
        if let c = settled(contractions) { parts.append(c ? "contractions" : "no contractions") }
        if let w = sentenceLength.average { parts.append("~\(Int(w.rounded())) words/sentence") }
        let applicable = phrasings.filter(\.isApplicable).count
        if applicable > 0 { parts.append("\(applicable) phrasing\(applicable == 1 ? "" : "s")") }
        let learned = parts.count > 1
            ? parts.joined(separator: " · ")
            : parts[0] + " · nothing learned yet"
        return correctionCount == 0
            ? learned
            : learned + " · from \(correctionCount) correction\(correctionCount == 1 ? "" : "s")"
    }

    // MARK: - Trait gating

    /// A trait only counts once it clears both bars. One place, so the gate
    /// cannot drift between the prompt, the offline pass and the summary.
    public func settled<V>(_ trait: StyleTrait<V>) -> V? {
        trait.settled(minimumSupport: Self.minimumSupport, minimumConfidence: Self.minimumConfidence)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case preset, appTones, isLearningEnabled, spelling, contractions, formality
        case oxfordComma, exclamations, sentenceLength, phrasings
        case correctionCount, modelAccepted, modelReverted, lastLearned
    }

    /// Hand-written and every field optional on the way in. The synthesised
    /// version throws on a missing key, and `StyleStore` turns a throw into a
    /// fresh profile — so adding one field in a later version would silently
    /// delete everything the user had taught it. Learned state is not something
    /// you get to lose during a refactor.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.preset = try c.decodeIfPresent(StylePreset.self, forKey: .preset) ?? .casual
        self.appTones = try c.decodeIfPresent([String: StylePreset].self, forKey: .appTones) ?? [:]
        self.isLearningEnabled = try c.decodeIfPresent(Bool.self, forKey: .isLearningEnabled) ?? true
        self.spelling = try c.decodeIfPresent(StyleTrait<SpellingConvention>.self, forKey: .spelling) ?? StyleTrait()
        self.contractions = try c.decodeIfPresent(StyleTrait<Bool>.self, forKey: .contractions) ?? StyleTrait()
        self.formality = try c.decodeIfPresent(StyleTrait<Formality>.self, forKey: .formality) ?? StyleTrait()
        self.oxfordComma = try c.decodeIfPresent(StyleTrait<Bool>.self, forKey: .oxfordComma) ?? StyleTrait()
        self.exclamations = try c.decodeIfPresent(StyleTrait<Bool>.self, forKey: .exclamations) ?? StyleTrait()
        self.sentenceLength = try c.decodeIfPresent(RunningMean.self, forKey: .sentenceLength) ?? RunningMean()
        self.phrasings = try c.decodeIfPresent([StylePhrasing].self, forKey: .phrasings) ?? []
        self.correctionCount = try c.decodeIfPresent(Int.self, forKey: .correctionCount) ?? 0
        self.modelAccepted = try c.decodeIfPresent(Int.self, forKey: .modelAccepted) ?? 0
        self.modelReverted = try c.decodeIfPresent(Int.self, forKey: .modelReverted) ?? 0
        self.lastLearned = try c.decodeIfPresent(Date.self, forKey: .lastLearned)
    }
}

// MARK: - Presets

/// The four voices, pickable in one click.
///
/// These are the feature for the first month. Learning needs corrections and
/// corrections are rare, so anything that depends on them alone is a feature
/// that ships broken and gets good later — which is the same as shipping broken.
public enum StylePreset: String, Codable, Sendable, CaseIterable {
    case neutral
    case casual
    case professional
    case technical

    public var title: String {
        switch self {
        case .neutral:      return "Neutral"
        case .casual:       return "Casual"
        case .professional: return "Professional"
        case .technical:    return "Technical"
        }
    }

    /// What picking it does, in the user's terms, for the picker.
    public var summary: String {
        switch self {
        case .neutral:      return "Clean it up and change nothing else."
        case .casual:       return "How you'd write to someone you know. Contractions, no sales voice."
        case .professional: return "Client-ready. Complete sentences, still human."
        case .technical:    return "Precise. Keeps identifiers, paths and version numbers exactly as spoken."
        }
    }

    /// One line, spent from the prompt budget, so it earns its length.
    ///
    /// Every one of these describes **word choice**, and never a kind of
    /// document. That distinction is the whole finding of the measurement below,
    /// and it is not a stylistic preference — it decides whether the AI pass
    /// works at all.
    ///
    /// # Benchmark — 2026-08-09, live against meta/llama-3.1-8b-instruct
    ///
    /// Transcript: "Send it to Noah no wait send it to Carlo instead and tell
    /// him the bed frames are ready". Variants interleaved round-robin so a slow
    /// patch of network could not land on one of them; 7–10 answered calls each;
    /// "no rewrite" means the output was still the instruction that was spoken,
    /// and "accepted" means `AIOutputGuard` let it through to the keyboard.
    ///
    ///     style line                                        accepted   no rewrite
    ///     ────────────────────────────────────────────────────────────────────────
    ///     none (base cleanup prompt only)                    7/7        7/7
    ///     "write it the way one person messages another…"    2/7        0/7
    ///     "use everyday wording. no marketing…"              6/6        6/6
    ///     "write it as a clear, complete message to a        0/7        0/7
    ///      client; polished but not stiff"
    ///     "use precise, complete wording. no slang…"         9/9        9/9
    ///
    /// The two persona lines did not adjust the tone of the sentence — they
    /// replaced it. "Tell him the bed frames are ready" came back as "I've sent
    /// the bed frames to Carlo, they're ready": a first-person report of an
    /// action nobody performed, in an app we do not control, pasted without
    /// review. The professional line was worse still at 0/7 accepted, because
    /// its rewrite ("Carlo, the bed frames are ready.") was short enough to trip
    /// AIOutputGuard's floor — meaning a user who picked Professional would have
    /// had the AI pass silently do nothing on every single dictation while still
    /// paying its deadline.
    ///
    /// Describing word choice instead costs nothing measurable: both replacement
    /// lines matched the base prompt exactly, 100% accepted and 100% unrewritten.
    ///
    /// Neutral and Technical were measured in the same run and behaved like the
    /// base prompt (100% self-correction, byte-identical output on the sample),
    /// which is what they were already written to do.
    var promptLine: String {
        switch self {
        case .neutral:
            return "Keep the speaker's own wording and register."
        case .casual:
            return "Use everyday wording. No marketing, sales or AI-assistant phrasing."
        case .professional:
            return "Use precise, complete wording. No slang and no marketing phrasing."
        case .technical:
            return "Keep identifiers, file paths, commands and version numbers exactly as spoken; do not prettify them."
        }
    }

    public var formality: Formality {
        switch self {
        case .neutral, .technical: return .neutral
        case .casual:              return .casual
        case .professional:        return .formal
        }
    }

    /// Sensible starting tone per destination app.
    ///
    /// Not learned and not guessed at — this is the small set where the answer
    /// is obvious to anyone. Everything else returns nil and falls back to the
    /// user's base preset. A shrug is the correct output for an app we know
    /// nothing about.
    public static func suggested(forBundleID bundleID: String) -> StylePreset? {
        switch bundleID {
        case "com.tinyspeck.slackmacgap",
             "com.hnc.Discord",
             "com.apple.MobileSMS",
             "net.whatsapp.WhatsApp",
             "ru.keepcoder.Telegram":
            return .casual
        case "com.apple.mail",
             "com.microsoft.Outlook",
             "com.readdle.smartemail-Mac":
            return .professional
        case "com.apple.dt.Xcode",
             "com.apple.Terminal",
             "com.googlecode.iterm2",
             "com.mitchellh.ghostty",
             "com.microsoft.VSCode",
             "com.todesktop.230313mzl4w4u92":   // Cursor
            return .technical
        default:
            return nil
        }
    }
}

// MARK: - Trait values

public enum SpellingConvention: String, Codable, Sendable, CaseIterable {
    case british
    case american

    public var shortName: String {
        switch self {
        case .british:  return "British spelling"
        case .american: return "American spelling"
        }
    }

    /// "British/Australian" rather than "British": Roman is Australian, en-AU
    /// follows British convention, and a model told "British" for an Australian
    /// has been told something slightly false about who it is writing for.
    var promptLine: String {
        switch self {
        case .british:  return "Use British/Australian spelling."
        case .american: return "Use American spelling."
        }
    }
}

public enum Formality: String, Codable, Sendable, CaseIterable {
    case casual
    case neutral
    case formal
}

/// A value a trait can hold. Traits store votes keyed by a stable string rather
/// than the value itself, so the tally survives a rename and stays readable in
/// style.json — a learned-preferences file you cannot read by eye is a learned-
/// preferences file nobody will ever debug.
public protocol StyleTraitValue: Sendable, Equatable {
    var traitKey: String { get }
    init?(traitKey: String)
}

extension SpellingConvention: StyleTraitValue {
    public var traitKey: String { rawValue }
    public init?(traitKey: String) { self.init(rawValue: traitKey) }
}

extension Formality: StyleTraitValue {
    public var traitKey: String { rawValue }
    public init?(traitKey: String) { self.init(rawValue: traitKey) }
}

extension Bool: StyleTraitValue {
    public var traitKey: String { self ? "yes" : "no" }
    public init?(traitKey: String) {
        switch traitKey {
        case "yes": self = true
        case "no":  self = false
        default:    return nil
        }
    }
}

// MARK: - Trait

/// One learned preference and the evidence for it.
///
/// A tally rather than a flag, for two reasons. A flag cannot express "I have
/// seen this once and am not sure", which is the state the profile spends most
/// of its life in. And a flag cannot be argued out of: people change, and a
/// preference learned in March should not need until December to unlearn.
public struct StyleTrait<Value: StyleTraitValue>: Codable, Sendable, Equatable {

    /// Votes per value. Public shape is deliberate — this is what appears in
    /// style.json and it should read as an explanation, not as a checksum.
    public private(set) var votes: [String: Int]
    public private(set) var lastObserved: Date?

    /// The most votes any one value can hold.
    ///
    /// This is the "can change its mind" number. Each vote also takes one off
    /// every rival, so a settled preference survives a stray correction but
    /// flips after `voteCeiling` consistent ones. Six is about a month of real
    /// corrections — long enough not to be flighty, short enough to be possible.
    public static var voteCeiling: Int { 6 }

    public init() {
        self.votes = [:]
        self.lastObserved = nil
    }

    /// A starting belief that is still only a belief. Used by
    /// `StyleProfile.romanDefault` for the two things known about him up front.
    public init(seeding value: Value, votes count: Int) {
        self.votes = [value.traitKey: min(count, Self.voteCeiling)]
        self.lastObserved = nil
    }

    /// The winner, ignoring how sure we are. A genuine tie is unknown, not a
    /// coin toss — silence is the safe output for a feature that rewrites text.
    public var value: Value? {
        let ranked = votes.filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let top = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].value == top.value { return nil }
        return Value(traitKey: top.key)
    }

    public var support: Int { votes.values.max() ?? 0 }

    public var totalObservations: Int { votes.values.reduce(0, +) }

    public var confidence: Double {
        let total = totalObservations
        guard total > 0 else { return 0 }
        return Double(support) / Double(total)
    }

    public func settled(minimumSupport: Int, minimumConfidence: Double) -> Value? {
        guard support >= minimumSupport, confidence >= minimumConfidence else { return nil }
        return value
    }

    /// One observation, one vote. Callers must not stuff the ballot by counting
    /// every "colour" in a paragraph — see `StyleLearner`, where each detector
    /// returns at most one value per correction.
    public mutating func record(_ value: Value, at date: Date) {
        let key = value.traitKey
        for other in votes.keys where other != key {
            let remaining = (votes[other] ?? 0) - 1
            // Dropped rather than left at zero: this file is meant to be read by
            // a human, and "american: 0" sitting under "british: 4" reads like a
            // half-held opinion instead of an absence of one.
            if remaining > 0 { votes[other] = remaining } else { votes.removeValue(forKey: other) }
        }
        votes[key] = min(Self.voteCeiling, (votes[key] ?? 0) + 1)
        lastObserved = date
    }
}

// MARK: - Running mean

/// A mean that forgets. Sentence length is a habit, not a constant, and a
/// average taken over every dictation since installation stops responding to the
/// writer some time in month two.
public struct RunningMean: Codable, Sendable, Equatable {

    public private(set) var total: Double
    public private(set) var count: Int

    /// Beyond this the window slides instead of growing. Forty samples is enough
    /// for the mean to be stable and few enough that a changed habit shows up
    /// within a few weeks.
    public static let sampleCeiling = 40
    /// Below this the mean is noise, and a prompt rule built on noise is worse
    /// than no rule.
    public static let minimumSamples = 3

    public init() {
        self.total = 0
        self.count = 0
    }

    public var average: Double? {
        guard count >= Self.minimumSamples else { return nil }
        return total / Double(count)
    }

    public mutating func add(_ sample: Double) {
        if count >= Self.sampleCeiling, count > 0 {
            total -= total / Double(count)   // drop one sample's worth at the current mean
            count -= 1
        }
        total += sample
        count += 1
    }
}

// MARK: - Phrasing

/// A rewrite the user has made more than once.
public struct StylePhrasing: Codable, Sendable, Equatable, Identifiable {

    /// What Quill wrote, lowercased — matching is case-insensitive.
    public let from: String
    /// What he changed it to, verbatim. Casing is preserved because casing is
    /// often the entire edit.
    public var to: String
    public var count: Int
    public var lastObserved: Date?

    /// Stable without a UUID: the pair *is* the identity, and generating a new
    /// UUID for a rewrite already in the list is how duplicates appear in a
    /// dashboard table.
    public var id: String { from + "→" + to }

    public init(from: String, to: String, count: Int = 1, lastObserved: Date? = nil) {
        self.from = from.lowercased()
        self.to = to
        self.count = count
        self.lastObserved = lastObserved
    }

    /// Whether this is allowed to rewrite text on its own.
    ///
    /// Three sightings, and a trigger distinctive enough to be safe: multi-word,
    /// or a single word long enough not to be grammar. The rule that is missing
    /// here — "and a target that means the same thing" — is not checkable, which
    /// is exactly why the count bar is where it is.
    public var isApplicable: Bool {
        guard count >= StyleProfile.minimumPhrasingCount else { return false }
        let words = from.split(separator: " ").count
        return words > 1 || from.count >= 6
    }
}

// MARK: - Output guard

/// The style-shaped half of the guard between a model and Roman's keyboard.
///
/// `AIOutputGuard` already rejects responses that changed length implausibly or
/// dropped one of his words. This adds the check that belongs to Style: text
/// that came back sounding like a language model rather than like him.
///
/// It is a post-check rather than a prompt rule on purpose, and the measurement
/// is in AIConfig: telling this model what *not* to write ("list + do not
/// introduce these") dropped spoken self-correction from 20/20 to 0/20. Every
/// constraint that can be checked with a string comparison is checked with a
/// string comparison, and the prompt keeps its budget for the job only the model
/// can do.
public enum StyleGuard {

    /// Phrases that mark text as written by an assistant rather than a person.
    ///
    /// Short and boring on purpose. Each one is judged only when it appears in
    /// the *output* and not in the input — a cleanup pass has no business
    /// introducing any of them, and if Roman actually said "delve" the check
    /// never fires. That asymmetry is what keeps a list this blunt safe.
    static let tells: [String] = [
        "i hope this finds you well",
        "i hope this email finds you",
        "delve",
        "tapestry",
        "in today's fast-paced",
        "it's important to note",
        "it is important to note",
        "as an ai",
        "unlock the power",
        "elevate your",
        "rest assured",
        "we are excited to",
        "we're excited to",
        "cutting-edge",
        "game-changer",
        "seamlessly",
        // Added after a live run: asked to make "The site is live. Invoice
        // attached, due in 7 days." sound warm, the model produced "Hello and
        // welcome to our August newsletter! We're thrilled to…". The length
        // ceiling caught that one, but the tells should catch it first — a
        // rewrite that stays the same length would otherwise walk straight
        // through. See StyleProfileTests.
        "thrilled",
        "delighted to",
        "welcome to our",
        "look no further",
    ]

    /// Tells present in the output that were not in the input.
    public static func introducedTells(input: String, output: String) -> [String] {
        let inLower = input.lowercased()
        let outLower = output.lowercased()
        return tells.filter { outLower.contains($0) && !inLower.contains($0) }
    }

    /// The whole guard for the dictation path: length and vocabulary from
    /// `AIOutputGuard`, then tone, then the profile's own deterministic pass.
    ///
    /// Returns nil when the model output cannot be trusted — which means "insert
    /// the fast pass", not "show an error". The fast pass is decent text; a
    /// rejected rewrite costs nothing but the deadline that was already spent.
    ///
    /// Order matters and is deliberate: the profile's own rewrites run *after*
    /// the vocabulary check, not before. If a learned phrasing of Roman's
    /// happens to remove one of his vocabulary terms, that is him overruling
    /// himself three times over, which beats a rule written to protect him from
    /// a model.
    public static func sanitise(
        _ raw: String,
        against input: String,
        profile: StyleProfile,
        preserving vocabulary: [String] = []
    ) -> String? {
        guard let cleaned = AIOutputGuard.sanitise(raw, against: input, preserving: vocabulary) else {
            return nil
        }
        guard introducedTells(input: input, output: cleaned).isEmpty else { return nil }
        return profile.applyDeterministically(cleaned)
    }
}

// MARK: - Store

/// The profile on disk.
///
/// Same idiom as `HistoryStore` and `SnippetStore` — serialised through a queue,
/// written atomically, injectable with a URL so a test never touches the real
/// file. One persistence pattern in the app is worth more than a marginally
/// better one used once.
public final class StyleStore: @unchecked Sendable {

    public static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quill/style.json")
    }()

    /// The instance the dictation path reads.
    public static let shared = StyleStore()

    private let url: URL?
    private let queue = DispatchQueue(label: "com.romangigliotti.quill.style")
    private var current: StyleProfile

    public init(url: URL = StyleStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            current = (try? decoder.decode(StyleProfile.self, from: data)) ?? .romanDefault
        } else {
            // First run seeds Roman's defaults rather than an empty profile, for
            // the same reason SnippetStore seeds: a feature that does nothing
            // until it is configured is a feature nobody configures.
            current = .romanDefault
        }
    }

    /// Memory only — for tests and the dashboard preview renderer, neither of
    /// which may write to a real user's file.
    public init(inMemory profile: StyleProfile) {
        self.url = nil
        self.current = profile
    }

    public var profile: StyleProfile { queue.sync { current } }

    public func update(_ transform: (inout StyleProfile) -> Void) {
        queue.sync {
            transform(&current)
            persist()
        }
    }

    /// The dashboard's entry point: he edited a dictation and saved it.
    ///
    /// `dictated` is what Quill inserted, not the raw recogniser output — the
    /// diff that matters is between Quill's answer and his answer.
    @discardableResult
    public func recordCorrection(
        dictated: String,
        edited: String,
        at date: Date = Date()
    ) -> StyleProfile {
        queue.sync {
            guard current.isLearningEnabled else { return current }
            current = StyleLearner.learn(dictated: dictated, edited: edited, into: current, at: date)
            persist()
            return current
        }
    }

    public func recordModelOutcome(accepted: Bool) {
        update { $0.recordModelOutcome(accepted: accepted) }
    }

    public func setPreset(_ preset: StylePreset) {
        update { $0.preset = preset }
    }

    /// nil clears the override and returns the app to the suggested-or-base tone.
    public func setTone(_ preset: StylePreset?, forBundleID bundleID: String) {
        update { $0.appTones[bundleID] = preset }
    }

    /// For the dashboard's "forget what you've learned" — the escape hatch a
    /// learning feature has to have, or a single bad week is permanent.
    ///
    /// Back to first run, not back to blank: the seeded spelling and contraction
    /// votes are the app's shipped defaults rather than anything it learned, and
    /// a reset that also throws those away leaves an Australian being corrected
    /// into American spelling. Chosen settings are kept — the user did not ask
    /// to undo his own preset.
    public func resetLearning() {
        update {
            var fresh = StyleProfile.romanDefault
            fresh.preset = $0.preset
            fresh.appTones = $0.appTones
            fresh.isLearningEnabled = $0.isLearningEnabled
            fresh.modelAccepted = $0.modelAccepted
            fresh.modelReverted = $0.modelReverted
            $0 = fresh
        }
    }

    private func persist() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(current) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Destination

/// Which app the text is about to land in.
///
/// Captured at key-down alongside the input device, and for the same reason: by
/// the time the dictation ends the frontmost app may have changed, and the tone
/// should match where the words were aimed, not where the cursor drifted.
public enum DictationDestination {
    @MainActor
    public static func currentBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

// MARK: - Spelling

/// American → British spelling, deterministically.
///
/// One direction only, and that is a decision rather than an omission. Going the
/// other way means turning "-ise" into "-ize", which needs an exception list
/// running to advertise, surprise, exercise, promise, revise, devise, comprise,
/// compromise, supervise, improvise, disguise, franchise, merchandise and
/// enterprise before it stops writing non-words into someone's email. The user
/// is Australian; the payoff for the reverse direction is zero and the downside
/// is a typo he did not make. A profile set to `.american` therefore changes the
/// prompt and nothing else, which is honest about what a rule can do.
public enum Orthography {

    public static func toBritish(_ text: String) -> String {
        // Whitespace is preserved exactly rather than normalised: this runs on
        // text that is about to be pasted, and a cleanup pass that quietly eats
        // a blank line between paragraphs is a cleanup pass nobody trusts.
        var out = ""
        var token = ""
        for character in text {
            if character.isWhitespace {
                if !token.isEmpty { out += convertToken(token); token = "" }
                out.append(character)
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty { out += convertToken(token) }
        return out
    }

    /// Which convention a single word is written in, or nil for the vast
    /// majority of words that are spelled the same either way.
    ///
    /// Only unambiguous markers count. "advise", "surprise" and "raise" are
    /// spelled that way on both sides of the Atlantic, so a detector that reads
    /// any "-ise" as British evidence would find British habits in every writer
    /// alive. Silence beats a false reading — the vote it would cast is the same
    /// weight as a real one.
    public static func convention(of word: String) -> SpellingConvention? {
        let core = Self.split(word).core.lowercased()
        // Same letters-only test as the converter: a URL ending in "/customize"
        // is not a statement about how anyone spells.
        guard core.count >= 4, core.allSatisfy(\.isLetter) else { return nil }
        if isBritishMarker(core) { return .british }
        if americanised(core) != nil { return .american }
        return nil
    }

    // MARK: Tokens

    /// Anything that is not plain prose is left alone: a URL, an email address,
    /// a file name or an identifier that happens to contain "ize" is not a
    /// spelling mistake, and "Normalization.swift" must survive intact.
    ///
    /// The test is on the *core* — the token with its outer punctuation taken
    /// off — and it is "letters only". Testing the whole token instead was the
    /// first version and it was wrong in the most ordinary way possible: it
    /// refused to convert any word at the end of a sentence, because "color."
    /// contains a full stop. A core of pure letters is exactly the set of things
    /// a spelling rule has any business touching, and it excludes hyphenated
    /// compounds like "bite-size" for free.
    private static func convertToken(_ token: String) -> String {
        let parts = split(token)
        guard parts.core.count >= 4,
              parts.core.allSatisfy(\.isLetter),
              let replacement = americanised(parts.core.lowercased())
        else { return token }

        return parts.prefix + matchCase(of: parts.core, to: replacement) + parts.suffix
    }

    /// A token as leading punctuation, letters, trailing punctuation — so a
    /// conversion can put back exactly what it took off.
    static func split(_ token: String) -> (prefix: String, core: String, suffix: String) {
        let characters = Array(token)
        var start = 0
        while start < characters.count, !characters[start].isLetter { start += 1 }
        var end = characters.count
        while end > start, !characters[end - 1].isLetter { end -= 1 }
        return (String(characters[..<start]),
                String(characters[start ..< end]),
                String(characters[end...]))
    }

    static func matchCase(of original: String, to replacement: String) -> String {
        if original == original.uppercased(), original.count > 1 { return replacement.uppercased() }
        if let first = original.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    // MARK: Rules

    /// The British spelling of an American word, or nil if it is not one.
    static func americanised(_ lower: String) -> String? {
        if let direct = table[lower] { return direct }

        // -ize/-ization and friends. The stop list is the entire risk here: the
        // suffix is only a suffix in some words, and "seize" is not a verb
        // anybody spells "seise".
        if !isIzeException(lower) {
            for (american, british) in izeSuffixes where lower.hasSuffix(american) {
                // Keep a stem worth the name — "size" must never reach this.
                guard lower.count - american.count >= 3 else { continue }
                return String(lower.dropLast(american.count)) + british
            }
        }
        for (american, british) in yzeSuffixes where lower.hasSuffix(american) {
            guard lower.count - american.count >= 3 else { continue }
            return String(lower.dropLast(american.count)) + british
        }

        // -or → -our, as a stem table with a whitelist of endings. A blanket
        // rule cannot be used: British keeps "humorous", "vigorous",
        // "honorary" and "laborious" with the American-looking -or-.
        for (stem, british) in ourStems where lower.hasPrefix(stem) {
            let ending = String(lower.dropFirst(stem.count))
            guard ourEndings.contains(ending) else { continue }
            return british + ending
        }
        return nil
    }

    /// Evidence of British spelling that cannot be anything else.
    ///
    /// Three sources, all unambiguous: the explicit table ("centre", "defence",
    /// "travelled"), the -our family and its endings ("colour", "favourite",
    /// "neighbourhood"), and the two suffixes with no American-English
    /// homographs — "-isation" and "-yse". Notably absent is bare "-ise", which
    /// would match "advise", "raise", "promise" and "exercise" and turn every
    /// writer on earth British.
    static func isBritishMarker(_ lower: String) -> Bool {
        if britishOnly.contains(lower) { return true }
        for (_, british) in ourStems where lower.hasPrefix(british) {
            if ourEndings.contains(String(lower.dropFirst(british.count))) { return true }
        }
        if lower.hasSuffix("isation") || lower.hasSuffix("isations") { return true }
        for (_, british) in yzeSuffixes where lower.hasSuffix(british) {
            if lower.count - british.count >= 3 { return true }
        }
        return false
    }

    /// Words where "ize" is not a suffix at all.
    ///
    /// Matched on the tail rather than the whole word, because the ones that
    /// matter compound freely — resize, downsize, supersize, oversized — and an
    /// enumerated list would be missing whichever one Roman says first. No real
    /// "-ize" verb ends in "size", "prize" or "seize", so the tail test is exact
    /// rather than approximate.
    static func isIzeException(_ lower: String) -> Bool {
        if izeExceptions.contains(lower) { return true }
        for stem in ["size", "prize", "seize"] {
            let inflections = [stem, stem + "s", stem + "d", String(stem.dropLast()) + "ing"]
            if inflections.contains(where: { lower.hasSuffix($0) }) { return true }
        }
        return false
    }

    static let izeExceptions: Set<String> = ["maize", "assize", "baize", "sizer", "sizers"]

    static let izeSuffixes: [(String, String)] = [
        ("izations", "isations"), ("ization", "isation"),
        ("izers", "isers"), ("izer", "iser"),
        ("izing", "ising"), ("ized", "ised"), ("izes", "ises"), ("ize", "ise"),
    ]

    static let yzeSuffixes: [(String, String)] = [
        ("yzing", "ysing"), ("yzed", "ysed"), ("yzes", "yses"), ("yze", "yse"),
    ]

    static let ourStems: [(String, String)] = [
        ("color", "colour"), ("favor", "favour"), ("honor", "honour"),
        ("labor", "labour"), ("neighbor", "neighbour"), ("behavior", "behaviour"),
        ("flavor", "flavour"), ("rumor", "rumour"), ("harbor", "harbour"),
        ("armor", "armour"), ("vapor", "vapour"), ("savor", "savour"),
        ("endeavor", "endeavour"), ("splendor", "splendour"), ("valor", "valour"),
        ("odor", "odour"), ("tumor", "tumour"), ("clamor", "clamour"),
        ("demeanor", "demeanour"), ("parlor", "parlour"), ("humor", "humour"),
        ("vigor", "vigour"),
    ]

    /// Endings that keep the "u". Deliberately excludes "ous" and "ary":
    /// "humorous", "vigorous", "glamorous" and "honorary" are British spellings
    /// as they stand, and a rule that "fixes" them is a rule that breaks them.
    static let ourEndings: Set<String> = ["", "s", "ed", "ing", "ful", "less", "ite", "ites", "hood", "al", "ally"]

    /// Everything with no rule behind it. A table rather than cleverness,
    /// because the alternative is a heuristic that is wrong in public.
    static let table: [String: String] = [
        "center": "centre", "centers": "centres", "centered": "centred", "centering": "centring",
        "theater": "theatre", "theaters": "theatres",
        "liter": "litre", "liters": "litres",
        "fiber": "fibre", "fibers": "fibres",
        "caliber": "calibre", "somber": "sombre", "specter": "spectre",
        "meager": "meagre", "luster": "lustre", "maneuver": "manoeuvre",
        "defense": "defence", "defenses": "defences",
        "offense": "offence", "offenses": "offences",
        "pretense": "pretence",
        "traveled": "travelled", "traveling": "travelling", "traveler": "traveller",
        "canceled": "cancelled", "canceling": "cancelling",
        "modeled": "modelled", "modeling": "modelling",
        "labeled": "labelled", "labeling": "labelling",
        "marveled": "marvelled", "signaled": "signalled",
        "totaled": "totalled", "fueled": "fuelled", "fueling": "fuelling",
        "counselor": "counsellor", "jeweler": "jeweller",
        "gray": "grey", "plow": "plough", "mold": "mould", "smolder": "smoulder",
        "practicing": "practising", "practiced": "practised",
    ]

    /// Spellings that only exist in British English, used by `convention` so a
    /// single "colour" is recognised without needing a rule to reverse it.
    static let britishOnly: Set<String> = Set(table.values).union(
        ourStems.map(\.1)
    )
}
