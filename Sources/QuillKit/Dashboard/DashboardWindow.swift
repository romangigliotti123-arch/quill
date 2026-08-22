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
    /// The translucent plate the sidebar sits on. Behind-window blending, so it
    /// picks up the desktop rather than a colour we invented.
    private let sidebarMaterial: DashboardMaterialView
    /// The content area, also behind-window.
    ///
    /// It was `.contentBackground` within-window, which blurs what is inside the
    /// window and therefore blurs nothing — the window was see-through at the
    /// sidebar and solid everywhere else, which is exactly what Roman noticed.
    /// `.windowBackground` behind-window is the material a translucent Mac window
    /// uses for its body. NOT `.underWindowBackground`, which was tried first and
    /// is the most transparent material AppKit has: he asked to see the window
    /// behind "slightly", and through that one the desktop competes with the text
    /// rather than sitting behind it.
    private let panel: DashboardMaterialView
    private let statusPill: DashboardStatusPill
    /// The one-pixel line between sidebar and content.
    ///
    /// A view rather than a stroke in `draw(_:)`, because draw runs on the root
    /// and both materials are subviews ON TOP of it — the line was being painted
    /// and then immediately covered, which is why the two surfaces met at a hard
    /// tonal step with nothing between them. Every AppKit split view draws this
    /// line, and its absence is most of why the join looked wrong.
    private let divider = NSView()
    private var sectionView: NSView?

    public override var isFlipped: Bool { true }

    public init(style: DashboardStyle,
                selection: DashboardSection = DashboardSection.opensOn,
                provider: DashboardSectionProvider? = nil) {
        self.style = style
        self.provider = provider
        sidebar = SidebarView(style: style, selection: selection)
        sidebarMaterial = DashboardMaterialView(material: .sidebar,
                                                blending: .behindWindow,
                                                fallback: style.canvasBottom)
        panel = DashboardMaterialView(material: .windowBackground,
                                      blending: .behindWindow,
                                      fallback: style.canvasTop)
        statusPill = DashboardStatusPill(style: style)
        super.init(frame: NSRect(origin: .zero, size: DashboardMetrics.windowSize))
        // Clip the section to the panel's corners so a scrolling list stops at
        // the curve instead of squaring it off. Verified to survive
        // `CALayer.render(in:)` — `masksToBounds` does, an explicit `layer.mask`
        // does not, which is why sections must never reach for the latter.
        // Only the two corners away from the sidebar. The content area meets the
        // sidebar square, the way a split view does, and rounds where the window
        // itself rounds — rounding all four is what made it a floating card.
        panel.round(corners: [.layerMinXMinYCorner, .layerMinXMaxYCorner], radius: 0)
        addSubview(sidebarMaterial)
        addSubview(sidebar)
        addSubview(panel)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = style.hairlineStrong.cgColor
        addSubview(divider)
        sidebar.delegate = self
        // No fade on the first paint: there is nothing to cross-fade from, and
        // starting at zero opacity is what made offscreen renders come out blank.
        showSection(selection, animated: false)
        observeReloads()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    public var selection: DashboardSection { sidebar.selection }

    /// Engine state, shown once — in the titlebar pill. Repeating it in the
    /// sidebar was the first thing cut in review: two "Ready"s on one screen
    /// means neither is trusted.
    public var statusText: String {
        get { statusPill.text }
        set { statusPill.text = newValue; needsLayout = true }
    }

    /// Swap the visible section.
    ///
    /// `animated` is false for the first paint and for offscreen rendering. The
    /// offscreen case is not cosmetic: the renderer used to capture a frame of
    /// the cross-fade, so every screenshot this project has ever taken of a
    /// section came out as an empty panel — the fade begins at zero opacity, and
    /// a view that is transparent when AppKit first walks the tree never gets its
    /// layer contents drawn at all. A harness whose whole job is to show what a
    /// screen looks like was reporting every screen as blank, and reporting it
    /// silently, with a valid PNG and a zero exit code.
    public func showSection(_ section: DashboardSection, animated: Bool = true) {
        let outgoing = sectionView
        let view = provider?.dashboardView(for: section, style: style)
            ?? DashboardPlaceholderView(section: section, style: style)

        // Cross-fade with a slight rise. A hard cut between two dense screens
        // reads as a glitch; a slow one reads as waiting. 0.18s with a small
        // upward offset is the range where the eye registers "this replaced that"
        // without being asked to sit through it.
        view.alphaValue = animated ? 0 : 1
        panel.addSubview(view)
        sectionView = view
        layoutSubtreeIfNeeded()

        guard animated else {
            // Synchronously, not in a completion handler. Two showSection calls
            // landing inside one 0.18s window left both views parented, stacked
            // and half-transparent — which is the second reason the renders were
            // unreadable.
            outgoing?.removeFromSuperview()
            needsLayout = true
            return
        }

        // A spring, not a cubic curve, and this is the case that shows why:
        // click three sidebar rows quickly and a Bezier either snaps to each new
        // target or restarts from zero, because a curve has no notion of the
        // velocity it was already carrying. A spring redirects. Apple's guidance
        // is that anything a person can interrupt should be one.
        //
        // Fade only. No movement, and the reason is a bug rather than taste.
        //
        // Roman: "some of them have the tab sort of drop down and fade in, and
        // then other ones just have it fade in." He is right, and the cause is
        // that the rise animated the view's frame ORIGIN while the root's
        // layout() sets that same origin every time it runs. Any section that
        // triggers a layout pass mid-animation — the scrolling ones do, the
        // static ones do not — had its rise stomped and simply faded. Two
        // different animations from one piece of code, decided by whether the
        // incoming screen happened to lay itself out.
        //
        // Animating position on a view whose position is owned by a layout method
        // is a race that cannot be won, so it does not move at all now. Every
        // section fades, identically, which is also what the HIG asks for on an
        // interaction this frequent.
        DashboardMotion.spring(DashboardMotion.viewSpring) { _ in
            view.animator().alphaValue = 1
            outgoing?.animator().alphaValue = 0
        } completion: {
            outgoing?.removeFromSuperview()
        }

        needsLayout = true
    }

    public func sidebar(_ sidebar: SidebarView, didSelect section: DashboardSection) {
        showSection(section)
    }

    /// Rebuild the visible section after it mutated something it displays —
    /// picking a tone, adding a note. Only the section on screen is rebuilt: a
    /// screen that refreshes everything is how two views end up disagreeing about
    /// the same data, and a screen that refreshes nothing is how a click appears
    /// to do nothing at all.
    private func observeReloads() {
        NotificationCenter.default.addObserver(
            forName: .quillDashboardNeedsReload, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.showSection(self.sidebar.selection) }
        }
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
        sidebarMaterial.restyle(fallback: newStyle.canvasBottom)
        panel.restyle(fallback: newStyle.canvasTop)
        divider.layer?.backgroundColor = newStyle.hairlineStrong.cgColor
        // Not animated. A theme change is not a navigation, and cross-fading here
        // leaves two section views parented for 0.18s — which the offscreen
        // renderer captures, because it renders light and dark from the same root
        // by applying a style between shots. It was invisible while both copies
        // sat at the same frame and appeared the moment they did not.
        showSection(sidebar.selection, animated: false)
        // Stays clear through a theme change. The materials carry the surface
        // now, and giving the window a colour again would put an opaque sheet in
        // front of the blending.
        window?.backgroundColor = .clear
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        sidebarMaterial.frame = NSRect(x: 0, y: 0,
                                       width: DashboardMetrics.sidebarWidth, height: bounds.height)
        sidebar.frame = sidebarMaterial.frame
        panel.frame = DashboardMetrics.panelFrame(in: bounds.size)
        divider.frame = NSRect(x: DashboardMetrics.sidebarWidth - 1, y: 0, width: 1, height: bounds.height)
        sectionView?.frame = DashboardMetrics.sectionFrame(in: panel.bounds)

        // The status pill used to live here. Removed: it said "Ready" at all
        // times except during a dictation, when the overlay is already saying so
        // an inch from the cursor, and repeated a shortcut the user is holding
        // down at the moment they can read it. A permanent label for a transient
        // state is chrome, not information.
    }

    /// Nothing to draw any more, and the omission is the point.
    ///
    /// This used to paint a canvas gradient and then cast a drop shadow under a
    /// floating content panel. Both are how a web page fakes depth. A Mac window
    /// gets its depth from the window itself and from one material sitting
    /// against another, and drawing a gradient here would sit *in front of* the
    /// behind-window blending and cancel the translucency it exists for.
    ///
    /// The one line kept is the divider. A sidebar and a content area that meet
    /// with no seam read as one flat surface at most desktop backgrounds, and
    /// AppKit's own split views draw exactly this hairline.
    /// Nothing. The materials cover this view entirely and the divider is a
    /// subview, so anything painted here is painted for nobody.
    public override func draw(_ dirtyRect: NSRect) {}
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

    deinit { NotificationCenter.default.removeObserver(self) }

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
        // Reads the live binding. A keycap in the titlebar that names a key the
        // user rebound is worse than no keycap at all.
        keycaps = [DashboardKeycap("hold \(QuillSettings.shared.hold.capText)", style: style)]
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
/// Shown for a section that does not exist yet.
///
/// It used to invent its content: "1,284 words dictated today", "119 wpm", and
/// eight fabricated dictations — "Groceries: coffee, oat milk…", "Quill beat Flow
/// on latency again this morning" — rendered exactly like real history with no
/// marker distinguishing them. Anyone opening Transforms would have read their
/// own past week off a screen that was making it up.
///
/// A section with nothing behind it says so.
public final class DashboardPlaceholderView: NSView {

    private let heading: NSTextField
    private let body: NSTextField

    public override var isFlipped: Bool { true }

    public init(section: DashboardSection, style: DashboardStyle) {
        heading = DashboardType.label(section.title, font: DashboardType.display, color: style.ink)
        body = DashboardType.label(DashboardPlaceholderView.explanation(for: section),
                                   font: DashboardType.body, color: style.inkSecondary,
                                   lines: 3, lineHeight: 20)
        super.init(frame: .zero)
        addSubview(heading)
        addSubview(body)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What the section will do, stated plainly. No numbers, because there are none.
    private static func explanation(for section: DashboardSection) -> String {
        switch section {
        case .transforms:
            return "Not built yet. It will rewrite what you just said — shorten it, make it a list, change the tone — without retyping it."
        case .settings:
            return "Not built yet. Hotkey, microphone, vocabulary and the AI connection are configurable from the menu bar in the meantime."
        case .help:
            return "Not built yet."
        default:
            return "Not built yet."
        }
    }

    public override func layout() {
        super.layout()
        let padX = DashboardMetrics.contentPaddingX
        let padY = DashboardMetrics.contentPaddingY
        let width = bounds.width - padX * 2
        guard width > 0 else { return }

        let headingSize = heading.fittingSize
        heading.frame = NSRect(x: padX, y: padY, width: headingSize.width, height: headingSize.height)

        let bodyWidth = min(width, 520)
        let bodyHeight = DashboardType.size(body, width: bodyWidth).height
        body.frame = NSRect(x: padX, y: padY + headingSize.height + 10,
                            width: bodyWidth, height: bodyHeight)
    }
}

// MARK: - Window

/// One mutable flag shared between an observer and the retry it can cancel.
private final class ActivationRetry {
    var value = false
}

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

    public init(provider: DashboardSectionProvider? = DashboardSectionRegistry.shared,
                selection: DashboardSection = DashboardSection.opensOn) {
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
        // Clear and non-opaque, or behind-window blending has nothing to blend
        // with: AppKit composites the window background OVER the material and the
        // sidebar comes out a flat colour that merely looks like vibrancy.
        window.backgroundColor = .clear
        window.isOpaque = false
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

    deinit { NotificationCenter.default.removeObserver(self) }

    public func present() {
        guard let window else { return }

        // Count windows, not calls.
        //
        // This incremented on every present() but only decremented in
        // windowWillClose, so pressing the menu-bar item while the dashboard was
        // already open pushed the count to two and closing it left one behind.
        // The app then stayed .regular for the rest of the session: Dock icon
        // that will not go away, and a full menu bar belonging to a window that
        // no longer exists.
        let wasAlreadyOpen = window.isVisible
        if !wasAlreadyOpen {
            // Back to Insights on every fresh open.
            //
            // The controller is kept alive between opens so the window does not
            // rebuild from nothing each time, which also means it reappears on
            // whatever tab it was closed on. "Open Quill" is not "resume what I
            // was doing" — the thing the user was doing is in their document, and
            // they came here to see how it is going. Deliberate navigation to
            // another tab still survives switching away and back, because that
            // leaves the window visible and never reaches this branch.
            if rootView.selection != DashboardSection.opensOn {
                rootView.showSection(DashboardSection.opensOn, animated: false)
            }
            if DashboardWindowController.openWindows == 0 {
                DashboardWindowController.savedMainMenu = NSApp.mainMenu
                // A .regular app with no main menu shows an empty menu bar —
                // worse than a Dock icon. Install one before the policy flip.
                NSApp.mainMenu = DashboardMainMenu.make()
                NSApp.setActivationPolicy(.regular)
            }
            DashboardWindowController.openWindows += 1
        }

        // Activate ONCE.
        //
        // This used to activate immediately and then again on the next turn of
        // the runloop, because a policy flip is asynchronous inside AppKit and an
        // activation issued in the same turn is ignored. The second one fixed
        // that and created something worse: it fires roughly a frame later, by
        // which time the user may already have clicked another application — and
        // it drags Quill back in front of whatever they just chose. Measured: open
        // the dashboard, click another app 100ms later, and Quill is frontmost
        // again. That is the window refusing to get out of the way.
        //
        // So it happens once, at the only moment it can work: deferred when the
        // policy has just changed, immediate when it has not.
        // Forceful, because an accessory app that has just become .regular is not
        // allowed to activate politely: `NSApp.activate()` is refused and the
        // window comes up behind whatever the user was typing in. This runs in
        // direct response to them clicking Quill's menu-bar item, which is what
        // the forceful variant is for.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // The very first flip to .regular is asynchronous inside AppKit, and even
        // a forced activation issued in the same turn is dropped — measured, the
        // window comes up behind the previous app every time. So there is one
        // retry, and the retry is the part that used to be the bug: it fired
        // unconditionally a frame or more later, by which time the user could
        // already have clicked another application, and it hauled Quill back in
        // front of what they had just chosen. Measured at a 100ms gap, Quill won.
        //
        // It now cancels itself the moment any other application becomes active.
        // That is the difference between "the window failed to come forward" and
        // "the user went somewhere else", which is the only thing the old code
        // could not tell apart.
        guard !wasAlreadyOpen, DashboardWindowController.openWindows == 1 else { return }
        let cancelled = ActivationRetry()
        let workspace = NSWorkspace.shared.notificationCenter
        let me = ProcessInfo.processInfo.processIdentifier
        let observer = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != me { cancelled.value = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak window] in
            workspace.removeObserver(observer)
            guard let window, !cancelled.value, !window.isKeyWindow else { return }
            // Ask the system as well as the notification.
            //
            // The observer above cancels the retry when another app activates,
            // and it loses a race: didActivateApplicationNotification is
            // delivered asynchronously, so a click landing inside this 50ms
            // window can be in flight while the retry fires. Quill then hauls
            // itself back in front of whatever was just chosen — which is exactly
            // "I open the app, click the terminal, and it stays on top", and
            // exactly the failure the observer was added to prevent.
            //
            // frontmostApplication is the system's answer at the moment it is
            // asked rather than a message that may still be on its way, so the
            // two together cannot both be wrong.
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front == nil || front == me else { return }
            NSApp.activate(ignoringOtherApps: true)
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

    deinit { NotificationCenter.default.removeObserver(self) }

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

    deinit { NotificationCenter.default.removeObserver(self) }

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
