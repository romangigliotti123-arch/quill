import AppKit
import Testing
@testable import QuillKit

// The shell is the one part of the dashboard every other section depends on, so
// the things sections rely on are pinned here rather than left to whoever edits
// the layout next.

@Test @MainActor func sidebarOrderMatchesTheAgreedInformationArchitecture() {
    #expect(DashboardSection.primary == [
        .dictation, .notetaker, .insights, .dictionary,
        .snippets, .style, .transforms, .scratchpad,
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

    func wordmarkColour() -> NSColor? {
        let labels = root.sidebar.subviews.compactMap { $0 as? NSTextField }
        let wordmark = labels.first { $0.attributedStringValue.string == "Quill" }
        return wordmark?.attributedStringValue
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    // Resolved against each appearance, not compared as objects.
    //
    // The palette now takes its text colours from the system — `.labelColor` and
    // friends — so the light and dark styles hold the SAME NSColor, and comparing
    // them as values says "nothing changed" while the screen plainly does. What
    // this test is actually about is whether the wordmark renders differently in
    // the two appearances, so that is what it now asks.
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

    let colour = try #require(wordmarkColour())
    let inLight = try #require(rgb(colour, .aqua))
    let inDark = try #require(rgb(colour, .darkAqua))
    #expect(inLight != inDark, "the wordmark renders identically in both appearances")

    // And the rail still rebuilds on a theme change rather than going stale.
    root.apply(.dark)
    #expect(wordmarkColour() != nil)
}

@Test @MainActor func previewRendersAtFlowsExactWindowSize() throws {
    // Same pixels Wispr Flow's window occupies, at 2x. If this drifts, every
    // side-by-side comparison after it is measuring the wrong thing.
    let image = DashboardPreviewRenderer.render(section: .dictation, dark: false)
    #expect(image.width == 2700)
    #expect(image.height == 1700)
}
