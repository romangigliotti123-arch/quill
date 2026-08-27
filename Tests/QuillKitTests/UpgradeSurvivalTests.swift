import Foundation
import Testing
@testable import QuillKit

/// Nothing a user has may be lost by installing a newer Quill.
///
/// An update replaces the app bundle and nothing else — every file the user
/// owns stays in `~/Library/Application Support/Quill/`, written by the old
/// build and read by the new one. That only holds while the new build can still
/// read what the old one wrote, and Swift's synthesised `Codable` breaks it in
/// the quietest way available: add one non-optional field and every record
/// written before it throws on decode. `StoreFile` then does the right thing and
/// refuses to overwrite the file, so nothing is destroyed — but the user opens
/// Quill after an update to an empty history, an empty Dictionary, no notes and
/// no snippets, and a store that has silently stopped saving. "Still on disk" is
/// no comfort to someone looking at a blank screen.
///
/// So the fixtures below are frozen: they are the exact bytes a shipped release
/// wrote, and they stay that way. Adding a required field to any of these types
/// fails these tests at the moment it is added, which is the only moment it is
/// cheap to fix.
///
/// They are read from a scratch directory. A test that reads the real
/// Application Support folder is a test that passes on the author's Mac and
/// tells nobody else anything.
@Suite struct UpgradeSurvivalTests {

    private func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quill-upgrade-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ json: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try json.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Settings

    /// Verbatim, keys and all, as v1.0.3 writes it: pretty-printed, sorted keys,
    /// and no `inputDeviceUID` because the encoder omits a nil optional.
    private let settingsAsShipped = """
    {
      "contextRecovery" : true,
      "finishThenEnterEnabled" : true,
      "historyRetention" : "week",
      "holdKeyCode" : 61,
      "liveText" : false,
      "numberStyle" : "alwaysDigits",
      "overlayBarEnabled" : false,
      "overlayBarPosition" : "topRight",
      "overlayShowsNewNoteButton" : false,
      "toggleKeyCode" : 58,
      "undoChord" : false
    }
    """

    @Test func everySettingWrittenByAShippedReleaseSurvivesTheUpdate() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write(settingsAsShipped, "settings.json", in: dir)

        let values = QuillSettings(url: url).current

        // Deliberately every field, and deliberately none of them at their
        // default: a test where the expected value and the fallback are the same
        // number passes just as happily when decoding does nothing at all.
        #expect(values.holdKeyCode == 61)
        #expect(values.toggleKeyCode == 58)
        #expect(values.liveText == false)
        #expect(values.undoChord == false)
        #expect(values.contextRecovery == true)
        #expect(values.finishThenEnterEnabled == true)
        #expect(values.overlayBarEnabled == false)
        #expect(values.overlayShowsNewNoteButton == false)
        #expect(values.overlayBarPosition == .topRight)
        #expect(values.numberStyle == .alwaysDigits)
        #expect(values.historyRetention == .week)
    }

    /// The update that adds a setting must not reset the ones already there.
    @Test func aSettingsFileFromBeforeTheNewerFieldsExistedKeepsWhatItHas() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // v0.1.0's shape: no overlay keys, no finish-then-enter, no retention.
        let url = try write("""
        {
          "holdKeyCode" : 58,
          "inputDeviceUID" : "BlackHole2ch_UID",
          "liveText" : false,
          "toggleKeyCode" : 58,
          "undoChord" : false
        }
        """, "settings.json", in: dir)

        let values = QuillSettings(url: url).current

        #expect(values.holdKeyCode == 58)
        #expect(values.inputDeviceUID == "BlackHole2ch_UID")
        #expect(values.liveText == false)
        #expect(values.undoChord == false)
        // Absent keys take the current default, which is the behaviour that file
        // already had — not a throw that would cost the user the four above.
        #expect(values.overlayBarPosition == .bottomLeft)
        #expect(values.finishThenEnterEnabled == true)
        #expect(values.historyRetention == .month)
    }

    /// The other direction, which matters because there is no auto-updater and
    /// people do reinstall an older build: a file written by a newer Quill, with
    /// a key this build has never heard of and an enum case it cannot name.
    @Test func aSettingsFileFromANewerBuildKeepsWhatThisBuildUnderstands() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write("""
        {
          "holdKeyCode" : 61,
          "liveText" : false,
          "overlayBarPosition" : "middleOfTheScreenSomehow",
          "somethingAddedInAFutureVersion" : { "nested" : [1, 2, 3] },
          "undoChord" : false
        }
        """, "settings.json", in: dir)

        let values = QuillSettings(url: url).current

        #expect(values.liveText == false)
        #expect(values.undoChord == false)
        #expect(values.holdKeyCode == 61)
        #expect(values.overlayBarPosition == .bottomLeft)  // unknown case → default
    }

    /// The rule the other five stores already follow, and the one settings was
    /// still missing: a file that cannot be read is not a file full of defaults.
    ///
    /// Before this, an unreadable settings.json meant the app ran on defaults and
    /// then wrote them over the top the first time the user changed anything —
    /// microphone, dictation key, retention, every toggle, gone, along with the
    /// file that could have been rescued by hand.
    @Test func anUnreadableSettingsFileIsNeverOverwritten() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let damaged = #"{"holdKeyCode": 61, "liveText": tru"#   // truncated mid-write
        let url = try write(damaged, "settings.json", in: dir)

        let settings = QuillSettings(url: url)
        settings.setLiveText(false)
        settings.setHistoryRetention(.day)
        settings.markConfigured()

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == damaged)

        // And the bytes are kept a second time, where a person can find them.
        let salvaged = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".unreadable-") }
        #expect(salvaged.count == 1)
    }

    // MARK: - History

    /// A record exactly as v1.0.3 writes it — ISO-8601 dates, nested timings.
    private let historyAsShipped = """
    [
      {
        "date" : "2026-08-23T09:00:21Z",
        "id" : "687743A7-7D06-4EAC-A444-B161D8A9622A",
        "inputDevice" : "MacBook Air Microphone",
        "insertedText" : "Send Noah the deposit terms.",
        "rawText" : "send noah the deposit terms",
        "timings" : {
          "audioDurationMs" : 2100,
          "endToEndMs" : 2400,
          "finalToInsertedMs" : 40,
          "timeToFirstWordMs" : 380,
          "usedThoroughCleanup" : true
        },
        "wordCount" : 5
      }
    ]
    """

    @Test func aHistoryWrittenByAShippedReleaseSurvivesTheUpdate() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write(historyAsShipped, "history.json", in: dir)

        let store = HistoryStore(url: url, cutoff: { nil })
        let all = store.all
        #expect(all.count == 1)
        let record = try #require(all.first)
        #expect(record.rawText == "send noah the deposit terms")
        #expect(record.insertedText == "Send Noah the deposit terms.")
        #expect(record.wordCount == 5)
        #expect(record.inputDevice == "MacBook Air Microphone")
        #expect(record.timings.audioDurationMs == 2100)
        #expect(record.timings.usedThoroughCleanup == true)
        // The three timings added after this record's shape was frozen.
        #expect(record.timings.releaseToInsertedMs == nil)
        #expect(record.timings.micOpenMs == nil)
    }

    /// The failure this suite exists for, in its purest form: 85 dictations and
    /// one field this build wants that the file does not have.
    @Test func aHistoryMissingFieldsAddedLaterStillLoadsEveryRecord() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let records = (0..<85).map { i in
            """
            { "date" : "2026-08-2\(i % 3)T09:00:21Z",
              "insertedText" : "record \(i)",
              "rawText" : "record \(i)" }
            """
        }.joined(separator: ",")
        let url = try write("[\(records)]", "history.json", in: dir)

        let store = HistoryStore(url: url, cutoff: { nil })
        #expect(store.all.count == 85)
        // wordCount was absent; derived rather than defaulted to zero, so
        // Insights does not report a month of dictation as no words at all.
        #expect(store.all.allSatisfy { $0.wordCount == 2 })
    }

    // MARK: - Notes, Dictionary, snippets

    @Test func notesWrittenByAShippedReleaseSurviveTheUpdate() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write("""
        [
          {
            "body" : "Ask about the Warwick cloth by the metre.",
            "created" : "2026-08-23T09:00:21Z",
            "id" : "687743A7-7D06-4EAC-A444-B161D8A9622A",
            "title" : "Builda Bed",
            "updated" : "2026-08-23T09:14:02Z"
          }
        ]
        """, "notes.json", in: dir)

        let all = NoteStore(url: url).all
        #expect(all.count == 1)
        #expect(all.first?.title == "Builda Bed")
        #expect(all.first?.body == "Ask about the Warwick cloth by the metre.")
    }

    @Test func theDictionaryWrittenByAShippedReleaseSurvivesTheUpdate() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write(#"{ "terms" : [ "Craigieburn", "graphify", "Netlify" ] }"#,
                            "vocabulary.json", in: dir)

        #expect(Vocabulary.load(from: url).terms == ["Craigieburn", "graphify", "Netlify"])
    }

    @Test func snippetsWrittenByAShippedReleaseSurviveTheUpdate() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write("""
        [
          {
            "created" : "2026-08-23T09:00:21Z",
            "id" : "687743A7-7D06-4EAC-A444-B161D8A9622A",
            "isEnabled" : true,
            "mode" : "alone",
            "phrase" : "sign off",
            "replacement" : "Cheers,\\nRoman",
            "useCount" : 12
          }
        ]
        """, "snippets.json", in: dir)

        let all = SnippetStore(url: url).all
        #expect(all.count == 1)
        #expect(all.first?.phrase == "sign off")
        #expect(all.first?.replacement == "Cheers,\nRoman")
        #expect(all.first?.mode == .alone)
        #expect(all.first?.useCount == 12)
    }

    // MARK: - The whole folder at once

    /// The end-to-end version: everything a user owns, written by the old build,
    /// opened by this one. Asserts both halves of "nothing is lost" — the values
    /// read back, and the bytes on disk are not rewritten just by launching.
    @Test func openingAFullDataFolderAfterAnUpdateChangesNothingOnDisk() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files: [String: String] = [
            "settings.json": settingsAsShipped,
            "history.json": historyAsShipped,
            "notes.json": #"[{"body":"b","created":"2026-08-23T09:00:21Z","id":"687743A7-7D06-4EAC-A444-B161D8A9622A","title":"t","updated":"2026-08-23T09:00:21Z"}]"#,
            "vocabulary.json": #"{"terms":["Craigieburn"]}"#,
            "snippets.json": #"[{"created":"2026-08-23T09:00:21Z","id":"11111111-1111-1111-1111-111111111111","isEnabled":true,"mode":"anywhere","phrase":"p","replacement":"r","useCount":0}]"#,
            // Not decoded by anything here, but they live in the same folder and
            // an update must leave them exactly as they were.
            "nim-key.txt": "nvapi-not-a-real-key",
            "my-voice-for-ai.md": "# How I write\n\nShort sentences.\n",
            "device.json": #"{"id":"dabc123"}"#,
        ]
        var before: [String: Data] = [:]
        for (name, body) in files {
            let url = try write(body, name, in: dir)
            before[name] = try Data(contentsOf: url)
        }

        // What a newer build does on first launch: read everything.
        let settings = QuillSettings(url: dir.appendingPathComponent("settings.json"))
        let history = HistoryStore(url: dir.appendingPathComponent("history.json"), cutoff: { nil })
        let notes = NoteStore(url: dir.appendingPathComponent("notes.json"))
        let snippets = SnippetStore(url: dir.appendingPathComponent("snippets.json"))
        let vocabulary = Vocabulary.load(from: dir.appendingPathComponent("vocabulary.json"))

        #expect(settings.current.overlayBarPosition == .topRight)
        #expect(history.all.count == 1)
        #expect(notes.all.count == 1)
        #expect(snippets.all.count == 1)
        #expect(vocabulary.terms == ["Craigieburn"])

        for (name, original) in before {
            let now = try Data(contentsOf: dir.appendingPathComponent(name))
            #expect(now == original, "\(name) was rewritten by an update that only read it")
        }
    }

    // MARK: - Noticing the update at all

    /// The version bookkeeping behind the post-update notice.
    ///
    /// v1.0.4 is the last release that will cost anyone their permissions — the
    /// certificate is pinned from here on — but it does cost them, once, and an
    /// app that responds by silently doing nothing is the failure the README
    /// calls "looks like a broken app".
    @Test func aLaunchAfterAnUpdateIsDistinguishableFromAnOrdinaryOne() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An install from before the version was ever recorded: every build up
        // to v1.0.3, and precisely the ones the next update affects.
        let url = try write(settingsAsShipped, "settings.json", in: dir)
        let settings = QuillSettings(url: url)

        #expect(settings.noteLaunch(of: "1.0.4") == nil)
        // Same version again is an ordinary launch, not an update.
        #expect(settings.noteLaunch(of: "1.0.4") == "1.0.4")
        #expect(settings.noteLaunch(of: "1.0.5") == "1.0.4")

        // Recorded, and it survives the next launch — which is the whole point.
        #expect(QuillSettings(url: url).lastLaunchedVersion == "1.0.5")

        // And recording it did not disturb anything the user had chosen.
        let values = QuillSettings(url: url).current
        #expect(values.overlayBarPosition == .topRight)
        #expect(values.numberStyle == .alwaysDigits)
        #expect(values.historyRetention == .week)
        #expect(values.toggleKeyCode == 58)
    }

    // MARK: - The certificate

    /// The other half of "nothing is lost", and the half that was actually
    /// costing users something on every single release.
    ///
    /// macOS binds a TCC grant to the app's Designated Requirement, which for a
    /// self-signed app names the signing certificate's leaf hash. Releases
    /// v1.0.1, v1.0.2 and v1.0.3 each shipped a different one — the workflow
    /// minted a throwaway certificate per run — so every update silently revoked
    /// Microphone, Accessibility and Input Monitoring, leaving the System
    /// Settings toggles reading ON while pointing at a hash that no longer
    /// existed. The README's "a stale Accessibility grant looks like a broken
    /// app" was describing this without naming its cause.
    ///
    /// One hash, in three files that must never disagree. A test rather than a
    /// convention because the symptom appears on other people's Macs, days
    /// later, as "it just stopped working".
    @Test func oneSigningCertificateIsPinnedEverywhereThatSignsOrChecks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // QuillKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root

        let sources = [
            "Scripts/build.sh",
            "Scripts/make_cert.sh",
            ".github/workflows/release.yml",
        ]

        let pattern = try NSRegularExpression(pattern: "\\b[0-9a-fA-F]{40}\\b")
        var found: [String: Set<String>] = [:]
        for path in sources {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let hashes = pattern
                .matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text).map { String(text[$0]).lowercased() } }
            found[path] = Set(hashes)
        }

        for (path, hashes) in found {
            #expect(hashes.count == 1, "\(path) names \(hashes.count) certificate hashes; it must name exactly one")
        }
        #expect(Set(found.values).count == 1, "these files disagree about which certificate signs Quill: \(found)")
    }

    // MARK: - Being signed in must survive an update

    /// The frozen bytes of a real `account.json`, as shipped builds write it.
    ///
    /// Roman's instruction was one sentence: never log him out by itself. The
    /// way that happens is not a bug anyone writes on purpose — it is adding a
    /// sixth field to `Session`, whose decoder used to be synthesised, so every
    /// file written before that version throws, `try?` turns the throw into nil,
    /// and nil reads as "signed out" everywhere in the app. His tokens would
    /// still be on disk while the app showed him a login screen.
    private let shippedAccountJSON = """
    {"uid":"abc123","email":"someone@example.com","idToken":"header.payload.signature",\
    "refreshToken":"AMf-refresh-token-value","expiresAt":"2026-08-27T09:00:00Z"}
    """

    @Test func aSessionWrittenByAnOlderBuildStillDecodes() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AccountStore.Session.self,
                                         from: Data(shippedAccountJSON.utf8))
        #expect(session.uid == "abc123")
        #expect(session.email == "someone@example.com")
        #expect(session.refreshToken == "AMf-refresh-token-value")
    }

    /// A field a newer build added and an older file does not carry must not be
    /// able to sign anyone out. This is the test that fails the moment someone
    /// adds a required sixth field, which is the only moment it is cheap to fix.
    @Test func anUnknownExtraFieldDoesNotDestroyTheSession() throws {
        let withExtra = """
        {"uid":"abc123","email":"someone@example.com","idToken":"a.b.c",\
        "refreshToken":"r","expiresAt":"2026-08-27T09:00:00Z","somethingNewer":42}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AccountStore.Session.self, from: Data(withExtra.utf8))
        #expect(session.uid == "abc123")
    }

    /// A damaged `account.json` is not a logout, and `StoreFile` must keep a
    /// salvage copy rather than let the app write over it.
    @Test func aDamagedAccountFileIsKeptRatherThanTreatedAsSignedOut() throws {
        let dir = scratch()
        let url = dir.appendingPathComponent("account.json")
        try Data("{\"uid\":\"abc".utf8).write(to: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let outcome = StoreFile.read(AccountStore.Session.self, from: url, decoder: decoder)

        guard case .unreadable = outcome else {
            Issue.record("a truncated account.json read as \(outcome) rather than unreadable")
            return
        }
        // The original is still there, and a salvage copy sits beside it.
        #expect(FileManager.default.fileExists(atPath: url.path))
        let salvaged = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("unreadable") }
        #expect(!salvaged.isEmpty, "no salvage copy was kept")
    }

    // MARK: - Corrupt counters heal on the way in

    /// The doubling bug reached Firestore as well as the local file, so repairing
    /// the local copy achieved nothing — the next sync pulled the corrupt cloud
    /// document down and merged it straight back in. Measured on his machine.
    ///
    /// Sanitising at the decoder is what breaks that loop: both sides of a sync
    /// are decoded before they are merged, so the bad value cannot survive a
    /// single round trip.
    @Test func aProfileCarryingTheDoublingCorruptionIsHealedWhenItIsRead() throws {
        // His real file, after logging back in mid-session: 2^62 + 1.
        let corrupt = """
        {"correctionCount":4611686018427387905,\
        "sentenceLength":{"count":4611686018427387905,"total":3.2281802128991715e+19},\
        "phrasings":[{"count":4611686018427387904,"from":"kashios","to":"CachyOS"}],\
        "preset":"neutral","isLearningEnabled":true}
        """
        let profile = try JSONDecoder().decode(StyleProfile.self, from: Data(corrupt.utf8))

        #expect(profile.correctionCount == 0, "got \(profile.correctionCount)")
        #expect(profile.sentenceLength.count == 0)
        #expect(profile.sentenceLength.total == 0)
        // The phrasing itself is real evidence and is kept, at a count of one.
        #expect(profile.phrasings.count == 1)
        #expect(profile.phrasings.first?.count == 1)
        #expect(profile.phrasings.first?.to == "CachyOS")
    }

    /// Ordinary values are not touched. A clamp that rounds real data off is a
    /// worse bug than the one it fixes.
    @Test func plausibleCountersSurviveTheSanitiser() throws {
        let ordinary = """
        {"correctionCount":37,"sentenceLength":{"count":12,"total":168.0},\
        "phrasings":[{"count":4,"from":"kashios","to":"CachyOS"}],"preset":"neutral"}
        """
        let profile = try JSONDecoder().decode(StyleProfile.self, from: Data(ordinary.utf8))
        #expect(profile.correctionCount == 37)
        #expect(profile.sentenceLength.count == 12)
        #expect(profile.sentenceLength.average == 14.0)
        #expect(profile.phrasings.first?.count == 4)
    }
}
