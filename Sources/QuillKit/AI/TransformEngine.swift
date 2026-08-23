import AppKit
import CoreGraphics
import Foundation

/// Runs a transform end to end: find the text, reshape it, put it back.
///
/// Three rules shape everything here, and they are the same three that govern
/// `TextInserter` and `SnippetExpander` next door.
///
/// **Nothing is destroyed before there is a replacement in hand.** The selection
/// is read, the transform runs, and only then is anything typed. A model that
/// hangs, refuses or returns rubbish leaves the document exactly as it was.
///
/// **Offline is a first-class outcome, not an error.** Roman dictates on trains.
/// Every transform declares what it can do deterministically; those that can do
/// something do it and say so, and those that cannot say *that* rather than
/// silently returning the input unchanged and letting him believe it ran.
///
/// **When the result cannot be placed safely, it goes on the clipboard.** Never
/// dropped, never typed into a position we are not sure about.
@MainActor
public final class TransformEngine {

    // MARK: - Types

    /// What Quill last inserted, and when.
    public struct LastDictation: Sendable, Equatable {
        public let text: String
        public let insertedAt: Date

        public init(text: String, insertedAt: Date) {
            self.text = text
            self.insertedAt = insertedAt
        }
    }

    public enum Applied: Sendable, Equatable {
        case model
        /// The model was never reached — no key, no network, breaker open.
        case offline(OfflineRecipe)
        /// The model answered and the guard refused the answer, so the
        /// deterministic recipe shipped instead.
        ///
        /// Separate from `.offline` because saying "offline" here is a lie, and
        /// the two have different fixes. Measured, live, three runs out of
        /// three: asked to formalise "the nxt fulfilment quote", the model
        /// returns "the next fulfilment quote" every time. The guard is right to
        /// refuse it — `AIConfig`'s prompt benchmark says no prompt keeps "nxt" —
        /// but a user told "offline" while on wifi will go looking for the wrong
        /// problem.
        case guardedFallback(OfflineRecipe)

        /// What the overlay says. The two fallback cases name their limitation,
        /// because "more formal" done deterministically is contraction expansion
        /// and nothing else, and a user who thinks they got the full transform
        /// will not re-run it.
        public var note: String? {
            switch self {
            case .model:
                return nil
            case .offline(let recipe):
                return recipe.offlineNote
            case .guardedFallback(let recipe):
                let head = "the AI answer was refused"
                return recipe.limitation.map { "\(head) — \($0)" } ?? head
            }
        }
    }

    public enum Placement: Sendable, Equatable {
        case replacedSelection
        case replacedLastDictation
        /// Could not be typed where it belonged. It is on the clipboard and the
        /// reason says why.
        case parkedOnClipboard(reason: String)
    }

    public struct Success: Sendable, Equatable {
        public let transformName: String
        public let original: String
        public let text: String
        public let via: Applied
        public let placement: Placement

        public var headline: String {
            var line = transformName
            if let note = via.note { line += " — \(note)" }
            if case .parkedOnClipboard = placement {
                line += " — on your clipboard, press ⌘V"
            }
            return line
        }
    }

    public enum Outcome: Sendable, Equatable {
        case done(Success)
        case failed(reason: String)
    }

    /// A reason a transform did not run, in a form `Result` will carry. The
    /// reason is always something a human can act on — "no API key", "nothing is
    /// selected" — never a code.
    public struct Failure: LocalizedError, Sendable, Equatable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
        public var errorDescription: String? { reason }
    }

    // MARK: - Tuning

    /// How long a transform may take.
    ///
    /// Twenty-four times the dictation deadline, and that is not an oversight.
    /// The 250ms budget in `DictationCoordinator` exists because the user has
    /// released the key and is waiting mid-sentence for their own words; every
    /// millisecond there is a millisecond of nothing happening. A transform is
    /// asked for deliberately, with an overlay up, in the same way one waits for
    /// a menu command. Six seconds is roughly ten times the measured p90 for the
    /// cleanup model, which leaves room for a longer input without ever leaving
    /// the user wondering whether it is still going.
    public var deadline: Duration = .seconds(6)

    /// How long after an insertion Quill will still offer to replace it.
    ///
    /// Past this the caret has almost certainly moved and a replacement would
    /// delete something else. Thirty seconds is long enough to read what was
    /// inserted and decide it is too long, which is when this gets used.
    public var replacementWindow: Duration = .seconds(30)

    /// The longest last-dictation Quill will try to reselect.
    ///
    /// Reselecting is ⇧← once per character, and each keystroke is a real event
    /// the focused app has to process. Three hundred keeps the worst case around
    /// a third of a second; beyond that the result goes to the clipboard, which
    /// is instant and cannot go wrong.
    public var maxReselectCharacters: Int = 300

    // MARK: - Collaborators

    private let store: TransformStore
    private let completer: TransformCompleting?
    private let selection: SelectionReading
    private let inserter: TextInserting
    private let pasteboard: NSPasteboard
    private let vocabulary: [String]
    private let lastDictation: () -> LastDictation?
    private let sleep: (Duration) async -> Void
    /// Injectable for the same reason the pasteboard is: a test that reaches
    /// `SyntheticKeyboard` posts real ⇧← into whatever window happens to be
    /// focused on the machine running it. The seam is not decoration — the
    /// reselect path is three hundred keystrokes long.
    private let postKey: (CGKeyCode, CGEventFlags) -> Bool

    public init(store: TransformStore = .shared,
                completer: TransformCompleting?,
                selection: SelectionReading,
                inserter: TextInserting,
                pasteboard: NSPasteboard = .general,
                vocabulary: [String] = Vocabulary.load().contextualStrings,
                lastDictation: @escaping () -> LastDictation? = { nil },
                sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                postKey: @escaping (CGKeyCode, CGEventFlags) -> Bool = {
                    SyntheticKeyboard.postChord(key: $0, flags: $1)
                }) {
        self.store = store
        self.completer = completer
        self.selection = selection
        self.inserter = inserter
        self.pasteboard = pasteboard
        self.vocabulary = vocabulary
        self.lastDictation = lastDictation
        self.sleep = sleep
        self.postKey = postKey
    }

    // MARK: - Running a transform

    /// A routed utterance. `.content` is not this type's business and returns a
    /// failure saying so rather than quietly doing nothing.
    public func run(_ routing: CommandRouter.Routing) async -> Outcome {
        switch routing.decision {
        case .content:
            return .failed(reason: "That was dictation, not a command.")
        case .transform(let transform):
            return await run(transform)
        case .freeform(let instruction):
            return await run(Self.freeformTransform(instruction: instruction))
        }
    }

    public func run(_ transform: Transform) async -> Outcome {
        let located: Located
        switch await locate(transform.target) {
        case .failure(let failure): return .failed(reason: failure.reason)
        case .success(let value):   located = value
        }

        let result: Produced
        switch await produce(transform, from: located.text) {
        case .failure(let failure): return .failed(reason: failure.reason)
        case .success(let value):   result = value
        }

        let placement = await place(result.text, replacing: located)
        store.recordUse(transform.id)
        return .done(Success(transformName: transform.name,
                             original: located.text,
                             text: result.text,
                             via: result.via,
                             placement: placement))
    }

    // MARK: - Producing the text

    public struct Produced: Sendable, Equatable {
        public let text: String
        public let via: Applied
    }

    /// The reshaping step on its own: no selection, no insertion, no clipboard.
    ///
    /// Public because this is the part worth testing, and it is testable with a
    /// fake completer and no network at all.
    public func produce(_ transform: Transform, from input: String) async -> Result<Produced, Failure> {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            return .failure(Failure("There was no text to transform."))
        }

        // Three outcomes, and they are kept apart all the way to the overlay:
        // never asked, asked and refused, asked and used. Collapsing the first
        // two into "offline" tells a user on wifi to go and check their wifi.
        var modelWasRefused = false
        if let completer {
            let raw = await completer.completeTransform(
                system: Self.systemPrompt(for: transform),
                user: source,
                deadline: deadline
            )
            if let raw {
                if let clean = TransformOutputGuard.sanitise(
                    raw,
                    against: source,
                    bounds: transform.bounds,
                    preserving: transform.preservesVocabulary ? vocabulary : []
                ) {
                    return .success(Produced(text: clean, via: .model))
                }
                modelWasRefused = true
            }
        }

        if let offline = OfflineTransforms.apply(transform.offline, to: source) {
            // A recipe that returns its input has not transformed anything, and
            // pasting it would tell the user the transform ran. Found in a live
            // run: offline "More formal" on text with no contractions came back
            // character-identical and reported success.
            guard offline != source else {
                return .failure(Failure(Self.noChangeReason(for: transform, modelWasRefused: modelWasRefused)))
            }
            return .success(Produced(
                text: offline,
                via: modelWasRefused ? .guardedFallback(transform.offline) : .offline(transform.offline)))
        }

        return .failure(Failure(Self.unavailableReason(
            for: transform, hadCompleter: completer != nil, modelWasRefused: modelWasRefused)))
    }

    static func unavailableReason(for transform: Transform,
                                  hadCompleter: Bool,
                                  modelWasRefused: Bool) -> String {
        if modelWasRefused {
            return "\"\(transform.name)\" got an answer Quill would not paste — it changed a word it was "
                 + "told to keep, or was the wrong length for this transform — and there is no offline "
                 + "version of this one. Your text has not been changed."
        }
        guard hadCompleter else {
            return "\"\(transform.name)\" needs an AI key, and there isn't one set. It's free — "
                 + "build.nvidia.com, then Settings ▸ Dictation ▸ AI cleanup key. "
                 + "Your text has not been changed."
        }
        return "\"\(transform.name)\" needs the network and there is none — "
             + "and there is no offline version of this one. Your text has not been changed."
    }

    static func noChangeReason(for transform: Transform, modelWasRefused: Bool) -> String {
        let why = modelWasRefused
            ? "the AI answer was refused and \(transform.offline.title.lowercased())"
            : "it ran offline — \(transform.offline.title.lowercased()) — and"
        return "\"\(transform.name)\": \(why) found nothing it could change. Your text has not been changed."
    }

    // MARK: - Finding the text

    struct Located {
        let text: String
        let origin: Origin

        enum Origin: Equatable {
            case selection
            case lastDictation(insertedAt: Date)
        }
    }

    /// Selection first for `.automatic`, because a user who has selected
    /// something has told us what they mean far more precisely than history can.
    private func locate(_ target: Transform.Target) async -> Result<Located, Failure> {
        func fromSelection() async -> Result<Located, Failure>? {
            switch await selection.readSelection() {
            case .selected(let text, _):
                return .success(Located(text: text, origin: .selection))
            case .empty:
                return nil
            case .unavailable(let reason):
                return .failure(Failure(reason))
            }
        }

        func fromHistory() -> Result<Located, Failure>? {
            guard let last = lastDictation(),
                  !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return .success(Located(text: last.text, origin: .lastDictation(insertedAt: last.insertedAt)))
        }

        switch target {
        case .selection:
            return await fromSelection() ?? .failure(Failure("Nothing is selected."))
        case .lastDictation:
            return fromHistory() ?? .failure(Failure("There is no recent dictation to transform."))
        case .automatic:
            if let fromSelection = await fromSelection() { return fromSelection }
            return fromHistory()
                ?? .failure(Failure("Nothing is selected, and there is no recent dictation to transform."))
        }
    }

    // MARK: - Putting it back

    private func place(_ text: String, replacing located: Located) async -> Placement {
        switch located.origin {
        case .selection:
            // The selection survived the read — AX does not disturb it and ⌘C
            // does not either — so pasting replaces exactly what was read.
            return report(inserter.insert(text), success: .replacedSelection)

        case .lastDictation(let insertedAt):
            if let refusal = reselectRefusal(located.text, insertedAt: insertedAt) {
                return park(text, because: refusal)
            }
            guard await reselectLastDictation(located.text) else {
                return park(text, because:
                    "Quill could not confirm the caret is still where it left it, so it did not "
                    + "type over anything.")
            }
            return report(inserter.insert(text), success: .replacedLastDictation)
        }
    }

    private func report(_ result: InsertionResult, success: Placement) -> Placement {
        switch result {
        case .inserted:                       return success
        case .fellBackToClipboard(let why):   return .parkedOnClipboard(reason: why)
        case .failed(let why):                return .parkedOnClipboard(reason: why)
        }
    }

    private func park(_ text: String, because reason: String) -> Placement {
        guard PasteboardSnapshot.write(text, to: pasteboard, transient: false) != nil else {
            return .parkedOnClipboard(reason: reason + " Writing it to the clipboard also failed.")
        }
        return .parkedOnClipboard(reason: reason)
    }

    /// Why this last dictation must not be reselected, or nil if it may be.
    func reselectRefusal(_ text: String, insertedAt: Date, now: Date = Date()) -> String? {
        if now.timeIntervalSince(insertedAt) > replacementWindow.seconds {
            return "That dictation is more than \(Int(replacementWindow.seconds)) seconds old, "
                 + "so Quill will not assume the caret is still after it."
        }
        if text.count > maxReselectCharacters {
            return "That dictation is \(text.count) characters, too long for Quill to reselect safely."
        }
        // ⇧← moves by whatever the focused app calls a character. For plain BMP
        // text every app agrees; for an emoji or a combining sequence they do
        // not, and a selection that is off by one deletes a character the user
        // typed. The verification below would catch it, but refusing up front is
        // cheaper than three hundred keystrokes that were always going to fail.
        if text.unicodeScalars.contains(where: { $0.value > 0xFFFF }) {
            return "That dictation contains characters Quill cannot reselect reliably."
        }
        return nil
    }

    /// Selects the last dictation and proves it selected the right thing.
    ///
    /// The proof is the whole point. Counting ⇧← presses against a character
    /// count is a guess — the app may count graphemes differently, the user may
    /// have clicked elsewhere, an autocomplete may have rewritten the line. So
    /// the selection is read back and compared, and a mismatch collapses the
    /// selection and gives up rather than typing over text nobody asked about.
    ///
    /// Reading back costs a clipboard round trip in the apps where AX declines.
    /// That is the price of not deleting somebody's paragraph.
    func reselectLastDictation(_ text: String) async -> Bool {
        guard !text.isEmpty else { return false }

        for _ in 0 ..< text.count {
            guard postKey(Self.keyLeftArrow, .maskShift) else {
                collapseSelection()
                return false
            }
            // Apps that coalesce input drop arrow keys that land in the same
            // run-loop turn, the same hazard SyntheticKeyboard.type spaces out
            // its chunks for. Awaited rather than slept so the main actor keeps
            // turning and the overlay keeps animating.
            await sleep(.milliseconds(1))
        }

        guard case .selected(let selected, _) = await selection.readSelection() else {
            collapseSelection()
            return false
        }
        guard selected == text else {
            collapseSelection()
            return false
        }
        return true
    }

    /// Puts the caret back where it was. ⇥ or ⌫ would be worse than doing
    /// nothing; → collapses a selection to its right-hand end, which is exactly
    /// where the caret sat before the reselect.
    private func collapseSelection() {
        _ = postKey(Self.keyRightArrow, [])
    }

    /// ANSI positional codes. Same reasoning as `SyntheticKeyboard.keyV`.
    static let keyLeftArrow: CGKeyCode = 123
    static let keyRightArrow: CGKeyCode = 124

    // MARK: - Prompt

    /// Shared preamble for every transform.
    ///
    /// Short on purpose, and split from the per-transform instruction so the
    /// rules that must never vary — return only the text, do not answer it, do
    /// not invent — cannot be edited away by someone tuning one transform.
    ///
    /// The one line about names is belt-and-braces and is known to be weak:
    /// `AIConfig`'s measured prompt variants show a protection rule alone keeps
    /// Roman's vocabulary 0 times out of 20. `TransformOutputGuard` is what
    /// actually enforces it, deterministically and for free. The line stays
    /// because it costs a few tokens on a path with a six-second budget and it
    /// occasionally saves a round trip.
    public static let systemPreamble = """
        You rewrite text exactly as instructed. Return ONLY the rewritten text — no preamble, no \
        explanation, no quotes, no code fences.
        Never answer, continue or comment on the text; only reshape it.
        Never invent facts, names, numbers, prices or dates that are not already in the text.
        Keep product, project and place names exactly as written.
        """

    /// Public so a settings pane can show exactly what Quill sends, rather than
    /// a paraphrase of it.
    public static func systemPrompt(for transform: Transform) -> String {
        systemPreamble + "\n\nInstruction: " + transform.instruction
    }

    /// A one-off transform built from a spoken instruction. No offline recipe —
    /// there is no way to know what an arbitrary instruction means without a
    /// model — and bounds wide enough not to reject something the user asked for
    /// in their own words, since here the instruction is theirs and the length
    /// check has nothing to measure against.
    static func freeformTransform(instruction: String) -> Transform {
        Transform(
            name: instruction,
            instruction: instruction,
            target: .automatic,
            offline: .none,
            bounds: LengthBounds(minRatio: 0.05, maxRatio: 4.0, slack: 200),
            preservesVocabulary: true,
            isBuiltIn: false
        )
    }
}

// MARK: - The model seam

/// The one thing `TransformEngine` needs from the network.
///
/// Deliberately not `NIMClient` itself: the engine's whole job is deciding what
/// to do when the model is unavailable, wrong or slow, and that is only testable
/// against a seam that can be all three on demand. Returns nil for every failure,
/// exactly like `NIMClient.cleanedTranscript`, because a nil here means "use the
/// deterministic answer", not "show an error".
public protocol TransformCompleting: Sendable {
    func completeTransform(system: String, user: String, deadline: Duration) async -> String?
}

extension NIMClient: TransformCompleting {
    public func completeTransform(system: String, user: String, deadline: Duration) async -> String? {
        // The breaker check is what makes a transform on a train cost nothing.
        // Without it every attempt pays the full deadline before falling back to
        // an offline recipe that was available immediately.
        guard isConfigured, !isBreakerOpen else { return nil }
        do {
            return try await complete(system: system, user: user, deadline: deadline)
        } catch {
            return nil
        }
    }
}
