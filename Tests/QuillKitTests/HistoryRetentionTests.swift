import Foundation
import Testing
@testable import QuillKit

// Quill deleting the user's data on its own.
//
// The only feature in the app that destroys something without being asked each
// time, so every test here is about it deleting the right thing and, more
// importantly, not deleting anything else.

private func record(_ daysAgo: Int, id: UUID = UUID()) -> DictationRecord {
    DictationRecord(
        id: id,
        date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!,
        rawText: "\(daysAgo) days ago", insertedText: "\(daysAgo) days ago",
        wordCount: 3, inputDevice: "MacBook Air Microphone",
        timings: .init(timeToFirstWordMs: nil, finalToInsertedMs: nil, endToEndMs: nil,
                       audioDurationMs: nil, usedThoroughCleanup: false))
}

private func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-retention-\(UUID().uuidString).json")
    return url
}

@Test func aMonthIsTheDefaultAndOlderDictationsGo() {
    let url = scratch()
    defer { try? FileManager.default.removeItem(at: url) }
    let cutoff: @Sendable () -> Date? = {
        QuillSettings.Values.HistoryRetention.month.cutoff(from: Date())
    }

    let store = HistoryStore(url: url, cutoff: cutoff)
    for days in [0, 3, 29, 31, 400] { store.append(record(days)) }

    let kept = store.all.map(\.rawText)
    #expect(kept.contains("0 days ago"))
    #expect(kept.contains("29 days ago"))
    #expect(!kept.contains("31 days ago"))
    #expect(!kept.contains("400 days ago"))

    // And it is on disk, not only in memory — the point of the feature is that
    // the transcript stops existing, not that the screen stops showing it.
    let reopened = HistoryStore(url: url, cutoff: cutoff)
    #expect(reopened.all.count == 3)
}

@Test func foreverDeletesNothing() {
    let url = scratch()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = HistoryStore(url: url, cutoff: {
        QuillSettings.Values.HistoryRetention.forever.cutoff(from: Date())
    })
    for days in [0, 400, 4_000] { store.append(record(days)) }
    #expect(store.all.count == 3)
}

@Test func aDayAndAWeekCutWhereTheySay() {
    let day = scratch(), week = scratch()
    defer { try? FileManager.default.removeItem(at: day); try? FileManager.default.removeItem(at: week) }

    let daily = HistoryStore(url: day, cutoff: {
        QuillSettings.Values.HistoryRetention.day.cutoff(from: Date())
    })
    for days in [0, 2, 8] { daily.append(record(days)) }
    #expect(daily.all.count == 1)

    let weekly = HistoryStore(url: week, cutoff: {
        QuillSettings.Values.HistoryRetention.week.cutoff(from: Date())
    })
    for days in [0, 2, 8] { weekly.append(record(days)) }
    #expect(weekly.all.count == 2)
}

@Test func expiryIsCheckedAgainstTheClockAtTheTimeNotAtLaunch() {
    // A store built at launch and still alive at midnight has to prune to the
    // new day. Holding a Date computed in init would leave a record alive for as
    // long as the app stayed open — which on this machine is days.
    let url = scratch()
    defer { try? FileManager.default.removeItem(at: url) }

    let now = UnsafeSendableBox(Date())
    let store = HistoryStore(url: url, cutoff: {
        QuillSettings.Values.HistoryRetention.day.cutoff(from: now.value)
    })
    store.append(record(0))
    #expect(store.all.count == 1)

    // Two days pass with the app open.
    now.value = Calendar.current.date(byAdding: .day, value: 2, to: now.value)!
    store.prune()
    #expect(store.all.isEmpty)
}

@Test func anUnreadableHistoryIsNotPrunedIntoAnEmptyFile() {
    // The rule the whole store is built around: never write over a file that
    // would not decode. Pruning must not become a new way through that.
    let url = scratch()
    defer {
        try? FileManager.default.removeItem(at: url)
        for extra in (try? FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        where extra.lastPathComponent.hasPrefix(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: extra)
        }
    }
    let damaged = #"[{"id":"not-a-uuid","#
    try? damaged.write(to: url, atomically: true, encoding: .utf8)

    let store = HistoryStore(url: url, cutoff: {
        QuillSettings.Values.HistoryRetention.day.cutoff(from: Date())
    })
    store.prune()
    #expect(try! String(contentsOf: url, encoding: .utf8) == damaged)
}

@Test func aSettingsFileWrittenBeforeRetentionExistedGetsTheDefault() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-oldretention-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try? #"{"holdKeyCode":61,"toggleKeyCode":61,"liveText":true}"#
        .write(to: url, atomically: true, encoding: .utf8)
    #expect(QuillSettings(url: url).historyRetention == .month)
}

@Test func anUnrecognisedRetentionDoesNotThrowTheSettingsFileAway() {
    // A value from a newer build must cost the default for this one setting, not
    // every setting in the file.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-futureretention-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try? #"{"holdKeyCode":58,"toggleKeyCode":58,"historyRetention":"fortnight"}"#
        .write(to: url, atomically: true, encoding: .utf8)
    let settings = QuillSettings(url: url)
    #expect(settings.historyRetention == .month)
    #expect(settings.hold.keyCode == 58)
}

/// A box so a test can move the clock. `nonisolated(unsafe)` in one place beats
/// threading a clock protocol through a store that has one caller.
private final class UnsafeSendableBox: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

// MARK: - Erasing everything

@Test func everyFileTheAppWritesIsOnTheEraseList() {
    // The promise "erase all my data" is kept by a list, and a list written from
    // memory is one that quietly breaks the next time somebody adds a store. So
    // the source is the authority: every file path built either the old way —
    // `appendingPathComponent("Quill/…")`, straight off Application Support —
    // or the current way — `QuillData.directory.appendingPathComponent("…")`,
    // which is what every store was moved to so `QUILL_DATA_DIR` alone actually
    // isolates it — must appear in QuillData.files.
    //
    // Failing here means a new store was added and its file would have survived
    // an erase — a transcript, a dictionary or a credential left behind by a
    // feature whose whole point is that nothing is.
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // QuillKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Sources")

    var written = Set<String>()
    let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    // Two shapes: the old direct one, and the current one routed through
    // QuillData.directory. Whichever is present, the text right after the open
    // quote is the filename.
    let markers = [#"appendingPathComponent("Quill/"#, #"QuillData.directory.appendingPathComponent(""#]
    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "swift",
              let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for marker in markers {
            var search = text[...]
            while let start = search.range(of: marker) {
                let rest = search[start.upperBound...]
                if let end = rest.firstIndex(of: "\"") {
                    let name = String(rest[..<end])
                    // Real filenames only. The pattern also appears inside the
                    // doc comment that explains this very test, written as
                    // "Quill/…".
                    if name.contains("."), !name.contains("…") { written.insert(name) }
                }
                search = rest
            }
        }
    }

    let listed = Set(QuillData.files.map(\.lastPathComponent))
    // Debug-harness receipts, not user data — already covered by
    // `QuillData.incidentalFiles`, which is what actually removes them.
    // `QuillData.files` is a fixed list built for `summary()` to name a byte
    // count against; these two are diagnostic output *about* an erase and have
    // no such count to show.
    let incidental: Set<String> = ["erase-dry-run.txt", "erased.txt"]
    // style.json is the one deliberate exception, not an oversight: it is
    // written (StyleStore.defaultURL) and intentionally NOT on the erase
    // list, so that "Erase everything" and "Uninstall" cannot take the
    // learned writing profile with them. See the comment on QuillData.files
    // and StyleStore.reset(), the button that removes it on its own.
    let deliberatelyExcluded: Set<String> = ["style.json"]
    let missing = written.subtracting(listed).subtracting(incidental).subtracting(deliberatelyExcluded)
    #expect(missing.isEmpty, "not on the erase list: \(missing.sorted().joined(separator: ", "))")
    // And nothing listed that the app never writes, which would be a stale entry
    // pointing at someone else's file.
    #expect(listed.subtracting(written).isEmpty)
}

@Test func eraseAndUninstallCannotTakeTheLearnedStyleWithThem() {
    // The positive half of the exception above: not just "the scan allows
    // this", but "this is actually true of the list a real erase reads".
    #expect(!QuillData.files.map(\.lastPathComponent).contains("style.json"))
}

@Test func eraseRemovesEverythingIncludingTheKeyAndTheSalvageCopies() {
    // Run against a real directory rather than the user's: an erase test that
    // points at the real Application Support folder is one bad path away from
    // being the bug it is testing for.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-erase-\(UUID().uuidString)")
    let quill = root.appendingPathComponent("Quill")
    try? FileManager.default.createDirectory(at: quill, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let names = ["history.json", "settings.json", "vocabulary.json", "nim-key.txt",
                 "history.json.unreadable-1700000000", "undo-trace.log", "caret-probe.txt",
                 "keep-me.txt"]
    for name in names {
        try? "x".write(to: quill.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // The enum reads the real Application Support path, so the arithmetic is
    // what is checked here: everything named goes, and an unrelated neighbour
    // stays.
    let listed = Set(QuillData.files.map(\.lastPathComponent))
    #expect(listed.contains("nim-key.txt"))
    #expect(listed.contains("history.json"))
    #expect(!listed.contains("keep-me.txt"))
}

@Test func theKeyIsWrittenPrivatelyAndAnEmptyStringRemovesIt() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-key-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(NIMKey.save("  nvapi-abc123  ", to: url))
    #expect(NIMKey.load(environment: [:], fileURL: url) == "nvapi-abc123")

    // 0600. A key that is world-readable for even a moment has been
    // world-readable, so the mode is set at creation rather than afterwards.
    let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    #expect(mode == 0o600)

    #expect(NIMKey.save("", to: url))
    #expect(NIMKey.load(environment: [:], fileURL: url) == nil)
}

@Test func firstRunIsDecidedByTheSettingsFileExisting() {
    // Not by a "hasOnboarded" flag, which is a fourth piece of state that can
    // disagree with the other three — and which would leave someone who erased
    // everything staring at a menu-bar icon with no setup and no permissions.
    #expect(OnboardingWindowController.isFirstRun
            == !FileManager.default.fileExists(atPath: QuillSettings.defaultURL.path))
}
