import AppKit
import Testing
@testable import QuillKit

// The shell is the one part of the dashboard every other section depends on, so
// the things sections rely on are pinned here rather than left to whoever edits
// the layout next.

@Test @MainActor func sidebarOrderMatchesTheAgreedInformationArchitecture() {
    // Reordered by value to the person using it rather than by the order things
    // were built. Insights leads because it is the only screen that answers "is
    // this actually helping me", and it is the one you open on purpose. Notetaker
    // and Scratchpad go last because a person can go a month without opening
    // either.
    //
    // This test earns its place here: the change was deliberate and it still had
    // to be made twice, once in the app and once here, which is the point of
    // pinning an ordering nobody can derive from the code.
    #expect(DashboardSection.primary == [
        .insights, .dictation, .dictionary, .snippets,
        .style, .transforms, .notetaker, .scratchpad,
    ])
    #expect(DashboardSection.footer == [.settings, .help])
    #expect(DashboardSection.allCases.count == DashboardSection.primary.count + DashboardSection.footer.count)
}

@Test @MainActor func everySectionCanBeDrawn() {
    for section in DashboardSection.allCases {
        #expect(NSImage(systemSymbolName: section.symbolName, accessibilityDescription: nil) != nil,
                "missing SF Symbol \(section.symbolName) for \(section.rawValue)")
        #expect(!section.blurb.isEmpty)
        // A page title that repeats the tab name teaches nothing, and the
        // placeholder is what a half-built section shows for weeks.
        #expect(!section.primaryAction.title.isEmpty)
    }
}

@Test @MainActor func theWindowIsAWindowAndFillsItsFrame() {
    let controller = DashboardWindowController()
    let window = try! #require(controller.window)

    // A panel cannot become main, and a dashboard that is never main draws
    // every text selection in it as inactive.
    #expect(!(window is NSPanel))
    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.styleMask.contains(.resizable))
    #expect(window.titlebarAppearsTransparent)
    #expect(window.titleVisibility == .hidden)
    #expect(window.tabbingMode == .disallowed)
    #expect(window.frame.size == DashboardMetrics.windowSize)

    // `.fullSizeContentView` is what makes the offscreen preview honest: the
    // root view's bounds are the window's bounds, so what the renderer draws is
    // the whole window and not the area under a titlebar.
    #expect(controller.rootView.frame.size == window.frame.size)
}

@Test @MainActor func selectingASectionSwapsTheContent() {
    let root = DashboardRootView(style: .light)
    root.frame = NSRect(origin: .zero, size: DashboardMetrics.windowSize)
    root.layoutSubtreeIfNeeded()
    #expect(root.selection == .dictation)

    root.sidebar.select(.snippets)
    #expect(root.selection == .snippets)
}

@Test @MainActor func layoutLeavesNoOverlapBetweenTheRailAndThePanel() {
    let root = DashboardRootView(style: .dark)
    root.frame = NSRect(origin: .zero, size: DashboardMetrics.windowSize)
    root.layoutSubtreeIfNeeded()

    let panel = DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize)
    #expect(panel.minX >= DashboardMetrics.sidebarWidth)
    #expect(panel.maxX == DashboardMetrics.windowSize.width - DashboardMetrics.panelGap)
    #expect(panel.maxY == DashboardMetrics.windowSize.height - DashboardMetrics.panelGap)
}

@Test @MainActor func switchingThemeRecoloursTheRailsStaticText() throws {
    // The palette is resolved eagerly, so nothing follows the system on its
    // own. Anything the rail draws once and never touches again is dark text on
    // a dark background the moment the Mac switches to dark mode.
    let root = DashboardRootView(style: .light)
    root.frame = NSRect(origin: .zero, size: DashboardMetrics.windowSize)
    root.layoutSubtreeIfNeeded()

    // The nav labels, not the wordmark. The wordmark is gone — the app's own
    // icon and name inside its own window is a website header, and no Apple app
    // does it. The rail's static text is now the row labels, so they are what
    // this has to hold.
    func railTextColour() -> NSColor? {
        func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? labels(in: $0) }
        }
        let named = labels(in: root.sidebar).first {
            $0.attributedStringValue.string == DashboardSection.dictation.title
        }
        return named?.attributedStringValue
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    // Resolved against each appearance, not compared as objects.
    //
    // The palette now takes its text colours from the system — `.labelColor` and
    // friends — so the light and dark styles hold the SAME NSColor, and comparing
    // them as values says "nothing changed" while the screen plainly does. What
    // this test is actually about is whether the rail's text renders differently
    // in the two appearances, so that is what it now asks.
    //
    // The original concern has not gone away, it has moved: a dynamic colour
    // follows the appearance only where AppKit resolves it at draw time. Anything
    // pushed into a CALayer as a cgColor still resolves once and stays put, which
    // is why `DashboardMaterialView` is restyled explicitly on a theme change.
    func rgb(_ color: NSColor, _ appearance: NSAppearance.Name) -> NSColor? {
        var out: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)
        }
        return out
    }

    let colour = try #require(railTextColour())
    let inLight = try #require(rgb(colour, .aqua))
    let inDark = try #require(rgb(colour, .darkAqua))
    #expect(inLight != inDark, "the rail's text renders identically in both appearances")

    // And the rail still rebuilds on a theme change rather than going stale.
    root.apply(.dark)
    #expect(railTextColour() != nil)
}

@Test @MainActor func previewRendersAtFlowsExactWindowSize() throws {
    // Same pixels Wispr Flow's window occupies, at 2x. If this drifts, every
    // side-by-side comparison after it is measuring the wrong thing.
    let image = DashboardPreviewRenderer.render(section: .dictation, dark: false)
    #expect(image.width == 2700)
    #expect(image.height == 1700)
}

@Test @MainActor func everySectionPutsItsTitleInTheSamePlace() {
    // Roman, looking at the app: "all of the tabs don't have the exact layout —
    // the heading of the tab at the top is in different positions."
    //
    // Measured across five rendered sections, the titles spread 65 points. Two
    // causes: some sections put a small-caps eyebrow above the title and some did
    // not, so the titles could never line up; and Transforms sized its header box
    // at a fixed 26pt around a 28pt face, which crops the leading and lifts the
    // glyphs. Both are fixed, and this stops either coming back.
    //
    // Asserted on the frames rather than on pixels: a render is slow, needs a
    // window server, and answers the same question less precisely.
    var tops: [DashboardSection: CGFloat] = [:]
    for section in [DashboardSection.dictation, .insights, .dictionary, .snippets, .transforms] {
        guard let view = DashboardSectionRegistry.shared.dashboardView(for: section, style: .dark)
        else { continue }
        view.frame = NSRect(origin: .zero,
                            size: DashboardMetrics.sectionFrame(
                                in: DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize)).size)
        view.layoutSubtreeIfNeeded()

        func titles(in v: NSView) -> [NSTextField] {
            v.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? titles(in: $0) }
        }
        // The title is the one drawn in the display face.
        let title = titles(in: view).first { $0.font?.pointSize == DashboardType.display.pointSize }
        if let title { tops[section] = view.convert(title.frame.origin, from: title.superview).y }
    }

    let values = Array(tops.values)
    guard let low = values.min(), let high = values.max() else { return }
    #expect(high - low <= 2,
            "section titles span \(Int(high - low))pt: \(tops.map { "\($0.key.rawValue) \(Int($0.value))" }.sorted())")
}
