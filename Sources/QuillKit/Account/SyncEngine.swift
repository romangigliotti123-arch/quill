import Foundation

/// What actually moves once someone is signed in — see `AccountStore` for the
/// account itself, which this reads and does nothing else with.
///
/// # Shape
///
/// Six files, six fields on one Firestore document (`users/{uid}/sync/data`):
/// history, vocabulary, snippets, transforms, style, and the AI key. Each
/// field holds the WHOLE file's contents as a single string, not a
/// Firestore-native document — Firestore's typed field format
/// (`stringValue`, `arrayValue`, `mapValue`...) is built for querying
/// individual fields from outside, and nothing outside Quill ever will. A
/// blob in a string field is simpler, cannot drift from what each store
/// already reads and writes on disk, and costs nothing extra: six small
/// files, not six hundred small documents. Five of the six are JSON; the AI
/// key is the plain text `nim-key.txt` already is, synced as-is.
///
/// # Merge, not overwrite
///
/// Roman's rule, exactly: signing into the same account on a second Mac must
/// never look like losing what that Mac already had. Every merge is a union
/// — new items added, matching items combined, nothing already on either
/// side ever dropped. See each `merge*` function for the per-store rule; the
/// most involved is `StyleProfile.merged(with:)`, which lives on the type
/// itself because two of its fields are `private(set)`. The AI key is the one
/// exception — a single credential has nothing to union — see
/// `mergeAPIKey` for what "merge" means for a scalar.
///
/// # What is deliberately excluded
///
/// `settings.json` (hotkey, microphone) — machine-specific; a microphone UID
/// from one Mac means nothing on another. `account.json` — the local
/// session token itself; each Mac keeps its own rather than trusting one
/// signed into two places with the same bearer token. `my-voice-for-ai.md`
/// — a derived export, regenerated on demand from the data that DOES sync.
///
/// The AI key travels over the same channel as everything else here —
/// HTTPS to Firestore, readable only by this account's own uid, per
/// `firestore.rules`. Not weaker than the rest of what already syncs; worth
/// naming because a credential is a different kind of thing to a Mac's
/// history than a dictation is.
public final class SyncEngine: @unchecked Sendable {

    public static let shared = SyncEngine()

    /// Every 2 minutes while signed in, plus once immediately on sign-in and
    /// once immediately before signing out — frequent enough that "automatic"
    /// means something, rare enough that it is not the thing keeping this
    /// Mac's network light on.
    private static let interval: TimeInterval = 120

    private let lock = NSLock()
    private var timer: Timer?
    private var isSyncing = false
    private var accountObserverID: UUID?
    /// Set only by tests, to point every request at a fake server instead of
    /// the real one.
    var session: URLSession = .shared

    private init() {
        accountObserverID = AccountStore.shared.observe { [weak self] account in
            guard let self else { return }
            if account != nil {
                self.startTimer()
                Task { await self.syncNow() }
            } else {
                self.stopTimer()
            }
        }
    }

    private func startTimer() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { await self?.syncNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        lock.withLock { timer?.invalidate(); timer = nil }
    }

    // MARK: - The sync itself

    @discardableResult
    public func syncNow() async -> Bool {
        guard let (uid, token) = try? await AccountStore.shared.validToken() else { return false }
        guard let config = loadConfig() else { return false }

        let alreadySyncing = lock.withLock { () -> Bool in
            if isSyncing { return true }
            isSyncing = true
            return false
        }
        guard !alreadySyncing else { return false }
        defer { lock.withLock { isSyncing = false } }

        let doc = await fetchDocument(uid: uid, token: token, config: config)

        let historyOK = await syncField(
            "history", localURL: HistoryStore.defaultURL, remoteText: doc["history"],
            decode: { try? JSONDecoder.quillDates.decode([DictationRecord].self, from: $0) },
            encode: { try? JSONEncoder.quillDates.encode($0) },
            merge: Self.mergeHistory, uid: uid, token: token, config: config)

        let vocabularyOK = await syncField(
            "vocabulary", localURL: Vocabulary.defaultURL, remoteText: doc["vocabulary"],
            decode: { try? JSONDecoder().decode(Vocabulary.self, from: $0) },
            encode: { try? JSONEncoder().encode($0) },
            merge: Self.mergeVocabulary, uid: uid, token: token, config: config)

        let snippetsOK = await syncField(
            "snippets", localURL: SnippetStore.defaultURL, remoteText: doc["snippets"],
            decode: { try? JSONDecoder.quillDates.decode([Snippet].self, from: $0) },
            encode: { try? JSONEncoder.quillDates.encode($0) },
            merge: { Self.mergeByID(local: $0, remote: $1) { a, b in a.useCount >= b.useCount ? a : b } },
            uid: uid, token: token, config: config)

        let transformsOK = await syncField(
            "transforms", localURL: TransformStore.defaultURL, remoteText: doc["transforms"],
            decode: { try? JSONDecoder.quillDates.decode([Transform].self, from: $0) },
            encode: { try? JSONEncoder.quillDates.encode($0) },
            merge: { Self.mergeByID(local: $0, remote: $1) { a, b in a.useCount >= b.useCount ? a : b } },
            uid: uid, token: token, config: config)

        let styleOK = await syncField(
            "style", localURL: StyleStore.defaultURL, remoteText: doc["style"],
            decode: { try? JSONDecoder.quillDates.decode(StyleProfile.self, from: $0) },
            encode: { try? JSONEncoder.quillDates.encode($0) },
            merge: { (local: StyleProfile, remote: StyleProfile) in local.merged(with: remote) },
            uid: uid, token: token, config: config)

        // Plain text, not JSON — `nim-key.txt` already is one, and `NIMKey`
        // itself never writes an empty file (see its own `save`), so an
        // absent file and an absent field both land in `syncField`'s
        // "nothing on either side" case rather than needing a special
        // empty-string check here.
        let apiKeyOK = await syncField(
            "aiKey", localURL: NIMKey.defaultFileURL, remoteText: doc["aiKey"],
            decode: { data in
                guard let text = String(data: data, encoding: .utf8) else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            },
            encode: { (key: String) -> Data? in Data(key.utf8) },
            merge: Self.mergeAPIKey, uid: uid, token: token, config: config,
            posixPermissions: 0o600)

        // Bookkeeping for the Devices list, not data — its failure does not
        // make the sync itself a failure, so it is not part of the boolean below.
        await registerDevice(uid: uid, token: token, config: config)

        return historyOK && vocabularyOK && snippetsOK && transformsOK && styleOK && apiKeyOK
    }

    /// Reads the local file (if any), merges it with whatever the cloud
    /// already holds (if anything), writes the merged result back to BOTH
    /// disk and Firestore.
    ///
    /// A store already running in this process — `HistoryStore.shared`,
    /// for instance — keeps its own in-memory copy and will not see this
    /// write until it next reads the file itself. Sync is between Macs, not
    /// between this write and whatever is on screen in the same launch; the
    /// gap closes on the next read that store does anyway, and every read in
    /// this app already goes through the file, never a cache assumed fresh.
    private func syncField<T>(
        _ field: String, localURL: URL, remoteText: String?,
        decode: (Data) -> T?, encode: (T) -> Data?,
        merge: (T, T) -> T,
        uid: String, token: String, config: FirebaseConfig,
        /// Set only for the AI key: `NIMKey.save()` writes 0600 because a
        /// key file that is briefly world-readable has been world-readable,
        /// and a generic disk write here must not quietly relax that.
        posixPermissions: Int? = nil
    ) async -> Bool {
        let local = (try? Data(contentsOf: localURL)).flatMap(decode)
        let remote = remoteText.flatMap { $0.data(using: .utf8) }.flatMap(decode)

        let merged: T
        switch (local, remote) {
        case let (.some(l), .some(r)): merged = merge(l, r)
        case let (.some(l), .none): merged = l
        case let (.none, .some(r)): merged = r
        case (.none, .none): return true // nothing on either side yet — not a failure
        }

        guard let data = encode(merged), let text = String(data: data, encoding: .utf8) else { return false }

        // Written locally even if the network half below fails — a
        // successful merge should not wait on Firestore to be worth having
        // on disk, and the next sync attempt will still push it up.
        try? FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let posixPermissions {
            try? FileManager.default.removeItem(at: localURL)
            FileManager.default.createFile(atPath: localURL.path, contents: data,
                                           attributes: [.posixPermissions: posixPermissions])
        } else {
            try? data.write(to: localURL, options: .atomic)
        }

        return await putField(field, text: text, uid: uid, token: token, config: config)
    }

    // MARK: - Merge rules

    static func mergeHistory(_ local: [DictationRecord], _ remote: [DictationRecord]) -> [DictationRecord] {
        mergeByID(local: local, remote: remote, keyOf: \.id) { existing, _ in existing }
    }

    static func mergeVocabulary(_ local: Vocabulary, _ remote: Vocabulary) -> Vocabulary {
        var terms = local.terms
        for term in remote.terms {
            let exists = terms.contains { $0.compare(term, options: .caseInsensitive) == .orderedSame }
            if !exists { terms.append(term) }
        }
        return Vocabulary(terms: terms)
    }

    /// A credential, not a collection — there is nothing to union. The rule
    /// that keeps this consistent with everywhere else "local wins on a
    /// collision" is used (`mergeHistory`'s duplicate-id case, `mergeByID`'s
    /// default): whichever key is already on THIS Mac stays, and is what
    /// gets pushed up. A Mac with no key yet picks up whatever the account
    /// already has; a Mac that already has one keeps deciding for itself
    /// until someone changes it there, and that change is what every other
    /// Mac converges to next.
    static func mergeAPIKey(_ local: String, _ remote: String) -> String {
        local
    }

    /// Union by id — the general case, used directly where the id type IS
    /// `UUID` (`DictationRecord`) and via the `Identifiable` overload below
    /// for the stores that already conform to it.
    static func mergeByID<T, ID: Hashable>(
        local: [T], remote: [T], keyOf: (T) -> ID, keepExisting: (T, T) -> T
    ) -> [T] {
        var byID: [ID: T] = [:]
        var order: [ID] = []
        for item in local {
            let key = keyOf(item)
            byID[key] = item
            order.append(key)
        }
        for item in remote {
            let key = keyOf(item)
            if let existing = byID[key] {
                byID[key] = keepExisting(existing, item)
            } else {
                byID[key] = item
                order.append(key)
            }
        }
        return order.map { byID[$0]! }
    }

    static func mergeByID<T: Identifiable>(
        local: [T], remote: [T], keepExisting: (T, T) -> T
    ) -> [T] {
        mergeByID(local: local, remote: remote, keyOf: \.id, keepExisting: keepExisting)
    }

    // MARK: - Firestore REST, minimal

    private struct FirebaseConfig { let projectID: String }
    private var cachedConfig: FirebaseConfig?

    private func loadConfig() -> FirebaseConfig? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedConfig { return cachedConfig }
        guard let url = Bundle.module.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url),
              let projectID = dict["PROJECT_ID"] as? String
        else { return nil }
        let config = FirebaseConfig(projectID: projectID)
        cachedConfig = config
        return config
    }

    private func documentURL(uid: String, config: FirebaseConfig) -> URL {
        URL(string: "https://firestore.googleapis.com/v1/projects/\(config.projectID)"
            + "/databases/(default)/documents/users/\(uid)/sync/data")!
    }

    /// The top-level `users/{uid}` document — where `AccountStore` writes
    /// email/createdAt, and where the Devices list lives, in its own
    /// `devices` field. Not the same document as `documentURL` above: that
    /// one is the `sync/data` subcollection doc holding the five data
    /// fields, and Firestore rules do not let one PATCH touch both.
    private func accountDocumentURL(uid: String, config: FirebaseConfig) -> URL {
        URL(string: "https://firestore.googleapis.com/v1/projects/\(config.projectID)"
            + "/databases/(default)/documents/users/\(uid)")!
    }

    /// Field name → its JSON text, for whatever fields already exist. Missing
    /// entirely (a brand new account, or the very first sync from any
    /// device) is not an error — every `syncField` call already treats
    /// "nothing remote yet" as "local wins".
    private func fetchDocument(uid: String, token: String, config: FirebaseConfig) async -> [String: String] {
        var request = URLRequest(url: documentURL(uid: uid, config: config))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = json["fields"] as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in fields {
            if let wrapped = value as? [String: Any], let text = wrapped["stringValue"] as? String {
                out[key] = text
            }
        }
        return out
    }

    /// `updateMask` is what makes this a per-field PATCH rather than a
    /// whole-document overwrite — without it, syncing "history" would erase
    /// whatever "vocabulary" already held, since Firestore's plain PATCH
    /// replaces every field not explicitly named.
    private func putField(_ field: String, text: String, uid: String, token: String,
                          config: FirebaseConfig) async -> Bool {
        var components = URLComponents(url: documentURL(uid: uid, config: config), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "updateMask.fieldPaths", value: field)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "fields": [field: ["stringValue": text]],
        ])
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200...299).contains(http.statusCode)
    }

    // MARK: - Devices, for the Account screen

    public struct DeviceEntry: Sendable, Equatable {
        public let id: String
        public let name: String
        public let lastSyncedAt: Date?
        public var isThisDevice: Bool { id == DeviceIdentity.id }
    }

    /// Writes this Mac's entry into `devices.<id>` on the account document —
    /// masked to just that one key, so two Macs syncing around the same time
    /// each write their own entry rather than racing to overwrite the whole
    /// map. Best-effort: see the call site in `syncNow()` for why a failure
    /// here does not fail the sync.
    private func registerDevice(uid: String, token: String, config: FirebaseConfig) async {
        var components = URLComponents(url: accountDocumentURL(uid: uid, config: config),
                                       resolvingAgainstBaseURL: false)!
        let path = "devices.\(DeviceIdentity.id)"
        components.queryItems = [URLQueryItem(name: "updateMask.fieldPaths", value: path)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "fields": [
                "devices": ["mapValue": ["fields": [
                    DeviceIdentity.id: ["mapValue": ["fields": [
                        "name": ["stringValue": DeviceIdentity.name],
                        "lastSyncedAt": ["timestampValue": ISO8601DateFormatter().string(from: Date())],
                    ]]],
                ]]],
            ],
        ])
        _ = try? await session.data(for: request)
    }

    /// Every device that has ever synced this account, newest sync first.
    /// A snapshot, not a live feed — there is no push channel for "another
    /// Mac just synced", so the Account screen calls this again to refresh.
    public func fetchDevices() async -> [DeviceEntry] {
        guard let (uid, token) = try? await AccountStore.shared.validToken(),
              let config = loadConfig()
        else { return [] }

        var request = URLRequest(url: accountDocumentURL(uid: uid, config: config))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = json["fields"] as? [String: Any],
              let devicesField = fields["devices"] as? [String: Any],
              let devicesMap = devicesField["mapValue"] as? [String: Any],
              let deviceFields = devicesMap["fields"] as? [String: Any]
        else { return [] }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        let entries: [DeviceEntry] = deviceFields.compactMap { id, value in
            guard let wrapped = value as? [String: Any],
                  let map = wrapped["mapValue"] as? [String: Any],
                  let deviceFields = map["fields"] as? [String: Any],
                  let name = (deviceFields["name"] as? [String: Any])?["stringValue"] as? String
            else { return nil }
            let stamp = (deviceFields["lastSyncedAt"] as? [String: Any])?["timestampValue"] as? String
            let lastSyncedAt = stamp.flatMap { formatter.date(from: $0) ?? fallbackFormatter.date(from: $0) }
            return DeviceEntry(id: id, name: name, lastSyncedAt: lastSyncedAt)
        }
        return entries.sorted { ($0.lastSyncedAt ?? .distantPast) > ($1.lastSyncedAt ?? .distantPast) }
    }
}

extension JSONDecoder {
    static var quillDates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var quillDates: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
