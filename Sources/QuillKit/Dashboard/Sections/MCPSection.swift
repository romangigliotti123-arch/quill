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
    private let promptExplain: NSTextField
    private let promptButton: DashboardButton
    private let promptStatus: NSTextField
    private let divider: NSView
    private let explain: NSTextField
    private let pathLabel: NSTextField
    private let copyButton: DashboardButton
    private let status: NSTextField

    override var isFlipped: Bool { true }

    /// Where the server actually is, read off the running bundle rather than
    /// assumed to be /Applications — Quill runs fine from anywhere, and a
    /// config file pointing at a path that does not exist fails as a Claude
    /// that simply has no Quill tools, with no error naming the reason.
    static var binaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/QuillMCP").path
    }

    /// The config snippet a person merges into their own
    /// `claude_desktop_config.json`, under whatever `mcpServers` already
    /// holds — not the whole file, because overwriting it would drop every
    /// other server they already have configured.
    static var configSnippet: String {
        """
        "quill": {
          "command": "\(binaryPath)"
        }
        """
    }

    /// The other way in: hand Claude the job instead of editing JSON by hand.
    ///
    /// Editing `claude_desktop_config.json` correctly means knowing where it
    /// is, that it may not exist yet, and that `mcpServers` is a dictionary to
    /// merge into rather than replace — which is three chances to lose every
    /// other server you had configured. A Claude with a terminal does it in one
    /// paste and can prove it worked afterwards.
    ///
    /// Everything it needs is in the text: the real resolved path, the config
    /// location, the tool's name, what to check, and the one failure that is
    /// not a setup problem at all. A prompt that assumes the reader already
    /// knows the app is a prompt that only works for someone who did not need
    /// it — see the same rule on every other copy-for-AI button in Quill.
    static var claudePrompt: String {
        // Written as one physical source line per paragraph, deliberately.
        //
        // A `\`-continuation inside a multi-line string joins the lines but does
        // NOT strip the continued line's indentation, so the pretty-wrapped
        // version of this produced sentences with eight spaces sitting in the
        // middle of them. Invisible in the source, obvious the moment you paste
        // it — which is only findable by printing the string rather than reading
        // the code that builds it.
        """
        Set up Quill's MCP server for me so Claude can write in my voice.

        Quill is a macOS dictation app. It ships a local MCP server as a binary inside its own app bundle, on this Mac at:

          \(binaryPath)

        It speaks MCP over stdio and exposes one tool, `get_writing_voice`, which returns a markdown document describing how I write, built from my own dictations. It takes no arguments, needs no API key, and makes no network requests.

        Please connect it wherever I would use it — skip either one I don't have installed:

        1. Claude Code:

             claude mcp add quill -- "\(binaryPath)"

        2. Claude Desktop — merge this into the "mcpServers" object in
           ~/Library/Application Support/Claude/claude_desktop_config.json

             "quill": {
               "command": "\(binaryPath)"
             }

           Create that file if it isn't there. If it is, keep every server already in it — merge, don't overwrite. Claude Desktop only picks the change up after it is quit and reopened, so tell me to do that.

        Then prove it works: call `get_writing_voice` and show me the first few lines of what comes back.

        Two answers that are not setup problems, so don't try to fix either by editing config:

        - If the tool says Quill isn't signed in, tell me. I need to open Quill, go to Account and sign in — that is what tells it whose voice to hand over.
        - If that path doesn't exist, Quill has been moved or renamed. Find Quill.app and use the QuillMCP binary inside its Contents/MacOS.
        """
    }

    init(style: DashboardStyle) {
        self.style = style
        card = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)

        promptExplain = DashboardType.label(
            "Easiest way: copy this and paste it into Claude Code, or any Claude that can run "
                + "commands on this Mac. It has the path, the config file and what to check, so "
                + "Claude can do the whole thing and then prove it worked.",
            font: DashboardType.callout, color: style.inkSecondary, lines: 4, lineHeight: 18)
        promptButton = DashboardButton(title: "Copy prompt for Claude", symbol: "sparkles",
                                       kind: .primary, style: style)
        promptStatus = DashboardType.label("", font: DashboardType.caption, color: style.inkTertiary)

        divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = style.hairline.cgColor

        explain = DashboardType.label(
            "Or do it yourself: add this under \u{201C}mcpServers\u{201D} in Claude Desktop\u{2019}s "
                + "config, then quit and reopen Claude.",
            font: DashboardType.callout, color: style.inkSecondary, lines: 3, lineHeight: 18)
        pathLabel = DashboardType.label(Self.configSnippet, font: DashboardType.mono,
                                        color: style.inkTertiary, lines: 4, lineHeight: 16)
        copyButton = DashboardButton(title: "Copy config", symbol: "doc.on.doc", kind: .secondary, style: style)
        status = DashboardType.label("", font: DashboardType.caption, color: style.inkTertiary)

        super.init(frame: .zero)
        addSubview(card)
        for view in [promptExplain, promptButton, promptStatus, divider,
                     explain, pathLabel, copyButton, status] as [NSView] {
            card.addSubview(view)
        }
        promptButton.onClick = { [weak self] in self?.copy(Self.claudePrompt, into: self?.promptStatus) }
        copyButton.onClick = { [weak self] in self?.copy(Self.configSnippet, into: self?.status) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// One copier for both buttons, and it clears the other one's receipt.
    ///
    /// Two "Copied." labels sitting on screen at once says the clipboard holds
    /// both, which it cannot — the second copy silently replaced the first, and
    /// the stale receipt is the one people act on.
    private func copy(_ text: String, into receipt: NSTextField?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        promptStatus.stringValue = ""
        status.stringValue = ""
        receipt?.stringValue = "Copied."
        needsLayout = true
    }

    func fittedHeight(width: CGFloat) -> CGFloat {
        let inner = width - 40
        return 16
            + DashboardType.size(promptExplain, width: inner).height + 12
            + 30 + 16
            + 1 + 16
            + DashboardType.size(explain, width: inner).height + 12
            + DashboardType.size(pathLabel, width: inner).height + 12
            + 30 + 16
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let inset: CGFloat = 20
        let inner = bounds.width - inset * 2
        guard inner > 0 else { return }

        func place(_ button: DashboardButton, _ receipt: NSTextField, at y: CGFloat) {
            button.frame = NSRect(x: inset, y: y, width: button.intrinsicWidth, height: 28)
            let size = receipt.fittingSize
            receipt.frame = NSRect(x: inset + button.intrinsicWidth + 10,
                                   y: y + (28 - size.height) / 2, width: 100, height: size.height)
        }

        var y: CGFloat = 16
        let promptHeight = DashboardType.size(promptExplain, width: inner).height
        promptExplain.frame = NSRect(x: inset, y: y, width: inner, height: promptHeight)
        y += promptHeight + 12

        place(promptButton, promptStatus, at: y)
        y += 30 + 16

        divider.frame = NSRect(x: inset, y: y, width: inner, height: 1)
        y += 1 + 16

        let explainHeight = DashboardType.size(explain, width: inner).height
        explain.frame = NSRect(x: inset, y: y, width: inner, height: explainHeight)
        y += explainHeight + 12

        let pathHeight = DashboardType.size(pathLabel, width: inner).height
        pathLabel.frame = NSRect(x: inset, y: y, width: inner, height: pathHeight)
        y += pathHeight + 12

        place(copyButton, status, at: y)
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
