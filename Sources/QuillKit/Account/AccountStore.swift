import CryptoKit
import Foundation

/// An account, entirely optional, that lets Quill's data — dictations, the
/// Dictionary, snippets, transforms, the learned style — follow you to a
/// second Mac. Nothing else in Quill reads this class or requires it to
/// exist, and see `SyncEngine` for what actually moves once it does.
///
/// # Why this talks to Firebase's REST API rather than its SDK
///
/// It did, at first — `FirebaseAuth` and `FirebaseFirestore`, the real SDKs.
/// Every sign-up and sign-in failed with `ERROR_KEYCHAIN_ERROR`: the SDK's
/// macOS keychain persistence needs a `keychain-access-groups` entitlement
/// backed by a real Apple-issued Team ID, and Quill is self-signed — there is
/// no Apple Developer Program membership behind it. Confirmed against
/// `firebase/firebase-ios-sdk#14191`: no known workaround, full stop.
///
/// The REST APIs underneath the SDK — Identity Toolkit for auth, Firestore's
/// own document API for data — have no such requirement. They are plain
/// HTTPS, and the session they hand back is a token, which is data, not a
/// keychain item. So it is stored the same way the AI API key already is:
/// one file, 0600, in the same folder as everything else Quill owns — see
/// `NIMKey` for the pattern this copies. This is not a workaround dressed up
/// as a design choice: it is a smaller dependency (no gRPC, no Abseil, no
/// LevelDB — Quill reads and writes a handful of JSON documents, which is
/// what the REST API is *for*) that also happens to sidestep a keychain
/// requirement this Mac cannot satisfy.
///
/// # Why this is allowed to be the one networked, cloud-backed thing in an
/// app whose entire argument for existing is "runs on your Mac, learns your
/// voice, sends nothing anywhere unless you add your own AI key"
///
/// Because it does not compromise that argument — it sits beside it. Nobody
/// is asked to create an account, nothing here runs unless the Account row
/// in Settings is touched, and no request is made at launch.
public final class AccountStore: @unchecked Sendable {

    public static let shared = AccountStore()

    public struct Account: Sendable, Equatable {
        public let uid: String
        public let email: String
    }

    /// What is stored locally, in place of a keychain item. The tokens are
    /// exactly as sensitive as the AI API key — enough to act as the user
    /// against their own account — and stored the identical way.
    struct Session: Codable, Sendable {
        let uid: String
        let email: String
        let idToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    static let fileURL: URL = QuillData.directory.appendingPathComponent("account.json")

    private let lock = NSLock()
    private var session: Session?
    private var listeners: [UUID: (Account?) -> Void] = [:]
    private var config: FirebaseConfig?
    private var loadedFromDisk = false

    private init() {}

    /// `loadSessionIfNeeded()` first, matching `observe` and `validToken` —
    /// without it this answered "signed out" for the entire life of any
    /// process that checks `current` before ever calling `observe`, because
    /// the session sits on disk until something loads it. Every caller in
    /// the app itself calls `observe` first and never hit this; `QuillMCP`
    /// is a plain command-line loop that checks `current` directly, and
    /// found it checking a session that had never actually been read.
    public var current: Account? {
        loadSessionIfNeeded()
        return lock.withLock { session.map { Account(uid: $0.uid, email: $0.email) } }
    }

    // MARK: - Configuration

    private struct FirebaseConfig {
        let apiKey: String
        let projectID: String
    }

    /// Read once, from the same plist a real Firebase SDK would have used —
    /// the API key here is not a secret the way the NIM key is: it identifies
    /// the Firebase *project*, and access is controlled by the security rules
    /// deployed alongside it (`firestore.rules`), not by hiding this string.
    /// Google's own documentation says so explicitly; it is why the plist is
    /// committed to this repo and the NIM key never is.
    private func loadConfig() -> FirebaseConfig? {
        lock.lock()
        defer { lock.unlock() }
        if let config { return config }
        guard let url = Bundle.module.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url),
              let apiKey = dict["API_KEY"] as? String,
              let projectID = dict["PROJECT_ID"] as? String
        else {
            NSLog("[quill] account: GoogleService-Info.plist missing or unreadable — accounts unavailable")
            return nil
        }
        let loaded = FirebaseConfig(apiKey: apiKey, projectID: projectID)
        config = loaded
        return loaded
    }

    /// Read from disk exactly once, the first time anything asks — matching
    /// the same lazy-touch rule as everything else here.
    private func loadSessionIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        session = try? decoder.decode(Session.self, from: data)
    }

    private func persist(_ newSession: Session?) {
        session = newSession
        guard let newSession else {
            try? FileManager.default.removeItem(at: Self.fileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(newSession) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: Self.fileURL)
        FileManager.default.createFile(atPath: Self.fileURL.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }

    private func notify() {
        let account = current
        let handlers = lock.withLock { Array(listeners.values) }
        handlers.forEach { $0(account) }
    }

    /// Called from the Account screen when it appears, and again whenever
    /// sign-in/out happens anywhere in the app while it is open.
    @discardableResult
    public func observe(_ handler: @escaping (Account?) -> Void) -> UUID {
        loadSessionIfNeeded()
        let id = UUID()
        lock.withLock { listeners[id] = handler }
        handler(current)
        return id
    }

    public func stopObserving(_ id: UUID) {
        lock.withLock { listeners.removeValue(forKey: id) }
    }

    // MARK: - Errors

    public enum AccountError: LocalizedError {
        case unavailable
        case server(String)
        case network

        public var errorDescription: String? {
            switch self {
            case .unavailable: return "Accounts aren't available in this build."
            case .server(let message): return message
            case .network: return "No connection right now — try again in a moment."
            }
        }
    }

    // MARK: - Actions

    public func signUp(email: String, password: String) async throws {
        try await authenticate(endpoint: "accounts:signUp", email: email, password: password, isNewAccount: true)
    }

    public func signIn(email: String, password: String) async throws {
        try await authenticate(endpoint: "accounts:signIn", email: email, password: password, isNewAccount: false)
    }

    /// `accounts:signIn` doesn't exist — the real path names are
    /// `accounts:signUp` and `accounts:signInWithPassword`. Kept as one
    /// function with an `endpoint` parameter because the two calls are
    /// otherwise identical: same request shape, same response shape, same
    /// error mapping. The typo-proofing is the guard right below.
    private func authenticate(endpoint: String, email: String, password: String,
                              isNewAccount: Bool) async throws {
        guard let config = loadConfig() else { throw AccountError.unavailable }
        let path = isNewAccount ? "accounts:signUp" : "accounts:signInWithPassword"
        var request = URLRequest(url: URL(string:
            "https://identitytoolkit.googleapis.com/v1/\(path)?key=\(config.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email, "password": password, "returnSecureToken": true,
        ])

        let (data, response) = try await send(request)
        try Self.throwIfError(data: data, response: response)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["idToken"] as? String,
              let refreshToken = json["refreshToken"] as? String,
              let uid = json["localId"] as? String,
              let expiresInText = json["expiresIn"] as? String,
              let expiresIn = Double(expiresInText)
        else { throw AccountError.server("The account server sent back something Quill didn't expect.") }

        let newSession = Session(uid: uid, email: email, idToken: idToken, refreshToken: refreshToken,
                                 expiresAt: Date().addingTimeInterval(expiresIn))
        lock.withLock { persist(newSession) }

        if isNewAccount {
            try await writeAccountDocument(session: newSession, config: config)
        }
        notify()
    }

    public func signOut() {
        lock.withLock { persist(nil) }
        notify()
    }

    /// Re-proves the current password with a normal sign-in before changing
    /// it — the same thing System Settings asks for before it lets you
    /// change yours, not because the session in hand isn't valid, but
    /// because this is worth asking again for.
    public func changePassword(currentPassword: String, newPassword: String) async throws {
        guard let account = current else { throw AccountError.unavailable }
        try await authenticate(endpoint: "accounts:signInWithPassword", email: account.email,
                               password: currentPassword, isNewAccount: false)
        guard let config = loadConfig() else { throw AccountError.unavailable }
        guard let reauthed = lock.withLock({ session }) else { throw AccountError.unavailable }

        var request = URLRequest(url: URL(string:
            "https://identitytoolkit.googleapis.com/v1/accounts:update?key=\(config.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "idToken": reauthed.idToken, "password": newPassword, "returnSecureToken": true,
        ])

        let (data, response) = try await send(request)
        try Self.throwIfError(data: data, response: response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["idToken"] as? String,
              let refreshToken = json["refreshToken"] as? String,
              let expiresInText = json["expiresIn"] as? String,
              let expiresIn = Double(expiresInText)
        else { throw AccountError.server("The account server sent back something Quill didn't expect.") }

        let updated = Session(uid: reauthed.uid, email: reauthed.email, idToken: idToken,
                              refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(expiresIn))
        lock.withLock { persist(updated) }
    }

    /// One document, `users/{uid}`: an email and a creation date. Nothing
    /// about how anyone writes, nothing they have dictated — that is
    /// `SyncEngine`'s job, and it writes to a different path under the same
    /// document once there is something worth syncing.
    private func writeAccountDocument(session: Session, config: FirebaseConfig) async throws {
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(config.projectID)"
            + "/databases/(default)/documents/users/\(session.uid)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "fields": [
                "email": ["stringValue": session.email],
                "createdAt": ["timestampValue": ISO8601DateFormatter().string(from: Date())],
            ],
        ])
        let (data, response) = try await send(request)
        // Not fatal to the sign-up itself — the account exists and the user
        // is signed in either way. Logged so a real failure here is at least
        // findable, rather than silently leaving the users/ collection one
        // document short of the accounts that exist.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            NSLog("[quill] account: writing the user document failed: %@",
                  String(data: data, encoding: .utf8) ?? "?")
        }
    }

    // MARK: - Token refresh, for SyncEngine

    /// A valid ID token, refreshing first if the current one is due to expire
    /// in under a minute. Every Firestore REST call `SyncEngine` makes goes
    /// through this rather than reading `session.idToken` directly.
    func validToken() async throws -> (uid: String, idToken: String) {
        loadSessionIfNeeded()
        guard let current = lock.withLock({ session }) else { throw AccountError.unavailable }
        guard current.expiresAt.timeIntervalSinceNow > 60 else {
            return try await refresh(current)
        }
        return (current.uid, current.idToken)
    }

    private func refresh(_ expiring: Session) async throws -> (uid: String, idToken: String) {
        guard let config = loadConfig() else { throw AccountError.unavailable }
        var request = URLRequest(url: URL(string:
            "https://securetoken.googleapis.com/v1/token?key=\(config.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token="
            + expiring.refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        request.httpBody = Data(body.utf8)

        let (data, response) = try await send(request)
        try Self.throwIfError(data: data, response: response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // The refresh endpoint's response uses different key casing
              // than sign-in's — snake_case, not camelCase. Different Google
              // API, different convention; both are read here rather than
              // assumed to match.
              let idToken = json["id_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresInText = json["expires_in"] as? String,
              let expiresIn = Double(expiresInText)
        else { throw AccountError.server("Couldn't refresh the sign-in — try signing in again.") }

        let refreshed = Session(uid: expiring.uid, email: expiring.email, idToken: idToken,
                                refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(expiresIn))
        lock.withLock { persist(refreshed) }
        return (refreshed.uid, refreshed.idToken)
    }

    // MARK: - Transport

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw AccountError.network
        }
    }

    /// Identity Toolkit puts the useful part of an error at
    /// `error.message`, an all-caps code ("EMAIL_EXISTS", "WEAK_PASSWORD",
    /// "INVALID_LOGIN_CREDENTIALS") rather than a sentence — translated where
    /// the common ones are known, passed through for anything else rather
    /// than hidden behind a generic failure.
    private static func throwIfError(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }
            .flatMap { $0["message"] as? String } ?? "UNKNOWN_ERROR"
        let readable: String
        switch code {
        case "EMAIL_EXISTS": readable = "An account already exists for that email."
        case "WEAK_PASSWORD : Password should be at least 6 characters", "WEAK_PASSWORD":
            readable = "That password is too weak — six characters or more."
        case "INVALID_EMAIL": readable = "That doesn't look like an email address."
        case "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS":
            readable = "That email and password don't match an account."
        case "TOO_MANY_ATTEMPTS_TRY_LATER": readable = "Too many attempts — wait a bit and try again."
        default: readable = code.split(separator: ":").first.map(String.init) ?? code
        }
        throw AccountError.server(readable)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
