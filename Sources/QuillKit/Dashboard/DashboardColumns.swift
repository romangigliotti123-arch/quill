import AppKit

/// Packs a stack of self-sizing blocks into columns.
///
/// Settings and Help both capped their content at a 620-point column and pinned
/// it to the left edge, which is what System Settings does — and correct there,
/// because that window is 715 points wide and the column fills it. Quill's is
/// 1350. The same rule left four hundred and fifty points of empty window beside
/// every screen, and Roman named those two among the tabs he did not like.
///
/// The row measure is not the thing to change: a settings row whose label and
/// control are a hand's width apart is genuinely worse to read. So the column
/// keeps its measure and the page gets a second one — which is also what the two
/// screens he *does* like already do. Insights and Dictionary are both grids that
/// fill the window.
///
/// Balanced by running height rather than by count: six groups of wildly
/// different heights split 3/3 leave one column half empty, and the eye reads
/// that as a mistake rather than as an arrangement.
public enum DashboardColumns {

    /// The narrowest a column may get before the layout gives up and stacks.
    /// Below this a label/control row starts truncating, and one readable column
    /// beats two unreadable ones.
    public static let minColumnWidth: CGFloat = 430
    public static let maxColumnWidth: CGFloat = 620

    public struct Placement {
        public let x: CGFloat
        public let y: CGFloat
        public let width: CGFloat
        public let height: CGFloat
    }

    /// - Parameters:
    ///   - heights: each block's height at a given column width.
    ///   - width: the full content width available.
    /// - Returns: one placement per block, and the total height used.
    public static func pack(_ heights: [(CGFloat) -> CGFloat],
                            width: CGFloat,
                            originX: CGFloat,
                            originY: CGFloat,
                            gap: CGFloat = DashboardSpace.lg) -> (placements: [Placement], height: CGFloat) {
        guard !heights.isEmpty, width > 0 else { return ([], 0) }

        let twoUp = width >= minColumnWidth * 2 + gap
        let columnWidth = twoUp
            ? min(maxColumnWidth, ((width - gap) / 2).rounded(.down))
            : min(maxColumnWidth, width)
        let columnCount = twoUp ? 2 : 1

        // Centre the pair when the columns cannot use the whole width. At 1116
        // points two 620s do not fit, so they land at 546 each and use all of it;
        // on a wider window they cap and the leftover is split rather than dumped
        // on the right.
        let used = CGFloat(columnCount) * columnWidth + CGFloat(columnCount - 1) * gap
        let leading = originX + ((width - used) / 2).rounded()

        var columnBottoms = [CGFloat](repeating: originY, count: columnCount)
        var placements: [Placement] = []
        for height in heights {
            let h = height(columnWidth)
            // Shortest column wins. This is the balance: a tall block dropped
            // into the shorter side keeps both ends of the page level.
            var target = 0
            for index in 1..<columnCount where columnBottoms[index] < columnBottoms[target] {
                target = index
            }
            let x = leading + CGFloat(target) * (columnWidth + gap)
            placements.append(Placement(x: x, y: columnBottoms[target], width: columnWidth, height: h))
            columnBottoms[target] += h + gap
        }
        return (placements, (columnBottoms.max() ?? originY) - originY)
    }
}
