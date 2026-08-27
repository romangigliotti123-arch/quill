import Foundation

/// Reading a store's file without mistaking damage for emptiness.
///
/// Every store in this app made the same mistake, and `HistoryStore` had already
/// been fixed for it in isolation, which is how the other three survived: a file
/// that exists but will not decode was treated as an empty collection, and the
/// next write atomically replaced it with `[]`. One partial write during a crash,
/// one field a newer build does not understand, and every note, every snippet,
/// every word in the dictionary is gone — in response to a single unreadable
/// byte, silently, at the moment the user next edited anything.
///
/// The distinction that matters is between three states, not two:
///
///   `missing`     — no file yet. Defaults are correct, writing is correct.
///   `decoded`     — read it.
///   `unreadable`  — a file exists and could not be read. Whatever is in memory
///                   is NOT the user's data, and writing it destroys what is.
///
/// A store that cannot tell the third from the first will eventually delete
/// everything its user has, and will report success while doing it.
enum StoreFile {

    enum Outcome<T> {
        case missing
        case decoded(T)
        case unreadable
    }

    static func read<T: Decodable>(_ type: T.Type,
                                   from url: URL,
                                   decoder: JSONDecoder = JSONDecoder()) -> Outcome<T> {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        // A zero-byte file is a crash mid-write, not an empty collection.
        guard !data.isEmpty else {
            salvage(data, at: url, note: "empty")
            return .unreadable
        }
        if let decoded = try? decoder.decode(type, from: data) { return .decoded(decoded) }
        salvage(data, at: url, note: "undecodable")
        return .unreadable
    }

    /// Writing a file whose permissions must be right from the first byte,
    /// without ever being between two files.
    ///
    /// Every other store here writes with `Data.write(options: .atomic)`, which
    /// is safe. The two that do not are the two that hold secrets —
    /// `account.json` and `nim-key.txt` — because a token must never be even
    /// briefly world-readable, and `.atomic` gives no control over the mode of
    /// the temporary file it creates. Both reached for the same thing instead:
    ///
    ///     try? fm.removeItem(at: url)                          // delete the good one
    ///     fm.createFile(atPath: url.path, contents: data, ...) // then write
    ///
    /// That is not a write, it is a window. Anything that makes the create fail
    /// leaves no file at all. `AccountStore` then discarded the return value on
    /// top, so a failed write logged the user out — silently, at the NEXT launch,
    /// hours after the write that lost it, with nothing connecting the two. It
    /// runs on every token refresh, roughly hourly for as long as someone stays
    /// signed in.
    ///
    /// So: create the new file beside the old one with the mode already set,
    /// then `rename(2)` over the top. rename is atomic within a filesystem — the
    /// path resolves to the old file or the new one and never to nothing — and
    /// it carries the temporary file's permissions with it, which is what makes
    /// this safe in both senses at once.
    ///
    /// Every failure leaves whatever is already there untouched, and says so.
    @discardableResult
    static func writeSecurely(_ data: Data, to url: URL, permissions: Int = 0o600) -> Bool {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: permissions]) else {
            NSLog("[quill] could not write a new %@ — keeping the existing one", url.lastPathComponent)
            return false
        }
        guard rename(temporary.path, url.path) == 0 else {
            NSLog("[quill] could not replace %@ (errno %d) — keeping the existing one",
                  url.lastPathComponent, errno)
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        return true
    }

    /// Keeps a copy of what could not be read, and says so.
    ///
    /// The user's data outranks the app's convenience every time, and a file the
    /// app refuses to touch is one a person can still open in a text editor and
    /// rescue by hand.
    private static func salvage(_ data: Data, at url: URL, note: String) {
        let copy = url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
        try? data.write(to: copy, options: .atomic)
        NSLog("[quill] %@ is %@ — refusing to overwrite it. Copy at %@",
              url.lastPathComponent, note, copy.lastPathComponent)
    }
}
