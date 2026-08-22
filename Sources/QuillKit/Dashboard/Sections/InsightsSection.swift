import AppKit

// The Insights screen.
//
// Wispr Flow's version of this page is the one screen of theirs that is easiest
// to beat, because three of its five cards are showing numbers that cannot be
// checked or cannot be acted on: a words-per-minute percentile against a
// population you cannot see, an app breakdown that reads 100% / 0% / 0% / 0%,
// and a heatmap of a window mostly older than the account. It looks handsome and
// says almost nothing.
//
// So the brief for ours is narrow. Every number is computed from this Mac's own
// history; the one figure that needs an assumption prints the assumption beside
// it; and the space Flow spends on a mobile-app advert goes to the measurement
// they structurally cannot publish — the response-time distribution. A hosted
// recogniser's tail is a network's tail, which is why nobody hosting one shows
// you the shape of it.

public final class InsightsView: NSView {

    // MARK: State

    private var style: DashboardStyle
    private let records: [DictationRecord]
    private let vocabulary: Vocabulary
    private let isSample: Bool
    private var range: InsightsRange
    private var metrics: InsightsMetrics

    // MARK: Chrome

    private let scroll = NSScrollView()
    private let content = InsightsFlippedView()
    private var header: DashboardSectionHeader!
    private var segmented: InsightsSegmented
    private var sampleChip: DashboardChip?

    // MARK: Cards

    private var volumeCard: InsightsStatCard
    private var paceCard: InsightsStatCard
    private var savedCard: InsightsStatCard
    private var activityCard: InsightsActivityCard
    private var fixesCard: InsightsFixesCard
    private var streakCard: InsightsStreakCard

    public override var isFlipped: Bool { true }

    // MARK: - Init

    public convenience init(style: DashboardStyle) {
        // Always the real history, including the honest zero.
        //
        // This used to substitute a thousand invented dictations, labelled
        // "Sample data", whenever real history fell short of forty records —
        // which is every new install, for a while. Every card on this screen
        // already has its own answer for thin data: "not enough dictations
        // yet", "nothing dictated in the last 30 days", "—" where a ratio would
        // otherwise divide by nothing. That degradation is what should be on
        // screen for a new user — not somebody else's invented ten months,
        // however clearly it was labelled. A number a person cannot check
        // reads as a claim about them regardless of the chip beside it.
        //
        // Measurements are not dictations. See DictationRecord.isMeasurement.
        let history = HistoryStore().all.filter { !$0.isMeasurement }
        self.init(records: history, vocabulary: Vocabulary.load(), style: style)
    }

    public init(records: [DictationRecord],
                vocabulary: Vocabulary = .load(),
                isSample: Bool = false,
                range: InsightsRange = .month,
                style: DashboardStyle) {
        self.style = style
        self.records = records
        self.vocabulary = vocabulary
        self.isSample = isSample
        self.range = range
        metrics = InsightsMetrics.compute(records: records, vocabulary: vocabulary, range: range)

        // A chip in the corner is the least a sample screen owes the reader. This
        // page shows a 23-day streak and 5,169 words; someone glancing at it will
        // believe those are theirs unless the page says otherwise in words, near
        // the title, where the eye already is. It also says what to do about it,
        // because "this is not yours" without "here is how it becomes yours" is
        // just an apology.
        let realSoFar = HistoryStore().all.filter { !$0.isMeasurement }.count
        segmented = InsightsSegmented(titles: InsightsRange.allCases.map(\.title),
                                      selectedIndex: InsightsRange.allCases.firstIndex(of: range) ?? 1,
                                      style: style)

        volumeCard = InsightsStatCard(style: style)
        paceCard = InsightsStatCard(style: style)
        savedCard = InsightsStatCard(style: style)
        activityCard = InsightsActivityCard(style: style)
        fixesCard = InsightsFixesCard(style: style)
        streakCard = InsightsStreakCard(style: style)

        super.init(frame: .zero)

        // Six cards with real floors under them need more than the 638 points a
        // 1060x700 window leaves — the streak band was being cut in half by the
        // panel edge with nothing on screen to say there was more. The document
        // is still sized to fill a tall window exactly, so this changes nothing
        // above the height where it stops fitting.
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.documentView = content
        addSubview(scroll)

        // The shared header, so this screen's title is placed by the same code as
        // every other one. It used to stack an empty eyebrow above the title and a
        // blurb below it, both of which were already being zeroed out at layout —
        // three views to draw one word.
        header = DashboardSectionHeader(title: "Insights", style: style)
        content.addSubview(header)
        content.addSubview(segmented)
        if isSample {
            let chip = DashboardChip(text: "Sample data", tone: .outline, style: style)
            content.addSubview(chip)
            sampleChip = chip
        }
        [volumeCard, paceCard, savedCard, activityCard, fixesCard, streakCard]
            .forEach(content.addSubview)

        segmented.onChange = { [weak self] index in
            guard let self else { return }
            self.range = InsightsRange.allCases[index]
            self.metrics = InsightsMetrics.compute(records: self.records,
                                                   vocabulary: self.vocabulary,
                                                   range: self.range)
            self.populate()
            self.needsLayout = true
        }

        populate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    private func populate() {
        let m = metrics

        // 1 — Volume. The delta chip is the only place a percentage appears
        // without its denominator, and it earns that by naming the window it is
        // comparing against directly underneath.
        volumeCard.configure(
            value: [(InsightsFormat.count(m.totalWords), false), ("  words", true)],
            caption: "dictated \(m.range.phrase)",
            // Short enough to survive the narrow column. At the minimum window a
            // stat card's footnote has 188 points, and "no earlier window to
            // compare against" needed ~195 — it truncated to "compare agai…",
            // which is a sentence that has lost the word carrying its meaning.
            footnote: m.previousWords > 0
                ? "\(InsightsFormat.count(m.previousWords)) \(m.range.comparisonPhrase)"
                : "nothing earlier to compare",
            chip: m.wordsDelta.map { delta in
                (text: "\(delta >= 0 ? "↑" : "↓") \(InsightsFormat.percent(delta))",
                 tone: DashboardChip.Tone.accent)
            },
            accent: false,
            accessory: .columns(m.dailyWords.map { Double($0.words) })
        )

        // 2 — Pace, and the spread it sits inside. This is the card that
        // replaces Flow's "Top 6%": same question, answered with data the user
        // can audit.
        // Pace needs a spoken duration to divide by. Dictations recorded before
        // Quill stored one contribute nothing, so with only old history this card
        // has no answer — and "0 wpm, usual range 0–0" is a confident wrong one.
        // Say there is nothing to report instead.
        let hasPace = m.medianWPM > 0
        paceCard.configure(
            value: hasPace ? [(String(m.medianWPM), false), ("  wpm", true)]
                           : [("—", true)],
            caption: hasPace ? "median pace over \(InsightsFormat.count(m.sessions)) dictations"
                             : "speaking pace",
            footnote: hasPace ? "your usual range is \(m.wpmP10)–\(m.wpmP90)"
                              : "not enough dictations yet",
            chip: nil,
            accent: false,
            accessory: hasPace
                ? .range(low: Double(m.wpmP10), high: Double(m.wpmP90), median: Double(m.medianWPM))
                : .none
        )

        // 3 — The payoff, with its assumption printed. A "time saved" figure
        // whose typing speed is hidden is marketing; the same figure with
        // "at 40 wpm" under it is arithmetic anyone can redo.
        let spoken = InsightsFormat.duration(m.speakingSeconds)
            .map(\.text).joined().replacingOccurrences(of: " ", with: "")
        let typed = InsightsFormat.duration(m.typingSeconds)
            .map(\.text).joined().replacingOccurrences(of: " ", with: "")
        let hasSpokenTime = m.speakingSeconds > 0
        savedCard.configure(
            value: hasSpokenTime ? InsightsFormat.duration(m.savedSeconds) : [("—", true)],
            caption: "saved against typing it out",
            // The spoken half is dropped, not the denominator. At the minimum
            // window this footnote had 188 points and needed ~195, so it truncated
            // to "...typed at 40" — deleting the unit from the one number this
            // card exists to publish. The comment above says why that matters: a
            // saved-time figure with its typing speed hidden is marketing.
            //
            // What went is also the part shown twice: the split-bar accessory and
            // the "54m saved" value already carry how long you spoke.
            footnote: hasSpokenTime ? "vs \(typed) typed at 40 wpm"
                                    : "needs the length of what you spoke",
            chip: nil,
            accent: false,
            accessory: hasSpokenTime
                ? .split(fraction: m.typingSeconds > 0 ? m.speakingSeconds / m.typingSeconds : 0)
                : .none
        )

        activityCard.configure(metrics: m)
        fixesCard.configure(metrics: m)
        streakCard.configure(metrics: m)
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        scroll.frame = bounds
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2
        guard width > 0 else { return }

        // Header. The range switch sits on the title's row, where every other
        // section puts its actions.
        header.frame = NSRect(x: padX, y: padY, width: width, height: header.height)

        let segmentedWidth = segmented.intrinsicWidth
        segmented.frame = NSRect(x: bounds.width - padX - segmentedWidth,
                                 y: padY + ((header.height - 32) / 2).rounded(),
                                 width: segmentedWidth, height: 32)
        if let sampleChip {
            sampleChip.frame = NSRect(x: segmented.frame.minX - 10 - sampleChip.frame.width,
                                      y: (segmented.frame.midY - sampleChip.frame.height / 2).rounded(),
                                      width: sampleChip.frame.width, height: sampleChip.frame.height)
        }

        var y = DashboardSectionHeader.contentTop(for: header) - DashboardSpace.xs

        // Three stat cards, then two panels, then the year band. Heights are
        // derived from what is left rather than fixed, so the page fills the
        // panel exactly at 850.
        //
        // Below the height where the floors stop fitting, the page grows past the
        // viewport and scrolls instead of being clipped. `max` against the
        // viewport is what keeps the tall case identical: the document is only
        // ever taller than the window when the alternative was losing a card.
        let gap = DashboardSpace.lg
        let statHeight: CGFloat = 138
        // 200, not 180. The activity card spends 19 + 20 + 16 + 36 + 14 + 18 on
        // its header, number, caption and padding before the chart gets anything,
        // so below about 200 the chart drops under the ~60pt where its bars and
        // its two date labels are still readable. At the minimum window this means
        // the page is taller than the viewport and scrolls — which is the honest
        // outcome: there IS more content than fits, and the scroll view has been
        // here all along.
        let minPanelHeight: CGFloat = 200
        // The streak band is the one card here with slack in it — it reads fine
        // compressed and merely has more air at 200 — so it gives its slack up
        // first, which is what lets the whole page fit a 1060x700 window instead
        // of making you scroll for the last fifty points of a card.
        //
        // But never below what it needs to draw itself. That floor is the card's
        // own answer, not a number chosen here: squeezing it further does not
        // shrink the content, it pushes the last stat out through the bottom edge.
        let slack = bounds.height - padY - y - statHeight - minPanelHeight - gap * 2
        let streakHeight = max(streakCard.preferredHeight, min(200, slack))
        let natural = y + statHeight + gap + minPanelHeight + gap + streakHeight + padY
        let documentHeight = max(bounds.height, natural)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: documentHeight)

        let remaining = documentHeight - padY - y
        let panelHeight = max(minPanelHeight, remaining - statHeight - streakHeight - gap * 2)

        let statWidth = ((width - gap * 2) / 3).rounded(.down)
        for (index, card) in [volumeCard, paceCard, savedCard].enumerated() {
            let x = padX + (statWidth + gap) * CGFloat(index)
            let last = index == 2
            card.frame = NSRect(x: x, y: y,
                                width: last ? width - (statWidth + gap) * 2 : statWidth,
                                height: statHeight)
        }
        y += statHeight + gap

        let fixesWidth: CGFloat = 366
        activityCard.frame = NSRect(x: padX, y: y, width: width - fixesWidth - gap, height: panelHeight)
        fixesCard.frame = NSRect(x: padX + width - fixesWidth, y: y, width: fixesWidth, height: panelHeight)
        y += panelHeight + gap

        streakCard.frame = NSRect(x: padX, y: y, width: width, height: streakHeight)
    }
}

/// Top-down inside the scroll view. Without it the header would sit at the
/// bottom of the document and the page would open on the year band.
final class InsightsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Stat card

/// A headline number, what it means, and one quiet drawing of its shape.
///
/// The micro-visualisation is the whole point of this component. "149 wpm" is a
/// fact; "149 wpm, and here is the band you almost always fall in" is something
/// you can disagree with, which means it is worth reading.
public final class InsightsStatCard: NSView {

    public enum Accessory {
        case none
        case columns([Double])
        case range(low: Double, high: Double, median: Double)
        case split(fraction: Double)
    }

    private var style: DashboardStyle
    private var accent = false

    private let value = NSTextField(labelWithString: "")
    private var caption: NSTextField
    private var footnote: NSTextField
    private var chip: DashboardChip?
    private var accessory: Accessory = .none

    private var columns: InsightsColumns?
    private var rangeBar: InsightsRangeBar?
    private var splitBar: InsightsSplitBar?

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle) {
        self.style = style
        caption = DashboardType.label("", font: DashboardType.callout, color: style.inkSecondary)
        footnote = DashboardType.label("", font: .systemFont(ofSize: 11, weight: .regular),
                                       color: style.inkQuaternary, tracking: 0)
        super.init(frame: .zero)
        value.isBezeled = false
        value.drawsBackground = false
        value.isEditable = false
        value.isSelectable = false
        value.maximumNumberOfLines = 1
        value.cell?.usesSingleLineMode = true
        addSubview(value)
        addSubview(caption)
        addSubview(footnote)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func configure(value parts: [(text: String, isUnit: Bool)],
                          caption captionText: String,
                          footnote footnoteText: String,
                          chip chipSpec: (text: String, tone: DashboardChip.Tone)?,
                          accent: Bool,
                          accessory: Accessory) {
        self.accent = accent
        self.accessory = accessory

        // Number and unit share one attributed string. Two labels means aligning
        // a 30pt box against a 14pt box by hand, and a hand-aligned baseline is
        // always wrong by a couple of points in a way you cannot unsee.
        let line = NSMutableAttributedString()
        for part in parts {
            line.append(NSAttributedString(string: part.text, attributes: [
                .font: part.isUnit ? NSFont.systemFont(ofSize: 14, weight: .medium) : DashboardType.metric,
                .foregroundColor: part.isUnit ? style.inkTertiary : (accent ? style.accent : style.ink),
                .kern: part.isUnit ? 0 : -0.9,
            ]))
        }
        value.attributedStringValue = line

        caption.removeFromSuperview()
        caption = DashboardType.label(captionText, font: DashboardType.callout, color: style.inkSecondary)
        addSubview(caption)

        footnote.removeFromSuperview()
        footnote = DashboardType.label(footnoteText, font: .systemFont(ofSize: 11, weight: .regular),
                                       color: style.inkTertiary, tracking: 0)
        addSubview(footnote)

        chip?.removeFromSuperview()
        chip = nil
        if let chipSpec {
            let view = DashboardChip(text: chipSpec.text, tone: chipSpec.tone, style: style, uppercase: false)
            addSubview(view)
            chip = view
        }

        [columns, rangeBar, splitBar].forEach { $0?.removeFromSuperview() }
        columns = nil; rangeBar = nil; splitBar = nil

        switch accessory {
        case .none:
            break
        case let .columns(values):
            let view = InsightsColumns(values: values, style: style)
            addSubview(view)
            columns = view
        case let .range(low, high, median):
            let view = InsightsRangeBar(low: low, high: high, median: median, style: style)
            addSubview(view)
            rangeBar = view
        case let .split(fraction):
            let view = InsightsSplitBar(fraction: fraction, style: style)
            addSubview(view)
            splitBar = view
        }

        needsLayout = true
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        let pad: CGFloat = 20
        let inner = bounds.width - pad * 2

        let valueSize = value.fittingSize
        value.frame = NSRect(x: pad, y: 19, width: min(valueSize.width, inner), height: valueSize.height)

        var y = 19 + valueSize.height + 7
        let captionSize = caption.fittingSize
        caption.frame = NSRect(x: pad, y: y, width: min(captionSize.width, inner), height: captionSize.height)
        y += captionSize.height + 3
        let footnoteSize = footnote.fittingSize
        footnote.frame = NSRect(x: pad, y: y, width: min(footnoteSize.width, inner), height: footnoteSize.height)

        if let chip {
            chip.frame = NSRect(x: bounds.width - pad - chip.frame.width, y: 20,
                                width: chip.frame.width, height: chip.frame.height)
        }

        // Accessories are anchored to the floor of the card on a shared line,
        // not to the text above them. Three cards with different amounts of copy
        // still align along the bottom, which is what makes the row read as one
        // band rather than three widgets.
        let floor = bounds.height - 16
        columns?.frame = NSRect(x: pad, y: floor - 24, width: inner, height: 24)
        rangeBar?.frame = NSRect(x: pad, y: floor - 14, width: inner, height: 14)
        splitBar?.frame = NSRect(x: pad, y: floor - 9, width: inner, height: 9)
    }

    public override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.sunkenSurface(bounds, radius: DashboardRadius.card, style: style, flipped: true)
        if accent {
            NSGraphicsContext.saveGraphicsState()
            DashboardDraw.path(bounds, DashboardRadius.card).addClip()
            style.accent.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

// MARK: - Panel header

/// Title on the left, one meta string on the right. Shared by the three big
/// cards so their headers sit on the same optical line.
final class InsightsCardHeader: NSView {

    private var titleField: NSTextField
    private var metaField: NSTextField
    private var style: DashboardStyle

    override var isFlipped: Bool { true }

    init(style: DashboardStyle) {
        self.style = style
        titleField = DashboardType.label("", font: DashboardType.headline, color: style.ink)
        metaField = DashboardType.label("", font: DashboardType.caption, color: style.inkTertiary, alignment: .right)
        super.init(frame: .zero)
        addSubview(titleField)
        addSubview(metaField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, meta: String) {
        titleField.removeFromSuperview()
        metaField.removeFromSuperview()
        titleField = DashboardType.label(title, font: DashboardType.headline, color: style.ink)
        metaField = DashboardType.label(meta, font: DashboardType.caption, color: style.inkTertiary, alignment: .right)
        addSubview(titleField)
        addSubview(metaField)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleSize = titleField.fittingSize
        titleField.frame = NSRect(x: 0, y: 0, width: min(titleSize.width, bounds.width * 0.7), height: titleSize.height)
        let metaSize = metaField.fittingSize
        metaField.frame = NSRect(x: bounds.width - metaSize.width,
                                 y: ((titleSize.height - metaSize.height) / 2).rounded(),
                                 width: metaSize.width, height: metaSize.height)
    }

    var height: CGFloat { titleField.fittingSize.height }
}

// MARK: - Activity card

/// Words a day — the biggest panel on the page, and the one about the person
/// rather than about the software.
///
/// It replaced a response-time histogram. Roman: *"the graph part shouldn't
/// really show the response time of how the actual app works, because that's
/// more so just bragging about how good the app is when it should more so focus
/// on the actual user's stats."*
///
/// The latency numbers are not deleted — they are still measured on every
/// dictation, still on the record, and still what the rig scores. They are just
/// not what the largest thing on a screen called Insights should be spending
/// itself on.
///
/// The headline follows the pointer. Hover a column and the number becomes that
/// day; move off and it goes back to the average. Health and Fitness both do
/// exactly this, and it is better than a tooltip for the same reason: the number
/// is already the biggest thing on the card, so putting the answer there costs
/// nothing and covers nothing.
public final class InsightsActivityCard: NSView {

    private var style: DashboardStyle
    private let header: InsightsCardHeader
    private let chart: InsightsDailyChart
    private var primary = NSTextField(labelWithString: "")
    private var caption: NSTextField

    private var averageValue: [(text: String, isUnit: Bool)] = []
    private var averageCaption = ""

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle) {
        self.style = style
        header = InsightsCardHeader(style: style)
        chart = InsightsDailyChart(style: style)
        caption = DashboardType.label("", font: .systemFont(ofSize: 11.5, weight: .regular),
                                      color: style.inkTertiary, tracking: 0)
        super.init(frame: .zero)
        primary.isBezeled = false
        primary.drawsBackground = false
        primary.isEditable = false
        primary.isSelectable = false
        primary.maximumNumberOfLines = 1
        primary.cell?.usesSingleLineMode = true
        [header, chart, primary, caption].forEach(addSubview)

        chart.onHover = { [weak self] day in self?.show(day) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func number(_ parts: [(text: String, isUnit: Bool)], size: CGFloat) -> NSAttributedString {
        let line = NSMutableAttributedString()
        for part in parts {
            line.append(NSAttributedString(string: part.text, attributes: [
                .font: NSFont.systemFont(ofSize: part.isUnit ? size * 0.45 : size,
                                         weight: .medium),
                .foregroundColor: part.isUnit ? style.inkTertiary : style.ink,
                .kern: part.isUnit ? 0 : -0.8,
            ]))
        }
        return line
    }

    /// The hovered bucket, or back to the average when there is none.
    private func show(_ bucket: InsightsBucket?) {
        guard let bucket else {
            primary.attributedStringValue = number(averageValue, size: 30)
            setCaption(averageCaption)
            needsLayout = true
            return
        }
        primary.attributedStringValue = number(
            [(InsightsFormat.count(bucket.words), false), ("  words", true)], size: 30)
        setCaption(bucket.label
                   + (bucket.sessions > 0
                      ? "  \u{00B7}  \(bucket.sessions) dictation\(bucket.sessions == 1 ? "" : "s")"
                      : "  \u{00B7}  nothing dictated"))
        needsLayout = true
    }

    private func setCaption(_ text: String) {
        caption.removeFromSuperview()
        caption = DashboardType.label(text, font: .systemFont(ofSize: 11.5, weight: .regular),
                                      color: style.inkTertiary, tracking: 0)
        addSubview(caption)
    }

    public func configure(metrics m: InsightsMetrics) {
        let bucketing = InsightsActivityCard.bucketing(for: m.range, observedDays: m.dailyWords.count)
        let buckets = InsightsActivityCard.bucket(m.dailyWords, by: bucketing)
        header.configure(title: "Words \(bucketing.headline)",
                         meta: m.activeDays > 0
                             ? "\(InsightsFormat.count(m.activeDays)) active day\(m.activeDays == 1 ? "" : "s")"
                             : "")

        // The average across ALL buckets, not just the ones with something in
        // them. "You average 300 words a day" is a false claim if you dictated on
        // six days out of thirty, and the honest version is the one the dashed
        // line in the chart is actually drawn at.
        let total = buckets.reduce(0) { $0 + $1.words }
        let mean = buckets.isEmpty ? 0 : Int((Double(total) / Double(buckets.count)).rounded())
        averageValue = buckets.isEmpty || total == 0
            ? [("\u{2014}", true)]
            : [(InsightsFormat.count(mean), false), ("  words", true)]
        averageCaption = buckets.isEmpty || total == 0
            ? "nothing dictated \(m.range.phrase)"
            : "\(bucketing.headline) on average, over \(InsightsFormat.count(buckets.count)) \(bucketing.unitPlural)"

        chart.buckets = buckets
        chart.style = style
        show(nil)

        // No footnote. "One column a week" is the card's own title, and "the
        // dashed line is your average" is the 616-words-on-average headline the
        // line is literally drawn at. It was two restatements in eleven-point
        // grey, and it cost the chart twenty-four points to say them.
        needsLayout = true
    }

    // MARK: - Bucketing

    /// How wide one column is, and what to call it.
    ///
    /// Thirty daily columns against a real habit is twenty-four empty slots and
    /// one spike — a chart that reads as broken rather than as sparse. The bucket
    /// has to widen with the window, which is what every Apple health chart does
    /// and what the first version of this card did not.
    enum Bucketing {
        case day, week, month

        var headline: String {
            switch self {
            case .day: return "a day"
            case .week: return "a week"
            case .month: return "a month"
            }
        }
        var unitPlural: String {
            switch self {
            case .day: return "days"
            case .week: return "weeks"
            case .month: return "months"
            }
        }
        var size: Int {
            switch self {
            case .day: return 1
            case .week: return 7
            case .month: return 30
            }
        }
    }

    /// - Parameter observedDays: how many days of history there actually are.
    ///   `.all` has no fixed span, so without this it fell through to monthly
    ///   buckets regardless — and on a two-week-old install that is a chart with
    ///   ONE column, one axis label, and a caption reading "a month on average,
    ///   over 1 months". The window a person picked is not the same thing as the
    ///   history they have.
    static func bucketing(for range: InsightsRange, observedDays: Int) -> Bucketing {
        switch range.days ?? observedDays {
        case ...10: return .day
        case ...45: return .week
        default: return .month
        }
    }

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()
    private static let shortLabel: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()
    private static let monthLabel: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f
    }()

    /// Buckets are filled from the END of the series backwards, so the last
    /// column is always a whole, current period. Filling forwards leaves the
    /// newest bucket a stub — the one column a person actually looks at, drawn
    /// short for a reason that has nothing to do with how much they said.
    static func bucket(_ days: [InsightsMetrics.Day], by bucketing: Bucketing) -> [InsightsBucket] {
        guard !days.isEmpty else { return [] }
        guard bucketing != .day else {
            return days.map {
                InsightsBucket(start: $0.date, words: $0.words, sessions: $0.sessions,
                               label: dayLabel.string(from: $0.date))
            }
        }
        let size = bucketing.size
        var out: [InsightsBucket] = []
        var end = days.count
        // Filling backwards leaves a SHORT bucket at the left edge whenever the
        // window is not a whole number of periods. A 30-day window is 4 weeks and
        // 2 days, and that 2-day stub was plotted at the same width and the same
        // height scale as the weeks beside it, counted in "over 5 weeks", and
        // divided into the average — three wrong answers from one leftover.
        //
        // It is dropped below, once the buckets exist, so the guard can see
        // whether there is anything left to drop it in favour of.
        while end > 0 {
            let start = max(0, end - size)
            let slice = days[start..<end]
            guard let first = slice.first else { break }
            out.append(InsightsBucket(
                start: first.date,
                words: slice.reduce(0) { $0 + $1.words },
                sessions: slice.reduce(0) { $0 + $1.sessions },
                label: bucketing == .month
                    ? monthLabel.string(from: first.date)
                    : shortLabel.string(from: first.date)))
            end = start
        }
        var buckets = Array(out.reversed())
        // Only when a whole period survives it. On "All time" with twelve days of
        // history every bucket is a stub, and dropping the first would throw away
        // a third of the chart to avoid an inaccuracy nobody can see.
        if buckets.count > 1, days.count % size != 0 {
            buckets.removeFirst()
        }
        return buckets
    }

    public override func layout() {
        super.layout()
        let pad: CGFloat = 20
        let inner = bounds.width - pad * 2
        guard inner > 0 else { return }

        header.frame = NSRect(x: pad, y: 19, width: inner, height: 20)
        var y: CGFloat = 19 + header.height + 16

        let primarySize = primary.fittingSize
        primary.frame = NSRect(x: pad, y: y, width: min(primarySize.width, inner), height: primarySize.height)
        let captionSize = caption.fittingSize
        caption.frame = NSRect(x: pad, y: y + primarySize.height + 1,
                               width: min(captionSize.width, inner), height: captionSize.height)
        y += primarySize.height + captionSize.height + 16

        // The card is the ceiling, and the 60pt chart floor is not.
        //
        // A `max(60, ...)` floor with no cap put the footnote at y + 60 + 10 inside
        // a 180pt card at the minimum window size — so "One column a week. The
        // dashed line is your average." was drawn OUTSIDE its own card, floating
        // on the page in the 24-point gutter above the streak band. A floor and a
        // hard container cannot both win; the container has to.
        //
        // So the footnote is what gives way. It is a legend for a chart that is
        // legible without it, and losing it is much cheaper than losing the chart
        // or printing on the page.
        // Whatever is left inside the card, and never a point more. The whole
        // reason the footnote is gone is that a floor and a hard container cannot
        // both win, and the container has to.
        let chartHeight = max(0, bounds.height - y - 18)
        chart.frame = NSRect(x: pad, y: y, width: inner, height: chartHeight)
    }

    public override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.sunkenSurface(bounds, radius: DashboardRadius.card, style: style, flipped: true)
    }
}

// MARK: - Fixes card

/// What the cleanup pass changed, with the words named.
///
/// Flow shows "15 words corrected / 16 dictionary fixes" and stops. The counts
/// are the least useful part: knowing that the dictionary fired sixteen times
/// tells you nothing about whether to add a seventeenth word. Naming the
/// substitutions — what it heard, what it wrote, how often — turns the card into
/// the reason the Dictionary screen exists.
public final class InsightsFixesCard: NSView {

    private var style: DashboardStyle
    private let header: InsightsCardHeader
    private var total = NSTextField(labelWithString: "")
    private let bar: InsightsStackedBar
    private var inlineLegend: InsightsInlineLegend
    private var listTitle: NSTextField
    private var rows: [InsightsFixRow] = []
    private let rule: DashboardRule

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle) {
        self.style = style
        header = InsightsCardHeader(style: style)
        bar = InsightsStackedBar(style: style)
        inlineLegend = InsightsInlineLegend(items: [], style: style)
        listTitle = DashboardType.label("", font: DashboardType.micro, color: style.inkQuaternary)
        rule = DashboardRule(color: style.hairline)
        super.init(frame: .zero)
        total.isBezeled = false
        total.drawsBackground = false
        total.isEditable = false
        total.isSelectable = false
        total.maximumNumberOfLines = 1
        total.cell?.usesSingleLineMode = true
        [header, total, bar, inlineLegend, rule, listTitle].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func configure(metrics m: InsightsMetrics) {
        // The share goes in the header's meta slot rather than on its own line:
        // the card has five things to say and only four lines to say them in,
        // and "roughly 1 word in 6" is context for the title, not a finding.
        let share = m.totalWords > 0 ? Double(m.totalFixes) / Double(m.totalWords) : 0
        header.configure(title: "What Quill fixed",
                         meta: share > 0 ? "roughly 1 word in \(max(2, Int((1 / share).rounded())))" : "")

        let line = NSMutableAttributedString(string: InsightsFormat.count(m.totalFixes), attributes: [
            .font: DashboardType.metric,
            .foregroundColor: style.ink,
            .kern: -0.9,
        ])
        line.append(NSAttributedString(string: "  fixes", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: style.inkTertiary,
        ]))
        total.attributedStringValue = line

        bar.left = m.wordsCorrected
        bar.right = m.dictionaryFixes
        bar.needsDisplay = true

        inlineLegend.removeFromSuperview()
        inlineLegend = InsightsInlineLegend(items: [
            (text: "\(InsightsFormat.count(m.wordsCorrected)) corrected",
             color: { $0.ink.withAlphaComponent($0.isDark ? 0.82 : 0.78) }),
            (text: "\(InsightsFormat.count(m.dictionaryFixes)) from your dictionary",
             color: { $0.accent }),
        ], style: style)
        addSubview(inlineLegend)

        // Dictionary hits first. Filler removal is the bulk of the count but it
        // is not actionable — "um" being deleted teaches nobody anything. A
        // recogniser mishearing a proper noun nineteen times is the argument for
        // the Dictionary screen existing, so that is what gets named.
        let named = m.topFixes.filter(\.isDictionary) + m.topFixes.filter { !$0.isDictionary }
        listTitle.removeFromSuperview()
        // A heading with nothing under it is worse than no heading: it reads as a
        // section that failed to load rather than one that has nothing to say.
        listTitle = DashboardType.label(named.isEmpty ? ""
                                        : (m.topFixes.contains(where: \.isDictionary)
                                        ? "Caught by your dictionary" : "Most repeated"),
                                        font: DashboardType.micro,
                                        color: style.inkQuaternary)
        addSubview(listTitle)

        rows.forEach { $0.removeFromSuperview() }
        rows = named.prefix(3).map { InsightsFixRow(fix: $0, style: style) }
        rows.forEach(addSubview)

        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let pad: CGFloat = 20
        let inner = bounds.width - pad * 2

        header.frame = NSRect(x: pad, y: 19, width: inner, height: 20)
        var y: CGFloat = 19 + header.height + 13

        let totalSize = total.fittingSize
        total.frame = NSRect(x: pad, y: y, width: min(totalSize.width, inner), height: totalSize.height)
        y += totalSize.height + 15

        bar.frame = NSRect(x: pad, y: y, width: inner, height: 8)
        y += 8 + 9
        inlineLegend.frame = NSRect(x: pad, y: y, width: inner, height: 15)
        y += 15 + 15

        rule.frame = NSRect(x: pad, y: y, width: inner, height: 1)
        y += 13

        let listTitleSize = listTitle.fittingSize

        // The heading is only worth its space if something can follow it. The
        // no-data case was already handled by emptying the string; the no-ROOM
        // case was not, so at 1060x700 the card ended with "Caught by your
        // dictionary" and then the bottom edge — the exact failure the emptied
        // string exists to avoid, arrived at from the other direction. The rule
        // above goes with it: a divider before nothing divides nothing.
        let listWouldFit = !rows.isEmpty
            && y + listTitleSize.height + 6 + 18 <= bounds.height - 11
        listTitle.isHidden = !listWouldFit
        rule.isHidden = !listWouldFit
        guard listWouldFit else {
            rows.forEach { $0.isHidden = true }
            return
        }

        listTitle.frame = NSRect(x: pad, y: y, width: listTitleSize.width, height: listTitleSize.height)
        y += listTitleSize.height + 6

        // The list takes what is left and stops cleanly. A row that runs off the
        // bottom of a card looks like a bug; three rows and a full stop looks
        // like an edit.
        for row in rows {
            let fits = y + 18 <= bounds.height - 11
            row.isHidden = !fits
            guard fits else { continue }
            row.frame = NSRect(x: pad, y: y, width: inner, height: 18)
            y += 18
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.sunkenSurface(bounds, radius: DashboardRadius.card, style: style, flipped: true)
    }
}

/// Two counts, one track. The split is the story, so it is one bar rather than
/// two — two bars would invite comparing lengths that share no baseline.
final class InsightsStackedBar: NSView {

    var left = 0
    var right = 0
    var style: DashboardStyle

    override var isFlipped: Bool { true }

    init(style: DashboardStyle) {
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2

        // Nothing has happened yet. `max(1, ...)` used to keep the maths safe and
        // in doing so drew a full-width accent bar for a count of zero — the same
        // defect we criticised in Flow, where six saturated 0% chips read as
        // populated at a glance. An empty track is the honest picture.
        guard left + right > 0 else {
            DashboardDraw.fill(bounds, radius: radius, color: style.hairline)
            return
        }

        let total = left + right
        let gap: CGFloat = 3
        let leftWidth = ((bounds.width - gap) * CGFloat(left) / CGFloat(total)).rounded()

        DashboardDraw.fill(NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height),
                           radius: radius,
                           color: style.ink.withAlphaComponent(style.isDark ? 0.82 : 0.78))
        DashboardDraw.fill(NSRect(x: leftWidth + gap, y: 0, width: bounds.width - leftWidth - gap, height: bounds.height),
                           radius: radius, color: style.accent)
    }
}

/// The stacked bar's key, on one line directly under it. Two stacked rows would
/// have pushed the named substitutions off the bottom of the card, and the names
/// are the part of this card Flow does not have.
final class InsightsInlineLegend: NSView {

    /// The swatch colours are held as CLOSURES, not as colours.
    ///
    /// This drew "41 corrected" with a white dot on a white card in light mode,
    /// while the bar directly above it — using the identical expression,
    /// `style.ink.withAlphaComponent(0.78)` — drew correctly.
    ///
    /// The difference is *when* the expression ran. `style.ink` is `.labelColor`,
    /// a dynamic catalog colour, and a dynamic colour resolves against whatever
    /// appearance is current at the moment it is asked. Inside `draw(_:)` that is
    /// the view's own appearance, which is right. The bar computed it there. The
    /// legend computed it in `configure(metrics:)` — no drawing appearance in
    /// scope — so it resolved against the SYSTEM appearance instead. This Mac is
    /// in dark mode, so the light theme was handed white.
    ///
    /// Nothing about the light render looked wrong except one seven-point dot, and
    /// the same class of bug is waiting anywhere a system colour is stored rather
    /// than asked for at draw time.
    private var swatches: [(DashboardStyle) -> NSColor] = []
    private var labels: [NSTextField] = []
    private let style: DashboardStyle

    override var isFlipped: Bool { true }

    init(items: [(text: String, color: (DashboardStyle) -> NSColor)], style: DashboardStyle) {
        self.style = style
        super.init(frame: .zero)
        for item in items {
            swatches.append(item.color)
            let label = DashboardType.label(item.text, font: .systemFont(ofSize: 11.5, weight: .medium),
                                            color: style.inkSecondary, tracking: 0)
            labels.append(label)
            addSubview(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func positions() -> [CGFloat] {
        var x: CGFloat = 0
        return labels.map { label in
            let start = x
            x += 12 + ceil(label.fittingSize.width) + 16
            return start
        }
    }

    override func layout() {
        super.layout()
        for (start, label) in zip(positions(), labels) {
            let size = label.fittingSize
            label.frame = NSRect(x: start + 12, y: ((bounds.height - size.height) / 2).rounded(),
                                 width: size.width, height: size.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (start, color) in zip(positions(), swatches) {
            color(style).setFill()
            NSBezierPath(ovalIn: NSRect(x: start, y: (bounds.height - 7) / 2, width: 7, height: 7)).fill()
        }
    }
}

/// `heard → written   ×12`. Monospaced, because the pair is a before-and-after
/// and proportional type makes two similar words look different lengths.
final class InsightsFixRow: NSView {

    private let pair: NSTextField
    private let count: NSTextField

    override var isFlipped: Bool { true }

    init(fix: InsightsMetrics.Fix, style: DashboardStyle) {
        let line = NSMutableAttributedString(string: fix.heard.lowercased(), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: style.inkTertiary,
        ])
        line.append(NSAttributedString(string: "  →  ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: style.inkQuaternary,
        ]))
        line.append(NSAttributedString(string: fix.written.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: fix.isDictionary ? style.accentInk : style.ink,
        ]))
        pair = NSTextField(labelWithString: "")
        pair.isBezeled = false
        pair.drawsBackground = false
        pair.isEditable = false
        pair.isSelectable = false
        pair.maximumNumberOfLines = 1
        pair.cell?.usesSingleLineMode = true
        pair.lineBreakMode = .byTruncatingTail
        pair.attributedStringValue = line

        count = DashboardType.label("×\(fix.count)", font: DashboardType.mono,
                                    color: style.inkQuaternary, tracking: 0, alignment: .right)
        super.init(frame: .zero)
        addSubview(pair)
        addSubview(count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let countSize = count.fittingSize
        count.frame = NSRect(x: bounds.width - countSize.width,
                             y: ((bounds.height - countSize.height) / 2).rounded(),
                             width: countSize.width, height: countSize.height)
        let pairSize = pair.fittingSize
        pair.frame = NSRect(x: 0, y: ((bounds.height - pairSize.height) / 2).rounded(),
                            width: min(pairSize.width, bounds.width - countSize.width - 10),
                            height: pairSize.height)
    }
}

// MARK: - Streak card

/// Ten months of days, and the three facts worth pulling out of them.
public final class InsightsStreakCard: NSView {

    private var style: DashboardStyle
    private let header: InsightsCardHeader
    private let heatmap: InsightsHeatmap
    private let divider: DashboardRule
    private var stats: [InsightsStatLine] = []

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle) {
        self.style = style
        header = InsightsCardHeader(style: style)
        heatmap = InsightsHeatmap(days: [], style: style)
        divider = DashboardRule(color: style.hairlineStrong)
        super.init(frame: .zero)
        [header, heatmap, divider].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The shorter of the two columns cannot decide this card's height.
    ///
    /// This used to measure the heatmap alone, and the heatmap is the *shorter*
    /// half — three values with two-line captions beside it need more than a
    /// twelve-row year grid does. The result was a card sized to its grid with
    /// the last stat, "your biggest day", drawn below its own bottom edge and out
    /// onto the panel. The layout below already distributes the stats into
    /// whatever height it is given, and that only works if the height it is given
    /// was asked to hold them.
    public var preferredHeight: CGFloat {
        let chrome: CGFloat = 19 + 18 + 12
        let grid = chrome + heatmap.intrinsicHeight + 14
        // 200 is the width the layout reserves for the stats column, so captions
        // wrap here exactly as they will on screen.
        let stacked = stats.map { $0.height(for: 200) }.reduce(0, +)
            + 9 * CGFloat(max(0, stats.count - 1))
        return max(grid, chrome + stacked + 16)
    }

    public func configure(metrics m: InsightsMetrics) {
        // The first dictation, not the first square drawn.
        let start = m.firstRecord ?? m.heat.first?.date
        header.configure(
            title: m.currentStreak > 0 ? "\(m.currentStreak) day streak" : "Every day you dictated",
            // "All time" is stated explicitly because the range control at the top
            // of the page does NOT govern this card. Without it the heatmap silently
            // contradicts the active filter and makes every number on the page look
            // untrustworthy on first read.
            meta: start.map { "All time · since \(InsightsFormat.shortDate($0))" } ?? "All time")

        heatmap.days = m.heat

        stats.forEach { $0.removeFromSuperview() }
        var lines: [InsightsStatLine] = [
            InsightsStatLine(value: "\(m.longestStreak)", unit: "days",
                             caption: "longest run without missing one", style: style),
            InsightsStatLine(value: "\(m.activeDays)", unit: "days",
                             caption: "you dictated on, out of \(m.observedDays)", style: style),
        ]
        if let busiest = m.busiestDay {
            lines.append(InsightsStatLine(value: InsightsFormat.count(busiest.words), unit: "words",
                                          caption: "your biggest day — \(InsightsFormat.shortDate(busiest.date))",
                                          style: style))
        }
        stats = lines
        stats.forEach(addSubview)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let pad: CGFloat = 20
        let inner = bounds.width - pad * 2

        header.frame = NSRect(x: pad, y: 19, width: inner * 0.62, height: 20)
        let gridTop: CGFloat = 19 + header.height + 11

        // The grid takes its natural width; the stats column takes the rest,
        // with a hairline between them so the two halves read as one card rather
        // than two crammed together.
        // The stats column needs 200pt of TEXT width, and there are 54pt of gaps
        // between it and the grid. Reserving only 200 total left it 146, which
        // wrapped every caption to three lines and pushed the last two stats out
        // through the bottom of the card.
        let statsColumn: CGFloat = 200
        let gapsToStats: CGFloat = 28 + 26
        let gridWidth = max(120, min(heatmap.intrinsicWidth, inner - statsColumn - gapsToStats))
        heatmap.frame = NSRect(x: pad, y: gridTop, width: gridWidth,
                               height: max(0, bounds.height - gridTop - 14))

        let dividerX = (pad + gridWidth + 28).rounded()
        divider.frame = NSRect(x: dividerX, y: gridTop + 2, width: 1,
                               height: max(0, bounds.height - gridTop - 24))

        // The stats column is distributed into the height the grid occupies
        // rather than stacked from the top with a fixed gap — a fixed gap put the
        // last caption through the bottom edge of the card the moment the grid
        // changed cell size.
        let statX = dividerX + 26
        let statWidth = bounds.width - pad - statX
        let heights = stats.map { $0.height(for: statWidth) }
        let available = max(0, bounds.height - gridTop - 16)
        let slack = available - heights.reduce(0, +)
        let spacing = stats.count > 1 ? min(24, max(9, slack / CGFloat(stats.count - 1))) : 0
        var y = gridTop + max(0, (slack - spacing * CGFloat(max(0, stats.count - 1))) / 2)
        for (line, height) in zip(stats, heights) {
            line.frame = NSRect(x: statX, y: y.rounded(), width: statWidth, height: height)
            y += height + spacing
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.sunkenSurface(bounds, radius: DashboardRadius.card, style: style, flipped: true)
    }
}

/// A medium number over a sentence. The stats column beside the heatmap.
final class InsightsStatLine: NSView {

    private let value = NSTextField(labelWithString: "")
    private let caption: NSTextField

    override var isFlipped: Bool { true }

    init(value valueText: String, unit: String, caption captionText: String, style: DashboardStyle) {
        let line = NSMutableAttributedString(string: valueText, attributes: [
            .font: DashboardType.metricSmall,
            .foregroundColor: style.ink,
            .kern: -0.5,
        ])
        line.append(NSAttributedString(string: "  " + unit, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: style.inkTertiary,
        ]))
        caption = DashboardType.label(captionText, font: .systemFont(ofSize: 11.5, weight: .regular),
                                      color: style.inkTertiary, tracking: 0, lines: 2, lineHeight: 15)
        super.init(frame: .zero)
        value.isBezeled = false
        value.drawsBackground = false
        value.isEditable = false
        value.isSelectable = false
        value.maximumNumberOfLines = 1
        value.cell?.usesSingleLineMode = true
        value.attributedStringValue = line
        addSubview(value)
        addSubview(caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat {
        value.fittingSize.height + 2 + DashboardType.size(caption, width: width).height
    }

    override func layout() {
        super.layout()
        let valueSize = value.fittingSize
        value.frame = NSRect(x: 0, y: 0, width: min(valueSize.width, bounds.width), height: valueSize.height)
        let captionHeight = DashboardType.size(caption, width: bounds.width).height
        caption.frame = NSRect(x: 0, y: valueSize.height + 2, width: bounds.width, height: captionHeight)
    }
}
