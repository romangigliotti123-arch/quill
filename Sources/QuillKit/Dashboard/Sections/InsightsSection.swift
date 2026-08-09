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

    private let eyebrow: NSTextField
    private let heading: NSTextField
    private let blurb: NSTextField
    private var segmented: InsightsSegmented
    private var sampleChip: DashboardChip?

    // MARK: Cards

    private var volumeCard: InsightsStatCard
    private var paceCard: InsightsStatCard
    private var savedCard: InsightsStatCard
    private var latencyCard: InsightsLatencyCard
    private var fixesCard: InsightsFixesCard
    private var streakCard: InsightsStreakCard

    public override var isFlipped: Bool { true }

    // MARK: - Init

    public convenience init(style: DashboardStyle) {
        let history = HistoryStore().all
        let vocabulary = Vocabulary.load()
        // Below the floor the percentiles are noise and the heatmap is empty —
        // and an empty statistics screen is the one state where showing nothing
        // is worse than showing a labelled sample. The label is not optional.
        let usingSample = history.count < InsightsFixture.minimumRealRecords
        self.init(records: usingSample ? InsightsFixture.sample : history,
                  vocabulary: vocabulary,
                  isSample: usingSample,
                  style: style)
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

        eyebrow = DashboardType.label("",
                                      font: DashboardType.eyebrow, color: style.inkTertiary)
        heading = DashboardType.label("Insights",
                                      font: DashboardType.display, color: style.ink)
        blurb = DashboardType.label("Measured on this Mac, from your own audio — no estimates, no ranking against strangers.",
                                    font: DashboardType.body, color: style.inkSecondary,
                                    lines: 2, lineHeight: 20)
        segmented = InsightsSegmented(titles: InsightsRange.allCases.map(\.title),
                                      selectedIndex: InsightsRange.allCases.firstIndex(of: range) ?? 1,
                                      style: style)

        volumeCard = InsightsStatCard(style: style)
        paceCard = InsightsStatCard(style: style)
        savedCard = InsightsStatCard(style: style)
        latencyCard = InsightsLatencyCard(style: style)
        fixesCard = InsightsFixesCard(style: style)
        streakCard = InsightsStreakCard(style: style)

        super.init(frame: .zero)

        addSubview(eyebrow)
        addSubview(heading)
        addSubview(blurb)
        addSubview(segmented)
        if isSample {
            let chip = DashboardChip(text: "Sample data", tone: .outline, style: style)
            addSubview(chip)
            sampleChip = chip
        }
        [volumeCard, paceCard, savedCard, latencyCard, fixesCard, streakCard].forEach(addSubview)

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
            footnote: m.previousWords > 0
                ? "\(InsightsFormat.count(m.previousWords)) \(m.range.comparisonPhrase)"
                : "no earlier window to compare against",
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
        paceCard.configure(
            value: [(String(m.medianWPM), false), ("  wpm", true)],
            caption: "median pace over \(InsightsFormat.count(m.sessions)) dictations",
            footnote: "your usual range is \(m.wpmP10)–\(m.wpmP90)",
            chip: nil,
            accent: false,
            accessory: .range(low: Double(m.wpmP10), high: Double(m.wpmP90), median: Double(m.medianWPM))
        )

        // 3 — The payoff, with its assumption printed. A "time saved" figure
        // whose typing speed is hidden is marketing; the same figure with
        // "at 40 wpm" under it is arithmetic anyone can redo.
        let spoken = InsightsFormat.duration(m.speakingSeconds)
            .map(\.text).joined().replacingOccurrences(of: " ", with: "")
        let typed = InsightsFormat.duration(m.typingSeconds)
            .map(\.text).joined().replacingOccurrences(of: " ", with: "")
        savedCard.configure(
            value: InsightsFormat.duration(m.savedSeconds),
            caption: "saved against typing it out",
            footnote: "\(spoken) spoken vs \(typed) typed at 40 wpm",
            chip: nil,
            accent: false,
            accessory: .split(fraction: m.typingSeconds > 0 ? m.speakingSeconds / m.typingSeconds : 0)
        )

        latencyCard.configure(metrics: m)
        fixesCard.configure(metrics: m)
        streakCard.configure(metrics: m)
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2
        guard width > 0 else { return }

        // Header.
        var y = padY
        let eyebrowSize = eyebrow.fittingSize
        eyebrow.frame = NSRect(x: padX, y: y, width: eyebrowSize.width, height: eyebrowSize.height)

        let segmentedWidth = segmented.intrinsicWidth
        segmented.frame = NSRect(x: bounds.width - padX - segmentedWidth, y: y - 3,
                                 width: segmentedWidth, height: 32)
        if let sampleChip {
            sampleChip.frame = NSRect(x: segmented.frame.minX - 10 - sampleChip.frame.width,
                                      y: (segmented.frame.midY - sampleChip.frame.height / 2).rounded(),
                                      width: sampleChip.frame.width, height: sampleChip.frame.height)
        }

        y += eyebrowSize.height + 9
        let headingSize = heading.fittingSize
        heading.frame = NSRect(x: padX, y: y, width: min(headingSize.width, width - 220), height: headingSize.height)
        y += headingSize.height + 5

        let blurbWidth = min(width - 260, 640)
        let blurbHeight = DashboardType.size(blurb, width: blurbWidth).height
        blurb.frame = NSRect(x: padX, y: y, width: blurbWidth, height: blurbHeight)
        y += blurbHeight + 22

        // Three stat cards, then two panels, then the year band. Heights are
        // derived from what is left rather than fixed, so the page fills the
        // panel exactly at 850 and degrades gracefully when the window is
        // dragged shorter.
        let gap = DashboardSpace.md
        let remaining = bounds.height - padY - y
        let statHeight: CGFloat = 138
        let streakHeight = max(150, min(200, streakCard.preferredHeight))
        let panelHeight = max(180, remaining - statHeight - streakHeight - gap * 2)

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
        latencyCard.frame = NSRect(x: padX, y: y, width: width - fixesWidth - gap, height: panelHeight)
        fixesCard.frame = NSRect(x: padX + width - fixesWidth, y: y, width: fixesWidth, height: panelHeight)
        y += panelHeight + gap

        streakCard.frame = NSRect(x: padX, y: y, width: width, height: streakHeight)
    }
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
                                       color: style.inkTertiary, tracking: 0)
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

// MARK: - Latency card

/// The card Flow cannot draw.
public final class InsightsLatencyCard: NSView {

    private var style: DashboardStyle
    private let header: InsightsCardHeader
    private let plot: InsightsLatencyPlot
    private var primary = NSTextField(labelWithString: "")
    private var primaryCaption: NSTextField
    private var secondary = NSTextField(labelWithString: "")
    private var secondaryCaption: NSTextField
    private var footnote: NSTextField
    private var footnoteMeta: NSTextField
    private let numbersDivider: DashboardRule
    private var legend: [InsightsLegendDot] = []

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle) {
        self.style = style
        header = InsightsCardHeader(style: style)
        plot = InsightsLatencyPlot(firstWord: [], endToEnd: [], p50: 0, p90: 0, style: style)
        primaryCaption = DashboardType.label("", font: .systemFont(ofSize: 11.5, weight: .regular),
                                             color: style.inkTertiary, tracking: 0)
        secondaryCaption = DashboardType.label("", font: .systemFont(ofSize: 11.5, weight: .regular),
                                               color: style.inkTertiary, tracking: 0)
        footnote = DashboardType.label("", font: .systemFont(ofSize: 11, weight: .regular),
                                       color: style.inkQuaternary, tracking: 0)
        footnoteMeta = DashboardType.label("", font: DashboardType.micro,
                                           color: style.inkQuaternary, alignment: .right)
        numbersDivider = DashboardRule(color: style.hairline)
        super.init(frame: .zero)
        for field in [primary, secondary] {
            field.isBezeled = false
            field.drawsBackground = false
            field.isEditable = false
            field.isSelectable = false
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
        }
        [header, plot, primary, primaryCaption, secondary, secondaryCaption,
         footnote, footnoteMeta, numbersDivider].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func number(_ text: String, unit: String, color: NSColor, size: CGFloat) -> NSAttributedString {
        let line = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .kern: -0.8,
        ])
        line.append(NSAttributedString(string: " " + unit, attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.47, weight: .medium),
            .foregroundColor: style.inkTertiary,
            .kern: 0,
        ]))
        return line
    }

    public func configure(metrics m: InsightsMetrics) {
        header.configure(title: "Response time",
                         meta: "\(InsightsFormat.count(m.endToEndMs.count)) dictations")

        primary.attributedStringValue = number(InsightsFormat.seconds(m.endToEndP50), unit: "s",
                                               color: style.accent, size: 30)
        primaryCaption.removeFromSuperview()
        primaryCaption = DashboardType.label("median, key release to text on screen",
                                             font: .systemFont(ofSize: 11.5, weight: .regular),
                                             color: style.inkTertiary, tracking: 0)
        addSubview(primaryCaption)

        secondary.attributedStringValue = number(InsightsFormat.seconds(m.firstWordP50), unit: "s",
                                                 color: style.ink, size: 22)
        secondaryCaption.removeFromSuperview()
        secondaryCaption = DashboardType.label("median to the first word appearing",
                                               font: .systemFont(ofSize: 11.5, weight: .regular),
                                               color: style.inkTertiary, tracking: 0)
        addSubview(secondaryCaption)

        plot.firstWord = m.firstWordMs
        plot.endToEnd = m.endToEndMs
        plot.markerP50 = m.endToEndP50
        plot.markerP90 = m.endToEndP90
        plot.needsDisplay = true

        footnote.removeFromSuperview()
        footnote = DashboardType.label("No server in the path — the slow tail is this Mac under load, not a network.",
                                       font: .systemFont(ofSize: 11, weight: .regular),
                                       color: style.inkQuaternary, tracking: 0)
        addSubview(footnote)

        // The two numbers the chart cannot show: what the worst hundredth costs,
        // and how often the thorough cleanup pass beat its deadline instead of
        // falling back to the fast one.
        footnoteMeta.removeFromSuperview()
        footnoteMeta = DashboardType.label("p99 \(InsightsFormat.seconds(m.endToEndP99))s · thorough cleanup \(InsightsFormat.percent(m.thoroughShare))",
                                           font: DashboardType.micro,
                                           color: style.inkQuaternary, alignment: .right)
        addSubview(footnoteMeta)

        legend.forEach { $0.removeFromSuperview() }
        legend = [
            InsightsLegendDot(text: "first word", color: style.inkTertiary, filled: false, style: style),
            InsightsLegendDot(text: "fully inserted", color: style.accent, filled: true, style: style),
        ]
        legend.forEach(addSubview)

        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let pad: CGFloat = 20
        let inner = bounds.width - pad * 2

        header.frame = NSRect(x: pad, y: 19, width: inner, height: 20)
        var y: CGFloat = 19 + header.height + 16

        let primarySize = primary.fittingSize
        primary.frame = NSRect(x: pad, y: y, width: primarySize.width, height: primarySize.height)
        let primaryCaptionSize = primaryCaption.fittingSize
        primaryCaption.frame = NSRect(x: pad, y: y + primarySize.height + 1,
                                      width: primaryCaptionSize.width, height: primaryCaptionSize.height)

        // The second number is set on the *baseline* of the first, not on its
        // box — 22pt and 30pt boxes centred against each other look like a
        // mistake, and their captions have to share one line to read as a pair.
        // A hairline between the pair. Without it the two captions run together
        // into one sentence at a glance, and the second number looks like a
        // continuation of the first rather than a different measurement.
        let secondX = pad + max(primarySize.width, primaryCaptionSize.width) + 37
        let secondarySize = secondary.fittingSize
        // Baselines, not boxes. Bottom-aligning a 22pt field against a 30pt one
        // leaves the smaller number sitting two points low, which is exactly far
        // enough to look like a bug and not far enough to spot straight away.
        let baselineDrop = primary.firstBaselineOffsetFromTop - secondary.firstBaselineOffsetFromTop
        secondary.frame = NSRect(x: secondX, y: (y + baselineDrop).rounded(),
                                 width: secondarySize.width, height: secondarySize.height)
        let secondaryCaptionSize = secondaryCaption.fittingSize
        secondaryCaption.frame = NSRect(x: secondX, y: y + primarySize.height + 1,
                                        width: secondaryCaptionSize.width, height: secondaryCaptionSize.height)

        // Legend rides on the same line as the numbers, hard right.
        var legendX = bounds.width - pad
        for dot in legend.reversed() {
            let width = dot.intrinsicWidth
            legendX -= width
            dot.frame = NSRect(x: legendX, y: y + 6, width: width, height: 16)
            legendX -= 16
        }

        numbersDivider.frame = NSRect(x: (secondX - 19).rounded(), y: y + 4, width: 1,
                                      height: primarySize.height + primaryCaptionSize.height - 3)

        y += primarySize.height + primaryCaptionSize.height + 12

        let footnoteHeight = DashboardType.size(footnote, width: inner).height
        let plotHeight = max(70, bounds.height - y - footnoteHeight - 18 - 8)
        plot.frame = NSRect(x: pad, y: y, width: inner, height: plotHeight)
        let footnoteSize = footnote.fittingSize
        footnote.frame = NSRect(x: pad, y: y + plotHeight + 8,
                                width: min(footnoteSize.width, inner), height: footnoteHeight)
        let metaSize = footnoteMeta.fittingSize
        footnoteMeta.frame = NSRect(x: bounds.width - pad - metaSize.width,
                                    y: (y + plotHeight + 8 + (footnoteHeight - metaSize.height) / 2).rounded(),
                                    width: metaSize.width, height: metaSize.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.sunkenSurface(bounds, radius: DashboardRadius.card, style: style, flipped: true)
    }
}

/// A legend entry: a swatch that matches how the series is drawn — filled for a
/// filled curve, ringed for an outlined one — plus its name.
final class InsightsLegendDot: NSView {

    private let label: NSTextField
    private let color: NSColor
    private let filled: Bool

    override var isFlipped: Bool { true }

    init(text: String, color: NSColor, filled: Bool, style: DashboardStyle) {
        self.color = color
        self.filled = filled
        label = DashboardType.label(text, font: .systemFont(ofSize: 11, weight: .medium),
                                    color: style.inkTertiary, tracking: 0)
        super.init(frame: .zero)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var intrinsicWidth: CGFloat { 14 + ceil(label.fittingSize.width) }

    override func layout() {
        super.layout()
        let size = label.fittingSize
        label.frame = NSRect(x: 14, y: ((bounds.height - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: (bounds.height - 8) / 2, width: 8, height: 8)
        if filled {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        } else {
            color.withAlphaComponent(0.8).setStroke()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            path.lineWidth = 1.2
            path.stroke()
        }
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
             color: style.ink.withAlphaComponent(style.isDark ? 0.82 : 0.78)),
            (text: "\(InsightsFormat.count(m.dictionaryFixes)) from your dictionary",
             color: style.accent),
        ], style: style)
        addSubview(inlineLegend)

        // Dictionary hits first. Filler removal is the bulk of the count but it
        // is not actionable — "um" being deleted teaches nobody anything. A
        // recogniser mishearing a proper noun nineteen times is the argument for
        // the Dictionary screen existing, so that is what gets named.
        let named = m.topFixes.filter(\.isDictionary) + m.topFixes.filter { !$0.isDictionary }
        listTitle.removeFromSuperview()
        listTitle = DashboardType.label(m.topFixes.contains(where: \.isDictionary)
                                        ? "Caught by your dictionary" : "Most repeated",
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

    private var swatches: [NSColor] = []
    private var labels: [NSTextField] = []

    override var isFlipped: Bool { true }

    init(items: [(text: String, color: NSColor)], style: DashboardStyle) {
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
            color.setFill()
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

    public var preferredHeight: CGFloat {
        19 + 18 + 12 + heatmap.intrinsicHeight + 14
    }

    public func configure(metrics m: InsightsMetrics) {
        let start = m.heat.first?.date
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
                             caption: "you dictated on, out of \(m.heat.count)", style: style),
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
        let gridWidth = min(heatmap.intrinsicWidth, inner - 200)
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
