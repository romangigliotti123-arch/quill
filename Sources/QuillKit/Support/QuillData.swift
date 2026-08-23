import Foundation

/// Everything Quill has ever written about you, in one list.
///
/// The list exists because "erase all my data" is a promise, and a promise kept
/// by a `rm` written from memory is one that quietly breaks the next time
/// somebody adds a store. Every file the app writes is named here, and the test
/// that walks the source for `appendingPathComponent("Quill/…")` fails when one
/// is added and not listed — so forgetting is a build failure rather than a
/// leftover transcript nobody knew about.
///
/// Deliberately a list and not "delete the directory". The same folder holds the
/// built app on a development machine, and a feature that reinstalls itself out
/// from under you is not the feature that was asked for.
public enum QuillData {

    /// `QUILL_DATA_DIR` points the whole thing at a scratch folder.
    ///
    /// Because the only honest test of "delete everything" is to run it and look
    /// at what is left, and a harness that can only do that against the real
    /// Application Support folder is one bad path away from being the accident it
    /// is meant to prevent. Same rule the history store already follows.
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["QUILL_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quill")
    }

    /// Everything a person would mean by "my data": what I said, what I taught
    /// it, how I set it up, and the credential.
    public static var files: [URL] {
        [
            "history.json",     // every dictation
            "settings.json",    // hotkeys, microphone, preferences
            "vocabulary.json",  // the Dictionary
            "transforms.json",  // saved transforms and their chords
            "snippets.json",
            "notes.json",       // the Scratchpad
            "style.json",       // the learned writing profile
            "my-voice-for-ai.md", // the exported "write like me" document
            "nim-key.txt",      // the API key
        ].map { directory.appendingPathComponent($0) }
    }

    /// Copies the stores made of files they refused to overwrite, plus the traces
    /// the debug switches write. Not data anybody chose to keep, but all of it is
    /// still the user's words and it goes when they ask for everything to go.
    public static var incidentalFiles: [URL] {
        let fm = FileManager.default
        let listed = (try? fm.contentsOfDirectory(at: directory,
                                                  includingPropertiesForKeys: nil)) ?? []
        return listed.filter { url in
            let name = url.lastPathComponent
            return name.contains(".unreadable-")
                || name.hasSuffix(".log")
                || name == "caret-probe.txt"
                // The two receipts QUILL_ERASE_NOW / QUILL_ERASE_DRY_RUN leave
                // behind for a harness to read back. Diagnostic output about an
                // erase, not data an erase is required to remove on its own —
                // but a stray one left over from a debug run should still go
                // when everything else does.
                || name == "erase-dry-run.txt"
                || name == "erased.txt"
        }
    }

    /// What `erase()` is about to remove, so a confirmation can say it out loud
    /// rather than asking someone to trust the word "everything".
    public static func summary() -> [(name: String, bytes: Int)] {
        let fm = FileManager.default
        return (files + incidentalFiles).compactMap { url in
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int
            else { return nil }
            return (url.lastPathComponent, size)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Delete the lot. Returns what actually went.
    ///
    /// Nothing in memory is touched, and that is on purpose rather than an
    /// omission: every store in this app holds its records in memory and writes
    /// the whole file on the next change, so a running Quill would put its
    /// history back within a dictation. The only honest way to finish this is to
    /// relaunch, which is what the caller does — and which is also what makes the
    /// result genuinely indistinguishable from a fresh install.
    @discardableResult
    public static func erase() -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for url in files + incidentalFiles where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                removed.append(url.lastPathComponent)
            } catch {
                NSLog("[quill] erase: could not remove %@ — %@",
                      url.lastPathComponent, error.localizedDescription)
            }
        }
        return removed
    }
}
