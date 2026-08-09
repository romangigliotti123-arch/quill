import AppKit
import Testing
@testable import QuillKit

// The Dictionary screen's whole claim is that it shows which entries actually
// fired. Two things have to hold for that claim to survive: the repair
// detection has to find real repairs and refuse to credit ordinary cleanup to
// the dictionary, and the numbers on the screen have to agree with each other.

@Test func repairDetectionFindsTheSpanTheRecogniserGotWrong() {
    let pairs = DictionaryEntry.repairs(
        raw: "push the neglify build once the fire store rules land",
        inserted: "Push the Netlify build once the Firestore rules land.",
        terms: ["Netlify", "Firestore"])

    #expect(pairs.count == 2)
    #expect(pairs.contains { $0.0 == "neglify" && $0.1 == "Netlify" })
    // The interesting half: one word came back as two, and the pair has to be
    // the whole span, not the first token of it.
    #expect(pairs.contains { $0.0 == "fire store" && $0.1 == "Firestore" })
}

@Test func ordinaryCleanupIsNotCreditedToTheDictionary() {
    // Filler removal, punctuation and casing all change the text without any
    // dictionary term being involved. Counting these as repairs is how a
    // dictionary reports that it is working when it is doing nothing at all.
    let pairs = DictionaryEntry.repairs(
        raw: "um so we should probably ship it i think",
        inserted: "We should ship it.",
        terms: ["Netlify", "graphify"])
    #expect(pairs.isEmpty)

    // A term already correct in the raw transcript was not repaired.
    let untouched = DictionaryEntry.repairs(raw: "the Netlify build is green",
                                            inserted: "The Netlify build is green.",
                                            terms: ["Netlify"])
    #expect(untouched.isEmpty)
}

@Test func derivingFromHistoryCountsRepeatsAndSortsByVolume() {
    let record = { (raw: String, clean: String) in
        DictationRecord(id: UUID(), date: Date(), rawText: raw, insertedText: clean,
                        wordCount: clean.split(separator: " ").count, inputDevice: nil,
                        timings: .init(timeToFirstWordMs: nil, finalToInsertedMs: nil,
                                       endToEndMs: nil, audioDurationMs: nil,
                                       usedThoroughCleanup: false))
    }
    let entries = DictionaryEntry.derive(
        vocabulary: Vocabulary(terms: ["Netlify", "graphify", "Vesper"]),
        records: [
            record("the neglify build", "The Netlify build"),
            record("neglify again", "Netlify again"),
            record("run graph if I", "Run graphify"),
        ])

    #expect(entries.first?.term == "Netlify")
    #expect(entries.first?.repairs == 2)
    #expect(entries.first?.mishearings.first?.heard == "neglify")
    #expect(entries.first(where: { $0.term == "graphify" })?.repairs == 1)
    // A term that never appeared has to come back as unused, not be dropped —
    // the unused count is the screen's honesty check.
    let vesper = entries.first { $0.term == "Vesper" }
    #expect(vesper?.hasFired == false)
    #expect(vesper?.lastFired == nil)
}

@Test func aFreshInstallGetsTheFixtureRatherThanAnEmptyShell() {
    #expect(DictionaryEntry.entries(vocabulary: .seed, records: []) == DictionaryEntry.preview)
    // ...but real history is never overridden by the fixture, however dull it is.
    let entries = DictionaryEntry.entries(
        vocabulary: Vocabulary(terms: ["Netlify"]),
        records: [DictationRecord(id: UUID(), date: Date(), rawText: "the neglify build",
                                  insertedText: "The Netlify build", wordCount: 3, inputDevice: nil,
                                  timings: .init(timeToFirstWordMs: nil, finalToInsertedMs: nil,
                                                 endToEndMs: nil, audioDurationMs: nil,
                                                 usedThoroughCleanup: false))])
    #expect(entries.count == 1)
    #expect(entries[0].term == "Netlify")
}

@Test func theWeeklyChartAlwaysAddsUpToTheNumberBesideIt() {
    // The chart is derived from the total rather than stored, which is only
    // safe while the two cannot disagree.
    for entry in DictionaryEntry.preview {
        let weekly = entry.weekly
        #expect(weekly.count == 8)
        #expect(weekly.reduce(0, +) == entry.repairs, "\(entry.term) chart disagrees with its count")
        #expect(weekly.allSatisfy { $0 >= 0 })
    }
    // Deterministic: a chart that reshuffles every launch is not a chart.
    #expect(DictionaryEntry.preview[0].weekly == DictionaryEntry.preview[0].weekly)
}

@Test @MainActor func theSectionRendersWithoutOverlappingItsFootnote() {
    let view = DictionarySectionView(style: .light, entries: DictionaryEntry.preview)
    view.frame = DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize)
    view.layoutSubtreeIfNeeded()

    // Every subview has to be inside the panel: the shell clips to the panel's
    // corner radius, so anything outside is silently gone rather than obviously
    // wrong.
    for child in view.subviews where !child.isHidden {
        #expect(view.bounds.contains(child.frame),
                "\(type(of: child)) escapes the panel: \(child.frame) vs \(view.bounds)")
    }
    #expect(view.subviews.contains { $0 is DictionaryListView })
    #expect(view.subviews.contains { $0 is DictionaryDetailView })
}

@Test @MainActor func theInspectorDropsBlocksRatherThanDrawingThroughItsFootnote() {
    let entry = DictionaryEntry.preview[0]
    for height in stride(from: 460.0, through: 150.0, by: -30.0) {
        let detail = DictionaryDetailView(entry: entry, style: .light)
        detail.frame = NSRect(x: 0, y: 0, width: 366, height: height)
        detail.layoutSubtreeIfNeeded()

        let footnote = detail.subviews.compactMap { $0 as? NSTextField }.last
        let top = try! #require(footnote).frame.minY
        for child in detail.subviews where !child.isHidden && child !== footnote {
            #expect(child.frame.maxY <= top + 1,
                    "\(type(of: child)) overlaps the footnote at height \(height)")
        }
    }
}
