import Foundation
import Testing
@testable import QuillKit

/// Roman: *"sometimes there's still really random crashes… I'm not sure if
/// that's all the time, or just sometimes, or if it's caused by other things."*
///
/// Answering that took reading eight `.ips` files by hand and checking the crash
/// reporter was even working that day. The answer — last crash 10:48, on a
/// version already replaced — is a fact the app was sitting on and never said.
@Suite struct CrashHistoryTests {

    /// A real report's shape: two JSON documents, newline-separated.
    private func write(_ dir: URL, name: String, stamp: String, version: String,
                       frames: [(String, String)]) throws {
        let head: [String: Any] = ["timestamp": stamp, "app_version": version,
                                   "bug_type": "309", "os_version": "macOS 27.0"]
        let body: [String: Any] = [
            "faultingThread": 0,
            "usedImages": frames.map { ["name": $0.0] },
            "threads": [["frames": frames.enumerated().map { i, f in
                ["imageIndex": i, "symbol": f.1] }]],
        ]
        let text = String(data: try JSONSerialization.data(withJSONObject: head), encoding: .utf8)!
            + "\n" + String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func scratch() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quill-crash-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func readsTheDateVersionAndTheFrameThatNamesTheBug() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        // The real v0.1.0 crash, in its real shape: the trap machinery on top and
        // the function that actually did it underneath.
        try write(dir, name: "Quill-2026-08-24-102732.ips",
                  stamp: "2026-08-24 10:27:32.0000 +1000", version: "0.1.0",
                  frames: [("libswiftCore.dylib", "_assertionFailure(_:_:file:line:flags:)"),
                           ("Quill", "AccountStore.loadConfig()")])

        let crashes = CrashHistory.recent(in: dir)
        #expect(crashes.count == 1)
        #expect(crashes.first?.version == "0.1.0")
        #expect(crashes.first?.symbol == "AccountStore.loadConfig()",
                "the top frame is always trap machinery; the app's own frame is the one worth showing")
    }

    @Test func mostRecentFirst() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir, name: "Quill-a.ips", stamp: "2026-08-24 01:35:06.0000 +1000",
                  version: "0.1.0", frames: [("Quill", "old()")])
        try write(dir, name: "Quill-b.ips", stamp: "2026-08-24 10:48:50.0000 +1000",
                  version: "1.0.1", frames: [("Quill", "new()")])
        let crashes = CrashHistory.recent(in: dir)
        #expect(crashes.map(\.version) == ["1.0.1", "0.1.0"])
    }

    /// Other apps' reports sit in the same folder. Reading them would be both
    /// wrong and a privacy problem.
    @Test func onlyQuillsOwnReportsAreRead() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir, name: "Quill-mine.ips", stamp: "2026-08-24 10:00:00.0000 +1000",
                  version: "1.0.1", frames: [("Quill", "mine()")])
        try write(dir, name: "Safari-2026-08-24-100000.ips", stamp: "2026-08-24 10:00:00.0000 +1000",
                  version: "26.0", frames: [("Safari", "theirs()")])
        try "not json at all".write(to: dir.appendingPathComponent("Quill-broken.ips"),
                                    atomically: true, encoding: .utf8)

        let crashes = CrashHistory.recent(in: dir)
        #expect(crashes.count == 1, "read someone else's report, or choked on a malformed one")
        #expect(crashes.first?.symbol == "mine()")
    }

    /// Apple owns this format and changes it. A file that will not parse is
    /// skipped, never thrown — losing one report must not lose the rest.
    @Test func aReportInAnUnexpectedShapeIsSkippedNotFatal() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"timestamp":"nonsense"}"#.write(to: dir.appendingPathComponent("Quill-x.ips"),
                                               atomically: true, encoding: .utf8)
        try write(dir, name: "Quill-y.ips", stamp: "2026-08-24 10:00:00.0000 +1000",
                  version: "1.3.1", frames: [("Quill", "fine()")])
        #expect(CrashHistory.recent(in: dir).count == 1)
    }

    @Test func noReportsIsAnAnswerRatherThanAFailure() {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(CrashHistory.recent(in: dir).isEmpty)
    }

    /// The real timestamp format, which `ISO8601DateFormatter` refuses.
    @Test func applesTimestampFormatParses() throws {
        let d = try #require(CrashHistory.timestamp("2026-08-24 10:48:50.0000 +1000"))
        let cal = Calendar(identifier: .gregorian)
        var utc = cal; utc.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        #expect(utc.component(.hour, from: d) == 10)
        #expect(utc.component(.minute, from: d) == 48)
    }
}
