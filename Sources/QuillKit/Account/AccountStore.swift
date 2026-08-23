import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

/// An account, entirely optional, for whatever needs one later — sync across
/// machines, and the hosted half of handing a writing voice to another AI.
/// Nothing else in Quill reads this class or requires it to exist.
///
/// # Why this is allowed to be the one networked, cloud-backed thing in an
/// app whose entire argument for existing is "runs on your Mac, learns your
/// voice, sends nothing anywhere unless you add your own AI key"
///
/// Because it does not compromise that argument — it sits beside it. Nobody
/// is asked to create an account, `AccountStore` is never touched unless the
/// Account row in Settings is, and Firebase itself is not initialised at
/// launch: `configure()` runs lazily on the first real use, not on every
/// cold start of every install. A person who never opens that row never
/// causes one network request this class is responsible for.
///
/// # What is actually stored
///
/// One document, `users/{uid}`: an email address and a creation date.
/// Nothing about how anyone writes, nothing they have dictated. The rules
/// deployed alongside this (`firestore.rules`) restrict a document to the
/// one account that owns it — not "any signed-in user", that uid and no
/// other.
public final class AccountStore: @unchecked Sendable {

    public static let shared = AccountStore()

    public struct Account: Sendable, Equatable {
        public let uid: String
        public let email: String
    }

    private let lock = NSLock()
    private var configured = false
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var _current: Account?
    private var listeners: [UUID: (Account?) -> Void] = [:]

    private init() {}

    /// The signed-in account, or nil. Read fresh — never cached past what
    /// Firebase itself has settled, which is what the listener below keeps
    /// current.
    public var current: Account? { lock.withLock { _current } }

    /// Called on first real use — see the type's own doc comment for why this
    /// is not called at launch. Safe to call more than once from more than
    /// one place; every call after the first is a no-op.
    private func ensureConfigured() {
        lock.lock()
        defer { lock.unlock() }
        guard !configured else { return }
        configured = true

        // `Bundle.main` is where Firebase looks by default, and it is the
        // wrong answer for an SwiftPM resource: `.copy` bundles the plist
        // inside QuillKit's OWN resource bundle, `Bundle.module`, not the
        // app's. Loading it explicitly is what makes that work instead of
        // failing to find a config file that is genuinely right there.
        guard FirebaseApp.app() == nil else { return }
        guard let path = Bundle.module.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path)
        else {
            // Not a throwing path: a build that somehow shipped without the
            // plist should fail every account action with a clear error
            // rather than crash the whole app over a feature nobody may ever
            // touch.
            NSLog("[quill] account: GoogleService-Info.plist not found — accounts unavailable")
            return
        }
        FirebaseApp.configure(options: options)

        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            let account = user.map { Account(uid: $0.uid, email: $0.email ?? "") }
            self.lock.lock()
            self._current = account
            let handlers = Array(self.listeners.values)
            self.lock.unlock()
            handlers.forEach { $0(account) }
        }
    }

    /// Called from the Account screen when it appears, so state is current
    /// the moment it is looked at, and again whenever it changes while the
    /// screen is open — a sign-in from this exact flow both creates the user
    /// and updates `current` on the same round trip, but a token expiring in
    /// the background should be reflected too.
    @discardableResult
    public func observe(_ handler: @escaping (Account?) -> Void) -> UUID {
        ensureConfigured()
        let id = UUID()
        lock.lock()
        listeners[id] = handler
        let snapshot = _current
        lock.unlock()
        handler(snapshot)
        return id
    }

    public func stopObserving(_ id: UUID) {
        lock.withLock { listeners.removeValue(forKey: id) }
    }

    // MARK: - Actions

    public enum AccountError: LocalizedError {
        case unavailable
        case firebase(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Accounts aren't available in this build."
            case .firebase(let message):
                return message
            }
        }
    }

    public func signUp(email: String, password: String) async throws {
        ensureConfigured()
        guard FirebaseApp.app() != nil else { throw AccountError.unavailable }
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            try await Firestore.firestore().collection("users").document(result.user.uid).setData([
                "email": email,
                "createdAt": FieldValue.serverTimestamp(),
            ])
        } catch {
            let ns = error as NSError
            NSLog("[quill] account signUp raw error: domain=%@ code=%d userInfo=%@",
                  ns.domain, ns.code, ns.userInfo)
            throw AccountError.firebase(Self.readable(error))
        }
    }

    public func signIn(email: String, password: String) async throws {
        ensureConfigured()
        guard FirebaseApp.app() != nil else { throw AccountError.unavailable }
        do {
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
        } catch {
            throw AccountError.firebase(Self.readable(error))
        }
    }

    public func signOut() throws {
        guard FirebaseApp.app() != nil else { return }
        do {
            try Auth.auth().signOut()
        } catch {
            throw AccountError.firebase(Self.readable(error))
        }
    }

    /// Firebase's own error strings name SDK internals ("ERROR_WEAK_PASSWORD")
    /// more often than they say something a person typing into a form would
    /// understand. Translated where the common cases are known; the SDK's own
    /// message survives for anything else rather than being hidden.
    private static func readable(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: ns.code) else {
            return error.localizedDescription
        }
        switch code {
        case .emailAlreadyInUse: return "An account already exists for that email."
        case .weakPassword: return "That password is too weak — six characters or more."
        case .invalidEmail: return "That doesn't look like an email address."
        case .wrongPassword, .userNotFound, .invalidCredential:
            return "That email and password don't match an account."
        case .networkError: return "No connection right now — try again in a moment."
        default: return error.localizedDescription
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
