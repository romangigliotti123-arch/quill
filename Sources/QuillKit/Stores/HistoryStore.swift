import Foundation

/// Every dictation, on disk, with its timings.
///
/// The shape here is load-bearing beyond the app: the comparison rig reads this
/// file to score us against Wispr Flow, and Flow's own history lives in a
/// sqlite table with separate raw-ASR and formatted columns. We keep the same
/// split so the two are scored like for like — raw against raw for accuracy,
/// cleaned against formatted for formatting. Collapsing them into one field
/// would mean measuring punctuation and calling it accuracy.
public struct DictationRecord: Codable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    /// Straight out of the recogniser, untouched. The accuracy column.
    public let rawText: String
    /// What was actually inserted. The formatting column.
    public let insertedText: String
    public let wordCount: Int
    /// The microphone the system was actually using, e.g. "MacBook Air Microphone"
    /// or "BlackHole 2ch". Mirrors Flow's micDevice column: without it a run
    /// cannot be audited, and a word-error-rate from an app that never heard the
    /// test audio looks exactly like a real one.
    public let inputDevice: String?
    public let timings: Timings

    public struct Timings: Codable, Sendable, Equatable {
        public let timeToFirstWordMs: Int?
        public let finalToInsertedMs: Int?
        public let endToEndMs: Int?
        public let audioDurationMs: Int?
        /// Whether the model cleanup beat its deadline, or the fast pass shipped.
        public let usedThoroughCleanup: Bool
        /// Key release → text on screen: the latency a person actually waits
        /// through, and the one Flow's 807ms is measured on. Optional because
        /// every record written before it existed does not have it — and the
        /// synthesised decoder treats a missing optional as nil rather than
        /// failing, so an old history file still loads.
        public let releaseToInsertedMs: Int?

        public init(timeToFirstWordMs: Int?,
                    finalToInsertedMs: Int?,
                    endToEndMs: Int?,
                    audioDurationMs: Int?,
                    usedThoroughCleanup: Bool,
                    releaseToInsertedMs: Int? = nil) {
            self.timeToFirstWordMs = timeToFirstWordMs
            self.finalToInsertedMs = finalToInsertedMs
            self.endToEndMs = endToEndMs
            self.audioDurationMs = audioDurationMs
            self.usedThoroughCleanup = usedThoroughCleanup
            self.releaseToInsertedMs = releaseToInsertedMs
        }
    }
}

public final class HistoryStore: @unchecked Sendable {

    public static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quill/history.json")
    }()

    private let url: URL
    private let queue = DispatchQueue(label: "com.romangigliotti.quill.history")
    private var records: [DictationRecord] = []

    /// Tests pass their own URL. A self-test that writes to the real history
    /// file is a bug, not a shortcut.
    public init(url: URL = HistoryStore.defaultURL) {
        self.url = url
        load()
    }

    /// Newest first — the rig reads index 0.
    public var all: [DictationRecord] {
        queue.sync { records }
    }

    public func append(_ record: DictationRecord) {
        queue.sync {
            records.insert(record, at: 0)
            persist()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([DictationRecord].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Atomic: a half-written history file read by the rig mid-run would
        // produce a scoring error that looks like a transcription error.
        try? data.write(to: url, options: .atomic)
    }
}
