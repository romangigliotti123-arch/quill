import AppKit
import Foundation

/// What kind of place the text is about to land in.
///
/// Every dictation app treats the destination as a single undifferentiated hole
/// to put words in, and the result is that dictating a shell command into a
/// terminal gives you `git status.` — with a full stop, which is not a command.
/// Dictating into a search field gives you `Melbourne weather.` Dictating a
/// commit message gives you a capital letter you then delete.
///
/// Quill already knows the answer: the insertion path reads the frontmost
/// application to decide where it is safe to type. That fact was being used for
/// safety and thrown away for formatting.
///
/// This is a place where an on-device app has a structural advantage. Wispr Flow
/// sends audio to a server and gets prose back; the server has no idea you are in
/// a terminal. Quill decides after transcription, locally, with the destination
/// in hand.
public enum AppContext: String, Sendable, CaseIterable {

    /// A shell. No trailing punctuation, no sentence casing — a command is not a
    /// sentence and every decoration has to be deleted by hand.
    case terminal
    /// A search field, address bar, or anything else where the text is a query.
    /// Queries do not end in full stops.
    case query
    /// A code editor. Sentence casing is wrong more often than right, and a
    /// trailing full stop inside a string literal or an identifier is noise.
    case code
    /// Ordinary prose: mail, chat, documents, notes. Full punctuation.
    case prose

    /// Bundle identifiers, matched exactly where possible and by prefix otherwise.
    ///
    /// Deliberately a small list of things actually on this machine rather than an
    /// attempt at completeness. A wrong guess here silently changes how someone's
    /// words come out, so the default is prose — the conservative answer, and what
    /// the app did before this existed.
    public static func of(bundleID: String?) -> AppContext {
        guard let id = bundleID?.lowercased() else { return .prose }

        let terminals = [
            "com.mitchellh.ghostty", "com.apple.terminal", "com.googlecode.iterm2",
            "dev.warp.warp-stable", "co.zeit.hyper", "net.kovidgoyal.kitty",
            "com.github.wez.wezterm", "io.alacritty",
        ]
        if terminals.contains(id) { return .terminal }

        let editors = [
            "com.microsoft.vscode", "com.visualstudio.code.oss", "com.apple.dt.xcode",
            "com.sublimetext", "com.jetbrains", "dev.zed.zed", "com.todesktop",
            "com.neovim", "org.vim",
        ]
        if editors.contains(where: { id.hasPrefix($0) }) { return .code }

        return .prose
    }

    /// The application the text is about to be inserted into.
    @MainActor
    public static func current() -> AppContext {
        of(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    // MARK: - What each context wants

    /// Whether a sentence should be given a capital letter at the front.
    public var capitalisesSentences: Bool {
        switch self {
        case .terminal, .code, .query: return false
        case .prose: return true
        }
    }

    /// Whether a trailing full stop is welcome.
    ///
    /// This is the one that bites hardest. `npm run build.` is not a command, and
    /// the full stop has to be found and deleted every single time — which is
    /// exactly the kind of small tax that makes someone stop using dictation
    /// without ever being able to say why.
    public var keepsTrailingFullStop: Bool {
        switch self {
        case .terminal, .query: return false
        case .code, .prose: return true
        }
    }

    public var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .query:    return "Search field"
        case .code:     return "Code editor"
        case .prose:    return "Everything else"
        }
    }

    /// One line, in the user's terms, for the settings screen.
    public var explanation: String {
        switch self {
        case .terminal: return "No capital, no full stop — a command is not a sentence."
        case .query:    return "No full stop; a query does not end in one."
        case .code:     return "Punctuation kept, no sentence casing."
        case .prose:    return "Full punctuation and sentence casing."
        }
    }
}

/// Applies the destination's conventions to already-cleaned text.
///
/// Runs last, after the deterministic cleanup and after any model pass, because
/// it is the only step that knows something the others cannot: where the words
/// are going. It only ever *removes* decoration that the cleanup added — it never
/// adds anything, never reorders, and never touches a word. The worst it can do
/// is leave text exactly as the cleanup produced it.
public enum AppContextFormatter {

    public static func apply(_ text: String, context: AppContext) -> String {
        var out = text
        if !context.keepsTrailingFullStop {
            // Only a full stop, and only one, and only at the very end. A question
            // mark is information — "did the build pass?" means something a full
            // stop does not — and an ellipsis is deliberate.
            if out.hasSuffix(".") && !out.hasSuffix("..") {
                out.removeLast()
            }
        }
        if !context.capitalisesSentences {
            out = lowercasingFirstLetterIfSafe(out)
        }
        return out
    }

    /// Undoes the cleanup's opening capital, unless the first word looks like it
    /// wanted one.
    ///
    /// A name at the start of a command is common — `Docker ps`, `Netlify deploy`,
    /// `Roman` — and the vocabulary corrector may deliberately have capitalised it
    /// moments earlier. So a word that is capitalised in the middle of the text
    /// too, or a word that is not plain lowercase-able, is left alone. Getting this
    /// wrong in the safe direction means an unwanted capital; getting it wrong in
    /// the unsafe direction means mangling a proper noun.
    static func lowercasingFirstLetterIfSafe(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let words = text.split(separator: " ")
        guard let firstWord = words.first else { return text }
        // ALL CAPS is an acronym: NPM, SSH, API. Leave it.
        if firstWord.count > 1, firstWord.allSatisfy({ !$0.isLetter || $0.isUppercase }) { return text }
        // The same word capitalised again later is a name, not a sentence start.
        let bare = String(firstWord).trimmingCharacters(in: .punctuationCharacters)
        if words.dropFirst().contains(where: { $0.hasPrefix(bare) }) { return text }
        return text.replacingCharacters(in: text.startIndex...text.startIndex,
                                        with: String(first).lowercased())
    }
}
