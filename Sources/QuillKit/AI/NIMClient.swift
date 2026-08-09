import CryptoKit
import Foundation

// NVIDIA NIM, OpenAI-compatible. The AI layer and nothing else — transcription
// is on-device and stays that way, so every path through this file has a "then
// we use the deterministic result instead" ending. A network that is down, slow,
// rate-limited or lying must cost a dictation nothing but the deadline it was
// already budgeted.

// MARK: - Credential

/// Where the key comes from, and the only place it is ever read.
///
/// Environment first so a rig or a test can override without touching the user's
/// file; file second so the shipped app needs no environment at all. The key is
/// never a literal in this repo — it is git-tracked, and a key in a commit is not
/// something you fix by deleting the line.
public enum NIMKey {

    public static let environmentVariable = "QUILL_NIM_API_KEY"

    public static let defaultFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quill/nim-key.txt")
    }()

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL = NIMKey.defaultFileURL
    ) -> String? {
        if let fromEnv = environment[environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fromEnv.isEmpty {
            return fromEnv
        }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Something a human can quote in a bug report that is not the key. Eight hex
    /// characters of SHA-256 identifies which key is loaded and reverses to
    /// nothing. A prefix of the key itself would be simpler and is not offered on
    /// purpose — "just the first six characters" is how keys end up in logs.
    public static func fingerprint(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8) + "…"
    }
}

// MARK: - Errors

public enum NIMError: LocalizedError, Equatable, Sendable {
    /// No key in the environment and none on disk. Not a failure — a state.
    case notConfigured
    /// The request never reached NVIDIA. Train, tunnel, captive portal, DNS.
    case offline(String)
    /// It reached NVIDIA and NVIDIA rejected the credential.
    case unauthorized
    /// The credential is fine; this model is not served to this account. The
    /// `/v1/models` catalogue lists models that 404 on use, so this is a normal
    /// outcome of picking a model, not an exotic one.
    case modelUnavailable(model: String, detail: String)
    case rateLimited(retryAfter: TimeInterval?)
    case serviceUnavailable(status: Int, detail: String)
    case malformedResponse(String)
    /// A 200 with nothing usable in it. Reasoning models do this: `content` is
    /// null and the whole budget went to `reasoning_content`.
    case emptyCompletion(model: String)
    case deadlineExceeded(milliseconds: Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI features are off because no key is configured. Put an NVIDIA NIM key in "
                 + "\(NIMKey.defaultFileURL.path) (chmod 600), or set \(NIMKey.environmentVariable), then reopen Quill."
        case .offline(let why):
            return "Could not reach NVIDIA — \(why). Dictation still works; the AI cleanup is skipped."
        case .unauthorized:
            return "NVIDIA rejected the API key. It is present but not valid — check it has not been "
                 + "rotated or revoked at build.nvidia.com."
        case .modelUnavailable(let model, let detail):
            return "The model \"\(model)\" is not available to this NVIDIA account. \(detail)"
        case .rateLimited(let after):
            let when = after.map { " Retry in about \(Int($0.rounded()))s." } ?? ""
            return "NVIDIA is rate-limiting this key.\(when)"
        case .serviceUnavailable(let status, let detail):
            return "NVIDIA returned \(status). \(detail)"
        case .malformedResponse(let what):
            return "NVIDIA returned something this client could not read: \(what)"
        case .emptyCompletion(let model):
            return "\"\(model)\" returned an empty completion. Reasoning models do this — their text "
                 + "goes to reasoning_content, not content. Pick a non-reasoning instruct model."
        case .deadlineExceeded(let ms):
            return "AI cleanup did not finish within \(ms)ms; the deterministic cleanup was used instead."
        case .cancelled:
            return "AI cleanup was cancelled."
        }
    }

    /// Worth trying again with the same request, if there is budget for it.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .serviceUnavailable: return true
        case .offline, .notConfigured, .unauthorized, .modelUnavailable,
             .malformedResponse, .emptyCompletion, .deadlineExceeded, .cancelled: return false
        }
    }

    /// Counts toward tripping the circuit breaker. Only failures that a retry in
    /// a minute might genuinely fix — a bad key will still be bad, and
    /// short-circuiting on it would hide the one error the user must act on.
    ///
    /// `.deadlineExceeded` is deliberately NOT here, and the live harness is why:
    /// with it included, two dictations at the coordinator's 250ms deadline —
    /// which the benchmark says miss ~89% of the time — tripped the breaker and
    /// switched the AI off for the following minute. A deadline miss means the
    /// service answered too slowly for this caller, not that it is unreachable,
    /// and it costs exactly the deadline the caller had already budgeted. The
    /// breaker exists for the case that costs more than that: no network at all.
    var trippsBreaker: Bool {
        switch self {
        case .offline, .rateLimited, .serviceUnavailable: return true
        default: return false
        }
    }
}

// MARK: - Reachability

/// The answer to "why is the AI not doing anything", in a form the settings pane
/// can render. Roman will hit every one of these, so they are separate cases
/// rather than one error string.
public enum NIMStatus: Equatable, Sendable {
    case ready(model: String, latencyMs: Int)
    case notConfigured
    case offline(String)
    case badKey
    case modelUnavailable(model: String, detail: String)
    case serviceBusy(String)

    public var isUsable: Bool {
        if case .ready = self { return true }
        return false
    }

    /// One line, no jargon.
    public var headline: String {
        switch self {
        case .ready(let model, let ms):   return "AI ready — \(model), \(ms)ms"
        case .notConfigured:              return "AI features are off because no key is configured"
        case .offline:                    return "AI unavailable — no network"
        case .badKey:                     return "AI unavailable — the API key is not valid"
        case .modelUnavailable(let m, _): return "AI unavailable — \"\(m)\" is not served to this account"
        case .serviceBusy:                return "AI unavailable — NVIDIA is busy or rate-limiting"
        }
    }

    /// What to do about it.
    public var detail: String {
        switch self {
        case .ready:
            return "Transcription is on-device either way; this only affects the cleanup pass."
        case .notConfigured:
            return NIMError.notConfigured.errorDescription ?? ""
        case .offline(let why):
            return "\(why). Dictation is unaffected — it never needed the network."
        case .badKey:
            return NIMError.unauthorized.errorDescription ?? ""
        case .modelUnavailable(_, let detail):
            return detail + " Pick another model; /v1/models lists the catalogue, "
                 + "but a listed model can still 404 for an account."
        case .serviceBusy(let detail):
            return detail
        }
    }
}

// MARK: - Client

public final class NIMClient: @unchecked Sendable {

    public let config: AIConfig
    private let key: String?
    private let session: URLSession
    private let clock = ContinuousClock()
    /// Roman's vocabulary, used to check the model gave his words back. Held
    /// here rather than looked up per call so a dictation never touches disk.
    private let vocabulary: [String]

    /// Breaker state. A plain lock rather than an actor: the dictation path calls
    /// in from an async context that must not pay an actor hop, and the state is
    /// two fields.
    private let lock = NSLock()
    private var consecutiveFailures = 0
    private var openedAt: ContinuousClock.Instant?

    public init(
        config: AIConfig = .default,
        key: String? = NIMKey.load(),
        vocabulary: [String] = Vocabulary.load().contextualStrings,
        session: URLSession? = nil
    ) {
        self.config = config
        self.key = key
        self.vocabulary = vocabulary
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            // Keep-alive matters more than anything else here: a cold TLS
            // handshake to this endpoint measured 294ms on its own, which is
            // more than the entire dictation budget. Reusing the connection
            // brings the floor to ~150ms.
            c.httpMaximumConnectionsPerHost = 2
            c.timeoutIntervalForRequest = 10
            c.timeoutIntervalForResource = 20
            c.waitsForConnectivity = false   // On a train, fail now; do not queue.
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: c)
        }
    }

    public var isConfigured: Bool { key != nil }

    /// Safe to log. Never the key.
    public var keyFingerprint: String { key.map(NIMKey.fingerprint) ?? "none" }

    // MARK: Dictation path

    /// The only call the dictation path is allowed to make.
    ///
    /// Never throws, never logs the key, and never takes longer than `deadline` —
    /// including the case where there is no key, where the breaker is open, and
    /// where the network hangs without ever answering. Returns nil for every
    /// failure, because the caller already has a good deterministic answer and a
    /// nil here means "use it", not "something went wrong".
    ///
    /// Pass the FastCleaner output, not the raw transcript. Measured: FastCleaner
    /// repairs "the graph if I build to neglify" to "the graphify build to
    /// Netlify" in under 2ms and no model in the benchmark managed it from raw.
    /// The model is here for the one thing rules cannot do — spoken
    /// self-correction — and it does that better on text that is already tidy.
    public func cleanedTranscript(_ text: String, deadline: Duration) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, key != nil, !isBreakerOpen else { return nil }

        do {
            let completion = try await complete(
                system: config.systemPrompt, user: trimmed, deadline: deadline
            )
            return AIOutputGuard.sanitise(completion, against: trimmed, preserving: vocabulary)
        } catch {
            return nil
        }
    }

    // MARK: Typed path

    /// The version that tells you why. For settings, diagnostics and the rig —
    /// not for the dictation path, which must never surface an AI error to
    /// someone who just wanted their words typed.
    public func complete(
        system: String,
        user: String,
        model: String? = nil,
        deadline: Duration
    ) async throws -> String {
        guard let key else { throw NIMError.notConfigured }
        let model = model ?? config.model
        let started = clock.now

        var attempt = 0
        var backoff = config.initialBackoff
        var lastError: NIMError = .deadlineExceeded(milliseconds: deadline.milliseconds)

        while attempt < config.maxAttempts {
            attempt += 1
            let remaining = deadline - started.duration(to: clock.now)
            guard remaining > .milliseconds(20) else { break }

            do {
                let text = try await withDeadline(min(remaining, config.requestTimeout)) {
                    try await self.performChat(system: system, user: user, model: model, key: key)
                }
                noteSuccess()
                return text
            } catch let error as NIMError {
                lastError = error
                if error.trippsBreaker { noteFailure() }
                guard error.isTransient else { throw error }

                // Only sleep if the budget can still cover the backoff *and* a
                // request afterwards. On a 250ms dictation deadline it never can,
                // which is the correct behaviour: fail out and let the fast pass
                // ship rather than burn the user's budget on politeness.
                let left = deadline - started.duration(to: clock.now)
                let wait = min(backoff, retryHint(from: error) ?? backoff)
                guard left > wait + .milliseconds(120) else { break }
                try? await Task.sleep(for: wait)
                backoff = backoff * 2
            }
        }
        throw lastError
    }

    // MARK: Reachability

    /// Distinguishes "no network" from "bad key" from "model unavailable" by
    /// actually doing the three things that tell them apart, in the order that
    /// costs least. A GET of the catalogue answers network and credential; only a
    /// real completion answers whether the model is served to this account,
    /// because the catalogue happily lists models that 404 on use.
    public func status(deadline: Duration = .seconds(12)) async -> NIMStatus {
        guard let key else { return .notConfigured }
        let started = clock.now

        var request = URLRequest(url: config.modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = deadline.seconds
        let probe = request

        do {
            let (data, response) = try await withDeadline(deadline) {
                try await self.session.data(for: probe)
            }
            guard let http = response as? HTTPURLResponse else {
                return .serviceBusy("NVIDIA returned a non-HTTP response.")
            }
            switch http.statusCode {
            case 200:
                break
            case 401, 403:
                return .badKey
            case 429:
                return .serviceBusy(NIMError.rateLimited(retryAfter: retryAfterSeconds(http)).localizedDescription)
            default:
                return .serviceBusy("Catalogue lookup returned \(http.statusCode). \(Self.errorDetail(from: data, redacting: key))")
            }
            _ = data
        } catch let error as NIMError {
            switch error {
            case .offline(let why): return .offline(why)
            case .unauthorized:     return .badKey
            case .deadlineExceeded: return .offline("the catalogue did not answer in \(deadline.milliseconds)ms")
            default:                return .serviceBusy(error.localizedDescription)
            }
        } catch {
            return .offline(Self.describe(error))
        }

        // Credential and network are proven. Now prove the model.
        let left = deadline - started.duration(to: clock.now)
        do {
            _ = try await complete(system: "Reply with the single word OK.", user: "ping",
                                   deadline: max(left, .seconds(2)))
            let ms = started.duration(to: clock.now).milliseconds
            return .ready(model: config.model, latencyMs: ms)
        } catch let error as NIMError {
            switch error {
            case .modelUnavailable(let m, let d): return .modelUnavailable(model: m, detail: d)
            case .emptyCompletion(let m):         return .modelUnavailable(model: m, detail: error.localizedDescription)
            case .unauthorized:                   return .badKey
            case .offline(let why):               return .offline(why)
            default:                              return .serviceBusy(error.localizedDescription)
            }
        } catch {
            return .serviceBusy(Self.describe(error))
        }
    }

    // MARK: - One request

    private func performChat(system: String, user: String, model: String, key: String) async throws -> String {
        var request = URLRequest(url: config.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = config.requestTimeout.seconds
        request.httpBody = try Self.encodeBody(
            model: model, system: system, user: user, config: config
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw Self.classify(urlError)
        } catch is CancellationError {
            throw NIMError.cancelled
        } catch {
            throw NIMError.offline(Self.describe(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw NIMError.malformedResponse("no HTTP status")
        }

        switch http.statusCode {
        case 200:
            return try Self.decodeCompletion(data, model: model, redacting: key)
        case 401, 403:
            throw NIMError.unauthorized
        case 404:
            throw NIMError.modelUnavailable(model: model, detail: Self.errorDetail(from: data, redacting: key))
        case 429:
            throw NIMError.rateLimited(retryAfter: retryAfterSeconds(http))
        case 400, 422:
            // Not transient: the same body will be rejected the same way.
            throw NIMError.malformedResponse(Self.errorDetail(from: data, redacting: key))
        default:
            throw NIMError.serviceUnavailable(
                status: http.statusCode, detail: Self.errorDetail(from: data, redacting: key)
            )
        }
    }

    // MARK: - Wire format

    private static func encodeBody(model: String, system: String, user: String, config: AIConfig) throws -> Data {
        // Hand-built rather than Codable structs: the request has four shapes we
        // care about and JSONEncoder on a struct with optionals produces keys
        // some NIM-hosted models reject.
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": config.temperature,
            "top_p": config.topP,
            "max_tokens": config.maxTokens,
            // Streaming would let the first token arrive sooner, but the caller
            // needs the whole cleaned sentence before it can insert anything —
            // there is no partial paste. Non-streaming keeps the parse trivial.
            "stream": false,
        ]
        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw NIMError.malformedResponse("could not encode request")
        }
    }

    private static func decodeCompletion(_ data: Data, model: String, redacting key: String) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw NIMError.malformedResponse(Self.redact(String(decoding: data.prefix(200), as: UTF8.self), key))
        }
        let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let content, !content.isEmpty else {
            // Measured: openai/gpt-oss-20b spends its entire 120-token budget in
            // reasoning_content and returns content: null every single time.
            throw NIMError.emptyCompletion(model: model)
        }
        return content
    }

    /// NVIDIA returns two different error envelopes and both show up in normal
    /// use: `{"status":404,"title":…,"detail":…}` from the routing layer and
    /// `{"error":{"message":…}}` from the model server.
    static func errorDetail(from data: Data, redacting key: String) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return redact(String(decoding: data.prefix(200), as: UTF8.self), key)
        }
        if let nested = root["error"] as? [String: Any], let message = nested["message"] as? String {
            return redact(String(message.prefix(300)), key)
        }
        if let detail = root["detail"] as? String {
            return redact(String(detail.prefix(300)), key)
        }
        if let title = root["title"] as? String {
            return redact(String(title.prefix(300)), key)
        }
        return redact(String(decoding: data.prefix(200), as: UTF8.self), key)
    }

    /// Belt and braces. Nothing observed has ever echoed the key back, but this
    /// is the one class of bug that cannot be fixed after it happens, so every
    /// string derived from a response body goes through here before it can reach
    /// a log, an alert or an error message.
    static func redact(_ text: String, _ key: String) -> String {
        guard !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "[redacted]")
    }

    // MARK: - Classification

    static func classify(_ error: URLError) -> NIMError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .offline("no internet connection")
        case .cannotFindHost, .dnsLookupFailed:
            return .offline("DNS could not resolve integrate.api.nvidia.com")
        case .cannotConnectToHost:
            return .offline("the connection was refused")
        case .timedOut:
            return .offline("the request timed out")
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            // The captive-portal signature: a wifi that answers everything with
            // its own login page, which is not the same as being offline.
            return .offline("TLS failed — this looks like a captive portal, not NVIDIA")
        case .cancelled:
            return .cancelled
        default:
            return .offline(error.localizedDescription)
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private func retryAfterSeconds(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(raw.trimmingCharacters(in: .whitespaces))
    }

    private func retryHint(from error: NIMError) -> Duration? {
        if case .rateLimited(let after) = error, let after { return .milliseconds(Int(after * 1000)) }
        return nil
    }

    // MARK: - Deadline

    /// Races the operation against the clock and cancels it when the clock wins.
    ///
    /// Unlike DictationCoordinator's equivalent, the loser is cancelled rather
    /// than left running: this one holds a socket and a rate-limit slot, and a
    /// dictation every ten seconds would otherwise pile up abandoned requests
    /// against a key that is already 429-prone.
    private func withDeadline<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let result { return result }
                throw NIMError.deadlineExceeded(milliseconds: duration.milliseconds)
            }
            throw NIMError.deadlineExceeded(milliseconds: duration.milliseconds)
        }
    }

    // MARK: - Circuit breaker

    /// Open means "do not even try". Costs nothing to check and saves the whole
    /// deadline on every dictation while the network is gone.
    public var isBreakerOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let openedAt else { return false }
        if openedAt.duration(to: clock.now) >= config.breakerCooldown {
            // Half-open: let the next call through. If it fails the breaker
            // re-trips immediately, so the cost of being wrong is one request.
            self.openedAt = nil
            consecutiveFailures = 0
            return false
        }
        return true
    }

    private func noteFailure() {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures += 1
        if consecutiveFailures >= config.breakerThreshold, openedAt == nil {
            openedAt = clock.now
        }
    }

    private func noteSuccess() {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures = 0
        openedAt = nil
    }

    /// For the settings pane's "try again now" button, and for tests.
    public func resetBreaker() {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures = 0
        openedAt = nil
    }
}

// MARK: - Duration conveniences

extension Duration {
    var seconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) * 1e-18
    }
    var milliseconds: Int { Int((seconds * 1000).rounded()) }
}
