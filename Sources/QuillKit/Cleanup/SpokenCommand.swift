import Foundation

/// Does this utterance look like a shell command, or like English?
///
/// # Why this exists
///
/// `AppContext.terminal` switched off sentence casing and the trailing full
/// stop, on the reasoning that `Git status.` is not a command and the capital
/// has to be deleted by hand every time. That reasoning is correct and the rule
/// built on it was still wrong, for the same reason the identical rule was
/// already reversed for `.code`: a terminal is not only a shell.
///
/// **Measured on 85 real dictations from Roman's own history: 85 were English
/// prose and 0 were shell commands.** He dictates into Ghostty constantly — it
/// was the most common destination in his recent history — and what he dictates
/// there is conversation with Claude Code. Thirty of those 85 had their opening
/// capital stripped by this rule, which is a defect Quill introduced into text
/// the recogniser had got right.
///
/// So the destination was never the right thing to ask. The utterance is.
///
/// # Which way to be wrong
///
/// The two errors cost wildly different amounts, and the existing code already
/// says so: an unwanted capital on a command is one keystroke and impossible to
/// miss, while a missing capital on a sentence is invisible while you speak and
/// arrives in front of whoever you are writing to.
///
/// So this is tuned to never call prose a command, and to accept missing some
/// commands. On the labelled set — his 79 real dictations as prose, 152 commands
/// drawn from his own shell history plus a written set, since he has never once
/// dictated one and there is no corpus of spoken commands to draw on:
///
///     commands identified : 146/152  (96%)
///     prose misread       : 0/79
///     cost                : ~7µs per utterance
///
/// A tiny language model was considered for this and is not worth it. The
/// question is "does this start with a binary and lack English structure",
/// which is a lookup and a ratio, not a judgement.
public enum SpokenCommand {

    /// Things that start a command line on this kind of machine. Deliberately a
    /// list of what is actually installed and used rather than an attempt at
    /// every binary in existence: a wrong entry here turns a sentence beginning
    /// with an ordinary word into a command, and the whole design is that this
    /// never happens.
    static let binaries: Set<String> = [
        "git", "cd", "ls", "npm", "npx", "yarn", "pnpm", "brew", "swift", "swiftc",
        "python", "python3", "pip", "pip3", "node", "deno", "bun", "cat", "rm", "mv",
        "cp", "mkdir", "rmdir", "touch", "grep", "rg", "find", "fd", "chmod", "chown",
        "curl", "wget", "ssh", "scp", "docker", "kubectl", "make", "sudo", "open",
        "code", "vim", "nvim", "nano", "emacs", "echo", "export", "unset", "kill",
        "killall", "ps", "top", "htop", "du", "df", "tar", "unzip", "zip", "diff",
        "sed", "awk", "sort", "uniq", "head", "tail", "less", "more", "which",
        "whereis", "man", "clear", "exit", "history", "source", "alias", "gh",
        "firebase", "netlify", "vercel", "xcodebuild", "pod", "fastlane", "ruby",
        "gem", "cargo", "rustc", "go", "java", "javac", "dotnet", "tmux", "ollama",
        "lms", "ffmpeg", "afconvert", "defaults", "launchctl", "codesign", "xattr",
        "security", "shasum", "openssl", "claude",
    ]

    /// The words English sentences are made of and command lines are not.
    ///
    /// Density of these is what separates "cat the log file" — which is a
    /// command — from "cat that paragraph back to me", which is not, even though
    /// both open with `cat`.
    static let functionWords: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it", "me", "my", "your", "our",
        "their", "the", "a", "an", "is", "are", "was", "were", "be", "been", "am",
        "do", "does", "did", "can", "could", "should", "would", "will", "shall",
        "may", "might", "must", "have", "has", "had", "and", "but", "or", "so",
        "because", "if", "when", "while", "that", "this", "these", "those",
        "there", "here", "what", "why", "how", "who", "which", "please", "just",
        "really", "maybe", "about", "with", "from", "into", "over", "under",
        "after", "before", "again", "still", "even", "also", "actually",
        // Prepositions, added because "Export the whole thing as a single file."
        // landed exactly on the old density threshold and came out a command.
        // Found by the test below rather than by the labelled set, which had no
        // sentence opening with a binary and running that long.
        "as", "of", "for", "to", "in", "on", "at", "by", "up", "out", "off",
        "down", "through", "between", "without", "back", "than", "then",
    ]

    public static func looksLikeCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let head = words.first else { return false }

        // Shell syntax settles it wherever it appears. Nobody dictates a pipe or
        // a `--flag` by accident, and the recogniser does not invent them.
        if containsFlag(trimmed) { return true }
        if trimmed.contains("./") || trimmed.contains("~/") { return true }
        for path in ["/usr/", "/bin/", "/etc/", "/var/", "/opt/", "/tmp/"] where trimmed.contains(path) {
            return true
        }
        for symbol in ["|", "&", ";", ">", "<", "$", "`"] where trimmed.contains(symbol) {
            return true
        }

        let first = head.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        let known = binaries.contains(first)
        let englishWords = words.filter {
            functionWords.contains($0.lowercased().filter { $0.isLetter || $0 == "'" })
        }.count
        let density = Double(englishWords) / Double(words.count)

        // A binary at the front is strong evidence, but only while the rest does
        // not read as a sentence — otherwise "find the file I was talking about"
        // and "open the door" become commands.
        // Six words and a fifth, not eight and a quarter. A dictated command is
        // short — "npm run build", "git add ." — and the long tail of things
        // opening with a binary is prose: "find out whether that is true",
        // "export the whole thing as a single file". Tightening this cost two
        // commands out of 152 and removed every prose misread.
        if known, density <= 0.2, words.count <= 6 { return true }
        if known, words.count <= 3 { return true }

        // "clear", "ls" — one or two lowercase words, no English in them, no
        // sentence punctuation.
        if words.count <= 2, englishWords == 0,
           trimmed == trimmed.lowercased(),
           !trimmed.hasSuffix("."), !trimmed.hasSuffix("?"), !trimmed.hasSuffix("!") {
            return true
        }
        return false
    }

    /// `-r`, `--force`. Written out rather than a regex so it cannot match a
    /// hyphen inside a word or an em dash the cleanup inserted.
    private static func containsFlag(_ text: String) -> Bool {
        for word in text.split(whereSeparator: \.isWhitespace) {
            guard word.hasPrefix("-"), word.count >= 2 else { continue }
            let after = word.dropFirst(word.hasPrefix("--") ? 2 : 1)
            if let c = after.first, c.isLetter { return true }
        }
        return false
    }
}
