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
