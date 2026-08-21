import AppKit

// MARK: - Message states

/// Empty states, "not built yet" pages and no-result answers, from one view.
///
/// It lived inside the Dictation section and was the best thing on any of the
/// quiet screens, while Scratchpad, Notetaker and Style each hand-rolled their
/// own — three stacks of centred labels, three sets of paddings, three different
/// ideas of what "nothing here" should look like. Roman, on exactly that: *"it's
/// just not how the other tabs have been styled."*
///
/// It measures itself, which is what makes it usable on a page rather than only
/// inside a container: `fittingHeight(width:)` is the real height, so a section
/// can centre it optically instead of stretching it to fill a hole.

/// Empty states, both of them, from one view: first run and no search match.
/// They differ by copy, by whether they offer an action, and by whether they
/// teach — which is not enough difference to justify two layouts.
///
/// It measures itself. First run gets a card sized to its content and centred,
/// not a full-bleed well with a paragraph floating in the middle of it: a screen
/// whose only content is an apology should not also be the biggest empty
/// rectangle in the app.
final class DashboardMessageView: NSView {

    enum Elevation { case none, sunken, raised }

    var onAction: (() -> Void)?

    private let style: DashboardStyle
    private let elevation: Elevation
    private let disc: DashboardIconView
    private let title: NSTextField
    private let body: NSTextField
    private var stepNumbers: [NSTextField] = []
    private var stepTexts: [NSTextField] = []
    private let button: DashboardButton?

    private static let discSize: CGFloat = 52
    private static let stepHeight: CGFloat = 30

    override var isFlipped: Bool { true }

    init(symbol: String,
         title: String,
         body: String,
         steps: [String],
         action: String?,
         actionSymbol: String?,
         style: DashboardStyle,
         elevation: Elevation) {
        self.style = style
        self.elevation = elevation
        disc = DashboardIconView(image: DashboardIcon.image(symbol, pointSize: 18, weight: .regular,
                                                            color: style.inkTertiary))
        self.title = DashboardType.label(title, font: DashboardType.title, color: style.ink, alignment: .center)
        self.body = DashboardType.label(body, font: DashboardType.body, color: style.inkTertiary,
                                        lines: 3, lineHeight: 21, alignment: .center)
        self.button = action.map {
            DashboardButton(title: $0, symbol: actionSymbol,
                            kind: steps.isEmpty ? .secondary : .primary, style: style)
        }
        super.init(frame: .zero)
        addSubview(disc)
        addSubview(self.title)
        addSubview(self.body)
        for (index, step) in steps.enumerated() {
            stepNumbers.append(DashboardType.label("\(index + 1)", font: DashboardType.micro,
                                                   color: style.inkTertiary, alignment: .center))
            stepTexts.append(DashboardType.label(step, font: DashboardType.callout, color: style.inkSecondary))
        }
        stepNumbers.forEach(addSubview)
        stepTexts.forEach(addSubview)
        self.button.map(addSubview)
        self.button?.onClick = { [weak self] in self?.onAction?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func bodyWidth(for width: CGFloat) -> CGFloat {
        min(width - DashboardSpace.xl * 2, 420)
    }

    /// The disc is the first thing to go when there is not enough room.
    ///
    /// It is decoration — a glyph in a ring, saying what the title already says —
    /// and it costs 76 points including its gap. At the minimum window size the
    /// no-match card has about 110 points to work in, which is the title, the
    /// sentence and the button or nothing. Dropping an ornament to keep an
    /// instruction is not a close call.
    private func showsDisc(in height: CGFloat) -> Bool {
        height >= fittingHeight(width: bounds.width)
    }

    /// Content height plus the card's own padding. Used by the section to size
    /// the card before it is laid out, so the same numbers drive both.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let inner = DashboardMessageView.discSize + DashboardSpace.lg
            + title.fittingSize.height + DashboardSpace.xs
            + DashboardType.size(body, width: bodyWidth(for: width)).height
            + (stepTexts.isEmpty ? 0 : DashboardSpace.lg + CGFloat(stepTexts.count) * DashboardMessageView.stepHeight)
            + (button == nil ? 0 : DashboardSpace.lg + 36)
        return inner + DashboardSpace.xxl * 2
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let bodyW = bodyWidth(for: width)
        let titleSize = title.fittingSize
        let bodyHeight = DashboardType.size(body, width: bodyW).height
        let total = fittingHeight(width: width) - DashboardSpace.xxl * 2

        // Never above its own top edge. This view does not clip, so a content
        // block taller than the frame it was given used to centre at a NEGATIVE
        // y and draw its disc and title straight through whatever sat above —
        // which at the minimum window size put the no-match card over Dictation's
        // search field and its own divider.
        let wantsDisc = showsDisc(in: bounds.height)
        let discBlock = wantsDisc ? DashboardMessageView.discSize + DashboardSpace.lg : 0
        var y = max(0, ((bounds.height - (total - (wantsDisc ? 0 : discBlock))) / 2).rounded())
        let disc = DashboardMessageView.discSize
        self.disc.isHidden = !wantsDisc
        if wantsDisc {
            discFrame = NSRect(x: ((width - disc) / 2).rounded(), y: y, width: disc, height: disc)
            self.disc.frame = NSRect(x: discFrame.minX + 16, y: y + 16, width: 20, height: 20)
            y += disc + DashboardSpace.lg
        } else {
            discFrame = .zero
        }

        title.frame = NSRect(x: ((width - titleSize.width) / 2).rounded(), y: y,
                             width: titleSize.width, height: titleSize.height)
        y += titleSize.height + DashboardSpace.xs

        body.frame = NSRect(x: ((width - bodyW) / 2).rounded(), y: y, width: bodyW, height: bodyHeight)
        y += bodyHeight

        if !stepTexts.isEmpty {
            y += DashboardSpace.lg
            // Steps are left-aligned as a block, centred as a group: three
            // centred sentences of different lengths read as a poem, not a list.
            let textWidth = stepTexts.map { $0.fittingSize.width }.max() ?? 0
            let blockWidth = 26 + DashboardSpace.sm + textWidth
            let x = ((width - blockWidth) / 2).rounded()
            numberFrames = []
            for (index, text) in stepTexts.enumerated() {
                let number = stepNumbers[index]
                let discRect = NSRect(x: x, y: y + 3, width: 22, height: 22)
                numberFrames.append(discRect)
                let numberSize = number.fittingSize
                number.frame = NSRect(x: discRect.minX, y: discRect.midY - numberSize.height / 2 + 0.5,
                                      width: discRect.width, height: numberSize.height)
                let size = text.fittingSize
                text.frame = NSRect(x: x + 26 + DashboardSpace.sm,
                                    y: discRect.midY - size.height / 2,
                                    width: min(size.width, width - x - 26 - DashboardSpace.sm - DashboardSpace.xl),
                                    height: size.height)
                y += DashboardMessageView.stepHeight
            }
        }

        if let button {
            y += DashboardSpace.lg
            let buttonWidth = button.intrinsicWidth
            button.frame = NSRect(x: ((width - buttonWidth) / 2).rounded(), y: y, width: buttonWidth, height: 36)
        }
        needsDisplay = true
    }

    private var discFrame: NSRect = .zero
    private var numberFrames: [NSRect] = []

    override func draw(_ dirtyRect: NSRect) {
        switch elevation {
        case .none: break
        case .sunken: DashboardDraw.sunkenSurface(bounds, radius: DashboardRadius.card, style: style, flipped: true)
        case .raised:
            DashboardDraw.raisedSurface(bounds, radius: DashboardRadius.card,
                                        fillColor: style.raised, topColor: style.raisedTop,
                                        style: style, shadow: style.shadowCard, flipped: true)
        }
        guard discFrame != .zero else { return }
        DashboardDraw.fill(discFrame, radius: discFrame.width / 2,
                           color: elevation == .raised ? style.card : style.panel)
        DashboardDraw.stroke(discFrame, radius: discFrame.width / 2, color: style.hairline)
        for rect in numberFrames {
            DashboardDraw.fill(rect, radius: rect.width / 2, color: style.card)
            DashboardDraw.stroke(rect, radius: rect.width / 2, color: style.hairline)
        }
    }
}
