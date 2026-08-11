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
        "net lify": "Netlify",
        "craigie burn": "Craigieburn",
        "swift ui": "SwiftUI",
        "mac os": "macOS",
        "i os": "iOS",
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
