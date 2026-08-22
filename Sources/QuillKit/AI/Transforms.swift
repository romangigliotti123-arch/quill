import CoreGraphics
import Foundation

// Transforms reshape text that already exists. That is a different job from
// TranscriptCleaner, and the difference decides almost every choice in this file.
//
// Cleanup is invisible, automatic and bounded — it runs on every dictation, it
// must beat a 250ms deadline, and it is only ever allowed to make the text look
// more like what the user meant to say. A transform is the opposite on all four
// counts: the user asks for it explicitly, it may take a second, and it is
// *supposed* to change the meaning of the shape ("make that an email" adds a
// greeting that nobody spoke). The AIOutputGuard bounds that protect cleanup —
// output between 0.5× and 1.6× the input — would reject almost every correct
// transform, so transforms carry their own bounds per transform.
//
// The offline story is the same as everywhere else in Quill: Roman dictates on
// trains. Every transform declares what it does with no network. Some can be
// done exactly and deterministically (a bullet list is a sentence split; "more
// formal" is largely contraction expansion); some genuinely cannot ("summarise
// this"). The ones that cannot say so and refuse, rather than silently returning
// the input unchanged and letting the user believe the transform ran.

// MARK: - Length bounds

/// How much a transform is allowed to change the length of its input.
///
/// This is the only automatic check that can tell "the model rewrote the text"
/// from "the model answered the text", and it has to be per transform because
/// the honest answer differs by an order of magnitude: `.summarise` legitimately
/// keeps 8% of the characters, `.email` legitimately triples them. One shared
/// bound would have to be the union of both, which admits everything.
///
/// It is a backstop, not a meaning check — it cannot catch a rewrite that lands
/// at the same length. The instruction is the real defence.
public struct LengthBounds: Codable, Sendable, Equatable {
    public var minRatio: Double
    public var maxRatio: Double
    /// Added to the ceiling only. Short inputs need absolute headroom — "- " on
    /// every line of a two-line list is a large ratio and a tiny edit — while a
    /// floor with slack in it collapses to zero for anything short.
    public var slack: Int

    public init(minRatio: Double, maxRatio: Double, slack: Int) {
        self.minRatio = minRatio
        self.maxRatio = maxRatio
        self.slack = slack
    }

    public func admits(input: Int, output: Int) -> Bool {
        let n = Double(input), m = Double(output)
        return m >= n * minRatio && m <= n * maxRatio + Double(slack)
    }

    /// For a transform that reshapes without adding or removing information.
    public static let reshaping = LengthBounds(minRatio: 0.6, maxRatio: 1.6, slack: 24)
}

// MARK: - Offline recipes

/// What a transform does with no network.
///
/// Deliberately a closed enum of named recipes rather than a closure: it has to
/// survive a round trip through JSON, because a user-defined transform picks one
/// too. A recipe that cannot be written down cannot be persisted.
public enum OfflineRecipe: String, Codable, Sendable, CaseIterable {
    /// There is no honest deterministic version of this transform. Offline it
    /// refuses. See `TransformEngine` for what refusing looks like.
    case none
    case bulletList
    case numberedList
    /// Contractions out, spoken shorthand out. Not the whole of "more formal",
    /// and the UI says so, but it is the majority of it and it is exact.
    case expandContractions
    /// The deterministic cleanup pass Quill already ships.
    case fastClean
    case sentenceCase
    case titleCase
    case upperCase
    case lowerCase

    public var title: String {
        switch self {
        case .none:               return "Needs the network"
        case .bulletList:         return "Split into bullets"
        case .numberedList:       return "Split into a numbered list"
        case .expandContractions: return "Expand contractions"
        case .fastClean:          return "Deterministic cleanup"
        case .sentenceCase:       return "Sentence case"
        case .titleCase:          return "Title Case"
        case .upperCase:          return "UPPERCASE"
        case .lowerCase:          return "lowercase"
        }
    }

    /// How far short of the full transform this recipe falls, in the user's
    /// terms. Nil when the recipe is the whole job — a bullet list split by
    /// sentence is not an approximation of anything.
    ///
    /// This exists so the user is never left thinking they got the full
    /// transform when they did not, and so does not re-run it later on a
    /// connection that would have done the real thing.
    public var limitation: String? {
        switch self {
        case .expandContractions: return "contractions and filler only"
        case .fastClean:          return "deterministic cleanup only"
        default:                  return nil
        }
    }

    /// What the overlay says when this recipe ran because there was no network.
    public var offlineNote: String? {
        guard self != .none else { return nil }
        return limitation.map { "offline — \($0)" } ?? "offline"
    }
}

/// The deterministic implementations. Pure functions over a string, no state, no
/// network, microseconds. Returns nil when the recipe cannot apply.
public enum OfflineTransforms {

    public static func apply(_ recipe: OfflineRecipe, to text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch recipe {
        case .none:               return nil
        case .bulletList:         return list(trimmed, marker: { _ in "- " })
        case .numberedList:       return list(trimmed, marker: { "\($0 + 1). " })
        case .expandContractions: return expandContractions(trimmed)
        case .fastClean:          return FastCleaner().cleanFast(trimmed)
        case .sentenceCase:       return FastCleaner.capitaliseSentences(in: trimmed.lowercased())
        case .titleCase:          return trimmed.capitalized
        case .upperCase:          return trimmed.uppercased()
        case .lowerCase:          return trimmed.lowercased()
        }
    }

    // MARK: Lists

    /// Text that is already lines stays lines; prose is split into sentences.
    ///
    /// Sentence splitting uses ICU rather than a regex on ".!?" because dictation
    /// is full of "e.g." and "9 a.m." and "roman@example.com", and a regex turns
    /// every one of those into two bullets.
    static func list(_ text: String, marker: (Int) -> String) -> String? {
        let items = existingLines(text) ?? sentences(text)
        guard items.count > 1 || !text.contains("\n") else { return nil }
        guard !items.isEmpty else { return nil }
        return items.enumerated()
            .map { marker($0.offset) + stripTrailingStop($0.element) }
            .joined(separator: "\n")
    }

    /// Multi-line input is already a list of something; splitting its sentences
    /// as well would shred a paragraph the user deliberately kept together.
    static func existingLines(_ text: String) -> [String]? {
        guard text.contains("\n") else { return nil }
        let lines = text.split(separator: "\n").map {
            stripExistingMarker(String($0).trimmingCharacters(in: .whitespaces))
        }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines
    }

    /// "- foo", "* foo", "1. foo", "1) foo" → "foo". Re-bulleting a bullet list
    /// must not produce "- - foo".
    static func stripExistingMarker(_ line: String) -> String {
        let patterns = ["^[-*\u{2022}]\\s+", "^\\d+[.)]\\s+"]
        for pattern in patterns {
            if let range = line.range(of: pattern, options: .regularExpression) {
                return String(line[range.upperBound...])
            }
        }
        return line
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        let full = text.startIndex ..< text.endIndex
        text.enumerateSubstrings(in: full, options: [.bySentences, .localized]) { substring, _, _, _ in
            let piece = (substring ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { out.append(piece) }
        }
        return out.isEmpty ? [text] : out
    }

    /// The full stop at the end of a bullet is noise; anything else — a question
    /// mark, an exclamation — carries meaning and stays.
    static func stripTrailingStop(_ s: String) -> String {
        s.hasSuffix(".") && !s.hasSuffix("..") ? String(s.dropLast()) : s
    }

    // MARK: Contractions

    /// Ordered longest-first at use, so "wouldn't've" cannot be half-matched by
    /// "wouldn't". Apostrophes are matched in both the ASCII and the typographic
    /// form because the recogniser emits ’ and a user editing a transform types '.
    static let contractions: [String: String] = [
        "can't": "cannot", "won't": "will not", "shan't": "shall not",
        "don't": "do not", "doesn't": "does not", "didn't": "did not",
        "isn't": "is not", "aren't": "are not", "wasn't": "was not",
        "weren't": "were not", "haven't": "have not", "hasn't": "has not",
        "hadn't": "had not", "wouldn't": "would not", "couldn't": "could not",
        "shouldn't": "should not", "mustn't": "must not", "mightn't": "might not",
        "i'm": "I am", "i've": "I have", "i'll": "I will", "i'd": "I would",
        "you're": "you are", "you've": "you have", "you'll": "you will", "you'd": "you would",
        "we're": "we are", "we've": "we have", "we'll": "we will", "we'd": "we would",
        "they're": "they are", "they've": "they have", "they'll": "they will", "they'd": "they would",
        "he's": "he is", "she's": "she is", "it's": "it is", "that's": "that is",
        "there's": "there is", "here's": "here is", "what's": "what is",
        "let's": "let us", "who's": "who is",
        "he'll": "he will", "she'll": "she will", "it'll": "it will",
        "gonna": "going to", "wanna": "want to", "gotta": "have to",
        "kinda": "kind of", "sorta": "sort of", "cos": "because", "cuz": "because",
        "yeah": "yes", "yep": "yes", "nope": "no", "ok": "OK", "okay": "OK",
    ]

    /// Contractions out, and the spoken filler with them.
    ///
    /// The filler pass was added after a live run: "so um we should probably…"
    /// came back from the offline path character-identical to what went in, and
    /// a transform that returns its input has told the user it ran. "Um" is also
    /// not formal by any reading, so this is the recipe doing its actual job
    /// rather than padding it out.
    static func expandContractions(_ text: String) -> String {
        var out = FastCleaner.stripStandaloneDisfluencies(from: text)
        out = FastCleaner.collapseWhitespace(in: out)
        out = FastCleaner.tightenPunctuationSpacing(in: out)
        // Longest first: "wouldn't" must not be rewritten by a shorter key that
        // happens to be a prefix of it once ordering is arbitrary.
        for key in contractions.keys.sorted(by: { $0.count > $1.count }) {
            guard let replacement = contractions[key] else { continue }
            for apostrophe in ["'", "\u{2019}"] {
                let variant = key.replacingOccurrences(of: "'", with: apostrophe)
                out = out.replacingOccurrences(
                    of: "\\b\(NSRegularExpression.escapedPattern(for: variant))\\b",
                    with: replacement,
                    options: [.regularExpression, .caseInsensitive]
                )
            }
        }
        // The expansions are lowercase by construction; a sentence that started
        // with one now starts lowercase.
        return FastCleaner.capitaliseSentences(in: out)
    }
}

// MARK: - Hotkey

/// A chord that runs a transform.
///
/// Distinct from `HotkeyBinding` next door, which is bare-modifier-only because
/// push-to-talk is a *hold*. A transform is a one-shot action, so it wants an
/// ordinary chord — and it must never be a bare key, because a bare key that
/// runs a transform is a key that cannot be typed.
public struct TransformHotkey: Codable, Sendable, Equatable {

    public let keyCode: UInt16
    /// `CGEventFlags.rawValue`, already masked to `HotkeyBinding.chordMask`.
    /// Stored as the raw value because CGEventFlags is not Codable and the file
    /// has to survive being edited by hand.
    public let modifiers: UInt64

    public init?(keyCode: UInt16, modifiers: CGEventFlags) {
        let masked = modifiers.intersection(HotkeyBinding.chordMask)
        // Refused rather than repaired: a transform bound to bare "B" swallows
        // the letter B everywhere on the machine, and the user would have no way
        // to work out why their keyboard stopped typing.
        guard !masked.isEmpty else { return nil }
        self.keyCode = keyCode
        self.modifiers = masked.rawValue
    }

    public var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    /// Compares against the chord bits only. Raw flags from a built-in keyboard
    /// carry `.maskSecondaryFn` and the numeric-pad bit on ordinary keys, so an
    /// equality test on the raw value silently never matches.
    public func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode
            && flags.intersection(HotkeyBinding.chordMask) == self.flags
    }

    public var displayName: String {
        var out = ""
        let f = flags
        if f.contains(.maskControl)   { out += "⌃" }
        if f.contains(.maskAlternate) { out += "⌥" }
        if f.contains(.maskShift)     { out += "⇧" }
        if f.contains(.maskCommand)   { out += "⌘" }
        return out + Self.keyName(keyCode)
    }

    /// ANSI positional codes for the keys the built-ins use. Anything else is
    /// shown by number rather than guessed at — a wrong key name in a settings
    /// pane is worse than an honest one.
    static func keyName(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
            35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
            13: "W", 7: "X", 16: "Y", 6: "Z", 36: "Return", 49: "Space",
        ]
        return names[code] ?? "Key \(code)"
    }
}

// MARK: - Transform

/// One named reshaping of text.
public struct Transform: Codable, Sendable, Equatable, Identifiable {

    /// What the transform reads.
    public enum Target: String, Codable, Sendable, CaseIterable {
        /// Whatever is selected in the focused app.
        case selection
        /// The text Quill last inserted.
        case lastDictation
        /// Selection if there is one, otherwise the last dictation. The right
        /// default: it is what the user means every time, and it costs one
        /// selection read to find out.
        case automatic

        public var title: String {
            switch self {
            case .selection:     return "The current selection"
            case .lastDictation: return "The last dictation"
            case .automatic:     return "Selection, or the last dictation"
            }
        }
    }

    public let id: UUID
    public var name: String
    /// Handed to the model as the system instruction. Written as an order, not a
    /// description — "Rewrite as a bullet list", not "this makes bullet lists".
    public var instruction: String
    /// Whole-utterance phrases that invoke this transform in command mode. These
    /// are matched exactly, and that is what makes them safe; see `CommandRouter`.
    public var triggers: [String]
    /// The distinctive words that identify this transform inside a spoken
    /// instruction that is not an exact trigger. "formal", "bullet", "email".
    /// Ordinary English that could appear in dictated content does not belong
    /// here — every keyword is a chance to eat a sentence.
    public var keywords: [String]
    public var hotkey: TransformHotkey?
    public var target: Target
    public var offline: OfflineRecipe
    public var bounds: LengthBounds
    /// Whether Roman's vocabulary must survive the round trip.
    ///
    /// True for transforms that reshape without removing — a bullet list that
    /// turned "nxt" into "next" got it wrong. False for `.shorter` and
    /// `.summarise`, where dropping words is the entire point and rejecting on a
    /// missing term would reject every correct answer.
    public var preservesVocabulary: Bool
    public var isEnabled: Bool
    /// Shipped with the app. Only affects presentation — a built-in can be
    /// edited and deleted like any other.
    public var isBuiltIn: Bool
    public var useCount: Int
    public var lastUsed: Date?
    public var created: Date

    public init(id: UUID = UUID(),
                name: String,
                instruction: String,
                triggers: [String] = [],
                keywords: [String] = [],
                hotkey: TransformHotkey? = nil,
                target: Target = .automatic,
                offline: OfflineRecipe = .none,
                bounds: LengthBounds = .reshaping,
                preservesVocabulary: Bool = true,
                isEnabled: Bool = true,
                isBuiltIn: Bool = false,
                useCount: Int = 0,
                lastUsed: Date? = nil,
                created: Date = Date()) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.triggers = triggers
        self.keywords = keywords
        self.hotkey = hotkey
        self.target = target
        self.offline = offline
        self.bounds = bounds
        self.preservesVocabulary = preservesVocabulary
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.useCount = useCount
        self.lastUsed = lastUsed
        self.created = created
    }

    /// Hand-written rather than synthesised, and the reason is durability of a
    /// user's own data. This type will gain fields — a transform is exactly the
    /// kind of thing that grows options — and with a synthesised decoder one new
    /// non-optional field makes every previously-saved file fail to decode, at
    /// which point the store falls back to the seed and the user's transforms are
    /// gone. Only `id`, `name` and `instruction` are required; everything else
    /// defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        instruction = try c.decode(String.self, forKey: .instruction)
        triggers = try c.decodeIfPresent([String].self, forKey: .triggers) ?? []
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        hotkey = try c.decodeIfPresent(TransformHotkey.self, forKey: .hotkey)
        target = try c.decodeIfPresent(Target.self, forKey: .target) ?? .automatic
        offline = try c.decodeIfPresent(OfflineRecipe.self, forKey: .offline) ?? .none
        bounds = try c.decodeIfPresent(LengthBounds.self, forKey: .bounds) ?? .reshaping
        preservesVocabulary = try c.decodeIfPresent(Bool.self, forKey: .preservesVocabulary) ?? true
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }

    /// True when this transform can do something useful with no network.
    public var worksOffline: Bool { offline != .none }
}

// MARK: - Store

/// Transforms on disk.
///
/// Same shape as `SnippetStore` and `HistoryStore` — one persistence idiom in the
/// app, serialised through a queue, written atomically, injectable with a URL so
/// a test never touches the real file.
public final class TransformStore: @unchecked Sendable {

    public static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quill/transforms.json")
    }()

    public static let shared = TransformStore()

    private let url: URL?
    private let queue = DispatchQueue(label: "com.romangigliotti.quill.transforms")
    private var items: [Transform] = []
    /// Set when transforms.json exists and will not decode. While it is set the
    /// store never writes, so a damaged file is never overwritten.
    private var loadFailed = false

    public init(url: URL = TransformStore.defaultURL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Three states, not two. `try? decode ?? seed` collapses "the file is not
        // there" and "the file is damaged" into the same answer, and they call for
        // opposite behaviour.
        //
        // What that cost: a partial write during a crash, a zero-byte file, or one
        // hand-edited object missing a required key — and this file is explicitly
        // meant to be hand-editable — silently substituted the eight built-ins.
        // The next time any transform ran, `recordUse` found its id (it came from
        // the seed) and `persist()` wrote the seed over the file. Every custom
        // transform the user had written was gone, permanently, with no error.
        switch StoreFile.read([Transform].self, from: url, decoder: decoder) {
        case .missing:
            items = TransformStore.seed
        case .decoded(let stored):
            items = stored
        case .unreadable:
            // The seed in memory so the feature still works this session; nothing
            // written, so the damaged file survives for the user to rescue. It has
            // already been copied aside by `StoreFile`.
            items = TransformStore.seed
            loadFailed = true
        }
    }

    /// Memory only — for tests and previews, neither of which may write to a
    /// real user's file.
    public init(inMemory items: [Transform]) {
        self.url = nil
        self.items = items
    }

    public var all: [Transform] { queue.sync { items } }

    public var enabled: [Transform] { all.filter(\.isEnabled) }

    /// Most-used first. A transform list is a menu, and the one you reach for
    /// belongs at the top.
    public var ordered: [Transform] {
        all.sorted { a, b in
            if a.useCount != b.useCount { return a.useCount > b.useCount }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Saves an edit without touching the usage statistics.
    ///
    /// The editor holds the transform as it was when it opened. If the transform
    /// fires while that editor is on screen — which is the normal case, since the
    /// reason to open it is usually that the last run came out wrong — then
    /// `recordUse` bumps the counter and the next Save writes the stale snapshot
    /// straight back over it. The count silently rolls backwards, the "most used
    /// first" ordering shuffles, and there is nothing on screen to explain it.
    ///
    /// `useCount` and `lastUsed` belong to the run path. An edit is not a use, so
    /// an edit does not get to decide what they are.
    @discardableResult
    public func upsert(_ transform: Transform) -> Transform {
        queue.sync {
            if let index = items.firstIndex(where: { $0.id == transform.id }) {
                var merged = transform
                merged.useCount = max(items[index].useCount, transform.useCount)
                merged.lastUsed = [items[index].lastUsed, transform.lastUsed]
                    .compactMap { $0 }.max()
                items[index] = merged
            } else {
                items.append(transform)
            }
            persist()
            return items.first { $0.id == transform.id } ?? transform
        }
    }

    public func remove(id: UUID) {
        queue.sync {
            items.removeAll { $0.id == id }
            persist()
        }
    }

    public func transform(id: UUID) -> Transform? {
        queue.sync { items.first { $0.id == id } }
    }

    /// Bumps the counter for one firing. Separate from `upsert` so running a
    /// transform never races an open editor into overwriting an edit.
    public func recordUse(_ id: UUID, at date: Date = Date()) {
        queue.sync {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].useCount += 1
            items[index].lastUsed = date
            persist()
        }
    }

    /// Every trigger phrase, offered to the recogniser as a contextual string
    /// alongside the dictionary. A trigger that never survives transcription can
    /// never fire.
    public var phrases: [String] {
        enabled.flatMap(\.triggers)
    }

    private func persist() {
        // Announced, because the event tap cannot ask.
        //
        // `all` is `queue.sync { items }`, and this method writes a file on that
        // same queue — so reading the list from the tap thread would put a
        // system-wide keystroke behind a disk write. The tap keeps its own
        // snapshot instead and refreshes on this.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .quillTransformsDidChange, object: nil)
        }
        // Never over a file we could not read. The user's data outranks the app's
        // convenience, and a file the app refuses to touch is one a person can
        // still open in a text editor and fix.
        guard let url, !loadFailed else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

public extension Notification.Name {
    /// The transform list changed: one was added, edited, removed, or ran.
    /// Posted on main. See `TransformStore.persist()` for why this exists rather
    /// than the tap reading the store directly.
    static let quillTransformsDidChange =
        Notification.Name("com.romangigliotti.quill.transformsDidChange")
}

// MARK: - Hotkey routing

/// Which transform a chord runs.
///
/// A pure lookup rather than an event tap, on purpose. Quill already runs one
/// CGEventTap on its own thread, with its own retry, force-disable recovery and
/// permission story; a second tap for transform hotkeys would double all of that
/// and put two taps in a race for the same keyDown. The engine's callback calls
/// this and swallows the event when it returns something — one line, one tap.
public enum TransformHotkeyRouter {

    public static func transform(forKeyCode keyCode: UInt16,
                                 flags: CGEventFlags,
                                 in transforms: [Transform]) -> Transform? {
        transforms.first {
            $0.isEnabled && ($0.hotkey?.matches(keyCode: keyCode, flags: flags) ?? false)
        }
    }

    /// Chords already claimed, so an editor can refuse a duplicate binding
    /// instead of shipping two transforms that fight over one key.
    public static func conflicts(with hotkey: TransformHotkey,
                                 excluding id: UUID,
                                 in transforms: [Transform]) -> [Transform] {
        transforms.filter { $0.id != id && $0.hotkey == hotkey }
    }
}

// MARK: - Seed

public extension TransformStore {

    /// First-run contents.
    ///
    /// Chosen by what Roman actually retypes rather than by what demos well:
    /// client email, list-shaped notes, and "that came out too long". Each one
    /// declares honestly what it can do on a train.
    ///
    /// The trigger phrases are the safety-critical part of this list. Every one
    /// contains a command verb *and* a referent ("that", "it", "this"), because
    /// `CommandRouter` will only fire on a whole utterance and those two things
    /// together are what make a whole utterance an instruction rather than a
    /// sentence someone dictated. A trigger like "bullet points" is deliberately
    /// absent: it is a phrase a person could plausibly dictate into a document,
    /// and eating it would cost them their words.
    static var seed: [Transform] {
        let now = Date()

        return [
            Transform(
                name: "Bullet points",
                instruction: """
                    Rewrite the text as a bullet list. One point per line, each line starting with "- ".
                    Keep every fact and every name; do not add, merge or invent points. No heading, no preamble.
                    """,
                triggers: ["make that a bullet list", "make it a bullet list",
                           "turn that into bullet points", "turn this into bullet points",
                           "make that bullet points", "format that as bullet points",
                           "bullet point that"],
                // "list" is shared with the numbered transform on purpose: it is
                // what makes "make that a bullet list" score two keywords against
                // the numbered transform's one, so the tie-break never has to run.
                keywords: ["bullet", "bullets", "bulleted", "list"],
                offline: .bulletList,
                bounds: LengthBounds(minRatio: 0.6, maxRatio: 1.6, slack: 24),
                isBuiltIn: true,
                useCount: 0,
                created: now),

            Transform(
                name: "Numbered list",
                instruction: """
                    Rewrite the text as a numbered list. One step per line, each line starting with "1. ", "2. " and so on.
                    Keep every fact and every name; do not add or invent steps. No heading, no preamble.
                    """,
                triggers: ["make that a numbered list", "make it a numbered list",
                           "turn that into a numbered list", "number that"],
                keywords: ["numbered", "number", "list"],
                offline: .numberedList,
                bounds: LengthBounds(minRatio: 0.6, maxRatio: 1.7, slack: 24),
                isBuiltIn: true,
                created: now),

            Transform(
                name: "Shorter",
                instruction: """
                    Rewrite the text in fewer words. Keep every fact, name and number; cut only padding and repetition.
                    Same voice, same person, same tense. Return only the rewritten text.
                    """,
                triggers: ["make that shorter", "make it shorter", "make this shorter",
                           "shorten that", "shorten it", "tighten that up", "trim that down"],
                keywords: ["shorter", "shorten", "tighten", "trim", "concise"],
                offline: .none,
                bounds: LengthBounds(minRatio: 0.15, maxRatio: 1.0, slack: 8),
                // Cutting words is the job. A vocabulary check here would reject
                // every correct answer that dropped a proper noun on purpose.
                preservesVocabulary: false,
                isBuiltIn: true,
                created: now),

            Transform(
                name: "Summarise",
                instruction: """
                    Summarise the text in one or two sentences. State only what the text says; add nothing.
                    Return only the summary, with no preamble and no heading.
                    """,
                // "give me the gist of that" was here and was removed: it has no
                // command verb, and a whole utterance of it is something a person
                // says to another person in a chat window.
                triggers: ["summarise that", "summarize that", "summarise this", "summarize this",
                           "sum that up"],
                keywords: ["summarise", "summarize", "summary", "gist"],
                offline: .none,
                bounds: LengthBounds(minRatio: 0.08, maxRatio: 0.8, slack: 24),
                preservesVocabulary: false,
                isBuiltIn: true,
                created: now),

            Transform(
                name: "More formal",
                instruction: """
                    Rewrite the text in a more formal register. Expand contractions, drop slang and filler,
                    and use complete sentences. Do not lengthen it, do not add pleasantries, and do not change any fact.
                    """,
                triggers: ["make that more formal", "make it more formal", "make this more formal",
                           "formalise that", "make that sound professional"],
                keywords: ["formal", "formalise", "formalize", "professional"],
                offline: .expandContractions,
                bounds: LengthBounds(minRatio: 0.7, maxRatio: 1.8, slack: 24),
                isBuiltIn: true,
                created: now),

            Transform(
                name: "More casual",
                instruction: """
                    Rewrite the text so it reads like one person talking to another they already know.
                    Plain words, contractions allowed, no corporate phrasing, no exclamation marks. Change no fact.
                    """,
                triggers: ["make that more casual", "make it more casual",
                           "make that sound friendlier", "make it less formal"],
                keywords: ["casual", "friendlier", "informal", "relaxed"],
                offline: .none,
                bounds: LengthBounds(minRatio: 0.5, maxRatio: 1.5, slack: 24),
                isBuiltIn: true,
                created: now),

            Transform(
                name: "Email",
                // "No subject line" is spelled out because a live run put one in
                // unasked — "Subject: Nxt Fulfilment Quote for Carlo" — and a
                // subject line pasted into a Slack message or a reply box is
                // invented scaffolding in the wrong place.
                instruction: """
                    Rewrite the text as a short email body: one greeting line, the body, and a sign-off of "Cheers,\nRoman".
                    No subject line, no headers, no "Subject:".
                    Keep the body to what the text actually says — do not invent context, deadlines, prices or names.
                    If the recipient is not named in the text, open with "Hey —". Return only the email.
                    """,
                // "write that as an email" is absent because "write" is not a
                // command verb and is not going to become one — "write that in
                // the notes" is dictation.
                triggers: ["make that an email", "make it an email", "turn that into an email",
                           "turn this into an email"],
                keywords: ["email"],
                offline: .none,
                // A greeting and a sign-off are roughly 40 characters of scaffolding
                // that were never in the input, so the ceiling is generous and the
                // slack is absolute rather than proportional.
                bounds: LengthBounds(minRatio: 0.8, maxRatio: 3.0, slack: 120),
                isBuiltIn: true,
                created: now),

            Transform(
                name: "Fix grammar",
                instruction: """
                    Correct grammar, spelling and punctuation. Change nothing else — not the wording, not the register,
                    not the order. If a sentence is already correct, return it untouched.
                    """,
                // Every trigger names what it acts on. Bare "fix the grammar" was
                // here and was removed — with no referent it is an instruction to
                // a person, and people dictate those.
                triggers: ["fix the grammar in that", "fix that up",
                           "clean that up", "clean up that", "tidy that up", "proofread that"],
                keywords: ["grammar", "spelling", "punctuation", "proofread", "tidy"],
                offline: .fastClean,
                bounds: LengthBounds(minRatio: 0.8, maxRatio: 1.3, slack: 16),
                isBuiltIn: true,
                created: now),
        ]
    }

    /// A store the dashboard can render without touching disk.
    static func preview() -> TransformStore { TransformStore(inMemory: seed) }
}

// MARK: - Output guard

/// The guard between a language model and text the user is about to send.
///
/// `AIOutputGuard` next door does this job for the cleanup pass, and its
/// stripping steps are reused verbatim — a model that wraps its answer in quotes
/// or prefixes it with "Here is the email:" does that regardless of what it was
/// asked. What is not reused is its length rule, which is calibrated for a pass
/// that must not change the text much, and its "\n\n means the model started
/// explaining" rule, which would reject every correct email.
public enum TransformOutputGuard {

    /// Returns the text to insert, or nil if the response cannot be trusted. Nil
    /// means "fall back to the offline recipe, or tell the user it did not run" —
    /// never "paste it anyway".
    public static func sanitise(_ raw: String,
                                against input: String,
                                bounds: LengthBounds,
                                preserving terms: [String]) -> String? {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }

        out = AIOutputGuard.stripCodeFence(out)
        out = AIOutputGuard.stripLeadingLabel(out)
        out = AIOutputGuard.stripWrappingQuotes(out)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }

        // A model that opens with "Sure, here you go" has answered the request
        // rather than performed it. `stripLeadingLabel` only catches the form
        // that ends in a colon; this catches the conversational form, which the
        // label stripper cannot touch without risking real sentences.
        guard !opensConversationally(out) || opensConversationally(input) else { return nil }

        guard bounds.admits(input: input.count, output: out.count) else { return nil }

        if !terms.isEmpty,
           !AIOutputGuard.droppedVocabulary(from: input, to: out, terms: terms).isEmpty {
            return nil
        }
        return out
    }

    static let conversationalOpeners = [
        "sure", "certainly", "of course", "here is", "here's", "here are",
        "i've", "i have", "absolutely", "no problem", "got it", "understood",
    ]

    public static func opensConversationally(_ text: String) -> Bool {
        let firstLine = text.split(separator: "\n", maxSplits: 1,
                                   omittingEmptySubsequences: false).first.map(String.init) ?? text
        let lowered = firstLine.lowercased()
        return conversationalOpeners.contains { opener in
            guard lowered.hasPrefix(opener) else { return false }
            // "Here is the deposit schedule" is a real sentence someone could be
            // transforming; "Here is the rewritten text:" is not. Require the
            // opener to be followed by a boundary that reads like an aside.
            let rest = lowered.dropFirst(opener.count)
            guard let next = rest.first else { return true }
            return next == "," || next == ":" || next == "!"
                || rest.hasPrefix(" the rewritten") || rest.hasPrefix(" the text")
                || rest.hasPrefix(" your") || rest.hasPrefix(" is the rewritten")
        }
    }
}
