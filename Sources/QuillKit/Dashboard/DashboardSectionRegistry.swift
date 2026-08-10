import AppKit

/// Where built sections plug into the shell.
///
/// `DashboardRootView` asks a provider for a view and draws a placeholder when
/// it gets `nil`, which is what lets eight sections land independently. This is
/// the single provider that knows about all of them, so adding a section is one
/// line here rather than an edit to the window, the renderer and the app
/// delegate.
///
/// It is deliberately not a global mutable free-for-all: builders are closures
/// registered once at construction, so the offscreen renderer and the shipping
/// window are guaranteed to be looking at the same set of screens. A registry
/// that could be half-populated would let a section pass review in the PNG and
/// be missing in the app.
public final class DashboardSectionRegistry: DashboardSectionProvider {

    public static let shared = DashboardSectionRegistry()

    private var builders: [DashboardSection: (DashboardStyle) -> NSView?] = [:]

    private init() {
        // One line per shipped section. A section that exists but is not
        // registered renders as a blank pane in the app while still looking
        // finished in its own preview PNG — which is exactly how four sections
        // can pass review and none of them appear.
        register(.insights) { InsightsView(style: $0) }
        register(.dictation) { DictationSectionProvider().dashboardView(for: .dictation, style: $0) }
        register(.dictionary) { DictionarySectionView(style: $0, entries: DictionaryEntry.entries()) }
        register(.snippets) { SnippetsSectionProvider().dashboardView(for: .snippets, style: $0) }
        register(.scratchpad) { ScratchpadSectionView(style: $0, notes: NoteStore.shared.all) }
        register(.style) { StyleSectionView(style: $0, profile: StyleStore.shared.profile) }
        register(.notetaker) { NotetakerSectionView(style: $0) }
        register(.settings) { SettingsSectionView(style: $0) }
    }

    public func register(_ section: DashboardSection, _ builder: @escaping (DashboardStyle) -> NSView?) {
        builders[section] = builder
    }

    public func dashboardView(for section: DashboardSection, style: DashboardStyle) -> NSView? {
        builders[section]?(style)
    }
}
