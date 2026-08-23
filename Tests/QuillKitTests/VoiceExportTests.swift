import Foundation
import Testing
@testable import QuillKit

// A document meant to leave the app entirely — pasted into Claude, ChatGPT,
// whatever the user already talks to — so the tests care about two things a
// unit test can actually check: that it never sends what should not be there
// (measurements, blanks), and that it never touches the real data directory
// while proving that.

private func record(_ text: String, daysAgo: Int, loopback: Bool = false) -> DictationRecord {
    DictationRecord(
        id: UUID(),
        date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!,
        rawText: text, insertedText: text,
        wordCount: text.split(separator: " ").count,
        inputDevice: loopback ? "BlackHole 2ch" : "MacBook Air Microphone",
        timings: .init(timeToFirstWordMs: nil, finalToInsertedMs: nil, endToEndMs: nil,
                       audioDurationMs: nil, usedThoroughCleanup: false))
}

@Test func aFreshProfileWithNoHistoryStillProducesAReadableDocument() {
    let doc = VoiceExport.markdown(profile: StyleProfile(), records: [])
    #expect(doc.contains("# How this person writes"))
    #expect(doc.contains("Nothing yet"))
}

@Test func measurementsNeverReachTheExportedDocument() {
    // The eval rig's loopback clips are not things the user said, and this
    // document exists specifically to teach an AI how the user actually talks
    // — a synthetic benchmark clip in there is worse than noise, it is a false
    // claim about someone's own voice.
    let doc = VoiceExport.markdown(profile: StyleProfile(), records: [
        record("the real thing I said", daysAgo: 1),
        record("a benchmark clip fed through a loopback", daysAgo: 1, loopback: true),
    ])
    #expect(doc.contains("the real thing I said"))
    #expect(!doc.contains("a benchmark clip fed through a loopback"))
}

@Test func blankDictationsAreDropped() {
    let doc = VoiceExport.markdown(profile: StyleProfile(), records: [
        record("   ", daysAgo: 1),
        record("something real", daysAgo: 1),
    ])
    #expect(doc.contains("something real"))
    #expect(doc.contains("1 dictation,"), "the blank one should not have been counted")
}

@Test func dictationsAppearOldestFirst() {
    let doc = VoiceExport.markdown(profile: StyleProfile(), records: [
        record("said most recently", daysAgo: 1),
        record("said a week ago", daysAgo: 7),
    ])
    let firstIndex = doc.range(of: "said a week ago")!.lowerBound
    let secondIndex = doc.range(of: "said most recently")!.lowerBound
    #expect(firstIndex < secondIndex, "the older dictation should read first, like a transcript")
}

@Test func learnedTraitsAppearWhenSettledAndNotWhenGuessed() {
    var profile = StyleProfile()
    for _ in 0 ..< 5 { profile.spelling.record(.british, at: Date()) }
    let doc = VoiceExport.markdown(profile: profile, records: [])
    #expect(doc.contains("British spelling"))
    // Nothing else was ever taught, so nothing else should be asserted as fact.
    #expect(!doc.contains("Uses contractions"))
    #expect(!doc.contains("no contractions"))
}

@Test func theInstructionsTellTheReceivingModelWhatThisIsAndWhenToUseIt() {
    // The whole reason this exists rather than being a plain history dump:
    // handed to a model with no framing, a thousand of someone's sentences
    // reads as either "imitate this in every reply from now on" or "ignore
    // it" — neither of which is what "write like me" means.
    let doc = VoiceExport.markdown(profile: StyleProfile(), records: [])
    #expect(doc.contains("Quill"))
    #expect(doc.localizedCaseInsensitiveContains("only when"))
    #expect(doc.localizedCaseInsensitiveContains("do not quote"))
}

// MARK: - Writing to disk never touches the real data directory

@Test func writingNeverTouchesTheRealDataDirectoryByDefaultDuringATest() {
    // Same rule as every store's `init(url:)`: a self-test that can reach the
    // real file is a bug waiting for someone to run the suite once. `write`
    // takes an explicit destination for exactly this reason — this pins that
    // the parameter exists and actually redirects the write.
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-voice-export-\(UUID().uuidString)")
        .appendingPathComponent("my-voice-for-ai.md")
    defer { try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent()) }

    let result = VoiceExport.write(profile: StyleProfile(),
                                   records: [record("a real dictation", daysAgo: 1)],
                                   to: scratch)
    #expect(result?.url == scratch)
    #expect(FileManager.default.fileExists(atPath: scratch.path))
    let onDisk = try? String(contentsOf: scratch, encoding: .utf8)
    #expect(onDisk == result?.text)
    #expect(onDisk?.contains("a real dictation") == true)
}

@Test func theExportFileIsOnTheEraseList() {
    #expect(QuillData.files.map(\.lastPathComponent).contains("my-voice-for-ai.md"))
}
