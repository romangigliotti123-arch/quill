import AppKit

// The MCP screen — always in the sidebar, per Roman's own words: "it should
// be there all the time anyways." Signed out, the real content sits behind
// a genuine blur (an `NSVisualEffectView` in `.withinWindow` blending mode,
// which samples the sibling views drawn beneath it — the one blending mode
// that actually blurs content inside the same window rather than the
// desktop behind it) with a lock card on top explaining what signing in
// unlocks. See `QuillMCP` for the server itself and `OnboardingWindow`'s
// MCP intro step for the same pitch shown once, at first sign-up.

/// The connection details themselves — explanation, config snippet, copy
/// button. Always renders its full content; the page around it decides
/// whether that content is visible, blurred, or locked behind a prompt.
final class MCPConnectionDetails: NSView {

    private let style: DashboardStyle
    private let card: DashboardCardView
    private let explain: NSTextField
    private let pathLabel: NSTextField
    private let copyButton: DashboardButton
    private let status: NSTextField

    override var isFlipped: Bool { true }

    /// The config snippet a person merges into their own
    /// `claude_desktop_config.json`, under whatever `mcpServers` already
    /// holds — not the whole file, because overwriting it would drop every
    /// other server they already have configured.
    private static var configSnippet: String {
        let binary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/QuillMCP").path
        return """
        "quill": {
          "command": "\(binary)"
        }
        """
    }

    init(style: DashboardStyle) {
        self.style = style
        card = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        explain = DashboardType.label(
            "Add this under \u{201C}mcpServers\u{201D} in Claude Desktop\u{2019}s config, then restart Claude. "
                + "Ask it to use your Quill voice when drafting or replying to something.",
            font: DashboardType.callout, color: style.inkSecondary, lines: 3, lineHeight: 18)
        pathLabel = DashboardType.label(Self.configSnippet, font: DashboardType.mono,
                                        color: style.inkTertiary, lines: 4, lineHeight: 16)
        copyButton = DashboardButton(title: "Copy config", symbol: "doc.on.doc", kind: .secondary, style: style)
        status = DashboardType.label("", font: DashboardType.caption, color: style.inkTertiary)

        super.init(frame: .zero)
        addSubview(card)
        card.addSubview(explain)
        card.addSubview(pathLabel)
        card.addSubview(copyButton)
        card.addSubview(status)
        copyButton.onClick = { [weak self] in self?.copyConfig() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func copyConfig() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.configSnippet, forType: .string)
        status.stringValue = "Copied."
        needsLayout = true
    }

    func fittedHeight(width: CGFloat) -> CGFloat {
        let inner = width - 40
        let explainHeight = DashboardType.size(explain, width: inner).height
        let pathHeight = DashboardType.size(pathLabel, width: inner).height
        return 16 + explainHeight + 12 + pathHeight + 12 + 30 + 16
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let inset: CGFloat = 20
        let inner = bounds.width - inset * 2
        guard inner > 0 else { return }

        var y: CGFloat = 16
        let explainHeight = DashboardType.size(explain, width: inner).height
        explain.frame = NSRect(x: inset, y: y, width: inner, height: explainHeight)
        y += explainHeight + 12

        let pathHeight = DashboardType.size(pathLabel, width: inner).height
        pathLabel.frame = NSRect(x: inset, y: y, width: inner, height: pathHeight)
        y += pathHeight + 12

        copyButton.frame = NSRect(x: inset, y: y, width: copyButton.intrinsicWidth, height: 28)
        let statusSize = status.fittingSize
        status.frame = NSRect(x: inset + copyButton.intrinsicWidth + 10,
                              y: y + (28 - statusSize.height) / 2, width: 100, height: statusSize.height)
    }
}

/// The full page: header, what it does, the connection details — and, only
/// while signed out, a genuine blur over all of it with a lock card asking
/// for a sign-in. Signing in un-blurs the SAME view rather than swapping to
/// a different one, so there is nothing to keep in sync between two copies
/// of this screen.
public final class MCPSectionView: NSView {

    private let scroll = NSScrollView()
    private let content = SettingsFlippedView()
    private let header: DashboardSectionHeader
    private let benefitsCard: SectionCard
    private let connectionHeading: NSTextField
    private let connectionDetails: MCPConnectionDetails

    private let blur = NSVisualEffectView()
    private let lockCard: DashboardMessageView
    private var observerID: UUID?

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle) {
        header = DashboardSectionHeader(title: "MCP", style: style)
        benefitsCard = SectionCard(style: style, title: "What this unlocks")
        connectionHeading = DashboardType.label("Connect to Claude", font: DashboardType.headline,
                                                color: style.inkSecondary)
        connectionDetails = MCPConnectionDetails(style: style)

        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active

        lockCard = DashboardMessageView(
            symbol: "lock.fill",
            title: "Log in to use this feature",
            body: "Signing in unlocks MCP — Claude reading your writing voice — and syncing this "
                + "data to another Mac. Everything else in Quill works exactly the same without an account.",
            steps: ["MCP: Claude can write like you", "Sync: this data follows you to another Mac"],
            action: "Go to Account",
            actionSymbol: "person.crop.circle",
            style: style,
            elevation: .raised)
        lockCard.onAction = {
            NotificationCenter.default.post(name: .quillNavigateToSection, object: DashboardSection.account)
        }

        super.init(frame: .zero)
        wantsLayer = true

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

        content.addSubview(header)

        for (title, detail) in [
            ("Claude can write like you", "Connect Quill's MCP server in Claude Desktop and it can read "
                + "your writing style and real dictations to draft in your voice."),
            ("Quill never touches your email", "It only ever hands over how you write. Whatever Claude "
                + "does with that is access you grant Claude separately."),
        ] {
            let row = OnboardingPoint(style: style, symbol: "sparkles", title: title, detail: detail)
            benefitsCard.add(row) { width in row.fittingHeight(width: width) + 8 }
        }
        content.addSubview(benefitsCard)
        content.addSubview(connectionHeading)
        content.addSubview(connectionDetails)

        addSubview(blur)
        addSubview(lockCard)

        observerID = AccountStore.shared.observe { [weak self] account in
            self?.applyGating(signedIn: account != nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observerID { AccountStore.shared.stopObserving(observerID) }
    }

    private func applyGating(signedIn: Bool) {
        blur.isHidden = signedIn
        lockCard.isHidden = signedIn
        // Real content behind the blur still exists and still lays out —
        // blurred, not hidden. A person who already knows what's here and
        // is mid-sign-in should not watch it flash empty and back.
        needsLayout = true
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        scroll.frame = bounds
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2
        guard width > 0 else { return }

        header.frame = NSRect(x: padX, y: padY, width: width, height: header.height)
        var y = DashboardSectionHeader.contentTop(for: header)

        let benefitsHeight = benefitsCard.fittedHeight(width: width)
        benefitsCard.frame = NSRect(x: padX, y: y, width: width, height: benefitsHeight)
        y += benefitsHeight + DashboardSpace.lg

        connectionHeading.frame = NSRect(x: padX, y: y, width: width, height: 24)
        y += 24 + 8
        let detailsHeight = connectionDetails.fittedHeight(width: width)
        connectionDetails.frame = NSRect(x: padX, y: y, width: width, height: detailsHeight)
        y += detailsHeight

        content.frame = NSRect(x: 0, y: 0, width: bounds.width,
                               height: max(bounds.height, y + DashboardSpace.md))

        blur.frame = bounds
        let lockWidth: CGFloat = min(520, bounds.width - padX * 2)
        let lockHeight = lockCard.fittingHeight(width: lockWidth)
        lockCard.frame = NSRect(x: (bounds.width - lockWidth) / 2,
                                y: ((bounds.height - lockHeight) * 0.42).rounded(),
                                width: lockWidth, height: lockHeight)
    }
}
