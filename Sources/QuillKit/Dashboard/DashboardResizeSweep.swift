import AppKit

/// Drives the real window through a series of sizes and captures each one.
///
/// This exists because the offscreen renderer, useful as it is, builds a fresh
/// view tree at a fixed size — so it can prove a layout is correct *at* a size
/// and can say nothing about what happens when a window *changes* size. The two
/// failures it structurally cannot see are the ones a person hits first: a
/// tracking area left behind at the old bounds, so a control stays lit after the
/// pointer has gone; and a constraint that only breaks while a frame is in
/// motion.
///
/// It captures with `cacheDisplay(in:)` rather than `screencapture`, which means
/// no Screen Recording permission and no dependence on the window being visible,
/// unobscured or on the active Space. What comes out is the real window's real
/// contents after a real resize.
///
/// `QUILL_RESIZE_SWEEP=/dir` runs it and exits.
public enum DashboardResizeSweep {

    /// Widths that have actually caught something, plus the two ends of the range.
    /// 1060x700 is the documented minimum; 1120x760 and 1160x740 are where the
    /// Insights and Dictionary collisions were first reproduced.
    public static let sizes: [NSSize] = [
        NSSize(width: 1060, height: 700),
        NSSize(width: 1120, height: 760),
        NSSize(width: 1160, height: 740),
        NSSize(width: 1350, height: 850),
        NSSize(width: 1700, height: 1040),
        // Back to the minimum last, and deliberately: shrinking after growing is
        // a different code path from starting small, and it is the one that
        // leaves stale frames behind.
        NSSize(width: 1060, height: 700),
    ]

    @MainActor
    public static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["QUILL_RESIZE_SWEEP"] else { return false }
        let outputDir = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Only the sections named, if any were. A sweep over all ten at six sizes
        // is 120 images nobody reads.
        let sections = ProcessInfo.processInfo.environment["QUILL_DASHBOARD_SECTIONS"]?
            .split(separator: ",")
            .compactMap { DashboardSection(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            ?? DashboardSection.allCases

        let controller = DashboardWindowController()
        controller.present()
        guard let window = controller.window,
              let root = window.contentView as? DashboardRootView
        else { return true }

        for section in sections {
            root.sidebar.select(section)
            for (index, size) in sizes.enumerated() {
                window.setContentSize(size)
                // Let AppKit finish: setContentSize schedules layout rather than
                // performing it, and capturing on the same turn photographs the
                // previous size.
                settle()
                let name = "\(section.rawValue)-\(index)-\(Int(size.width))x\(Int(size.height)).png"
                write(window, to: outputDir.appendingPathComponent(name))
                print(name)
            }
        }
        return true
    }

    /// Runs the runloop long enough for layout, and for the display links driving
    /// hover and selection tweens to come to rest.
    @MainActor
    private static func settle() {
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor
    private static func write(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
