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

    public init() {}

    public func cleanFast(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        text = Self.applyCorrections(to: text)
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

    static func capitaliseSentences(in text: String) -> String {
        var chars = Array(text)
        var capitaliseNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitaliseNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitaliseNext = false
            } else if c == "." || c == "!" || c == "?" {
                capitaliseNext = true
            }
        }
        return String(chars)
    }
}
