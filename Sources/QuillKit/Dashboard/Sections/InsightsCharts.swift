import AppKit

// Every chart on the Insights screen, drawn by hand.
//
// No charting framework and no `NSVisualEffectView`, for the same reason the
// rest of the dashboard avoids both: `DashboardPreviewRenderer` rasterises this
// tree through `CALayer.render(in:)`, and anything that samples a backdrop or
// defers its drawing to a display link comes back as a hole. What you read in
// the PNG is what ships.
//
// All of these are flipped views, so `y` grows downward and a value maps to the
// plot with `baseline - value * height`. Getting that backwards is the classic
// way to ship a chart that is upside down but still plausible.

// MARK: - Curves

enum InsightsPath {

    /// Catmull-Rom through the points, converted to cubic Béziers.
    ///
    /// Straight segments between 60 histogram bins render as a visibly faceted
    /// silhouette at 2x — the eye reads the facets as data. A spline reads as a
    /// distribution, which is what it is.
    static func smooth(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count > 1 else { return path }
        path.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]
            let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        return path
    }

    /// Fills a path with a vertical gradient. `NSGradient.draw(in:angle:)` reads
    /// its angle in the view's coordinate system, which points the wrong way in
    /// a flipped view — explicit endpoints are the only version that behaves the
    /// same in both.
    static func fill(_ path: NSBezierPath, top: NSColor, bottom: NSColor, in rect: NSRect) {
        guard let gradient = NSGradient(starting: top, ending: bottom) else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        gradient.draw(from: NSPoint(x: rect.midX, y: rect.minY),
                      to: NSPoint(x: rect.midX, y: rect.maxY), options: [])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Bins samples and smooths the counts with a small triangular kernel.
    /// Un-smoothed bins from a few hundred samples are spiky enough that the
    /// shape changes when one dictation is added, which is not a property a
    /// distribution should have.
    static func density(_ samples: [Double], bins: Int, upperBound: Double) -> [Double] {
        guard !samples.isEmpty, upperBound > 0 else { return [Double](repeating: 0, count: bins) }
        var counts = [Double](repeating: 0, count: bins)
        for sample in samples {
            let position = sample / upperBound * Double(bins - 1)
            let index = Int(position.rounded())
            if index >= 0 && index < bins { counts[index] += 1 }
        }
        // A seven-tap kernel, not three. A few hundred samples across seventy
        // bins is three or four per bin, and at that density a light smooth
        // leaves a silhouette with four false peaks in it — the reader sees
        // modes in the pipeline that are just sampling noise.
        var smoothed = [Double](repeating: 0, count: bins)
        let kernel: [Double] = [0.06, 0.12, 0.18, 0.24, 0.18, 0.12, 0.06]
        let weightSum = kernel.reduce(0, +)
        for index in 0..<bins {
            var total = 0.0
            for (offset, weight) in kernel.enumerated() {
                let source = index + offset - 3
                if source >= 0 && source < bins { total += counts[source] * weight }
            }
            smoothed[index] = total / weightSum
        }
        return smoothed
    }
}

// MARK: - Daily columns

/// Daily volume as columns, sitting on the floor of a stat card.
///
/// Columns rather than an area, and the reason is the data: real dictation has
/// zero-word weekends in it, and an area chart through a run of zeroes breaks
/// into a row of disconnected humps that reads as a rendering fault. One column
/// per day is honest about the gaps — the weekends *are* the shape.
public final class InsightsColumns: NSView {

    public var values: [Double] { didSet { needsDisplay = true } }
    public var style: DashboardStyle { didSet { needsDisplay = true } }

    public override var isFlipped: Bool { true }

    public init(values: [Double], style: DashboardStyle) {
        self.values = values
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty, let peak = values.max(), peak > 0 else { return }

        let pitch = bounds.width / CGFloat(values.count)
        let width = max(2, (pitch - 2.4).rounded())
        let radius = min(1.75, width / 2)
        let quiet = style.ink.withAlphaComponent(style.isDark ? 0.30 : 0.20)
        let empty = style.ink.withAlphaComponent(style.isDark ? 0.10 : 0.07)

        for (index, value) in values.enumerated() {
            let x = (CGFloat(index) * pitch + (pitch - width) / 2).rounded()
            // A day with nothing in it still gets a stub, so the baseline reads
            // as a series with a hole rather than as a shorter series.
            let height = value <= 0 ? 2 : max(2.5, (bounds.height * CGFloat(value / peak)).rounded())
            DashboardDraw.fill(NSRect(x: x, y: bounds.height - height, width: width, height: height),
                               radius: radius, color: value <= 0 ? empty : quiet)
        }
    }
}

// MARK: - Range bar

/// Where the median sits inside your own spread.
///
/// This is the honest replacement for Flow's "Top 6%". A percentile against
/// other people is unverifiable and, on a dictation app, meaningless — everyone
/// speaks at the speed they speak. A percentile against *your own* dictations
/// is checkable from this Mac, and it answers the question that actually has an
/// answer: is today normal for me.
public final class InsightsRangeBar: NSView {

    public var low: Double
    public var high: Double
    public var median: Double
    public var style: DashboardStyle { didSet { needsDisplay = true } }

    public override var isFlipped: Bool { true }

    public init(low: Double, high: Double, median: Double, style: DashboardStyle) {
        self.low = low
        self.high = high
        self.median = median
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 8) / 2, width: bounds.width, height: 8)
        DashboardDraw.fill(track, radius: 4, color: style.isDark ? NSColor(white: 1, alpha: 0.08)
                                                                 : NSColor(white: 0, alpha: 0.06))

        // Domain is padded past the observed range so neither end of the band
        // touches the end of the track — a band that runs to the edge reads as
        // clipped data.
        let span = max(1, high - low)
        let lower = low - span * 0.55
        let upper = high + span * 0.55
        func x(_ value: Double) -> CGFloat {
            CGFloat((value - lower) / (upper - lower)) * bounds.width
        }

        let band = NSRect(x: x(low), y: track.minY, width: max(8, x(high) - x(low)), height: track.height)
        DashboardDraw.fill(band, radius: 4, color: style.ink.withAlphaComponent(style.isDark ? 0.34 : 0.20))

        let tickX = (x(median) - 1).rounded()
        let tick = NSRect(x: min(max(0, tickX), bounds.width - 2.5), y: track.minY - 4,
                          width: 2.5, height: track.height + 8)
        DashboardDraw.fill(tick, radius: 1.25, color: style.ink)
    }
}

// MARK: - Split bar

/// One track, two readings. Used for spoken-versus-typed, where the *unfilled*
/// part is the point being made.
public final class InsightsSplitBar: NSView {

    public var fraction: Double
    public var style: DashboardStyle { didSet { needsDisplay = true } }
    public var filledColor: NSColor?

    public override var isFlipped: Bool { true }

    public init(fraction: Double, style: DashboardStyle) {
        self.fraction = fraction
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        DashboardDraw.fill(bounds, radius: radius,
                           color: style.isDark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.07))
        let width = max(bounds.height, bounds.width * CGFloat(min(1, max(0, fraction))))
        DashboardDraw.fill(NSRect(x: 0, y: 0, width: width, height: bounds.height),
                           radius: radius, color: filledColor ?? style.ink.withAlphaComponent(0.72))
    }
}

// MARK: - Latency

/// Two response-time distributions on one axis.
///
/// This is the card that has no equivalent in Wispr Flow, and the reason is not
/// that they could not draw it — it is that a hosted recogniser's latency
/// depends on a network they do not control, so a distribution is a liability.
/// Quill's runs on this Mac, so the tail is short enough to publish. Showing the
/// whole shape rather than one median is the entire argument: a median hides the
/// slow tenth, and the slow tenth is what a user actually feels.
public final class InsightsLatencyPlot: NSView {

    public var firstWord: [Double]
    public var endToEnd: [Double]
    public var markerP50: Double
    public var markerP90: Double
    public var style: DashboardStyle { didSet { needsDisplay = true } }

    private let axisHeight: CGFloat = 17
    private let headroom: CGFloat = 24

    public override var isFlipped: Bool { true }

    public init(firstWord: [Double], endToEnd: [Double], p50: Double, p90: Double, style: DashboardStyle) {
        self.firstWord = firstWord
        self.endToEnd = endToEnd
        self.markerP50 = p50
        self.markerP90 = p90
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Rounded up to a whole quarter-second past the slow tail, so the axis
    /// labels are numbers a person would say out loud.
    private var upperBound: Double {
        // Cut at the 97th percentile, not at the maximum. One 2.1-second outlier
        // sets an axis that spends half the card on empty space and squashes the
        // shape everything else lives in — and the p99 is printed under the
        // chart in words, which is the honest way to keep the tail on screen.
        let tail = InsightsMetrics.percentile(endToEnd, 0.97)
        return min(1_500, max(750, (tail / 250).rounded(.up) * 250))
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard !endToEnd.isEmpty else { return }

        let baseline = (bounds.height - axisHeight).rounded()
        let plotTop = headroom
        let plotHeight = baseline - plotTop
        let bound = upperBound
        let bins = 46

        func x(_ ms: Double) -> CGFloat { CGFloat(ms / bound) * bounds.width }

        let slow = InsightsPath.density(endToEnd, bins: bins, upperBound: bound)
        let quick = InsightsPath.density(firstWord, bins: bins, upperBound: bound)
        let peak = max(slow.max() ?? 1, quick.max() ?? 1, 0.0001)

        func points(_ density: [Double]) -> [NSPoint] {
            density.enumerated().map { index, value in
                NSPoint(x: CGFloat(index) / CGFloat(bins - 1) * bounds.width,
                        y: baseline - plotHeight * CGFloat(value / peak))
            }
        }

        // Baseline first, so both fills sit on a drawn floor rather than on the
        // card's background.
        style.hairlineStrong.setFill()
        NSRect(x: 0, y: baseline, width: bounds.width, height: 1).fill()

        func plot(_ density: [Double], stroke: NSColor, top: NSColor, bottom: NSColor, width: CGFloat, dashed: Bool) {
            let line = InsightsPath.smooth(points(density))
            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: bounds.maxX, y: baseline))
            area.line(to: NSPoint(x: bounds.minX, y: baseline))
            area.close()
            InsightsPath.fill(area, top: top, bottom: bottom,
                              in: NSRect(x: 0, y: plotTop, width: bounds.width, height: plotHeight))
            stroke.setStroke()
            line.lineWidth = width
            line.lineJoinStyle = .round
            if dashed { line.setLineDash([3, 3], count: 2, phase: 0) }
            line.stroke()
        }

        // Time-to-first-word underneath: it is the earlier, tighter event, and
        // drawing it as an outline keeps it from competing with the number the
        // card is actually about.
        plot(quick,
             stroke: style.inkTertiary.withAlphaComponent(0.75),
             top: style.ink.withAlphaComponent(style.isDark ? 0.10 : 0.055),
             bottom: style.ink.withAlphaComponent(0),
             width: 1, dashed: false)

        plot(slow,
             stroke: style.accent,
             top: style.accent.withAlphaComponent(style.isDark ? 0.34 : 0.24),
             bottom: style.accent.withAlphaComponent(0.02),
             width: 1.6, dashed: false)

        // Markers.
        drawMarker(at: markerP50, label: "median", baseline: baseline, top: plotTop,
                   color: style.accent, emphasis: true)
        drawMarker(at: markerP90, label: "p90", baseline: baseline, top: plotTop,
                   color: style.inkTertiary, emphasis: false)

        // Axis ticks. Quarter-second steps unless that would crowd the labels.
        let step: Double = bound > 1_400 ? 500 : 250
        var tick: Double = 0
        while tick <= bound + 0.5 {
            let tx = x(tick).rounded()
            style.hairline.setFill()
            NSRect(x: min(tx, bounds.width - 1), y: baseline + 1, width: 1, height: 4).fill()

            let text = tick == 0 ? "0" : String(format: tick.truncatingRemainder(dividingBy: 1_000) == 0 ? "%.0f s" : "%.2f s", tick / 1_000)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: DashboardType.micro,
                .foregroundColor: style.inkQuaternary,
                .kern: 0.3,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            var labelX = tx - size.width / 2
            labelX = min(max(0, labelX), bounds.width - size.width)
            (text as NSString).draw(at: NSPoint(x: labelX.rounded(), y: baseline + 7), withAttributes: attributes)
            tick += step
        }
    }

    private func drawMarker(at ms: Double, label: String, baseline: CGFloat, top: CGFloat,
                            color: NSColor, emphasis: Bool) {
        let bound = upperBound

        // A marker past the axis has nowhere honest to sit. The old code clamped
        // it to the right edge, which drew it at a position that was not its
        // value AND stacked both labels in the same place when two markers were
        // out of range — "median" and "p90" printed on top of each other. The
        // number is already stated in the card header; the plot simply does not
        // claim to show it.
        guard ms <= bound else { return }

        let tx = (CGFloat(ms / bound) * bounds.width).rounded()

        let line = NSBezierPath()
        line.move(to: NSPoint(x: tx + 0.5, y: baseline))
        line.line(to: NSPoint(x: tx + 0.5, y: top - 6))
        line.lineWidth = emphasis ? 1.25 : 1
        color.withAlphaComponent(emphasis ? 0.9 : 0.55).setStroke()
        if !emphasis { line.setLineDash([2.5, 2.5], count: 2, phase: 0) }
        line.stroke()

        let text = "\(label)  \(InsightsFormat.seconds(ms))s"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: emphasis ? NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold)
                            : NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: emphasis ? color : style.inkTertiary,
            .kern: 0.3,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var labelX = tx - size.width / 2
        labelX = min(max(0, labelX), bounds.width - size.width)
        let labelY = top - 20

        if emphasis {
            let pill = NSRect(x: labelX - 6, y: labelY - 3, width: size.width + 12, height: size.height + 6)
            DashboardDraw.fill(pill, radius: pill.height / 2, color: style.accentSoft)
        }
        (text as NSString).draw(at: NSPoint(x: labelX.rounded(), y: labelY.rounded()), withAttributes: attributes)
    }
}

// MARK: - Heatmap

/// A year-of-squares grid, sized to the eight months Quill has existed.
///
/// The one rule that decides whether this reads as a design or as filler: the
/// window has to be short enough that most of it is filled. Flow renders six
/// months of empty squares around two faint days, which makes the same component
/// say "you do not use this".
public final class InsightsHeatmap: NSView {

    public var days: [InsightsMetrics.Day] { didSet { needsDisplay = true } }
    public var style: DashboardStyle { didSet { needsDisplay = true } }

    /// The size a square would like to be.
    public var cell: CGFloat = 11

    /// The size it actually gets. The grid draws a fixed square per column, so a
    /// frame narrower than intrinsicWidth used to overflow — at 1120pt the year
    /// band ran straight under the stats column beside it. Squares shrink to fit
    /// instead, which is what a calendar does when the window does.
    private var fittedCell: CGFloat {
        guard bounds.width > 0 else { return cell }
        let available = bounds.width - labelColumn
        let fit = (available + gap) / CGFloat(columns) - gap
        return max(4, min(cell, fit.rounded(.down)))
    }
    public var gap: CGFloat = 3
    /// Which square the cursor is over, or nil. Drives the ring and the tooltip.
    private var hovered: Int? { didSet { if oldValue != hovered { needsDisplay = true } } }
    public let labelColumn: CGFloat = 30
    public let monthRow: CGFloat = 15
    public let legendRow: CGFloat = 22

    public override var isFlipped: Bool { true }

    public init(days: [InsightsMetrics.Day], style: DashboardStyle) {
        self.days = days
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public var columns: Int { max(1, Int((Double(days.count) / 7).rounded(.up))) }

    public var intrinsicWidth: CGFloat {
        labelColumn + CGFloat(columns) * (cell + gap) - gap
    }

    public var intrinsicHeight: CGFloat {
        monthRow + 7 * (cell + gap) - gap + legendRow
    }

    /// Quartiles of the days you actually dictated on. Fixed thresholds would
    /// wash out a light month and saturate a heavy one; quartiles keep the
    /// scale meaningful for whoever is looking at it.
    private var thresholds: [Int] {
        let active = days.map(\.words).filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return [1, 2, 3, 4] }
        func at(_ q: Double) -> Int {
            active[min(active.count - 1, max(0, Int(q * Double(active.count - 1))))]
        }
        return [1, at(0.35), at(0.65), at(0.88)]
    }

    private func color(for words: Int, thresholds: [Int]) -> NSColor {
        guard words > 0 else {
            return style.isDark ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 0, alpha: 0.052)
        }
        let level: Int
        if words >= thresholds[3] { level = 4 }
        else if words >= thresholds[2] { level = 3 }
        else if words >= thresholds[1] { level = 2 }
        else { level = 1 }
        return levelColor(level)
    }

    /// The ramp starts almost neutral and ends at the accent. A grid of 238
    /// saturated squares would spend the screen's entire colour budget in one
    /// component; a grid that greys out the quiet days spends it on the loud
    /// ones, which is where the information is.
    public func levelColor(_ level: Int) -> NSColor {
        switch level {
        case 1: return style.accent.withAlphaComponent(style.isDark ? 0.26 : 0.22)
        case 2: return style.accent.withAlphaComponent(style.isDark ? 0.40 : 0.34)
        case 3: return style.accent.withAlphaComponent(style.isDark ? 0.66 : 0.62)
        case 4: return style.accent
        default: return style.isDark ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 0, alpha: 0.052)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let thresholds = self.thresholds
        var calendar = Calendar.current
        calendar.firstWeekday = 1

        let pitch = fittedCell + gap
        let gridTop = monthRow

        // Squares. Index 0 is a Sunday by construction — the dense series is cut
        // to end on a Saturday, so `index % 7` is the weekday row and no date
        // arithmetic is needed per cell.
        for (index, day) in days.enumerated() {
            let column = index / 7
            let row = index % 7
            let rect = NSRect(x: labelColumn + CGFloat(column) * pitch,
                              y: gridTop + CGFloat(row) * pitch,
                              width: fittedCell, height: fittedCell)
            DashboardDraw.fill(rect, radius: 3.5, color: color(for: day.words, thresholds: thresholds))
        }

        // Month labels above the first column that starts a month.
        let monthAttributes: [NSAttributedString.Key: Any] = [
            .font: DashboardType.micro,
            .foregroundColor: style.inkTertiary,
            .kern: 0.6,
        ]
        var lastMonth = -1
        var lastLabelX: CGFloat = -100
        for column in 0..<columns {
            let index = column * 7
            guard index < days.count else { break }
            let month = calendar.component(.month, from: days[index].date)
            guard month != lastMonth else { continue }
            lastMonth = month
            let x = labelColumn + CGFloat(column) * pitch
            guard x - lastLabelX > 30 else { continue }
            lastLabelX = x
            let text = InsightsFormat.monthLabel(days[index].date).uppercased() as NSString
            text.draw(at: NSPoint(x: x, y: 0), withAttributes: monthAttributes)
        }

        // Weekday gutter. Three of seven, like every calendar heatmap that has
        // ever been legible — seven labels at this pitch is a wall of text.
        let dayAttributes: [NSAttributedString.Key: Any] = [
            .font: DashboardType.micro,
            .foregroundColor: style.inkQuaternary,
            .kern: 0.3,
        ]
        for (row, name) in [(1, "MON"), (3, "WED"), (5, "FRI")] {
            let text = name as NSString
            let size = text.size(withAttributes: dayAttributes)
            text.draw(at: NSPoint(x: labelColumn - 8 - size.width,
                                  y: (gridTop + CGFloat(row) * pitch + (fittedCell - size.height) / 2).rounded()),
                      withAttributes: dayAttributes)
        }

        // Legend, right-aligned under the grid.
        let legendY = gridTop + 7 * pitch - gap + 8
        let swatch: CGFloat = 10
        let legendAttributes: [NSAttributedString.Key: Any] = [
            .font: DashboardType.micro,
            .foregroundColor: style.inkQuaternary,
            .kern: 0.4,
        ]
        let less = "Less" as NSString
        let more = "More" as NSString
        let lessSize = less.size(withAttributes: legendAttributes)
        let moreSize = more.size(withAttributes: legendAttributes)
        let legendWidth = lessSize.width + 6 + 5 * (swatch + 3) - 3 + 6 + moreSize.width
        var x = labelColumn + CGFloat(columns) * pitch - gap - legendWidth

        less.draw(at: NSPoint(x: x, y: legendY + (swatch - lessSize.height) / 2 + 1), withAttributes: legendAttributes)
        x += lessSize.width + 6
        for level in 0...4 {
            DashboardDraw.fill(NSRect(x: x, y: legendY, width: swatch, height: swatch),
                               radius: 2.5, color: levelColor(level))
            x += swatch + 3
        }
        x += 3
        more.draw(at: NSPoint(x: x, y: legendY + (swatch - moreSize.height) / 2 + 1), withAttributes: legendAttributes)

        drawHover(pitch: pitch, gridTop: gridTop)
    }

    // MARK: Hover

    private func rect(forIndex index: Int, pitch: CGFloat, gridTop: CGFloat) -> NSRect {
        NSRect(x: labelColumn + CGFloat(index / 7) * pitch,
               y: gridTop + CGFloat(index % 7) * pitch,
               width: fittedCell, height: fittedCell)
    }

    /// Nil in the gutters between squares as well as outside the grid. A
    /// heatmap that keeps the tooltip up while the cursor is on the gap makes
    /// the reading feel approximate, which is the opposite of the point.
    public func index(at point: NSPoint) -> Int? {
        let pitch = fittedCell + gap
        let column = Int(((point.x - labelColumn) / pitch).rounded(.down))
        let row = Int(((point.y - monthRow) / pitch).rounded(.down))
        guard column >= 0, row >= 0, row < 7 else { return nil }
        let origin = NSPoint(x: labelColumn + CGFloat(column) * pitch, y: monthRow + CGFloat(row) * pitch)
        guard point.x <= origin.x + fittedCell, point.y <= origin.y + fittedCell else { return nil }
        let index = column * 7 + row
        return index >= 0 && index < days.count ? index : nil
    }

    private func drawHover(pitch: CGFloat, gridTop: CGFloat) {
        guard let hovered, hovered < days.count else { return }
        let day = days[hovered]
        let square = rect(forIndex: hovered, pitch: pitch, gridTop: gridTop)

        // Ring rather than a fill swap: recolouring the square would change the
        // one thing the reader is trying to read off it.
        DashboardDraw.stroke(square.insetBy(dx: -2, dy: -2), radius: 5,
                             color: style.ink.withAlphaComponent(0.55), width: 1.5)

        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        let title = formatter.string(from: day.date) as NSString
        let detail = (day.sessions == 0
                      ? "nothing dictated"
                      : "\(InsightsFormat.count(day.words)) words · \(day.sessions) dictation\(day.sessions == 1 ? "" : "s")") as NSString

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: style.ink,
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: style.inkTertiary,
        ]
        let titleSize = title.size(withAttributes: titleAttributes)
        let detailSize = detail.size(withAttributes: detailAttributes)
        let width = max(titleSize.width, detailSize.width) + 24
        let height = titleSize.height + detailSize.height + 20

        // Above the square by default, below it when that would run off the top —
        // and always inside the view, because a tooltip clipped by its own
        // container is worse than no tooltip.
        var x = square.midX - width / 2
        x = min(max(0, x), bounds.width - width)
        var y = square.minY - height - 8
        if y < 0 { y = square.maxY + 8 }
        let panel = NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)

        DashboardDraw.raisedSurface(panel, radius: DashboardRadius.control,
                                    fillColor: style.raised, topColor: style.raisedTop,
                                    style: style, shadow: style.shadowCard, flipped: true)
        title.draw(at: NSPoint(x: panel.minX + 12, y: panel.minY + 9), withAttributes: titleAttributes)
        detail.draw(at: NSPoint(x: panel.minX + 12, y: panel.minY + 9 + titleSize.height + 2),
                    withAttributes: detailAttributes)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseMoved(with event: NSEvent) {
        hovered = index(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) { hovered = nil }
}

// MARK: - Segmented control

/// The range switch. Drawn rather than `NSSegmentedControl`, which arrives with
/// a system tint, a bezel and a height that none of the rest of this window uses.
public final class InsightsSegmented: NSView {

    public var titles: [String]
    public var selectedIndex: Int {
        didSet {
            rebuild()
            thumb.animate(to: CGFloat(selectedIndex), duration: DashboardMotion.standard)
            onChange?(selectedIndex)
        }
    }
    public var style: DashboardStyle { didSet { rebuild() } }
    public var onChange: ((Int) -> Void)?

    private var labels: [NSTextField] = []
    private var hoveredIndex: Int? {
        didSet {
            guard hoveredIndex != oldValue else { return }
            hover.animate(to: hoveredIndex == nil ? 0 : 1)
        }
    }
    /// Segment index as a continuous number: the thumb slides to what was
    /// clicked rather than reappearing there.
    private lazy var thumb = DashboardTween(view: self, initial: CGFloat(selectedIndex))
    private lazy var hover = DashboardTween(view: self)

    public override var isFlipped: Bool { true }

    public init(titles: [String], selectedIndex: Int, style: DashboardStyle) {
        self.titles = titles
        self.selectedIndex = selectedIndex
        self.style = style
        super.init(frame: .zero)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        labels.forEach { $0.removeFromSuperview() }
        labels = titles.enumerated().map { index, title in
            DashboardType.label(title,
                                font: .systemFont(ofSize: 12, weight: index == selectedIndex ? .semibold : .medium),
                                color: index == selectedIndex ? style.ink : style.inkTertiary,
                                tracking: 0,
                                alignment: .center)
        }
        labels.forEach(addSubview)
        needsLayout = true
        needsDisplay = true
    }

    public var intrinsicWidth: CGFloat {
        labels.reduce(4) { $0 + ceil($1.fittingSize.width) + 24 }
    }

    private func segmentRects() -> [NSRect] {
        var rects: [NSRect] = []
        var x: CGFloat = 3
        for label in labels {
            let width = ceil(label.fittingSize.width) + 24
            rects.append(NSRect(x: x, y: 3, width: width, height: bounds.height - 6))
            x += width
        }
        return rects
    }

    public override func layout() {
        super.layout()
        for (rect, label) in zip(segmentRects(), labels) {
            let size = label.fittingSize
            label.frame = NSRect(x: rect.minX, y: (rect.midY - size.height / 2).rounded(),
                                 width: rect.width, height: size.height)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        DashboardDraw.fill(bounds, radius: radius, color: style.card)
        DashboardDraw.stroke(bounds, radius: radius, color: style.hairline)

        let rects = segmentRects()
        if let hoveredIndex, hoveredIndex != selectedIndex, hoveredIndex < rects.count {
            DashboardDraw.fill(rects[hoveredIndex], radius: rects[hoveredIndex].height / 2,
                               color: style.hover.faded(hover.value))
        }
        guard !rects.isEmpty else { return }
        // Between two segments while it travels. Clamped because the tween can be
        // mid-flight when a rebuild shortens the list.
        let position = max(0, min(CGFloat(rects.count - 1), thumb.value))
        let low = rects[Int(position.rounded(.down))]
        let high = rects[Int(position.rounded(.up))]
        let rect = low.lerp(to: high, position - position.rounded(.down))
        DashboardDraw.raisedSurface(rect, radius: rect.height / 2,
                                    fillColor: style.raised, topColor: style.raisedTop,
                                    style: style, shadow: style.shadowRaised, flipped: true)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredIndex = segmentRects().firstIndex { $0.contains(point) }
    }

    public override func mouseExited(with event: NSEvent) { hoveredIndex = nil }

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = segmentRects().firstIndex(where: { $0.contains(point) }), index != selectedIndex else { return }
        selectedIndex = index
    }
}
