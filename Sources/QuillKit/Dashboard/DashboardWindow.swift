import AppKit

/// Supplies the view for a section. Everything else in the dashboard plugs in
/// here; the shell owns the chrome and nothing else.
///
/// Returning `nil` is legitimate — the shell draws its own placeholder, so an
/// unbuilt section is a quiet page rather than an empty rectangle.
public protocol DashboardSectionProvider: AnyObject {
    func dashboardView(for section: DashboardSection, style: DashboardStyle) -> NSView?
}

// MARK: - Root

/// Everything inside the window frame: canvas, sidebar rail, floating panel.
///
/// The window uses `.fullSizeContentView`, so this view's bounds are the
/// window's bounds — which is what lets `DashboardPreviewRenderer` build the
/// identical view in a borderless offscreen window and get a byte-for-byte
/// preview of the shipping layout.
public final class DashboardRootView: NSView, SidebarDelegate {

    public private(set) var style: DashboardStyle
    public weak var provider: DashboardSectionProvider?

    public let sidebar: SidebarView
    private let panel: DashboardCardView
    private let statusPill: DashboardStatusPill
    private var sectionView: NSView?

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle,
                selection: DashboardSection = .dictation,
                provider: DashboardSectionProvider? = nil) {
        self.style = style
        self.provider = provider
        sidebar = SidebarView(style: style, selection: selection)
        panel = DashboardCardView(style: style, elevation: .panel, radius: DashboardRadius.panel)
        statusPill = DashboardStatusPill(style: style)
        super.init(frame: NSRect(origin: .zero, size: DashboardMetrics.windowSize))
        // Clip the section to the panel's corners so a scrolling list stops at
        // the curve instead of squaring it off. Verified to survive
        // `CALayer.render(in:)` — `masksToBounds` does, an explicit `layer.mask`
        // does not, which is why sections must never reach for the latter.
        panel.wantsLayer = true
        panel.layer?.cornerRadius = DashboardRadius.panel
        panel.layer?.cornerCurve = .continuous
        panel.layer?.masksToBounds = true
        addSubview(sidebar)
        addSubview(panel)
        addSubview(statusPill)
        sidebar.delegate = self
        showSection(selection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public var selection: DashboardSection { sidebar.selection }

    /// Engine state, shown once — in the titlebar pill. Repeating it in the
    /// sidebar was the first thing cut in review: two "Ready"s on one screen
    /// means neither is trusted.
    public var statusText: String {
        get { statusPill.text }
        set { statusPill.text = newValue; needsLayout = true }
    }

    public func showSection(_ section: DashboardSection) {
        sectionView?.removeFromSuperview()
        let view = provider?.dashboardView(for: section, style: style)
            ?? DashboardPlaceholderView(section: section, style: style)
        panel.addSubview(view)
        sectionView = view
        needsLayout = true
    }

    public func sidebar(_ sidebar: SidebarView, didSelect section: DashboardSection) {
        showSection(section)
    }

    // Layers keep the colours they were handed, and `draw(_:)` here resolves the
    // palette once — so a theme switch has to walk the tree and rebuild.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(DashboardStyle.resolve(effectiveAppearance))
    }

    public func apply(_ newStyle: DashboardStyle) {
        style = newStyle
        sidebar.style = newStyle
        panel.style = newStyle
        statusPill.style = newStyle
        showSection(sidebar.selection)
        // Shows through during a live resize, when AppKit fills the newly
        // exposed area before the view has drawn into it.
        window?.backgroundColor = newStyle.canvasBottom
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        sidebar.frame = NSRect(x: 0, y: 0, width: DashboardMetrics.sidebarWidth, height: bounds.height)
        panel.frame = DashboardMetrics.panelFrame(in: bounds.size)
        sectionView?.frame = panel.bounds

        let size = statusPill.fittingSize
        statusPill.frame = NSRect(x: bounds.width - DashboardMetrics.panelGap - 6 - size.width,
                                  y: ((DashboardMetrics.titlebarHeight - size.height) / 2).rounded(),
                                  width: size.width, height: size.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.gradient(bounds, radius: 0,
                               top: style.canvasTop, bottom: style.canvasBottom, flipped: true)
        // The panel's own shadow has to be cast from underneath it — a view
        // cannot draw outside its bounds, so the drop shadow lives here.
        let frame = DashboardMetrics.panelFrame(in: bounds.size)
        DashboardDraw.shadowed(style.shadowPanel, flipped: true) {
            style.panel.setFill()
            DashboardDraw.path(frame, DashboardRadius.panel).fill()
        }
    }
}

// MARK: - Status pill

/// Live engine state, parked in the titlebar strip.
///
/// This is the one piece of chrome Flow does not have, and it is the piece that
/// matters most for a hotkey app: the answer to "is it listening, and what do I
/// hold" should be on screen, not in a menu.
public final class DashboardStatusPill: NSView {

    public var style: DashboardStyle { didSet { rebuild() } }
    public var text: String = "Ready" { didSet { rebuild() } }

    private let dot: DashboardStatusDot
    private var label: NSTextField
    private var keycaps: [DashboardKeycap] = []

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle) {
        self.style = style
        dot = DashboardStatusDot(color: style.accent)
        label = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        addSubview(dot)
        addSubview(label)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        dot.color = style.accent
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: DashboardType.caption, .foregroundColor: style.inkSecondary, .kern: 0])
        keycaps.forEach { $0.removeFromSuperview() }
        keycaps = [DashboardKeycap("hold ⌥", style: style)]
        keycaps.forEach(addSubview)
        needsLayout = true
        needsDisplay = true
    }

    public override var fittingSize: NSSize {
        let width = 10 + 14 + 6 + ceil(label.fittingSize.width) + 8
            + keycaps.reduce(0) { $0 + $1.frame.width + 4 } + 6
        return NSSize(width: width, height: 32)
    }

    public override func layout() {
        super.layout()
        var x: CGFloat = 10
        dot.frame = NSRect(x: x, y: (bounds.height - 14) / 2, width: 14, height: 14)
        x += 14 + 6
        let size = label.fittingSize
        label.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
        x += size.width + 8
        for cap in keycaps {
            cap.frame = NSRect(x: x, y: ((bounds.height - cap.frame.height) / 2).rounded(),
                               width: cap.frame.width, height: cap.frame.height)
            x += cap.frame.width + 4
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.fill(bounds, radius: bounds.height / 2,
                           color: style.isDark ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 1, alpha: 0.55))
        DashboardDraw.stroke(bounds, radius: bounds.height / 2, color: style.hairline)
    }
}

// MARK: - Placeholder section

/// What a section looks like before its owner ships it — and the specimen the
/// design system is reviewed against. Header, metric row, content well: the
/// three shapes every section is built from.
public final class DashboardPlaceholderView: NSView {

    private let section: DashboardSection
    private let style: DashboardStyle

    private let eyebrow: NSTextField
    private let heading: NSTextField
    private let blurb: NSTextField
    private let action: DashboardButton
    private let secondary: DashboardButton?
    private var tiles: [DashboardMetricTile] = []
    private let well: DashboardCardView
    private let wellTitle: NSTextField
    private let wellChip: DashboardChip
    private var rowViews: [DashboardSampleRow] = []

    public override var isFlipped: Bool { true }

    public init(section: DashboardSection, style: DashboardStyle) {
        self.section = section
        self.style = style
        eyebrow = DashboardType.label(section.title, font: DashboardType.eyebrow,
                                      color: style.inkTertiary, uppercase: true)
        heading = DashboardType.label(DashboardPlaceholderView.heading(for: section),
                                      font: DashboardType.display, color: style.ink)
        blurb = DashboardType.label(section.blurb, font: DashboardType.body,
                                    color: style.inkSecondary, lines: 2, lineHeight: 20)
        action = DashboardButton(title: section.primaryAction.title,
                                 symbol: section.primaryAction.symbol,
                                 kind: .primary, style: style)
        secondary = section.secondaryAction.map {
            DashboardButton(title: $0.title, symbol: $0.symbol, kind: .secondary, style: style)
        }
        well = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        wellTitle = DashboardType.label("Today", font: DashboardType.headline, color: style.ink)
        wellChip = DashboardChip(text: "\(DashboardPlaceholderView.samples.count) entries", tone: .neutral, style: style)

        super.init(frame: .zero)

        addSubview(eyebrow)
        addSubview(heading)
        addSubview(blurb)
        addSubview(action)
        secondary.map(addSubview)

        for (value, unit, caption, accent) in DashboardPlaceholderView.metrics {
            let tile = DashboardMetricTile(value: value, unit: unit, caption: caption,
                                           accent: accent, style: style)
            addSubview(tile)
            tiles.append(tile)
        }

        addSubview(well)
        well.addSubview(wellTitle)
        well.addSubview(wellChip)
        for (time, text) in DashboardPlaceholderView.samples {
            let row = DashboardSampleRow(time: time, text: text, style: style)
            well.addSubview(row)
            rowViews.append(row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Never the section's own name — the sidebar and the eyebrow have already
    /// said that twice, and a page whose title repeats its tab teaches nothing.
    private static func heading(for section: DashboardSection) -> String {
        switch section {
        case .dictation: return "Everything you have said"
        case .notetaker: return "Record the room, keep the notes"
        case .insights: return "How you actually speak"
        case .dictionary: return "Words only you use"
        case .snippets: return "Say less, insert more"
        case .style: return "How Quill writes for you"
        case .transforms: return "Rewrite it without retyping"
        case .scratchpad: return "Somewhere to think out loud"
        case .settings: return "Quill, tuned to this machine"
        case .help: return "When something goes wrong"
        }
    }

    private static let metrics: [(String, String, String, Bool)] = [
        ("1,284", "words", "dictated today", false),
        ("119", "wpm", "median, last 7 days", true),
        ("0.42", "s", "speech end to text in", false),
    ]

    private static let samples: [(String, String)] = [
        ("9:41 am", "Push the Netlify build once the Firestore rules land — Carlo needs the workshop dashboard before Thursday."),
        ("9:12 am", "Reply to Noah: the booking page is live, the deposit flow goes in tonight, nothing else changes this week."),
        ("8:57 am", "Idea for Quill — let a transform run on the clipboard, not just on the last dictation."),
        ("8:30 am", "Groceries: coffee, oat milk, the good bread from the place on Sydney Road."),
        ("8:04 am", "Draft the Builda Bed copy — lead with the reversible bedhead, the fabric range second, price last."),
        ("7:52 am", "Remind me to check whether the analyzer keeps its context window across a locked session."),
        ("7:41 am", "Yes to Friday, but I'd rather do the morning — afternoon is already booked with the Rosehill thing."),
        ("7:26 am", "Quill beat Flow on latency again this morning. Median 0.42 against 1.1."),
    ]

    public override func layout() {
        super.layout()
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2

        var y = padY
        let eyebrowSize = eyebrow.fittingSize
        eyebrow.frame = NSRect(x: padX, y: y, width: eyebrowSize.width, height: eyebrowSize.height)
        y += eyebrowSize.height + 10

        let headingSize = heading.fittingSize
        heading.frame = NSRect(x: padX, y: y, width: min(headingSize.width, width - 260), height: headingSize.height)
        y += headingSize.height + 8

        let blurbWidth = min(width - 300, 700)
        let blurbHeight = DashboardType.size(blurb, width: blurbWidth).height
        blurb.frame = NSRect(x: padX, y: y, width: blurbWidth, height: blurbHeight)
        y += blurbHeight

        // Actions sit on the heading's optical line, right-aligned.
        let actionWidth = action.intrinsicWidth
        action.frame = NSRect(x: bounds.width - padX - actionWidth,
                              y: padY + eyebrowSize.height + 6, width: actionWidth, height: 36)
        if let secondary {
            let secondaryWidth = secondary.intrinsicWidth
            secondary.frame = NSRect(x: action.frame.minX - 10 - secondaryWidth,
                                     y: action.frame.minY, width: secondaryWidth, height: 36)
        }

        y += DashboardSpace.xl

        let gap = DashboardSpace.md
        let tileWidth = ((width - gap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)).rounded(.down)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: padX + (tileWidth + gap) * CGFloat(index), y: y,
                                width: tileWidth, height: 104)
        }
        y += 104 + DashboardSpace.lg

        well.frame = NSRect(x: padX, y: y, width: width, height: max(120, bounds.height - y - padY))
        let titleSize = wellTitle.fittingSize
        wellTitle.frame = NSRect(x: 20, y: 18, width: titleSize.width, height: titleSize.height)
        wellChip.frame = NSRect(x: 20 + titleSize.width + 10,
                                y: 18 + ((titleSize.height - wellChip.frame.height) / 2).rounded(),
                                width: wellChip.frame.width, height: wellChip.frame.height)

        // Rows are laid out until one would not fit whole. A list that runs off
        // the bottom edge of its container looks like a bug; a list that stops
        // cleanly and obviously has more below it looks like a list.
        var rowY: CGFloat = 18 + titleSize.height + 14
        for row in rowViews {
            let height = row.height(for: well.bounds.width - 2)
            let fits = rowY + height <= well.bounds.height - 4
            row.isHidden = !fits
            guard fits else { continue }
            row.frame = NSRect(x: 1, y: rowY, width: well.bounds.width - 2, height: height)
            rowY += height
        }
    }
}

/// A number and what it means. Deliberately not a card — the tiles read as one
/// horizontal band divided by rules, which keeps three numbers from looking like
/// three unrelated widgets.
public final class DashboardMetricTile: NSView {

    private let style: DashboardStyle
    private let accent: Bool
    private let value: NSTextField
    private let caption: NSTextField

    public override var isFlipped: Bool { true }

    public init(value: String, unit: String, caption: String, accent: Bool, style: DashboardStyle) {
        self.style = style
        self.accent = accent

        // Number and unit are one attributed string, not two labels. Two labels
        // means aligning a 30pt box against a 14pt box by hand, and every
        // hand-aligned baseline is wrong by two or three points in a way you
        // cannot unsee. The text system already knows where the baseline is.
        let line = NSMutableAttributedString(string: value, attributes: [
            .font: DashboardType.metric,
            .foregroundColor: accent ? style.accent : style.ink,
            .kern: -0.9,
        ])
        line.append(NSAttributedString(string: "  " + unit, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: style.inkTertiary,
            .kern: 0,
        ]))
        let field = NSTextField(labelWithString: "")
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.attributedStringValue = line
        self.value = field

        self.caption = DashboardType.label(caption, font: DashboardType.callout, color: style.inkSecondary)
        super.init(frame: .zero)
        addSubview(self.value)
        addSubview(self.caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        let valueSize = value.fittingSize
        value.frame = NSRect(x: 20, y: 22, width: min(valueSize.width, bounds.width - 40), height: valueSize.height)
        let captionSize = caption.fittingSize
        caption.frame = NSRect(x: 20, y: 22 + valueSize.height + 10,
                               width: min(captionSize.width, bounds.width - 40), height: captionSize.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        DashboardDraw.sunkenSurface(bounds, radius: DashboardRadius.card, style: style, flipped: true)
        if accent {
            // One hairline of colour along the top edge, clipped to the corner
            // curve. Enough to say "this is the number that matters".
            NSGraphicsContext.saveGraphicsState()
            DashboardDraw.path(bounds, DashboardRadius.card).addClip()
            style.accent.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// One history row: timestamp gutter, text, hairline. The gutter is a fixed
/// column so four rows scan as a table rather than four paragraphs.
public final class DashboardSampleRow: NSView {

    private let style: DashboardStyle
    private let time: NSTextField
    private let text: NSTextField

    public override var isFlipped: Bool { true }

    public init(time: String, text: String, style: DashboardStyle) {
        self.style = style
        self.time = DashboardType.label(time, font: DashboardType.mono, color: style.inkTertiary)
        self.text = DashboardType.label(text, font: DashboardType.body, color: style.ink,
                                        lines: 3, lineHeight: 21)
        super.init(frame: .zero)
        addSubview(self.time)
        addSubview(self.text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func height(for width: CGFloat) -> CGFloat {
        DashboardType.size(text, width: width - 130).height + 28
    }

    public override func layout() {
        super.layout()
        let timeSize = time.fittingSize
        time.frame = NSRect(x: 20, y: 15, width: timeSize.width, height: timeSize.height)
        let textWidth = bounds.width - 130
        text.frame = NSRect(x: 106, y: 13, width: textWidth,
                            height: DashboardType.size(text, width: textWidth).height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        style.hairline.setFill()
        NSRect(x: 20, y: 0, width: bounds.width - 40, height: 1).fill()
    }
}

// MARK: - Window

/// The dashboard window.
///
/// `LSUIElement` is true, which makes Quill an accessory app — and an accessory
/// app cannot reliably front a window. `makeKeyAndOrderFront` on an accessory
/// gets you a window behind whatever you were just typing in, with a title bar
/// that never goes key, because the app is not allowed to be the active one.
///
/// So the policy flips: `.regular` while any dashboard window is open, back to
/// `.accessory` when the last one closes. That is what keeps the menu-bar item
/// as the app's normal face while still giving the window real focus. The Dock
/// icon appearing while the window is open is the price, and it is the same
/// trade every menu-bar app with a real window makes.
public final class DashboardWindowController: NSWindowController, NSWindowDelegate {

    private static var openWindows = 0
    private static var savedMainMenu: NSMenu?

    public let rootView: DashboardRootView

    public init(provider: DashboardSectionProvider? = nil, selection: DashboardSection = .dictation) {
        let style = DashboardStyle.resolve(nil)
        rootView = DashboardRootView(style: style, selection: selection, provider: provider)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: DashboardMetrics.windowSize),
            // A window, not an NSPanel: panels do not take the main-window role,
            // and a dashboard that never becomes main leaves every text field in
            // it drawing an inactive selection.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Quill"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = DashboardMetrics.minWindowSize
        window.backgroundColor = style.canvasBottom
        window.isReleasedWhenClosed = false
        // Tabs bring a system tab bar, which is exactly the default chrome this
        // window is drawn from scratch to avoid.
        window.tabbingMode = .disallowed
        window.toolbar = nil
        window.contentView = rootView
        window.center()
        window.setFrameAutosaveName("QuillDashboard")

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func present() {
        guard let window else { return }
        if DashboardWindowController.openWindows == 0 {
            DashboardWindowController.savedMainMenu = NSApp.mainMenu
            // A .regular app with no main menu shows an empty menu bar — worse
            // than a Dock icon. Install one before the policy flip, not after.
            NSApp.mainMenu = DashboardMainMenu.make()
            NSApp.setActivationPolicy(.regular)
        }
        DashboardWindowController.openWindows += 1

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // The policy change is asynchronous inside AppKit: on the first flip the
        // activation lands before the app is regular, and the window comes up
        // unfocused behind the previous app. Ordering front once more on the
        // next turn of the runloop is the cheap, reliable fix.
        DispatchQueue.main.async {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        DashboardWindowController.openWindows = max(0, DashboardWindowController.openWindows - 1)
        guard DashboardWindowController.openWindows == 0 else { return }
        // Back to the menu bar. Deferred, because flipping the policy inside the
        // close notification leaves the Dock icon behind.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            NSApp.mainMenu = DashboardWindowController.savedMainMenu
        }
    }
}

// MARK: - Menu

public enum DashboardMainMenu {

    /// The minimum credible menu bar for the window's lifetime. Edit is not
    /// optional — without it ⌘C/⌘V do nothing in any text field in the window,
    /// which users read as the app being broken.
    public static func make() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Quill", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Quill", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Quill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        return main
    }
}
