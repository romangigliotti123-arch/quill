import AppKit

/// The first five minutes, which are the only ones a stranger gives you.
///
/// Quill needs three system permissions and, optionally, an API key. Every one
/// of those fails silently when it is missing: no microphone means "nothing was
/// heard", no Accessibility means the hotkey does nothing at all with no error
/// anywhere, and no key means the model cleanup quietly never runs. Someone who
/// installed this from GitHub would meet all three as "it doesn't work", in an
/// order they did not choose, with a menu-bar icon and no idea what to click.
///
/// So it is asked for once, in order, before any of it can fail.
public final class OnboardingWindowController: NSWindowController {

    /// Whether this Mac has ever run Quill.
    ///
    /// Keyed on the settings file rather than a "hasOnboarded" flag, because a
    /// flag is a fourth piece of state that can disagree with the other three —
    /// and because "erase everything" deletes settings.json, which is exactly
    /// when the setup should come back.
    public static var isFirstRun: Bool {
        !FileManager.default.fileExists(atPath: QuillSettings.defaultURL.path)
    }

    private static var shared: OnboardingWindowController?

    /// Shown at launch on a fresh install, and from Help ▸ Show setup again.
    @discardableResult
    public static func present() -> OnboardingWindowController {
        if let shared, shared.window?.isVisible == true {
            shared.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return shared
        }
        let controller = OnboardingWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    public init() {
        let style = DashboardStyle.resolve(nil)
        let root = OnboardingRootView(style: style)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 620, height: 430)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Welcome to Quill"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.contentView = root
        super.init(window: window)
        root.onFinish = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - The page

final class OnboardingRootView: NSView {

    enum Step: Int, CaseIterable {
        case welcome, permissions, key, ready

        var title: String {
            switch self {
            case .welcome:     return "Quill types what you say"
            case .permissions: return "Three permissions"
            case .key:         return "Cleanup, if you want it"
            case .ready:       return "That's it"
            }
        }
    }

    var onFinish: (() -> Void)?

    private let style: DashboardStyle
    private let material: DashboardMaterialView
    private var heading: NSTextField
    private var blurb: NSTextField
    private let back: DashboardButton
    private let next: DashboardButton
    private let skip: DashboardButton
    private let dots = OnboardingDots()

    private var step: Step = .welcome { didSet { rebuild() } }
    private var body: NSView?
    private var permissionPoll: Timer?

    override var isFlipped: Bool { true }

    init(style: DashboardStyle) {
        self.style = style
        material = DashboardMaterialView(material: .windowBackground,
                                         blending: .behindWindow,
                                         fallback: style.canvasTop)
        heading = DashboardType.label("", font: DashboardType.display, color: style.ink)
        blurb = DashboardType.label("", font: DashboardType.body,
                                    color: style.inkSecondary, lines: 4, lineHeight: 20)
        back = DashboardButton(title: "Back", kind: .ghost, style: style)
        next = DashboardButton(title: "Continue", kind: .primary, style: style)
        skip = DashboardButton(title: "Skip", kind: .ghost, style: style)
        super.init(frame: .zero)

        addSubview(material)
        addSubview(heading)
        addSubview(blurb)
        addSubview(dots)
        addSubview(back)
        addSubview(next)
        addSubview(skip)

        back.onClick = { [weak self] in self?.goBack() }
        next.onClick = { [weak self] in self?.goNext() }
        skip.onClick = { [weak self] in self?.goNext() }
        dots.tint = style
        // QUILL_ONBOARDING_STEP=2 opens straight onto the third page.
        //
        // Same reason every other screen in this app has a shot hook: the only
        // way to look at page three otherwise is to click through pages one and
        // two, which nobody does often enough to catch a layout that broke.
        if let wanted = ProcessInfo.processInfo.environment["QUILL_ONBOARDING_STEP"],
           let index = Int(wanted), let start = Step(rawValue: index) {
            // Assigned, then built by hand. `didSet` does not fire for a property
            // set inside `init`, so the obvious version of this — assign and
            // return — opened a window with a footer, a set of dots and no page
            // at all. The screenshot caught it; nothing else would have.
            step = start
        }
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { permissionPoll?.invalidate() }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func goNext() {
        guard let following = Step(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        step = following
    }

    /// Write the settings file even if nothing was changed.
    ///
    /// `isFirstRun` is "settings.json does not exist", so without this the setup
    /// reappears on every launch until the user happens to change a setting. The
    /// file is the record that the question was asked.
    private func finish() {
        QuillSettings.shared.setHistoryRetention(QuillSettings.shared.historyRetention)
        onFinish?()
    }

    // MARK: Building each step

    private func rebuild() {
        body?.removeFromSuperview()
        permissionPoll?.invalidate()
        permissionPoll = nil

        heading.removeFromSuperview()
        heading = DashboardType.label(step.title, font: DashboardType.display, color: style.ink)
        addSubview(heading)
        blurb.removeFromSuperview()
        blurb = DashboardType.label(blurbText, font: DashboardType.body,
                                    color: style.inkSecondary, lines: 4, lineHeight: 20)
        addSubview(blurb)

        let view: NSView
        switch step {
        case .welcome:     view = welcomeBody()
        case .permissions: view = permissionsBody()
        case .key:         view = keyBody()
        case .ready:       view = readyBody()
        }
        addSubview(view)
        body = view

        back.isHidden = step == .welcome
        skip.isHidden = step != .key
        next.title = step == .ready ? "Start using Quill" : "Continue"
        dots.count = Step.allCases.count
        dots.index = step.rawValue

        if step == .permissions { startPermissionPoll() }
        needsLayout = true
    }

    private var blurbText: String {
        switch step {
        case .welcome:
            return "Hold a key, speak, let go. The words land wherever your caret is. "
                + "Speech recognition runs on this Mac — no audio ever leaves it."
        case .permissions:
            return "Quill needs all three. Each one fails silently when it is missing, "
                + "which is why it asks now rather than the first time you hold the key."
        case .key:
            return "Everything above works with no account and no network. A key adds one "
                + "thing: a model pass that fixes what you said mid-sentence."
        case .ready:
            return "Quill lives in the menu bar. Open it any time for your history, "
                + "your Dictionary and everything else."
        }
    }

    private func welcomeBody() -> NSView {
        let container = OnboardingStack(spacing: 14)
        container.add(OnboardingPoint(style: style, symbol: "waveform",
                                      title: "On-device transcription",
                                      detail: "Apple's Speech framework, running locally. Works on a plane."))
        container.add(OnboardingPoint(style: style, symbol: "keyboard",
                                      title: "Hold right Option to talk",
                                      detail: "Double-tap it for hands-free. Both are changeable in Settings."))
        container.add(OnboardingPoint(style: style, symbol: "text.book.closed",
                                      title: "It learns your words",
                                      detail: "Names, tools and jargon go in the Dictionary and stop coming out wrong."))
        return container
    }

    private func permissionsBody() -> NSView {
        let container = OnboardingStack(spacing: 10)
        for permission in Permission.allCases {
            container.add(OnboardingPermissionRow(style: style, permission: permission))
        }
        return container
    }

    private func startPermissionPoll() {
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let stack = self?.body as? OnboardingStack else { return }
                for row in stack.rows.compactMap({ $0 as? OnboardingPermissionRow }) { row.refresh() }
            }
        }
    }

    private func keyBody() -> NSView { keyStep }

    private lazy var keyStep = OnboardingKeyStep(style: style)

    private func readyBody() -> NSView {
        let container = OnboardingStack(spacing: 14)
        let hold = QuillSettings.shared.hold.displayName
        container.add(OnboardingPoint(style: style, symbol: "mic",
                                      title: "Hold \(hold) and say something",
                                      detail: "Let go and it types. Nothing to click first."))
        container.add(OnboardingPoint(style: style, symbol: "arrow.uturn.backward",
                                      title: "⌥⌫ takes it back",
                                      detail: "Deletes the last thing Quill inserted. Off by a switch in Settings."))
        container.add(OnboardingPoint(style: style, symbol: "questionmark.circle",
                                      title: "If the key does nothing",
                                      detail: "It is almost always Accessibility. The Help tab says what to check."))
        return container
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        material.frame = bounds
        let pad: CGFloat = 40
        let width = bounds.width - pad * 2
        guard width > 0 else { return }

        var y: CGFloat = 56
        heading.frame = NSRect(x: pad, y: y, width: width,
                               height: DashboardType.size(heading, width: width).height)
        y += heading.frame.height + 10
        blurb.frame = NSRect(x: pad, y: y, width: width,
                             height: DashboardType.size(blurb, width: width).height)
        y += blurb.frame.height + 26

        // Centred in what is left, not pinned under the blurb.
        //
        // Pinned, the welcome step put three lines of content at the top of a
        // 560-point window and left 350 points of nothing under them — the same
        // "sized but empty" shape the layout probe was written to find, and the
        // first thing anyone sees of this app. The steps are different heights,
        // so centring is what makes all four look composed instead of one.
        let footerHeight: CGFloat = 76
        let room = bounds.height - y - footerHeight
        if let body {
            let needed = min(room, (body as? OnboardingSizing)?.fittingHeight(width: width) ?? room)
            body.frame = NSRect(x: pad, y: y + min(24, ((room - needed) / 3)).rounded(),
                                width: width, height: needed)
            body.layoutSubtreeIfNeeded()
        }

        let buttonY = bounds.height - footerHeight + 22
        next.frame = NSRect(x: bounds.width - pad - next.intrinsicWidth, y: buttonY,
                            width: next.intrinsicWidth, height: 32)
        skip.frame = NSRect(x: next.frame.minX - 8 - skip.intrinsicWidth, y: buttonY,
                            width: skip.intrinsicWidth, height: 32)
        back.frame = NSRect(x: pad, y: buttonY, width: back.intrinsicWidth, height: 32)
        dots.frame = NSRect(x: bounds.midX - 40, y: buttonY + 12, width: 80, height: 8)
    }
}

// MARK: - Pieces

/// A vertical run of equal-width rows that size themselves.
final class OnboardingStack: NSView, OnboardingSizing {
    private(set) var rows: [NSView] = []
    private let spacing: CGFloat
    override var isFlipped: Bool { true }

    init(spacing: CGFloat) {
        self.spacing = spacing
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func add(_ view: NSView) {
        rows.append(view)
        addSubview(view)
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        let content = rows.reduce(CGFloat(0)) { total, row in
            total + ((row as? OnboardingSizing)?.fittingHeight(width: width) ?? 56)
        }
        return content + spacing * CGFloat(rows.count - 1)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for row in rows {
            let height = (row as? OnboardingSizing)?.fittingHeight(width: bounds.width) ?? 56
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            row.layoutSubtreeIfNeeded()
            y += height + spacing
        }
    }
}

protocol OnboardingSizing { func fittingHeight(width: CGFloat) -> CGFloat }

/// Icon, title, one line under it.
final class OnboardingPoint: NSView, OnboardingSizing {
    private let icon: DashboardIconView
    private let title: NSTextField
    private let detail: NSTextField
    private let style: DashboardStyle
    override var isFlipped: Bool { true }

    init(style: DashboardStyle, symbol: String, title titleText: String, detail detailText: String) {
        self.style = style
        icon = DashboardIconView(image: DashboardIcon.image(
            symbol, pointSize: 15, weight: .medium, color: style.accentInk))
        title = DashboardType.label(titleText, font: DashboardType.title, color: style.ink)
        detail = DashboardType.label(detailText, font: DashboardType.body,
                                     color: style.inkSecondary, lines: 2, lineHeight: 18)
        super.init(frame: .zero)
        addSubview(icon)
        addSubview(title)
        addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fittingHeight(width: CGFloat) -> CGFloat {
        let textWidth = width - 40
        return DashboardType.size(title, width: textWidth).height
            + 3
            + DashboardType.size(detail, width: textWidth).height
    }

    override func layout() {
        super.layout()
        let textX: CGFloat = 40
        let textWidth = bounds.width - textX
        icon.frame = NSRect(x: 4, y: 1, width: 20, height: 20)
        let titleHeight = DashboardType.size(title, width: textWidth).height
        title.frame = NSRect(x: textX, y: 0, width: textWidth, height: titleHeight)
        detail.frame = NSRect(x: textX, y: titleHeight + 3, width: textWidth,
                              height: bounds.height - titleHeight - 3)
    }
}

/// One permission, its reason, and whether it is granted right now.
final class OnboardingPermissionRow: NSView, OnboardingSizing {
    private let permission: Permission
    private let style: DashboardStyle
    private let name: NSTextField
    private let why: NSTextField
    private let dot: DashboardStatusDot
    private let action: DashboardButton
    override var isFlipped: Bool { true }

    init(style: DashboardStyle, permission: Permission) {
        self.permission = permission
        self.style = style
        action = DashboardButton(title: "Grant", kind: .secondary, style: style)
        name = DashboardType.label(permission.rawValue, font: DashboardType.title, color: style.ink)
        why = DashboardType.label(permission.whyQuillNeedsIt, font: DashboardType.body,
                                  color: style.inkSecondary, lines: 2, lineHeight: 18)
        dot = DashboardStatusDot(color: style.inkQuaternary)
        super.init(frame: .zero)
        // `request` prompts when macOS still has a question to ask and opens the
        // pane when it does not. Both are the same button here on purpose: the
        // user pressed "Grant" and does not care which of those two roads gets
        // them there.
        action.onClick = { [weak self] in
            guard let self else { return }
            Permissions.request(self.permission)
        }
        addSubview(name)
        addSubview(why)
        addSubview(dot)
        addSubview(action)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let granted = Permissions.state(of: permission) == .granted
        dot.color = granted ? style.accent : style.inkQuaternary
        action.isHidden = granted
        needsLayout = true
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        let textWidth = width - 26 - 90
        return max(44, DashboardType.size(name, width: textWidth).height
            + 3
            + DashboardType.size(why, width: textWidth).height)
    }

    override func layout() {
        super.layout()
        let textX: CGFloat = 26
        let textWidth = bounds.width - textX - 90
        dot.frame = NSRect(x: 0, y: 1, width: 14, height: 14)
        let nameHeight = DashboardType.size(name, width: textWidth).height
        name.frame = NSRect(x: textX, y: 0, width: textWidth, height: nameHeight)
        why.frame = NSRect(x: textX, y: nameHeight + 3, width: textWidth,
                           height: bounds.height - nameHeight - 3)
        action.frame = NSRect(x: bounds.width - action.intrinsicWidth, y: 0,
                              width: action.intrinsicWidth, height: 28)
    }
}
