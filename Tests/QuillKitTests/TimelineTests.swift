import Foundation
import Testing
@testable import QuillKit

// The instrumentation, pinned.
//
// This file exists because two of these numbers were wrong for the whole life of
// the project and nothing failed. `audioDurationMs` was nil on all 230 records on
// this Mac — the transcribers wrote it into a timeline of their own that nobody
// read — which silently emptied two Insights cards. And the latency card was
// showing key-DOWN to text under the words "key release to text on screen",
// which made a 3ms wait read as 12 seconds because the number contained however
// long the person had been speaking.
//
// Neither is the kind of bug a screenshot catches. Both are arithmetic.

private func stamp(_ seconds: Double, from base: Date) -> Date {
    base.addingTimeInterval(seconds)
}

@Test func releaseLatencyExcludesHowLongYouSpoke() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var t = DictationTimeline()
    t.hotkeyDown = start
    t.audioFirstBuffer = stamp(0.05, from: start)
    t.firstPartial = stamp(1.1, from: start)
    // Thirty seconds of talking.
    t.hotkeyUp = stamp(30, from: start)
    t.finalTranscript = stamp(30.2, from: start)
    t.textInserted = stamp(30.4, from: start)

    // The number a person waits through.
    #expect(t.releaseToInsertedMs == 400)
    // The number that contains the whole utterance. Both are real; only one of
    // them is a latency.
    #expect(t.endToEndMs == 30_400)
    #expect(t.timeToFirstWordMs == 1_100)
}

@Test func audioDurationIsMeasuredFromTheFirstBufferNotTheKeyPress() {
    let start = Date(timeIntervalSince1970: 2_000_000)
    var t = DictationTimeline()
    t.hotkeyDown = start
    // The microphone takes a moment to open. Counting from the key press would
    // inflate every spoken duration and depress every words-per-minute figure.
    t.audioFirstBuffer = stamp(0.3, from: start)
    t.finalTranscript = stamp(5.3, from: start)
    #expect(t.audioDurationMs == 5_000)
}

@Test func everyDurationIsNilUntilBothOfItsEndsExist() {
    var t = DictationTimeline()
    #expect(t.releaseToInsertedMs == nil)
    #expect(t.audioDurationMs == nil)

    t.hotkeyUp = Date()
    // One end is not a measurement. Reporting zero here would put a confident
    // 0.00s on the latency card for a dictation that never finished.
    #expect(t.releaseToInsertedMs == nil)
}

@Test func historyWrittenBeforeTheReleaseStampStillLoads() throws {
    // Verbatim shape of a record from the 230 already on this Mac: no
    // `releaseToInsertedMs` key at all.
    let json = """
    {"id":"\(UUID().uuidString)","date":781920000,"rawText":"hello there",
     "insertedText":"Hello there.","wordCount":2,"inputDevice":"BlackHole 2ch",
     "timings":{"timeToFirstWordMs":3070,"finalToInsertedMs":3,
                "endToEndMs":12244,"usedThoroughCleanup":false}}
    """
    let record = try JSONDecoder().decode(DictationRecord.self, from: Data(json.utf8))
    #expect(record.timings.releaseToInsertedMs == nil)
    #expect(record.timings.endToEndMs == 12_244)
}

@Test func theLatencyCardReportsNothingRatherThanTheWrongThing() {
    // Old records only. The card must not quietly substitute end-to-end, which
    // is the substitution that produced a 12.11s headline.
    let old = (1...50).map { i in
        DictationRecord(id: UUID(), date: Date().addingTimeInterval(-Double(i) * 3600),
                        rawText: "a b", insertedText: "A b.", wordCount: 2,
                        inputDevice: "BlackHole 2ch",
                        timings: .init(timeToFirstWordMs: 3_000, finalToInsertedMs: 3,
                                       endToEndMs: 12_000, audioDurationMs: nil,
                                       usedThoroughCleanup: false))
    }
    let m = InsightsMetrics.compute(records: old, vocabulary: Vocabulary(terms: []), range: .month)
    #expect(!m.hasReleaseLatency)
    #expect(m.releaseMs.isEmpty)
    #expect(m.endToEndP50 == 12_000, "the diagnostic is still there, it is just not the headline")
}

@Test func oneNewDictationIsEnoughToStartReportingRealLatency() {
    let fresh = DictationRecord(
        id: UUID(), date: Date(), rawText: "a b", insertedText: "A b.", wordCount: 2,
        inputDevice: "MacBook Air Microphone",
        timings: .init(timeToFirstWordMs: 900, finalToInsertedMs: 3, endToEndMs: 6_000,
                       audioDurationMs: 5_000, usedThoroughCleanup: false,
                       releaseToInsertedMs: 240))
    let m = InsightsMetrics.compute(records: [fresh], vocabulary: Vocabulary(terms: []), range: .month)
    #expect(m.hasReleaseLatency)
    #expect(m.releaseP50 == 240)
}

@Test func theSampleDataAgreesWithItself() {
    // The fixture used to generate a ~379ms "end to end", which only ever made
    // sense as a release latency — so sample history modelled a world the real
    // app could not produce, and the two disagreed by an order of magnitude on
    // the same card.
    for record in InsightsFixture.sample {
        let t = record.timings
        guard let release = t.releaseToInsertedMs, let e2e = t.endToEndMs,
              let audio = t.audioDurationMs else {
            Issue.record("sample record is missing a timing")
            continue
        }
        #expect(release < e2e, "you cannot finish before you stopped speaking")
        #expect(e2e >= audio, "end to end contains the whole utterance")
    }
}
