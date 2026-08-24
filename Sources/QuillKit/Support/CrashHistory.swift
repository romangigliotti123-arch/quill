import Foundation

/// Whether Quill has crashed, and when, read from macOS's own crash reports.
///
/// # Why an app should tell you this
///
/// Roman: *"sometimes there's still really random crashes… but I'm not sure if
/// that's all the time, or if that's just sometimes, or if it's caused by other
/// things."*
///
/// He could not tell, and neither could the app. Answering it took reading
/// `~/Library/Logs/DiagnosticReports` by hand, parsing eight `.ips` files, and
/// checking that the crash reporter was even working that day by looking at what
/// it had written for other processes. The answer turned out to be that the last
/// crash was hours earlier on a version already replaced — but "it has not
/// crashed since 10:48" is exactly the kind of fact the app is sitting on top of
/// and never says.
///
/// So it says it. A crash becomes a date, a version and a function name instead
/// of a feeling, and "no crashes" becomes an answer rather than an absence of
/// evidence.
///
/// # It reads its own reports and nothing else
///
/// Only files named `Quill-*.ips`, only in the user's own report folder, and only
/// the fields below. macOS wrote them about this app; reading them is the app
/// finding out what happened to it. Nothing leaves the machine — same rule as the
/// rest of Quill, and the reason this is safe to do at all.
public enum CrashHistory {

    public struct Crash: Equatable, Sendable {
        public let date: Date
        /// The version that crashed. Usually the interesting part: a crash on a
        /// version you no longer run is history, not a live problem.
        public let version: String
        /// The top frame inside Quill itself, which is the one that names the
        /// bug. The frames above it are always the trap machinery.
        public let symbol: String?
    }

    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["QUILL_CRASH_REPORTS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports")
    }

    /// Most recent first.
    public static func recent(limit: Int = 5, in directory: URL = CrashHistory.directory) -> [Crash] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("Quill-") && $0.hasSuffix(".ips") }
            .compactMap { parse(directory.appendingPathComponent($0)) }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    /// An `.ips` is two JSON documents separated by a newline: a one-line header
    /// with the timestamp and version, then the report body. Parsed by hand
    /// rather than with a model type because the format is Apple's and it changes
    /// — every field here is optional and a file that will not parse is skipped
    /// rather than throwing away the rest.
    static func parse(_ url: URL) -> Crash? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let head = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any]
        else { return nil }

        let stamp = head["timestamp"] as? String ?? ""
        guard let date = timestamp(stamp) else { return nil }
        let version = (head["app_version"] as? String) ?? "unknown"

        let body = (try? JSONSerialization.jsonObject(with: Data(parts[1].utf8))) as? [String: Any]
        return Crash(date: date, version: version, symbol: topAppFrame(in: body))
    }

    /// "2026-08-24 10:48:50.0000 +1000". `ISO8601DateFormatter` will not take it —
    /// the space and the fractional seconds are both wrong for that — so it is
    /// spelled out.
    static func timestamp(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        if let d = formatter.date(from: raw) { return d }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: raw)
    }

    /// The first frame belonging to Quill's own binary. Everything above it —
    /// `_assertionFailure`, `abort`, `objc_terminate` — is the same in every
    /// crash and names nothing.
    private static func topAppFrame(in body: [String: Any]?) -> String? {
        guard let body,
              let threads = body["threads"] as? [[String: Any]] else { return nil }
        let faulting = (body["faultingThread"] as? Int) ?? 0
        guard faulting < threads.count else { return nil }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let frames = (threads[faulting]["frames"] as? [[String: Any]]) ?? []
        for frame in frames {
            guard let index = frame["imageIndex"] as? Int, index < images.count,
                  let name = images[index]["name"] as? String, name == "Quill",
                  let symbol = frame["symbol"] as? String
            else { continue }
            return symbol
        }
        return nil
    }
}
