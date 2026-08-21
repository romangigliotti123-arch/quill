import AppKit

/// The top of every screen, built once.
///
/// Roman, looking at the app: *"all of the tabs don't have the exact layout —
/// the heading of the tab at the top is in different positions."* That was fixed
/// once by hand, pinned with a test, and drifted straight back — because the
/// test matched nothing (it asked `NSTextField.font`, which answers 13pt for a
/// label whose size lives in its attributed string) and because ten sections each
/// built their own header out of the same three ingredients. Two of them stacked
/// an empty eyebrow above the title; one centred its meta line under it; three
/// used Auto Layout in an unflipped view and three used manual frames in a
/// flipped one. Nine correct-looking headers and one wrong one is a coin flip
/// every time a section is edited.
///
/// So a section does not lay out a title any more. It hands one of these a name,
/// optionally a line of meta and some trailing controls, and asks how tall it
/// came out. The title cannot move, because there is only one piece of code that
/// puts it anywhere.
public final class DashboardSectionHeader: NSView {

    /// Baseline height when there is no meta line: title only.
    public static let titleHeight: CGFloat = 34
    /// Every control on a header row is this tall.
    ///
    /// Asking a `DashboardButton` for its `fittingSize` returns the height of the
    /// LABEL inside it — the button draws its own pill and owns no constraints of
    /// its own — so a header laid out from fitting sizes gives its buttons about
    /// seventeen points and the pill disappears behind its own text. That was
    /// invisible in dark mode and lost the primary action outright in light.
    public static let controlHeight: CGFloat = 34

    private let titleLabel: NSTextField
    private var metaLabel: NSTextField?
    private var trailing: [NSView] = []

    public override var isFlipped: Bool { true }

    /// - Parameters:
    ///   - meta: one quiet line under the title. Not a paragraph — a section that
    ///     needs to explain itself in three lines has a naming problem, and the
    ///     blurb that used to sit here pushed every screen's content down by 40pt
    ///     to say what the sidebar row already said.
    ///   - trailing: right-aligned controls on the title's own row, in visual
    ///     order left to right.
    public init(title: String,
                meta: String? = nil,
                trailing: [NSView] = [],
                style: DashboardStyle) {
        titleLabel = DashboardType.label(title, font: DashboardType.display, color: style.ink)
        super.init(frame: .zero)
        addSubview(titleLabel)
        if let meta, !meta.isEmpty {
            let label = DashboardType.label(meta, font: DashboardType.callout, color: style.inkTertiary)
            addSubview(label)
            metaLabel = label
        }
        self.trailing = trailing
        trailing.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Swap the meta line without rebuilding the header. Used by sections whose
    /// count changes under a filter.
    public func setMeta(_ text: String, style: DashboardStyle) {
        if let metaLabel { metaLabel.removeFromSuperview(); self.metaLabel = nil }
        guard !text.isEmpty else { needsLayout = true; return }
        let label = DashboardType.label(text, font: DashboardType.callout, color: style.inkTertiary)
        addSubview(label)
        metaLabel = label
        needsLayout = true
    }

    /// How tall this header is, so the section can start its content under it.
    /// One number, asked for rather than assumed — a section that hardcodes 78
    /// is a section that breaks the day a meta line is added to it.
    public var height: CGFloat {
        let title = ceil(titleLabel.fittingSize.height)
        guard let metaLabel else { return max(DashboardSectionHeader.titleHeight, title) }
        return title + 6 + ceil(metaLabel.fittingSize.height)
    }

    /// Where the content below should start, measured from the section's top
    /// edge. The header is placed at `contentPaddingY`, so this is that plus its
    /// own height plus the gap under it.
    public static func contentTop(for header: DashboardSectionHeader) -> CGFloat {
        DashboardMetrics.contentPaddingY + header.height + DashboardSpace.lg
    }

    public override func layout() {
        super.layout()
        let width = bounds.width

        // Trailing controls first: they claim their width, and the title takes
        // what is left. The other way round, a long title pushes the buttons off
        // the right edge of the window instead of truncating itself.
        var right = width
        for view in trailing.reversed() {
            let w: CGFloat
            let h: CGFloat
            if let button = view as? DashboardButton {
                w = button.intrinsicWidth
                h = DashboardSectionHeader.controlHeight
            } else {
                let size = view.fittingSize
                w = size.width > 0 ? size.width : view.frame.width
                h = size.height > 0 ? size.height : view.frame.height
            }
            view.frame = NSRect(x: right - w, y: 0, width: w, height: h)
            right -= w + DashboardSpace.xs + 2
        }

        let available = max(80, (trailing.isEmpty ? width : right) - DashboardSpace.md)
        let titleSize = titleLabel.fittingSize
        titleLabel.frame = NSRect(x: 0, y: 0,
                                  width: min(titleSize.width, available),
                                  height: ceil(titleSize.height))

        // Optically centred on the title, not on the header box. A header with a
        // meta line under it is taller, and centring the buttons in the box drops
        // them halfway down the title's descender.
        for view in trailing {
            view.frame.origin.y = ((titleLabel.frame.height - view.frame.height) / 2).rounded()
        }

        if let metaLabel {
            let size = metaLabel.fittingSize
            metaLabel.frame = NSRect(x: 0, y: titleLabel.frame.maxY + 6,
                                     width: min(size.width, width), height: ceil(size.height))
        }
    }
}
