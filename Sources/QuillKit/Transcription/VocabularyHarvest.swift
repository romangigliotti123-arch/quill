import Foundation

/// Finds the proper nouns you actually use, by looking at your own machine.
///
/// The dictionary is the single highest-leverage thing in this app and the one
/// nobody maintains. Measured on Roman's voice: "Netlify" came back as
/// "Netterfly", "graphify" as "grapify", "Firestore" as "fire pay will fi" — and
/// every one of those was already in the seed list, which is the only reason any
/// of them were repaired. The words that are *not* in the list fail silently and
/// forever, and asking someone to sit down and type out their own vocabulary is a
/// task that never gets done.
///
/// So it reads the names off the machine instead. Folder names under the projects
/// directory, git remote names, the `name` field of package manifests: these are
/// exactly the words a developer says out loud all day and exactly the ones a
/// general speech model has never seen.
///
/// **It reads names, never contents.** Directory entries, a remote URL, and one
/// field from a manifest. It does not open source files, does not read documents,
/// and never leaves the machine — the whole point of an on-device app is that
/// this kind of thing is safe to do, and it is only safe if the boundary is
/// drawn tightly and kept there. Wispr Flow could not offer this at any price:
/// harvesting a user's project names into a cloud service is a different product
/// with a different privacy story.
///
/// Suggestions are proposed, never auto-applied. A dictionary that adds words by
/// itself is one that starts rewriting your speech into terms you did not choose.
public enum VocabularyHarvest {

    public struct Suggestion: Sendable, Equatable, Identifiable {
        public var id: String { term }
        public let term: String
        /// Where it was found, in the user's terms — shown so a suggestion can be
        /// judged rather than merely accepted.
        public let source: String
    }

    /// Roots worth looking in, in order. Only directories that already exist are
    /// visited; nothing is created and nothing is walked recursively beyond the
    /// depth named here.
    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents/Work/Projects"),
            home.appendingPathComponent("Developer"),
            home.appendingPathComponent("Projects"),
        ]
    }

    /// Everything worth suggesting, minus what is already known.
    public static func suggestions(
        roots: [URL] = defaultRoots,
        existing: Vocabulary = .load(),
        fileManager: FileManager = .default
    ) -> [Suggestion] {
        let known = Set(existing.contextualStrings.map { $0.lowercased() })
        // key is the lowercased term, so duplicates across sources collapse;
        // the value keeps the casing that was actually on disk.
        var found: [String: (display: String, source: String)] = [:]

        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let entries = (try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []

            for entry in entries {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                let name = entry.lastPathComponent
                if let term = candidate(from: name) {
                    let key = term.lowercased()
                    if found[key] == nil { found[key] = (term, "folder \(name)") }
                }
                for (term, source) in fromManifests(in: entry, fileManager: fileManager) {
                    let key = term.lowercased()
                    if found[key] == nil { found[key] = (term, source) }
                }
            }
        }

        return found
            .filter { !known.contains($0.key) }
            .map { Suggestion(term: $0.value.display, source: $0.value.source) }
            .sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }

    // MARK: - Sources

    /// The `name` field of a package manifest, and the last path component of a
    /// git remote. Both are read as text and matched with a narrow pattern rather
    /// than parsed — a JSON parser here would happily read the whole file, and
    /// this should not be able to see more than it needs to.
    private static func fromManifests(in project: URL, fileManager: FileManager) -> [(String, String)] {
        var out: [(String, String)] = []

        let packageJSON = project.appendingPathComponent("package.json")
        if let text = head(of: packageJSON, bytes: 2_048),
           let name = firstMatch(in: text, pattern: #""name"\s*:\s*"([^"]{2,40})""#),
           let term = candidate(from: name) {
            out.append((term, "package.json in \(project.lastPathComponent)"))
        }

        let swiftPM = project.appendingPathComponent("Package.swift")
        if let text = head(of: swiftPM, bytes: 2_048),
           let name = firstMatch(in: text, pattern: #"name\s*:\s*"([^"]{2,40})""#),
           let term = candidate(from: name) {
            out.append((term, "Package.swift in \(project.lastPathComponent)"))
        }

        // .git/config holds the remote URL. The repository name is very often the
        // product name spoken aloud, and it is one line of a config file.
        let gitConfig = project.appendingPathComponent(".git/config")
        if let text = head(of: gitConfig, bytes: 4_096),
           let url = firstMatch(in: text, pattern: #"url\s*=\s*(\S+)"#) {
            let repo = url.split(separator: "/").last.map(String.init)?
                .replacingOccurrences(of: ".git", with: "") ?? ""
            if let term = candidate(from: repo) {
                out.append((term, "git remote in \(project.lastPathComponent)"))
            }
        }
        return out
    }

    /// Reads at most `bytes` from the front of a file. A manifest's name field is
    /// near the top, and a cap means a pathological file cannot be pulled into
    /// memory by something the user did not ask for.
    private static func head(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    // MARK: - What counts as a word worth suggesting

    /// Turns a folder or package name into a term, or rejects it.
    ///
    /// The filter matters more than the finding. A dictionary stuffed with "src",
    /// "node-modules" and "test" is worse than an empty one, because every junk
    /// entry is another chance for the corrector to rewrite a word the user meant.
    static func candidate(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A hyphenated or underscored name is several words; the spoken form is
        // the words, not the slug. "roman-design-co" is said "Roman Design Co".
        // Spaces count as separators too. A folder called "client work" is two
        // ordinary words and must be rejected on the same grounds as
        // "client-work", or the hyphen becomes the only thing standing between
        // the dictionary and a pile of English.
        let parts = trimmed
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.count <= 4 else { return nil }

        let rejoined = parts.joined(separator: " ")
        guard rejoined.count >= 3, rejoined.count <= 40 else { return nil }
        // Names, not sentences or version strings.
        guard rejoined.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " }) else { return nil }
        guard rejoined.contains(where: \.isLetter) else { return nil }
        // A pile of digits is a date or a version, not something anyone dictates.
        guard rejoined.filter(\.isNumber).count <= 2 else { return nil }

        let lowered = rejoined.lowercased()
        guard !boring.contains(lowered) else { return nil }
        // Every part being an ordinary English word means the recogniser already
        // knows it, and adding it only creates a chance to mis-correct. "blockcraft"
        // is worth having; "my website" is not.
        if parts.allSatisfy({ isCommonWord($0.lowercased()) }) { return nil }
        return rejoined
    }

    /// Directory names that are structure rather than product.
    static let boring: Set<String> = [
        "src", "lib", "bin", "dist", "build", "out", "tmp", "temp", "test", "tests",
        "node modules", "nodemodules", "public", "assets", "docs", "doc", "scripts",
        "backup", "backups", "old", "new", "archive", "archives", "untitled",
        "desktop", "downloads", "documents", "projects", "work", "code", "dev",
        "website", "websites", "app", "apps", "site", "sites", "project", "misc",
    ]

    /// Deliberately small and deliberately not the system spell checker.
    ///
    /// `NSSpellChecker` would call "blockcraft" a non-word and also call "quill" a
    /// word, which is the wrong way round for this job — and it costs an IPC per
    /// call, which is measurable when scanning a few hundred directory names. What
    /// is wanted is only "is this so ordinary that the recogniser certainly knows
    /// it", and a short list answers that.
    static func isCommonWord(_ word: String) -> Bool {
        word.count <= 2 || common.contains(word)
    }

    static let common: Set<String> = [
        "my", "the", "and", "for", "with", "from", "this", "that", "your", "our",
        "home", "page", "pages", "landing", "portfolio", "resume", "blog", "shop",
        "store", "client", "clients", "final", "copy", "version", "draft", "demo",
        "sample", "example", "template", "starter", "boilerplate", "playground",
        "sandbox", "practice", "learning", "tutorial", "course", "school", "notes",
        "site", "work", "works", "web", "website", "app", "apps", "page", "test",
        "old", "new", "main", "dev", "prod", "live", "temp", "backup", "personal",
    ]

}
