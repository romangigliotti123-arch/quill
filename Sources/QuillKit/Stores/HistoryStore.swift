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
    /// The bundle identifier of the app the text was inserted into, e.g.
    /// "com.apple.TextEdit". Nil for a record written before this existed, and
    /// for the paths where the text never landed anywhere.
    ///
    /// Recorded whether or not the app will let Quill read the field back:
    /// knowing where your words went does not depend on being able to re-read
    /// them, and Insights and the Style screen both want it.
    public let destinationBundleID: String?
    public let timings: Timings

    /// Whether this record is a measurement rather than something the user said.
    ///
    /// The eval rig feeds audio files through a loopback device, and it writes to
    /// the same history file the app does. On this Mac that is 684 of 696
    /// records — so Insights was reporting "14,145 words dictated in the last 30
    /// days", "81 wpm median pace over 696 dictations" and "3h 59m saved against
    /// typing it out", every one of them a statistic about a test harness,
    /// presented to Roman as a fact about himself.
    ///
    /// A dictation is words a person spoke into a microphone. Audio played into a
    /// loopback is a measurement, and the two must not be added together on a
    /// screen whose only job is to be trusted. The history *log* still lists them
    /// — that is a record of what the app did — but nothing that says "you"
    /// counts them.
    public var isMeasurement: Bool {
        inputDevice.map(AudioDeviceInfo.isLoopback) ?? false
    }


    /// Written out because `init(from:)` below suppresses the synthesised one.
    public init(id: UUID,
                date: Date,
                rawText: String,
                insertedText: String,
                wordCount: Int,
                inputDevice: String?,
                destinationBundleID: String? = nil,
                timings: Timings) {
        self.id = id
        self.date = date
        self.rawText = rawText
        self.insertedText = insertedText
        self.wordCount = wordCount
        self.inputDevice = inputDevice
        self.destinationBundleID = destinationBundleID
        self.timings = timings
    }

    /// Decoded key by key, with a default for anything absent.
    ///
    /// The synthesised decoder throws on a missing key, and these records are
    /// read as one `[DictationRecord]` — so a single field added in a future
    /// release makes every record written before it undecodable, `StoreFile`
    /// correctly refuses to overwrite the file, and the user opens Quill after
    /// an update to an empty history and a store that has stopped saving. The
    /// data is still on disk, which is no comfort to someone looking at a blank
    /// screen.
    ///
    /// `Timings` already had the shape right, one field at a time, each with a
    /// comment explaining that a missing optional decodes to nil rather than
    /// failing. That worked because the author remembered. This makes it
    /// structural instead: adding a field here cannot break an existing history.
    ///
    /// `rawText` and `insertedText` stay required. They are the record — a
    /// history entry without them is not a dictation that lost a field, it is
    /// corruption, and quietly inventing an empty one hides that.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        rawText = try c.decode(String.self, forKey: .rawText)
        insertedText = try c.decode(String.self, forKey: .insertedText)
        wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount)
            ?? insertedText.split(whereSeparator: \.isWhitespace).count
        inputDevice = try c.decodeIfPresent(String.self, forKey: .inputDevice)
        destinationBundleID = try c.decodeIfPresent(String.self, forKey: .destinationBundleID)
        timings = try c.decodeIfPresent(Timings.self, forKey: .timings)
            ?? Timings(timeToFirstWordMs: nil, finalToInsertedMs: nil,
                       endToEndMs: nil, audioDurationMs: nil,
                       usedThoroughCleanup: false)
    }

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
        /// Key-down → microphone delivering audio. Ours.
        public let micOpenMs: Int?
        /// Microphone open → the user starts speaking. Theirs, and not a defect.
        public let speechOnsetMs: Int?
        /// Speech starts → the recogniser's first guess. The model's, and the
        /// only part of "time to first word" worth tuning.
        ///
        /// All three are optional because every record written before they
        /// existed does not have them, and the synthesised decoder treats a
        /// missing optional as nil rather than failing to load the history.
        public let recogniserFirstWordMs: Int?

        /// Same reason as the record's own decoder above. Every field here is
        /// already optional except `usedThoroughCleanup`, which would still be
        /// enough on its own to make a whole history file unreadable.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            timeToFirstWordMs = try c.decodeIfPresent(Int.self, forKey: .timeToFirstWordMs)
            finalToInsertedMs = try c.decodeIfPresent(Int.self, forKey: .finalToInsertedMs)
            endToEndMs = try c.decodeIfPresent(Int.self, forKey: .endToEndMs)
            audioDurationMs = try c.decodeIfPresent(Int.self, forKey: .audioDurationMs)
            usedThoroughCleanup = try c.decodeIfPresent(Bool.self, forKey: .usedThoroughCleanup) ?? false
            releaseToInsertedMs = try c.decodeIfPresent(Int.self, forKey: .releaseToInsertedMs)
            micOpenMs = try c.decodeIfPresent(Int.self, forKey: .micOpenMs)
            speechOnsetMs = try c.decodeIfPresent(Int.self, forKey: .speechOnsetMs)
            recogniserFirstWordMs = try c.decodeIfPresent(Int.self, forKey: .recogniserFirstWordMs)
        }

        public init(timeToFirstWordMs: Int?,
                    finalToInsertedMs: Int?,
                    endToEndMs: Int?,
                    audioDurationMs: Int?,
                    usedThoroughCleanup: Bool,
                    releaseToInsertedMs: Int? = nil,
                    micOpenMs: Int? = nil,
                    speechOnsetMs: Int? = nil,
                    recogniserFirstWordMs: Int? = nil) {
            self.timeToFirstWordMs = timeToFirstWordMs
            self.finalToInsertedMs = finalToInsertedMs
            self.endToEndMs = endToEndMs
            self.audioDurationMs = audioDurationMs
            self.usedThoroughCleanup = usedThoroughCleanup
            self.releaseToInsertedMs = releaseToInsertedMs
            self.micOpenMs = micOpenMs
            self.speechOnsetMs = speechOnsetMs
            self.recogniserFirstWordMs = recogniserFirstWordMs
        }
    }
}

public final class HistoryStore: @unchecked Sendable {

    /// Overridable so a measurement run does not write into the user's history.
    ///
    /// 684 of the 696 records on this Mac are eval clips fed through a loopback,
    /// not things Roman said. See `DictationRecord.isMeasurement` for what that
    /// cost on the statistics screen.
    /// `QUILL_HISTORY_FILE` narrows further, to an exact file rather than a directory —
    /// kept for a caller that wants a one-off path shape. Everything else,
    /// including plain `QUILL_DATA_DIR`, is `QuillData.directory`: the same
    /// source `QuillData.erase()` reads, so the two can never disagree about
    /// which file is real.
    public static let defaultURL: URL = {
        if let override = ProcessInfo.processInfo.environment["QUILL_HISTORY_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return QuillData.directory.appendingPathComponent("history.json")
    }()

    private let url: URL
    private let queue = DispatchQueue(label: "com.romangigliotti.quill.history")
    private var records: [DictationRecord] = []
    private let cutoff: @Sendable () -> Date?

    /// Tests pass their own URL. A self-test that writes to the real history
    /// file is a bug, not a shortcut.
    ///
    /// `cutoff` answers "delete anything older than this, or nil to keep
    /// everything". A closure rather than a stored date because the answer moves
    /// with the clock — a store built at launch and still alive at midnight has
    /// to prune to the new day, not the old one — and a closure rather than the
    /// setting itself so a test can hand over a fixed instant instead of
    /// depending on what the person running it happens to have configured.
    public init(url: URL = HistoryStore.defaultURL,
                cutoff: @escaping @Sendable () -> Date? = {
                    QuillSettings.shared.historyRetention.cutoff(from: Date())
                }) {
        self.url = url
        self.cutoff = cutoff
        load()
        prune()
        startExpiryTimer()
    }

    deinit { expiryTimer?.cancel() }

    private var expiryTimer: DispatchSourceTimer?

    /// Hourly, because "a month old" becomes true while the app is sitting
    /// there and Roman asked for the record to go that day rather than at the
    /// next restart.
    ///
    /// On the store's own queue, so it cannot collide with a dictation being
    /// appended, and it writes nothing on the hours where nothing expired —
    /// which is all of them but one per record.
    private func startExpiryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3600, repeating: 3600, leeway: .seconds(300))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let removed = self.expire()
            guard removed > 0 else { return }
            self.persist()
            NSLog("[quill] history: deleted %d expired dictation(s)", removed)
        }
        timer.resume()
        expiryTimer = timer
    }

    /// Newest first — the rig reads index 0.
    public var all: [DictationRecord] {
        queue.sync { records }
    }

    public func append(_ record: DictationRecord) {
        queue.sync {
            records.insert(record, at: 0)
            let removed = expire()
            persist()
            if removed > 0 { NSLog("[quill] history: deleted %d expired dictation(s)", removed) }
        }
    }

    /// Delete anything past its date. Safe to call as often as you like — it
    /// writes only when it actually removed something.
    ///
    /// Called at launch, after every dictation, and on a timer, because "a month
    /// old" becomes true while the app is sitting there. Roman asked for exactly
    /// that: a dictation made a month ago goes today, not the next time Quill
    /// happens to restart.
    public func prune() {
        queue.sync {
            let removed = expire()
            guard removed > 0 else { return }
            persist()
            NSLog("[quill] history: deleted %d expired dictation(s)", removed)
        }
    }

    /// Must be called on `queue`. Returns how many went.
    @discardableResult
    private func expire() -> Int {
        guard let cutoff = cutoff() else { return 0 }
        let before = records.count
        records.removeAll { $0.date < cutoff }
        return before - records.count
    }

    /// Set when the file exists but could not be read. While it is true nothing
    /// is written, because the alternative is writing an empty array over data
    /// that is probably still recoverable.
    private var loadFailed = false

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([DictationRecord].self, from: data) {
            records = decoded
            loadFailed = false
            return
        }
        // A file that will not decode is NOT an empty history.
        //
        // It used to be treated as one, and the next dictation atomically wrote
        // an empty array over the top — every dictation ever recorded, gone, in
        // response to a single unreadable byte. One partial write during a crash,
        // one field this build does not understand, and the whole file is
        // replaced with `[]`.
        //
        // So: refuse to write, keep a copy of what could not be read, and say so.
        // The user's data outranks the app's convenience every time.
        loadFailed = true
        let salvage = url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
        try? data.write(to: salvage, options: .atomic)
        NSLog("[quill] history.json could not be decoded — refusing to overwrite it. Copy at %@",
              salvage.lastPathComponent)
    }

    private func persist() {
        // Never overwrite a file we failed to read. See load().
        guard !loadFailed else { return }
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
