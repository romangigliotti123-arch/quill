import Foundation

// Everything the Insights screen shows, derived from `DictationRecord`s and
// nothing else.
//
// The rule this file exists to enforce: no number on that screen may be an
// estimate, a constant, or a percentile against a population we cannot see.
// Wispr Flow's Insights leads with "Top 6%" — a ranking against users we are
// not allowed to inspect, next to a words-per-minute figure it does not explain.
// Every field below is computable from this Mac's own history, and anything
// that needs an assumption (typing speed) states the assumption on screen.

// MARK: - Range

public enum InsightsRange: String, CaseIterable, Sendable {
    case week
    case month
    case all

    public var title: String {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .all: return "All time"
        }
    }

    public var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }

    public var phrase: String {
        switch self {
        case .week: return "in the last 7 days"
        case .month: return "in the last 30 days"
        case .all: return "since Quill was installed"
        }
    }

    public var comparisonPhrase: String {
        switch self {
        case .week: return "vs the 7 days before"
        case .month: return "vs the 30 days before"
        case .all: return "vs the first half"
        }
    }
}

// MARK: - Metrics

public struct InsightsMetrics: Sendable {

    /// One recogniser mistake Quill repaired, kept with the word it produced so
    /// the screen can name it. "16 dictionary fixes" is a number; "neglify →
    /// Netlify, seven times" is a reason to keep the dictionary.
    public struct Fix: Sendable, Equatable {
        public let heard: String
        public let written: String
        public let count: Int
        public let isDictionary: Bool
    }

    public struct Day: Sendable, Equatable {
        public let date: Date
        public let words: Int
        public let sessions: Int
    }

    public let range: InsightsRange
    public let generatedAt: Date

    // Volume
    public let sessions: Int
    public let totalWords: Int
    public let previousWords: Int
    /// Fraction, e.g. 0.18 for +18%. Nil when there is no prior window to
    /// compare against — a delta against zero history is theatre.
    public let wordsDelta: Double?
    public let dailyWords: [Day]

    // Pace, measured against the audio we actually recorded.
    public let medianWPM: Int
    public let wpmP10: Int
    public let wpmP90: Int
    public let speakingSeconds: Double

    /// The one stated assumption on the screen, held here so the caption and the
    /// arithmetic can never drift apart.
    public static let typingWPM: Double = 40
    public var typingSeconds: Double { Double(totalWords) / InsightsMetrics.typingWPM * 60 }
    public var savedSeconds: Double { max(0, typingSeconds - speakingSeconds) }

    // Latency — the measurement nobody else exposes.
    public let firstWordMs: [Double]
    public let endToEndMs: [Double]
    /// Key release → text on screen. The number a person actually waits through,
    /// and the one Flow's published 807ms is measured on. Empty for history
    /// written before the release moment was stamped, which is deliberate: those
    /// records genuinely do not contain it, and filling the gap with end-to-end
    /// would report a figure that includes however long the person was speaking.
    public let releaseMs: [Double]
    public let firstWordP50: Double
    public let endToEndP50: Double
    public let endToEndP90: Double
    public let endToEndP99: Double
    public let releaseP50: Double
    public let releaseP90: Double
    public let releaseP99: Double
    public let thoroughShare: Double

    /// True once any dictation has been recorded with the release stamp. The
    /// card shows "not measured yet" rather than a wrong number until then.
    public var hasReleaseLatency: Bool { !releaseMs.isEmpty }

    // Corrections
    public let wordsCorrected: Int
    public let dictionaryFixes: Int
    public let topFixes: [Fix]

    // Consistency
    public let heat: [Day]
    public let currentStreak: Int
    public let longestStreak: Int
    public let busiestDay: Day?
    public let activeDays: Int

    public var totalFixes: Int { wordsCorrected + dictionaryFixes }

    /// How far back the heatmap reaches. Ten months is the widest window that
    /// still leaves a cell you can aim a cursor at inside the panel — and, more
    /// importantly, a window Quill has actually been installed for, so the grid
    /// is mostly full rather than mostly grey.
    public static let heatWeeks = 44

    // MARK: Compute

    public static func compute(records: [DictationRecord],
                               vocabulary: Vocabulary = .load(),
                               range: InsightsRange = .month,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> InsightsMetrics {

        var cal = calendar
        cal.firstWeekday = 1

        let windowStart: Date? = range.days.map { cal.date(byAdding: .day, value: -$0, to: now)! }
        let inRange = records.filter { record in
            guard let windowStart else { return record.date <= now }
            return record.date > windowStart && record.date <= now
        }

        // The prior window of equal length. For "all time" that is the older
        // half of the history, which is the only honest analogue.
        let previous: [DictationRecord]
        if let days = range.days {
            let priorStart = cal.date(byAdding: .day, value: -days * 2, to: now)!
            let priorEnd = cal.date(byAdding: .day, value: -days, to: now)!
            previous = records.filter { $0.date > priorStart && $0.date <= priorEnd }
        } else if let oldest = records.map(\.date).min() {
            let midpoint = oldest.addingTimeInterval(now.timeIntervalSince(oldest) / 2)
            previous = records.filter { $0.date <= midpoint }
        } else {
            previous = []
        }

        let totalWords = inRange.reduce(0) { $0 + $1.wordCount }
        let previousWords = previous.reduce(0) { $0 + $1.wordCount }
        let delta: Double? = previousWords > 0
            ? (Double(totalWords) - Double(previousWords)) / Double(previousWords)
            : nil

        // Pace. Records with no audio duration cannot contribute a rate, and a
        // sub-second clip divides into nonsense — both are dropped rather than
        // clamped, because a clamped outlier still moves the median.
        let rates: [Double] = inRange.compactMap { record in
            guard let ms = record.timings.audioDurationMs, ms > 900, record.wordCount > 2 else { return nil }
            return Double(record.wordCount) / (Double(ms) / 60_000)
        }.sorted()
        let speakingSeconds = inRange.reduce(0.0) { $0 + Double($1.timings.audioDurationMs ?? 0) / 1000 }

        let firstWord = inRange.compactMap { $0.timings.timeToFirstWordMs.map(Double.init) }.sorted()
        let endToEnd = inRange.compactMap { $0.timings.endToEndMs.map(Double.init) }.sorted()
        let release = inRange.compactMap { $0.timings.releaseToInsertedMs.map(Double.init) }.sorted()
        let thorough = inRange.filter { $0.timings.usedThoroughCleanup }.count
        let thoroughShare = inRange.isEmpty ? 0 : Double(thorough) / Double(inRange.count)

        let corrections = Corrections.tally(inRange, vocabulary: vocabulary)

        // Daily series for the sparkline: dense across the window, because a
        // sparkline that skips empty days draws a flat line through a week off.
        let dailyWindow = range.days ?? max(1, daysBetween(records.map(\.date).min() ?? now, now, cal))
        let dailyWords = densify(records: inRange, days: min(dailyWindow, 120), endingAt: now, calendar: cal)

        // Heatmap window is deliberately independent of the range control: a
        // streak is a property of the whole history, not of the last 7 days.
        let heatDays = heatWeeks * 7
        let heatEnd = endOfWeek(containing: now, calendar: cal)
        let heat = densify(records: records, days: heatDays, endingAt: heatEnd, calendar: cal)
        let streaks = streakLengths(heat, now: now, calendar: cal)

        return InsightsMetrics(
            range: range,
            generatedAt: now,
            sessions: inRange.count,
            totalWords: totalWords,
            previousWords: previousWords,
            wordsDelta: delta,
            dailyWords: dailyWords,
            medianWPM: Int(percentile(rates, 0.5).rounded()),
            wpmP10: Int(percentile(rates, 0.10).rounded()),
            wpmP90: Int(percentile(rates, 0.90).rounded()),
            speakingSeconds: speakingSeconds,
            firstWordMs: firstWord,
            endToEndMs: endToEnd,
            releaseMs: release,
            firstWordP50: percentile(firstWord, 0.5),
            endToEndP50: percentile(endToEnd, 0.5),
            endToEndP90: percentile(endToEnd, 0.9),
            endToEndP99: percentile(endToEnd, 0.99),
            releaseP50: percentile(release, 0.5),
            releaseP90: percentile(release, 0.9),
            releaseP99: percentile(release, 0.99),
            thoroughShare: thoroughShare,
            wordsCorrected: corrections.words,
            dictionaryFixes: corrections.dictionary,
            topFixes: corrections.top,
            heat: heat,
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            busiestDay: heat.max(by: { $0.words < $1.words }).flatMap { $0.words > 0 ? $0 : nil },
            activeDays: heat.filter { $0.sessions > 0 }.count
        )
    }

    // MARK: Helpers

    /// Linear-interpolated percentile on a sorted array. Nearest-rank jumps in
    /// visible steps on small samples, which makes a median look like it is
    /// snapping to individual dictations.
    public static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let t = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * t
    }

    private static func daysBetween(_ a: Date, _ b: Date, _ cal: Calendar) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day ?? 0
    }

    private static func endOfWeek(containing date: Date, calendar cal: Calendar) -> Date {
        let start = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: start)   // 1 = Sunday
        return cal.date(byAdding: .day, value: 7 - weekday, to: start)!
    }

    /// One entry per calendar day, zeroes included.
    private static func densify(records: [DictationRecord],
                                days: Int,
                                endingAt end: Date,
                                calendar cal: Calendar) -> [Day] {
        let lastDay = cal.startOfDay(for: end)
        var words: [Date: Int] = [:]
        var counts: [Date: Int] = [:]
        for record in records {
            let day = cal.startOfDay(for: record.date)
            words[day, default: 0] += record.wordCount
            counts[day, default: 0] += 1
        }
        return (0..<days).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: lastDay)!
            return Day(date: day, words: words[day] ?? 0, sessions: counts[day] ?? 0)
        }
    }

    /// Current streak counts back from today, and tolerates a today that has not
    /// happened yet — at 9am a run of thirty days should not read as zero
    /// because you have not dictated since breakfast.
    private static func streakLengths(_ days: [Day], now: Date, calendar cal: Calendar) -> (current: Int, longest: Int) {
        var longest = 0
        var run = 0
        for day in days {
            run = day.sessions > 0 ? run + 1 : 0
            longest = max(longest, run)
        }

        let today = cal.startOfDay(for: now)
        var current = 0
        var cursor = today
        let index = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0.sessions) })
        if (index[today] ?? 0) == 0 {
            cursor = cal.date(byAdding: .day, value: -1, to: today)!
        }
        while (index[cursor] ?? 0) > 0 {
            current += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, longest)
    }
}

// MARK: - Corrections

/// What the cleanup pass changed, recovered by aligning the raw transcript
/// against what was inserted.
///
/// Storing raw and inserted separately is what makes this possible at all — the
/// same split the comparison rig needs to score accuracy and formatting apart.
/// A single "text" column would leave this screen with nothing to show but a
/// word count.
enum Corrections {

    struct Tally {
        var words = 0
        var dictionary = 0
        var top: [InsightsMetrics.Fix] = []
    }

    /// Multi-word entries have to match a single token too — the recogniser
    /// hears "no acuss", cleanup writes "Noah Kass", and the fix that matters is
    /// the surname. The stoplist keeps ordinary English inside those phrases
    /// ("next", "co") from claiming credit for a fix it had nothing to do with.
    private static let phraseStoplist: Set<String> = ["next", "co", "the", "and", "of", "a"]

    static func vocabularyTokens(_ vocabulary: Vocabulary) -> Set<String> {
        var terms = Set<String>()
        for phrase in vocabulary.contextualStrings {
            let lower = phrase.lowercased()
            terms.insert(lower)
            for word in lower.split(separator: " ") where !phraseStoplist.contains(String(word)) {
                terms.insert(String(word))
            }
        }
        return terms
    }

    static func tally(_ records: [DictationRecord], vocabulary: Vocabulary) -> Tally {
        let terms = vocabularyTokens(vocabulary)
        var tally = Tally()
        var pairs: [String: (heard: String, written: String, count: Int, dictionary: Bool)] = [:]

        for record in records {
            let before = tokenize(record.rawText)
            let after = tokenize(record.insertedText)
            guard !before.isEmpty, !after.isEmpty else { continue }

            for change in align(before, after) {
                switch change {
                case let .substitute(from, to):
                    let isDictionary = terms.contains(normalise(to))
                    if isDictionary { tally.dictionary += 1 } else { tally.words += 1 }
                    let key = normalise(from) + "→" + normalise(to)
                    let existing = pairs[key]
                    pairs[key] = (from, to, (existing?.count ?? 0) + 1, isDictionary)
                case .insert, .delete:
                    tally.words += 1
                }
            }
        }

        tally.top = pairs.values
            .sorted { ($0.count, $0.written) > ($1.count, $1.written) }
            .prefix(8)
            .map { InsightsMetrics.Fix(heard: $0.heard, written: $0.written,
                                       count: $0.count, isDictionary: $0.dictionary) }
        return tally
    }

    enum Change {
        case substitute(String, String)
        case insert(String)
        case delete(String)
    }

    /// Tokens with no letters or digits in them are dropped outright. Quill's
    /// cleanup adds an em dash to roughly every second dictation, and counting a
    /// dash as a corrected word would put the fix total within a rounding error
    /// of the sentence count.
    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !normalise($0).isEmpty }
    }

    /// Case and punctuation are stripped for *matching* only. Quill adds a full
    /// stop to almost every dictation; counting that as a correction would put
    /// the fix count within a rounding error of the sentence count and mean
    /// nothing.
    static func normalise(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Classic LCS alignment. Runs of unmatched tokens on both sides are paired
    /// off as substitutions; the remainder are insertions or deletions.
    static func align(_ before: [String], _ after: [String]) -> [Change] {
        let a = before.map(normalise)
        let b = after.map(normalise)
        let n = a.count, m = b.count

        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j]
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var changes: [Change] = []
        var i = 0, j = 0
        var removed: [String] = []
        var added: [String] = []

        func flush() {
            let shared = min(removed.count, added.count)
            for k in 0..<shared { changes.append(.substitute(removed[k], added[k])) }
            for k in shared..<removed.count { changes.append(.delete(removed[k])) }
            for k in shared..<added.count { changes.append(.insert(added[k])) }
            removed.removeAll()
            added.removeAll()
        }

        while i < n && j < m {
            if a[i] == b[j] {
                flush()
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                removed.append(before[i]); i += 1
            } else {
                added.append(after[j]); j += 1
            }
        }
        while i < n { removed.append(before[i]); i += 1 }
        while j < m { added.append(after[j]); j += 1 }
        flush()
        return changes
    }
}

// MARK: - Formatting

public enum InsightsFormat {

    private static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter
    }()

    public static func count(_ value: Int) -> String {
        grouped.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "1h 52m" / "48m" / "2m". The unit is part of the number here rather than
    /// a caption, because "1h 52m" has no honest single unit.
    public static func duration(_ seconds: Double) -> [(text: String, isUnit: Bool)] {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return [("\(hours)", false), ("h ", true), ("\(minutes)", false), ("m", true)]
        }
        if minutes > 0 {
            return [("\(minutes)", false), ("m", true)]
        }
        return [("\(total)", false), ("s", true)]
    }

    /// Milliseconds shown in seconds to two places. A latency screen that prints
    /// "382 ms" beside "0.71 s" is asking the reader to do the conversion.
    public static func seconds(_ ms: Double) -> String {
        String(format: "%.2f", ms / 1000)
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((abs(fraction) * 100).rounded()))%"
    }

    public static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    public static func monthLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }
}
