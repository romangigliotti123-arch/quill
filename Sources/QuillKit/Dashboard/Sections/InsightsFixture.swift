import Foundation

/// A plausible ten months of dictation, generated deterministically.
///
/// This exists for exactly one reason: a statistics screen with no statistics is
/// not reviewable. An empty Insights page tells you nothing about whether the
/// median marker collides with the p90 label, whether four digits fit in the
/// word count, or whether the heatmap reads as a grid or as noise — and those
/// are the only questions worth asking of the design.
///
/// It is never written to `HistoryStore`. It is substituted in memory when the
/// real history is too thin to draw, and the screen says so in the corner rather
/// than passing invented numbers off as measurements.
public enum InsightsFixture {

    /// Below this the charts are shapeless and the percentiles are noise.
    public static let minimumRealRecords = 40

    /// Built once. The dashboard rebuilds every section view on a theme switch
    /// and on every sidebar click, and regenerating three thousand records plus
    /// their diffs on each of those is a visible stall for data that cannot
    /// change.
    public static let sample: [DictationRecord] = records()

    public static func records(now: Date = Date(), seed: UInt64 = 0x5175_696C_6C00_0001) -> [DictationRecord] {
        var random = SeededRandom(seed: seed)
        var calendar = Calendar.current
        calendar.firstWeekday = 1

        let span = InsightsMetrics.heatWeeks * 7 + 6
        let today = calendar.startOfDay(for: now)
        var out: [DictationRecord] = []

        for offset in stride(from: span - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let isWeekend = weekday == 1 || weekday == 7

            // Usage ramps: the first month is someone trying it, the last month
            // is someone who has stopped noticing they are using it.
            let maturity = 0.42 + 0.72 * (Double(span - offset) / Double(span))

            // Two guaranteed runs: a current one, so the streak card has
            // something true to report, and a longer one back in autumn so the
            // "longest run" stat is not a duplicate of it. Two identical streak
            // numbers on one card read as a bug in the arithmetic, not as a
            // coincidence.
            let guaranteed = offset < 19 || (offset >= 118 && offset < 154)
            let active = guaranteed || random.unit() < (isWeekend ? 0.44 : 0.90) * min(1, maturity + 0.15)
            guard active else { continue }

            let base = isWeekend ? 3.0 : 11.0
            let count = max(1, Int((base * maturity * (0.55 + random.unit() * 0.9)).rounded()))

            for _ in 0..<count {
                out.append(make(on: day, calendar: calendar, random: &random, now: now))
            }
        }

        // Newest first, matching HistoryStore's contract.
        return out.sorted { $0.date > $1.date }
    }

    // MARK: - One dictation

    private static func make(on day: Date,
                             calendar: Calendar,
                             random: inout SeededRandom,
                             now: Date) -> DictationRecord {
        // Two humps: the morning block and the after-lunch block. A flat hour
        // distribution is the tell of generated data.
        let hour = random.unit() < 0.58
            ? 8 + Int(random.unit() * 4)
            : 13 + Int(random.unit() * 6)
        let minute = Int(random.unit() * 60)
        let second = Int(random.unit() * 60)
        var date = calendar.date(bySettingHour: hour, minute: minute, second: second, of: day) ?? day
        if date > now { date = now.addingTimeInterval(-Double(random.int(60...5_400))) }

        // A quarter of dictations are two thoughts in one breath, which is what
        // gives the word count and pace a spread rather than a spike.
        var raw = ""
        var inserted = ""
        let parts = random.unit() < 0.26 ? 2 : 1
        for index in 0..<parts {
            let sample = lines[random.int(0...(lines.count - 1))]
            raw += (index == 0 ? "" : " ") + sample.raw
            inserted += (index == 0 ? "" : " ") + sample.inserted
        }

        let words = inserted.split(whereSeparator: { $0 == " " }).count

        // Speaking rate, then the silence at either end of the hold — the audio
        // is always a little longer than the words justify.
        let rate = min(198, max(96, 149 + random.normal() * 21))
        let speech = Double(words) / rate * 60_000
        let audio = Int((speech + 520 + random.unit() * 900).rounded())

        let firstWord = Int(random.logNormal(median: 206, sigma: 0.46).clamped(to: 118...940))
        // This distribution was always modelling release → text — a median of
        // 379ms only makes sense as "how long after you let go". It was being
        // stored as end-to-end, which is why the sample looked plausible while
        // real history on the same card read twelve seconds. It is now labelled
        // as what it is, and end-to-end is derived the way it actually happens:
        // however long you spoke, plus the wait afterwards.
        let release = Int(random.logNormal(median: 379, sigma: 0.47).clamped(to: 186...2_150))
        // The key is held for the whole recording, not merely for the speech —
        // `audio` already carries the lead-in and the tail — so end-to-end is
        // the recording plus the wait afterwards.
        let endToEnd = audio + release
        let finalToInserted = Int(random.logNormal(median: 88, sigma: 0.38).clamped(to: 38...420))

        return DictationRecord(
            id: UUID(),
            date: date,
            rawText: raw,
            insertedText: inserted,
            wordCount: words,
            inputDevice: random.unit() < 0.84 ? "MacBook Air Microphone" : "AirPods Pro",
            timings: DictationRecord.Timings(
                timeToFirstWordMs: firstWord,
                finalToInsertedMs: finalToInserted,
                endToEndMs: endToEnd,
                audioDurationMs: audio,
                // The thorough cleanup pass has a deadline; when it misses, the
                // fast pass ships. Roughly one in six.
                usedThoroughCleanup: random.unit() < 0.83,
                releaseToInsertedMs: release
            )
        )
    }

    // MARK: - Corpus

    /// Raw is what a recogniser with no biasing actually produces: no
    /// punctuation, filler intact, proper nouns guessed phonetically. Inserted is
    /// what Quill writes. The gap between the two columns is the entire
    /// corrections card, so these pairs are written to be wrong in the ways the
    /// recogniser is really wrong — "neglify" for Netlify is a transcript from
    /// the first harness run, not an invention.
    struct Line {
        let raw: String
        let inserted: String
    }

    static let lines: [Line] = [
        Line(raw: "push the neglify build once the fire store rules land carlo needs the workshop dashboard before thursday",
             inserted: "Push the Netlify build once the Firestore rules land, Carlo needs the workshop dashboard before Thursday."),
        Line(raw: "reply to nokas the booking page is live um the deposit flow goes in tonight and nothing else changes this week",
             inserted: "Reply to Noah Kass: the booking page is live, the deposit flow goes in tonight, nothing else changes this week."),
        Line(raw: "idea for quil let a transform run on the clipboard not just on the last dictation",
             inserted: "Idea for Quill: let a transform run on the clipboard, not just on the last dictation."),
        Line(raw: "so basically i think we should ship the crag e burn page first and then do the rest",
             inserted: "We should ship the Craigieburn page first, then do the rest."),
        Line(raw: "check whether the analyser keeps its context window across a locked session",
             inserted: "Check whether the analyzer keeps its context window across a locked session."),
        Line(raw: "um can you send me the invoice for the rose hill job when you get a sec",
             inserted: "Can you send me the invoice for the Rosehill job when you get a sec?"),
        Line(raw: "the swift you i layout is fighting me again im going to do it in app kit",
             inserted: "The SwiftUI layout is fighting me again, I'm going to do it in AppKit."),
        Line(raw: "yes to friday but id rather do the morning afternoon is already booked",
             inserted: "Yes to Friday, but I'd rather do the morning, the afternoon is already booked."),
        Line(raw: "add super base to the list of things to look at after the launch",
             inserted: "Add Supabase to the list of things to look at after the launch."),
        Line(raw: "groceries coffee oat milk and the good bread from the place on sydney road",
             inserted: "Groceries: coffee, oat milk, the good bread from the place on Sydney Road."),
        Line(raw: "next full filment needs the stage two form done before the onboarding call",
             inserted: "Next Fulfilment needs the stage two form done before the onboarding call."),
        Line(raw: "run graph if i over the projects folder and see what it says about the overlay",
             inserted: "Run graphify over the Projects folder and see what it says about the overlay."),
        Line(raw: "i think the pull request is fine but the tests are flaky on c i let me look",
             inserted: "The pull request is fine, but the tests are flaky on CI, let me look."),
        Line(raw: "book the melbin flight for the twenty third and tell mum about it tonight",
             inserted: "Book the Melbourne flight for the twenty-third and tell Mum about it tonight."),
        Line(raw: "the nib on the mark is too thin at sixteen points bump it and re render",
             inserted: "The nib on the mark is too thin at sixteen points, bump it and re-render."),
        Line(raw: "um so the type script types are wrong in the client folder again",
             inserted: "The TypeScript types are wrong in the client folder again."),
        Line(raw: "remind me to renew the domain for roman design co before september",
             inserted: "Remind me to renew the domain for Roman Design Co before September."),
        Line(raw: "play right keeps timing out on the head less run bump it to sixty seconds",
             inserted: "Playwright keeps timing out on the headless run, bump it to sixty seconds."),
        Line(raw: "the build a bed fabric page should lead with the war wick range not the frames",
             inserted: "The Builda Bed fabric page should lead with the Warwick range, not the frames."),
        Line(raw: "ghost e is dropping the last line when i resize it worth reporting",
             inserted: "Ghostty is dropping the last line when I resize it, worth reporting."),
        Line(raw: "obsidian vault sync is fine now it was the sim link the whole time",
             inserted: "Obsidian vault sync is fine now, it was the symlink the whole time."),
        Line(raw: "we need a proper empty state for the dictionary screen not just a message",
             inserted: "We need a proper empty state for the dictionary screen, not just a message."),
        Line(raw: "the latency numbers held up this morning median under four hundred milliseconds",
             inserted: "The latency numbers held up this morning, median under four hundred milliseconds."),
        Line(raw: "ex code ships the wrong s d k so keep using command line tools for this one",
             inserted: "Xcode ships the wrong SDK, so keep using Command Line Tools for this one."),
        Line(raw: "send nowa the deposit link and tell him the cutoff is friday at five",
             inserted: "Send Noah the deposit link and tell him the cutoff is Friday at five."),
        Line(raw: "vesper needs the block craft renderer before i can test the chunk loader",
             inserted: "Vesper needs the blockcraft renderer before I can test the chunk loader."),
        Line(raw: "i want the heat map to start on a sunday like get hub does",
             inserted: "I want the heatmap to start on a Sunday, like GitHub does."),
        Line(raw: "murmur is basically done just the menu bar icon and the first run flow left",
             inserted: "Murmur is basically done, just the menu bar icon and the first-run flow left."),
        Line(raw: "swift p m wont pick up the plugin path unless you pass it twice",
             inserted: "SwiftPM won't pick up the plugin path unless you pass it twice."),
        Line(raw: "tell carlo the reversible bed head photos need to be re shot in daylight",
             inserted: "Tell Carlo the reversible bedhead photos need to be reshot in daylight."),
        Line(raw: "nebular is loading but the ring is off centre by about eight pixels",
             inserted: "Nebula is loading, but the ring is off-centre by about eight pixels."),
        Line(raw: "um i reckon we drop the third card and let the chart breathe a bit",
             inserted: "I reckon we drop the third card and let the chart breathe a bit."),
        Line(raw: "the fire store rules are still open lock them down before thursday",
             inserted: "The Firestore rules are still open, lock them down before Thursday."),
        Line(raw: "start the essay on mac beth tonight guilt first then ambition",
             inserted: "Start the essay on Macbeth tonight, guilt first, then ambition."),
    ]
}

// MARK: - Determinism

/// A tiny LCG. The point is not statistical quality — it is that two renders of
/// the same screen on two machines produce the same pixels, so a design review
/// is comparing designs rather than comparing random seeds.
struct SeededRandom {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// Half-open [0, 1). Never exactly zero, so callers can take its logarithm.
    mutating func unit() -> Double {
        let value = Double(next() >> 11) / Double(UInt64(1) << 53)
        return value <= 0 ? 1e-9 : value
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(unit() * Double(range.count))
    }

    mutating func normal() -> Double {
        let u1 = unit(), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// Latency is not symmetric — most dictations land fast and a few take a
    /// long tail, which is exactly a log-normal. Sampling it normally would draw
    /// a bell curve that no real pipeline has ever produced.
    mutating func logNormal(median: Double, sigma: Double) -> Double {
        exp(log(median) + normal() * sigma)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
