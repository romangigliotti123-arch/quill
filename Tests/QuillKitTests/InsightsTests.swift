import AppKit
import Testing
@testable import QuillKit

// The Insights screen is the one place in Quill where a wrong number looks
// exactly like a right one, so the arithmetic is pinned here rather than checked
// by eye against a render.
//
// Nothing in this file touches the real `HistoryStore`. Every test builds its
// own records — a test that reads the user's dictation history to check a
// median is one refactor away from writing to it.

// MARK: - Helpers

private extension DictationRecord {
    /// Midday on the day `daysAgo` days before `now`, in the current calendar.
    static func midday(daysAgo: Int, from now: Date) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }
}

private func record(daysAgo: Int,
                    words: Int = 10,
                    raw: String = "hello there",
                    inserted: String = "Hello there.",
                    firstWord: Int = 200,
                    endToEnd: Int = 400,
                    audioMs: Int = 5_000,
                    now: Date = Date()) -> DictationRecord {
    DictationRecord(
        id: UUID(),
        // Anchored to midday of the target day, not "now minus an hour".
        //
        // The old form subtracted a day and then an hour, so between midnight and
        // 1am every record landed on the calendar day BEFORE the one intended and
        // the streak assertions failed. A test that passes 23 hours out of 24 is
        // worse than one that fails, because it teaches you to re-run it.
        date: DictationRecord.midday(daysAgo: daysAgo, from: now),
        rawText: raw,
        insertedText: inserted,
        wordCount: words,
        inputDevice: "MacBook Air Microphone",
        timings: DictationRecord.Timings(timeToFirstWordMs: firstWord,
                                         finalToInsertedMs: 80,
                                         endToEndMs: endToEnd,
                                         audioDurationMs: audioMs,
                                         usedThoroughCleanup: true))
}

// MARK: - Corrections

@Test func alignmentPairsMisheardWordsWithWhatWasWritten() {
    let changes = Corrections.align(
        Corrections.tokenize("push the neglify build um before thursday"),
        Corrections.tokenize("Push the Netlify build before Thursday."))

    var substitutions: [(String, String)] = []
    var deletions: [String] = []
    for change in changes {
        switch change {
        case let .substitute(from, to): substitutions.append((from, to))
        case let .delete(word): deletions.append(word)
        case .insert: break
        }
    }
    #expect(substitutions.count == 1)
    #expect(substitutions.first?.0 == "neglify")
    #expect(substitutions.first?.1 == "Netlify")
    #expect(deletions == ["um"])
}

@Test func casingAndPunctuationAreNotCountedAsCorrections() {
    // Quill capitalises and adds a full stop to almost everything it inserts.
    // Counting those would put the fix total within a rounding error of the
    // sentence count and make the whole card meaningless.
    let changes = Corrections.align(
        Corrections.tokenize("book the melbourne flight tonight"),
        Corrections.tokenize("Book the Melbourne flight tonight."))
    #expect(changes.isEmpty)
}

@Test func emDashesInsertedByCleanupAreNotWords() {
    #expect(Corrections.tokenize("land — Carlo needs it") == ["land", "Carlo", "needs", "it"])
}

@Test func dictionaryFixesAreCountedSeparatelyFromOrdinaryOnes() {
    let vocabulary = Vocabulary(terms: ["Netlify", "Noah Kass"])
    let tally = Corrections.tally([
        record(daysAgo: 1, raw: "push the neglify build um now", inserted: "Push the Netlify build now."),
        record(daysAgo: 1, raw: "tell nokas about it", inserted: "Tell Noah Kass about it."),
    ], vocabulary: vocabulary)

    // neglify→Netlify and nokas→Noah are dictionary hits; the deleted "um" and
    // the inserted "Kass" are ordinary cleanup.
    #expect(tally.dictionary == 2)
    #expect(tally.words == 2)
    #expect(tally.top.contains { $0.written == "Netlify" && $0.isDictionary })
}

@Test func multiWordVocabularyEntriesStillMatchASingleToken() {
    let tokens = Corrections.vocabularyTokens(Vocabulary(terms: ["Next Fulfilment", "Noah Kass"]))
    #expect(tokens.contains("kass"))
    #expect(tokens.contains("fulfilment"))
    // "next" is ordinary English and must not claim credit for a fix.
    #expect(!tokens.contains("next"))
}

// MARK: - Statistics

@Test func percentilesInterpolateRatherThanSnapToASample() {
    let sorted: [Double] = [100, 200, 300, 400, 500]
    #expect(InsightsMetrics.percentile(sorted, 0) == 100)
    #expect(InsightsMetrics.percentile(sorted, 1) == 500)
    #expect(InsightsMetrics.percentile(sorted, 0.5) == 300)
    #expect(abs(InsightsMetrics.percentile(sorted, 0.25) - 200) < 0.001)
    #expect(InsightsMetrics.percentile([], 0.5) == 0)
}

@Test func totalsAndDeltasComeFromTheWindowTheyClaim() {
    let now = Date()
    let records = (0..<10).map { record(daysAgo: $0 * 2 + 1, words: 100, now: now) }   // 5 inside 30 days
        + (0..<4).map { record(daysAgo: 35 + $0, words: 50, now: now) }                 // 4 in the window before

    let m = InsightsMetrics.compute(records: records, vocabulary: Vocabulary(terms: []),
                                    range: .month, now: now)
    #expect(m.sessions == 10)
    #expect(m.totalWords == 1_000)
    #expect(m.previousWords == 200)
    #expect(m.wordsDelta != nil)
    #expect(abs((m.wordsDelta ?? 0) - 4.0) < 0.0001)
}

@Test func aWindowWithNoHistoryBeforeItShowsNoDelta() {
    let now = Date()
    let m = InsightsMetrics.compute(records: [record(daysAgo: 1, now: now)],
                                    vocabulary: Vocabulary(terms: []), range: .month, now: now)
    #expect(m.wordsDelta == nil)
}

@Test func paceIgnoresClipsTooShortToDivide() {
    let now = Date()
    let records = [
        record(daysAgo: 1, words: 100, audioMs: 60_000, now: now),  // 100 wpm
        record(daysAgo: 2, words: 200, audioMs: 60_000, now: now),  // 200 wpm
        record(daysAgo: 3, words: 40, audioMs: 200, now: now),      // 12,000 wpm — nonsense
    ]
    let m = InsightsMetrics.compute(records: records, vocabulary: Vocabulary(terms: []),
                                    range: .month, now: now)
    #expect(m.medianWPM == 150)
}

@Test func theCurrentStreakStopsAtTheFirstMissedDay() {
    let now = Date()
    // Today, yesterday, the day before — then a gap, then more.
    let records = [0, 1, 2, 4, 5, 6, 7].map { record(daysAgo: $0, now: now) }
    let m = InsightsMetrics.compute(records: records, vocabulary: Vocabulary(terms: []),
                                    range: .all, now: now)
    #expect(m.currentStreak == 3)
    #expect(m.longestStreak == 4)
    #expect(m.activeDays == 7)
}

@Test func aStreakSurvivesADayThatHasNotHappenedYet() {
    // Checking Insights at 9am should not report a broken streak just because
    // you have not dictated since breakfast.
    let now = Date()
    let records = (1...5).map { record(daysAgo: $0, now: now) }
    let m = InsightsMetrics.compute(records: records, vocabulary: Vocabulary(terms: []),
                                    range: .all, now: now)
    #expect(m.currentStreak == 5)
}

@Test func timeSavedStatesItsAssumptionAndNeverGoesNegative() {
    let now = Date()
    // 400 words spoken in 2 minutes. Typing at 40 wpm would take 10 minutes.
    let m = InsightsMetrics.compute(records: [record(daysAgo: 1, words: 400, audioMs: 120_000, now: now)],
                                    vocabulary: Vocabulary(terms: []), range: .month, now: now)
    #expect(InsightsMetrics.typingWPM == 40)
    #expect(abs(m.typingSeconds - 600) < 0.001)
    #expect(abs(m.savedSeconds - 480) < 0.001)

    // Someone speaking slower than they type must not be shown a negative saving.
    let slow = InsightsMetrics.compute(records: [record(daysAgo: 1, words: 10, audioMs: 600_000, now: now)],
                                       vocabulary: Vocabulary(terms: []), range: .month, now: now)
    #expect(slow.savedSeconds == 0)
}

@Test func theHeatmapGridStartsOnASundayAndIsWholeWeeks() {
    let now = Date()
    let m = InsightsMetrics.compute(records: [record(daysAgo: 1, now: now)],
                                    vocabulary: Vocabulary(terms: []), range: .month, now: now)
    #expect(m.heat.count == InsightsMetrics.heatWeeks * 7)
    // The view maps index % 7 straight to a weekday row, which is only correct
    // if the series begins on a Sunday.
    #expect(Calendar.current.component(.weekday, from: m.heat[0].date) == 1)
}

// MARK: - Fixture

@Test func theFixtureIsDeterministicAndDenseEnoughToDraw() {
    let now = Date()
    let a = InsightsFixture.records(now: now)
    let b = InsightsFixture.records(now: now)
    #expect(a.count == b.count)
    #expect(a.first?.rawText == b.first?.rawText)
    #expect(a.count > InsightsFixture.minimumRealRecords * 10)

    // Newest first, matching HistoryStore's contract — the whole screen reads
    // index 0 as "most recent".
    #expect(zip(a, a.dropFirst()).allSatisfy { $0.date >= $1.date })
    #expect(a.allSatisfy { $0.date <= now })

    let m = InsightsMetrics.compute(records: a, range: .month, now: now)
    #expect(m.totalWords > 0)
    #expect(m.medianWPM > 60 && m.medianWPM < 260)
    #expect(m.endToEndP50 > 0 && m.endToEndP50 < m.endToEndP90)
    #expect(m.endToEndP90 < m.endToEndP99)
    #expect(m.dictionaryFixes > 0)
    // Two identical streak numbers on one card read as broken arithmetic.
    #expect(m.longestStreak > m.currentStreak)
}

// MARK: - Layout

@Test @MainActor func nothingOnTheScreenIsDrawnOutsideItsContainer() throws {
    // The regression this exists for: the streak card's stats column ran a
    // caption through the bottom edge of its own card, and the render still
    // looked fine at a glance.
    let panel = DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize)
    let view = InsightsView(records: InsightsFixture.sample,
                            vocabulary: .seed,
                            isSample: true,
                            style: .light)
    view.frame = NSRect(origin: .zero, size: panel.size)
    view.layoutSubtreeIfNeeded()

    func check(_ parent: NSView, path: String) {
        for child in parent.subviews where !child.isHidden {
            let frame = child.frame
            #expect(frame.minX >= -0.5, "\(path) overflows left by \(-frame.minX)")
            #expect(frame.minY >= -0.5, "\(path) overflows top by \(-frame.minY)")
            #expect(frame.maxX <= parent.bounds.width + 0.5,
                    "\(path) overflows right by \(frame.maxX - parent.bounds.width)")
            #expect(frame.maxY <= parent.bounds.height + 0.5,
                    "\(path) overflows bottom by \(frame.maxY - parent.bounds.height)")
            check(child, path: path + " > " + String(describing: type(of: child)))
        }
    }
    check(view, path: "InsightsView")
}

@Test @MainActor func changingTheRangeChangesTheNumbers() throws {
    let view = InsightsView(records: InsightsFixture.sample,
                            vocabulary: .seed, isSample: true, style: .dark)
    view.frame = NSRect(origin: .zero, size: DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize).size)
    view.layoutSubtreeIfNeeded()

    func headlineWords() -> String? {
        func find(_ view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? find($0) }
        }
        return find(view).map(\.attributedStringValue.string).first { $0.hasSuffix("  words") }
    }

    let month = headlineWords()
    // Recursive, like `headlineWords` above. A direct-subview search silently
    // returned nil the moment the page gained a scroll view, and a nil optional
    // chained into `?.selectedIndex` changes nothing and reports nothing — the
    // test went on to compare the month figure against itself.
    func findSegmented(_ view: NSView) -> InsightsSegmented? {
        for child in view.subviews {
            if let hit = child as? InsightsSegmented { return hit }
            if let hit = findSegmented(child) { return hit }
        }
        return nil
    }
    let segmented = try #require(findSegmented(view))
    segmented.selectedIndex = 0        // 7 days
    view.layoutSubtreeIfNeeded()
    let week = headlineWords()

    #expect(month != nil)
    #expect(week != nil)
    #expect(month != week)
}

@Test @MainActor func theHeatmapOnlyReportsASquareWhenTheCursorIsOnOne() {
    let m = InsightsMetrics.compute(records: InsightsFixture.sample, range: .month)
    let heatmap = InsightsHeatmap(days: m.heat, style: .light)
    heatmap.frame = NSRect(x: 0, y: 0, width: heatmap.intrinsicWidth, height: heatmap.intrinsicHeight)

    let pitch = heatmap.cell + heatmap.gap
    // Dead centre of the third column, second row.
    let inside = NSPoint(x: heatmap.labelColumn + pitch * 2 + heatmap.cell / 2,
                         y: heatmap.monthRow + pitch * 1 + heatmap.cell / 2)
    #expect(heatmap.index(at: inside) == 2 * 7 + 1)

    // The gutter between two squares is not a square.
    let gutter = NSPoint(x: heatmap.labelColumn + pitch * 2 + heatmap.cell + 1,
                         y: heatmap.monthRow + pitch * 1 + heatmap.cell / 2)
    #expect(heatmap.index(at: gutter) == nil)
    #expect(heatmap.index(at: NSPoint(x: 2, y: 2)) == nil)
}

@Test @MainActor func theShellRendersTheRealSectionRatherThanThePlaceholder() {
    let root = DashboardRootView(style: .light, selection: .insights,
                                 provider: InsightsOnlyProvider())
    root.frame = NSRect(origin: .zero, size: DashboardMetrics.windowSize)
    root.layoutSubtreeIfNeeded()

    func contains(_ view: NSView) -> Bool {
        view is InsightsView || view.subviews.contains(where: contains)
    }
    #expect(contains(root))
}

/// Keeps the shell test off the real `HistoryStore` — the shipping registry
/// reads it, and a test has no business opening a user's dictation history.
private final class InsightsOnlyProvider: DashboardSectionProvider {
    func dashboardView(for section: DashboardSection, style: DashboardStyle) -> NSView? {
        guard section == .insights else { return nil }
        return InsightsView(records: InsightsFixture.sample, vocabulary: .seed, isSample: true, style: style)
    }
}

@Test func theStreakDenominatorCountsOnlyDaysSinceTheFirstDictation() {
    // It used to be the whole heatmap window. On a fresh install that read
    // "3 days you dictated on, out of 308" — counting 305 days before Quill
    // existed as days the user failed to use it. Arithmetically true, and it
    // tells the reader something false about themselves, on a screen whose only
    // job is to be trusted with numbers.
    let now = Date()
    let day: TimeInterval = 86_400
    let records = (0 ..< 3).map { offset in
        DictationRecord(id: UUID(), date: now.addingTimeInterval(-Double(offset) * day),
                        rawText: "a b c", insertedText: "A b c.", wordCount: 3,
                        inputDevice: "test",
                        timings: .init(timeToFirstWordMs: 200, finalToInsertedMs: 10,
                                       endToEndMs: 900, audioDurationMs: 1200,
                                       usedThoroughCleanup: false, releaseToInsertedMs: 30))
    }
    let metrics = InsightsMetrics.compute(records: records, vocabulary: Vocabulary(terms: []),
                                          range: .all, now: now)

    // Three calendar days of history, possibly four squares if "now" is early in
    // the day and the heat window ends on a week boundary.
    #expect((3 ... 4).contains(metrics.observedDays),
            "denominator was \(metrics.observedDays) for three days of history")
    #expect(metrics.activeDays <= metrics.observedDays,
            "more active days than days observed")
    #expect(metrics.heat.count > metrics.observedDays,
            "the heatmap should still draw its full window — only the ratio is scoped")
    #expect(metrics.firstRecord != nil)
}

@Test func aClipPlayedThroughALoopbackIsNotADictation() {
    // 684 of the 696 records on this Mac are eval clips fed through BlackHole.
    // Insights counted every one, and told Roman he had dictated 14,145 words in
    // thirty days, at 81 wpm, saving 3h 59m against typing — statistics about a
    // test harness, presented as facts about him.
    func record(device: String?) -> DictationRecord {
        DictationRecord(id: UUID(), date: Date(), rawText: "a b c", insertedText: "A b c.",
                        wordCount: 3, inputDevice: device,
                        timings: .init(timeToFirstWordMs: 200, finalToInsertedMs: 10,
                                       endToEndMs: 900, audioDurationMs: 1200,
                                       usedThoroughCleanup: false, releaseToInsertedMs: 30))
    }
    #expect(record(device: "BlackHole 2ch").isMeasurement)
    #expect(record(device: "Loopback Audio").isMeasurement)
    #expect(!record(device: "MacBook Air Microphone").isMeasurement)
    // No device recorded is not evidence of a loopback, and guessing against the
    // user here would quietly delete real dictations from their own statistics.
    #expect(!record(device: nil).isMeasurement)
}
