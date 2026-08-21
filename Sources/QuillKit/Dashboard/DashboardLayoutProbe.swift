import AppKit

/// Measures what a screenshot can only suggest.
///
/// Three of the four complaints that started the layout overhaul are *measurable*
/// and were all argued about from renders instead: the titles sit at different
/// heights, the content stops a third of the way across the window, and half the
/// height below it is empty. A PNG shows you those; it does not tell you the
/// title moved 38 points or that Settings leaves 660 of 1104 points unused, and
/// "looks about right" is how the title alignment drifted back after being fixed
/// once already.
///
/// `QUILL_LAYOUT_PROBE=1` prints one line per section: where the title starts,
/// how far the content reaches, and how much of the panel it never touches.
/// Numbers, before and after, for a change whose whole point is the numbers.
public enum DashboardLayoutProbe {

    public struct Reading {
        public let section: DashboardSection
        /// Top of the display-face title, in section coordinates.
        public let titleTop: CGFloat
        /// Rightmost pixel any subview reaches.
        public let contentRight: CGFloat
        /// Bottommost pixel any subview reaches.
        public let contentBottom: CGFloat
        public let panelWidth: CGFloat
        public let panelHeight: CGFloat
        /// Fraction of a 16x16 grid over the panel that any content lands in.
        ///
        /// A bounding box cannot see a hole. Dictation's two panels reach every
        /// corner of the screen and the right-hand one is two thirds empty, so
        /// "content reaches 1070 of 1116 points" scores it as full. Coverage
        /// counts the cells, so a void anywhere shows up as a lower number.
        public let coverage: Double
        /// The tallest run of grid rows with nothing in them, in points — the
        /// void you can actually see, wherever it is.
        public let tallestGap: CGFloat

        /// Points of panel width nothing reaches into, past the trailing padding.
        public var deadRight: CGFloat {
            max(0, panelWidth - DashboardMetrics.contentPaddingX - contentRight)
        }
        /// Points of panel height nothing reaches into, past the bottom padding.
        public var deadBottom: CGFloat {
            max(0, panelHeight - DashboardMetrics.contentPaddingY - contentBottom)
        }
    }

    /// How far actual CONTENT reaches, not how far a container does.
    ///
    /// This is the whole difference between a useful number and a useless one.
    /// Dictation's list well and record card both stretch to the bottom padding,
    /// so a frame walk says the screen is full — while the render plainly shows
    /// six hundred points of empty card. Only leaves count: a label with text in
    /// it, an icon, a rule, a drawn control. A box is not content, it is a box.
    static let grid = 16

    private static func extent(of view: NSView, in root: NSView)
        -> (right: CGFloat, bottom: CGFloat, cells: [Bool]) {
        var right: CGFloat = 0
        var bottom: CGFloat = 0
        var cells = [Bool](repeating: false, count: grid * grid)
        func draws(_ v: NSView) -> Bool {
            if let field = v as? NSTextField { return field.attributedStringValue.length > 0 }
            // A container with children is measured through its children.
            return v.subviews.isEmpty
        }
        // Everything is walked, scrolled content included: a column's WIDTH is a
        // fact whether or not you have scrolled to the row that proves it. Height
        // is different — a row parked below the fold is not filling the screen —
        // so the bottom only counts what is currently on it.
        let limit = view.bounds.height
        func walk(_ v: NSView) {
            for child in v.subviews where !child.isHidden && child.alphaValue > 0.01 {
                if draws(child) {
                    let rect = root.convert(child.bounds, from: child)
                    // Same flip correction as the title: `maxY` is the bottom edge
                    // in a flipped view and the top edge in an unflipped one.
                    let low = root.isFlipped ? rect.maxY : root.bounds.height - rect.minY
                    let high = low - rect.height
                    right = max(right, rect.maxX)
                    if low <= limit + 0.5 { bottom = max(bottom, low) }
                    let cw = root.bounds.width / CGFloat(grid)
                    let ch = limit / CGFloat(grid)
                    guard cw > 0, ch > 0 else { continue }
                    let c0 = max(0, Int(rect.minX / cw)), c1 = min(grid - 1, Int(rect.maxX / cw))
                    let r0 = max(0, Int(high / ch)), r1 = min(grid - 1, Int(low / ch))
                    guard c0 <= c1, r0 <= r1 else { continue }
                    for r in r0...r1 { for c in c0...c1 { cells[r * grid + c] = true } }
                }
                walk(child)
            }
        }
        walk(view)
        return (right, bottom, cells)
    }

    /// The section's display-face title.
    ///
    /// Read off the ATTRIBUTED STRING, not `NSTextField.font`. Every label here is
    /// built by `DashboardType.label`, which sets `attributedStringValue` and never
    /// touches the cell's font — so `field.font` answers 13pt for a 28pt heading.
    /// The shell test that pins title alignment asked the wrong one of those two
    /// and matched nothing at all, which is why it kept passing while three
    /// sections sat 38 points lower than the rest.
    /// Weight matters as much as size here. `DashboardType.metric` is also 28pt,
    /// so matching on size alone finds the first big NUMBER on the page and calls
    /// it the heading — which reported three sections' titles at y=707.
    public static func title(in view: NSView) -> NSTextField? {
        func labels(in v: NSView) -> [NSTextField] {
            v.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? labels(in: $0) }
        }
        return labels(in: view).first { field in
            guard !field.isHidden, field.attributedStringValue.length > 0 else { return false }
            guard let font = field.attributedStringValue
                .attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return false }
            return font.pointSize == DashboardType.display.pointSize
                && font.fontDescriptor.symbolicTraits.contains(.bold)
        }
    }

    @MainActor
    public static func measure(_ section: DashboardSection,
                               style: DashboardStyle = .dark,
                               size: NSSize = DashboardMetrics.windowSize) -> Reading? {
        guard let view = DashboardSectionRegistry.shared.dashboardView(for: section, style: style)
        else { return nil }
        let frame = DashboardMetrics.sectionFrame(in: DashboardMetrics.panelFrame(in: size))
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.layoutSubtreeIfNeeded()

        // Distance from the TOP of the panel, whichever way the section's
        // coordinate system runs. Half the sections are flipped and half are
        // Auto Layout in an unflipped view; reading `.origin.y` from both and
        // comparing them is how a 30pt drift can be reported as 670.
        let title = DashboardLayoutProbe.title(in: view)
        let top = title.map { label -> CGFloat in
            let rect = view.convert(label.frame, from: label.superview)
            return view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
        } ?? -1

        let bounds = extent(of: view, in: view)
        let filled = bounds.cells.filter { $0 }.count
        var longest = 0, run = 0
        for r in 0..<grid {
            let empty = !(0..<grid).contains { bounds.cells[r * grid + $0] }
            run = empty ? run + 1 : 0
            longest = max(longest, run)
        }
        return Reading(section: section,
                       titleTop: top,
                       contentRight: bounds.right,
                       contentBottom: bounds.bottom,
                       panelWidth: frame.width,
                       panelHeight: frame.height,
                       coverage: Double(filled) / Double(grid * grid),
                       tallestGap: CGFloat(longest) * frame.height / CGFloat(grid))
    }

    @discardableResult
    @MainActor
    public static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["QUILL_LAYOUT_PROBE"] != nil else { return false }
        let size = DashboardPreviewRenderer.size
        print("panel \(Int(size.width))x\(Int(size.height))   "
              + "section \(Int(DashboardMetrics.panelFrame(in: size).width))"
              + "x\(Int(DashboardMetrics.sectionFrame(in: DashboardMetrics.panelFrame(in: size)).height))")
        func pad(_ s: String, _ n: Int) -> String {
            s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
        }
        func left(_ s: String, _ n: Int) -> String {
            s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
        }
        print(left("section", 12) + ["titleY", "deadR", "deadB", "gap", "cover", "right"]
            .map { pad($0, 7) }.joined())
        var tops: [CGFloat] = []
        for section in DashboardSection.allCases {
            guard let r = measure(section, size: size) else { continue }
            if r.titleTop >= 0 { tops.append(r.titleTop) }
            print(left(section.rawValue, 12)
                  + [String(Int(r.titleTop)), String(Int(r.deadRight)), String(Int(r.deadBottom)),
                     String(Int(r.tallestGap)), "\(Int(r.coverage * 100))%", String(Int(r.contentRight))]
                    .map { pad($0, 7) }.joined())
        }
        if let low = tops.min(), let high = tops.max() {
            print("title spread: \(Int(high - low))pt")
        }
        return true
    }
}
