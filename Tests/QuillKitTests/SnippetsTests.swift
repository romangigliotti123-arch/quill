import AppKit
import Testing
@testable import QuillKit

// The expander edits text the user is about to send to someone else. The tests
// that matter here are therefore not "does it work" but "does it refuse" — a
// snippet that fails to fire costs a retype, and a snippet that fires when it
// should not costs a paragraph of a client quote in the wrong message.

private func snippet(_ phrase: String,
                     _ replacement: String,
                     mode: Snippet.Mode = .anywhere,
                     enabled: Bool = true) -> Snippet {
    Snippet(phrase: phrase, replacement: replacement, mode: mode, isEnabled: enabled)
}

// MARK: - Firing

@Test func firesInTheMiddleOfASentence() {
    let s = snippet("deposit terms", "50% up front, the rest on launch.")
    let result = SnippetExpander().expand("Send them the deposit terms and I'll follow up.", using: [s])
    #expect(result.text == "Send them the 50% up front, the rest on launch. And I'll follow up.")
    #expect(result.firings.map(\.id) == [s.id])
}

@Test func capitalisesTheWordAfterAReplacementThatEndedTheSentence() {
    // The cleaner has already run by the time we expand, so this is the only
    // place the capital can come from.
    let ends = snippet("deposit terms", "50% up front, the rest on launch.")
    #expect(SnippetExpander().expand("the deposit terms and then some", using: [ends]).text
        == "the 50% up front, the rest on launch. And then some")

    // …and does not invent one where the replacement did not end a sentence.
    let open = snippet("studio link", "https://example.com")
    #expect(SnippetExpander().expand("the studio link and then some", using: [open]).text
        == "the https://example.com and then some")
}

@Test func keepsThePunctuationThatFollowedTheTrigger() {
    // The comma belongs to the sentence, not to the phrase. Eating it is the
    // difference between a feature that works and one that feels unfinished.
    let s = snippet("my email address", "roman@example.com")
    let result = SnippetExpander().expand("It's my email address, if that helps.", using: [s])
    #expect(result.text == "It's roman@example.com, if that helps.")
}

@Test func forgivesTheCapitalTheRecogniserAdded() {
    let s = snippet("my email address", "roman@example.com")
    let result = SnippetExpander().expand("My email address.", using: [s])
    #expect(result.text == "roman@example.com.")
}

@Test func forgivesPunctuationInsideThePhrase() {
    // "e-mail" and "email" are the same spoken word; the hyphen is a
    // transcription artefact, not a different phrase.
    let s = snippet("my e-mail", "roman@example.com")
    let result = SnippetExpander().expand("Send my email please.", using: [s])
    #expect(result.text == "Send roman@example.com please.")
}

@Test func firesMoreThanOnceInOneUtterance() {
    let s = snippet("studio link", "https://example.com")
    let result = SnippetExpander().expand("Studio link, and again: studio link.", using: [s])
    #expect(result.text == "https://example.com, and again: https://example.com.")
    #expect(result.firings.count == 2)
}

// MARK: - Refusing

@Test func doesNotFireOnANearMiss() {
    // The load-bearing test. VocabularyCorrector next door matches fuzzily on
    // purpose; here anything short of the words themselves must be left alone.
    let s = snippet("deposit terms", "50% up front, the rest on launch.")
    for text in ["Send them the deposits terms.",
                 "Send them the deposit term.",
                 "Send them the depositterms.",
                 "Send them the deposit payment terms."] {
        let result = SnippetExpander().expand(text, using: [s])
        #expect(result.text == text, "expanded when it should not have: \(text)")
        #expect(!result.didFire)
    }
}

@Test func doesNotFireInsideALongerWord() {
    let s = snippet("terms", "the terms and conditions")
    let result = SnippetExpander().expand("Check the thermostat.", using: [s])
    #expect(!result.didFire)
}

@Test func disabledSnippetsNeverFire() {
    let s = snippet("sign off", "Cheers,\nRoman", enabled: false)
    let result = SnippetExpander().expand("sign off", using: [s])
    #expect(result.text == "sign off")
    #expect(!result.didFire)
}

@Test func emptyReplacementsNeverFire() {
    let s = snippet("sign off", "")
    #expect(!SnippetExpander().expand("sign off", using: [s]).didFire)
}

// MARK: - Precedence

@Test func theLongestPhraseWins() {
    let short = snippet("email", "WRONG")
    let long = snippet("my email address", "roman@example.com")
    // Order in the array must not decide it — creation order is arbitrary.
    let result = SnippetExpander().expand("It is my email address.", using: [short, long])
    #expect(result.text == "It is roman@example.com.")
    #expect(result.firings.map(\.id) == [long.id])
}

@Test func aloneOnlyFiresWhenItIsTheWholeUtterance() {
    let s = snippet("sign off", "Cheers,\nRoman", mode: .alone)
    #expect(SnippetExpander().expand("Sign off.", using: [s]).text == "Cheers,\nRoman")
    #expect(SnippetExpander().expand("Let me sign off here.", using: [s]).text == "Let me sign off here.")
}

@Test func aloneBeatsAnywhereWhenBothCouldMatch() {
    let alone = snippet("standup", "Yesterday:\nToday:", mode: .alone)
    let anywhere = snippet("standup", "the standup meeting")
    #expect(SnippetExpander().expand("Standup", using: [anywhere, alone]).text == "Yesterday:\nToday:")
}

// MARK: - Ranges

@Test func rangesPointAtTheRightText() {
    let s = snippet("studio link", "https://example.com")
    let result = SnippetExpander().expand("Send the studio link over.", using: [s])
    let firing = try! #require(result.firings.first)
    #expect(("Send the studio link over." as NSString).substring(with: firing.sourceRange) == "studio link")
    #expect((result.text as NSString).substring(with: firing.outputRange) == "https://example.com")
}

// MARK: - Store

@Test func storeRoundTripsThroughDisk() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-snippets-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = SnippetStore(url: url)
    // A fresh file seeds rather than starting empty, same as Vocabulary.
    #expect(!store.isEmpty)

    let added = Snippet(phrase: "test phrase", replacement: "expanded")
    store.upsert(added)
    #expect(SnippetStore(url: url).snippet(id: added.id)?.replacement == "expanded")

    store.remove(id: added.id)
    #expect(SnippetStore(url: url).snippet(id: added.id) == nil)
}

@Test func expandingThroughTheStoreCountsTheFiring() {
    let s = snippet("studio link", "https://example.com")
    let store = SnippetStore(inMemory: [s])
    #expect(store.expand("Here's the studio link.") == "Here's the https://example.com.")

    let after = try! #require(store.snippet(id: s.id))
    #expect(after.useCount == 1)
    #expect(after.lastUsed != nil)

    // And a dictation that matched nothing must not touch the counters.
    _ = store.expand("Nothing in here matches.")
    #expect(store.snippet(id: s.id)?.useCount == 1)
}

@Test func inMemoryStoresNeverTouchDisk() {
    // The harness rule: a self-test that writes to a real user's data is a bug.
    let before = try? Data(contentsOf: SnippetStore.defaultURL)
    let store = SnippetStore(inMemory: SnippetStore.seed)
    store.upsert(Snippet(phrase: "x", replacement: "y"))
    let after = try? Data(contentsOf: SnippetStore.defaultURL)
    #expect(before == after)
}

@Test func orderingPutsTheOneYouJustUsedOnTop() {
    let old = Snippet(phrase: "a", replacement: "a", useCount: 900, lastUsed: Date(timeIntervalSinceNow: -9_000))
    let recent = Snippet(phrase: "b", replacement: "b", useCount: 2, lastUsed: Date())
    let never = Snippet(phrase: "c", replacement: "c")
    let store = SnippetStore(inMemory: [old, never, recent])
    #expect(store.ordered.map(\.phrase) == ["b", "a", "c"])
}

@Test func seedIsUsableRatherThanFiller() {
    for snippet in SnippetStore.seed {
        #expect(!snippet.phrase.isEmpty)
        #expect(!snippet.replacement.isEmpty)
        // A phrase that is one ordinary word will fire in the middle of normal
        // speech. Anything that short has to be `.alone`.
        let words = SnippetExpander.words(of: snippet.phrase).count
        #expect(words >= 2 || snippet.mode == .alone, "risky trigger: \(snippet.phrase)")
    }
    #expect(SnippetStore.seed.count == Set(SnippetStore.seed.map { $0.phrase.lowercased() }).count)
}

// MARK: - Section

@Test @MainActor func theSectionDrawsWithRealData() {
    let store = SnippetStore.preview()
    let view = SnippetsSectionView(store: store, style: .light)
    view.frame = DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize)
    view.layoutSubtreeIfNeeded()

    let rows = allSubviews(of: view).compactMap { $0 as? SnippetRowView }
    #expect(rows.count == store.all.count)
    #expect(rows.filter(\.isSelected).count == 1)
    // Every row must have somewhere to be drawn — a zero-height row is a list
    // that renders as an empty card.
    #expect(rows.allSatisfy { $0.frame.height > 0 && $0.frame.width > 0 })
}

@Test @MainActor func nothingCollidesAtTheWindowsMinimumSize() {
    // The window is resizable down to 1060x700, and a two-column master-detail
    // is exactly the layout that survives the design size and falls apart 300
    // points below it.
    let view = SnippetsSectionView(store: .preview(), style: .light)
    view.frame = DashboardMetrics.panelFrame(in: DashboardMetrics.minWindowSize)
    view.layoutSubtreeIfNeeded()

    let boxes = allSubviews(of: view).filter { !$0.isHidden && $0.superview === view }
    for box in boxes {
        #expect(box.frame.maxX <= view.bounds.width + 0.5, "\(type(of: box)) overflows the panel")
        #expect(box.frame.maxY <= view.bounds.height + 0.5, "\(type(of: box)) runs off the bottom")
    }

    // Inside the editor, the two blocks that compete for the leftover height.
    let editor = try! #require(boxes.compactMap { $0 as? SnippetEditorView }.first)
    let area = try! #require(allSubviews(of: editor).compactMap { $0 as? SnippetsTextArea }.first)
    let segmented = try! #require(allSubviews(of: editor).compactMap { $0 as? SnippetsSegmented }.first)
    #expect(area.frame.height >= 60)
    #expect(area.frame.maxY <= segmented.frame.minY)
}

@Test @MainActor func anEmptyStoreShowsTheEmptyStateAndNotAnEmptyCard() {
    let view = SnippetsSectionView(store: SnippetStore(inMemory: []), style: .dark)
    view.frame = DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize)
    view.layoutSubtreeIfNeeded()

    let subviews = allSubviews(of: view)
    let empty = try! #require(subviews.compactMap { $0 as? SnippetsEmptyStateView }.first)
    #expect(!empty.isHidden)
    #expect(subviews.compactMap { $0 as? SnippetRowView }.isEmpty)
    #expect(empty.frame.height > 200)
}

@Test @MainActor func theFiringPreviewShowsTheEnginesOwnOutput() {
    // The preview is only worth having if it is the real substitution. This
    // pins it to the expander rather than to a hand-written example string.
    let s = snippet("deposit terms", "50% up front, the rest on launch.")
    let (typed, highlight) = SnippetsPreviewPanel.condense(
        SnippetExpander().expand("… deposit terms …", using: [s]).text,
        highlight: SnippetExpander().expand("… deposit terms …", using: [s]).firings.first?.outputRange)
    #expect(typed.contains("50% up front"))
    #expect(highlight.length > 0)
}

@Test @MainActor func condenseKeepsTheHighlightInsideTheStringItTrimmed() {
    let long = String(repeating: "x", count: 400)
    let (text, range) = SnippetsPreviewPanel.condense(long, highlight: NSRange(location: 0, length: 400))
    #expect((text as NSString).length <= 75)
    #expect(NSMaxRange(range) <= (text as NSString).length)
    #expect(text.hasSuffix("…"))
}

// MARK: - Render

/// Writes the section to PNG at Flow's exact window size. Off by default —
/// `QUILL_SNIPPET_SHOTS=/dir` turns it on — because a test suite that writes
/// four megabytes of images on every run is a test suite people stop running.
@Test @MainActor func rendersToPNGWhenAsked() throws {
    guard let path = ProcessInfo.processInfo.environment["QUILL_SNIPPET_SHOTS"] else { return }
    let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

    for (dark, name) in [(false, "light"), (true, "dark")] {
        try DashboardPreviewRenderer.write(
            section: .snippets, dark: dark, provider: SnippetsSectionProvider.preview(),
            to: directory.appendingPathComponent("snippets-\(name).png"))
    }
    try DashboardPreviewRenderer.write(
        section: .snippets, dark: false, provider: SnippetsSectionProvider.empty(),
        to: directory.appendingPathComponent("snippets-empty-light.png"))
    try DashboardPreviewRenderer.write(
        section: .snippets, dark: true, provider: SnippetsSectionProvider.empty(),
        to: directory.appendingPathComponent("snippets-empty-dark.png"))
}

// MARK: - End to end

/// The claim that matters: a snippet fires during a real dictation, not merely
/// in a list. Driven through `DictationCoordinator` itself with fakes at the
/// four seams, so the assertion covers the ordering (clean, then expand, then
/// insert) rather than the existence of an expander.
@Test @MainActor func aSnippetFiresThroughTheRealDictationPath() async throws {
    let phrase = snippet("deposit terms", "50% up front, the rest on launch.")
    let snippets = SnippetStore(inMemory: [phrase])

    let transcriber = FakeTranscriber(text: "send them the deposit terms and I'll follow up")
    let inserter = RecordingInserter()
    let historyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: historyURL) }

    let coordinator = DictationCoordinator(
        hotkey: FakeHotkey(),
        transcriber: transcriber,
        inserter: inserter,
        overlay: SilentOverlay(),
        history: HistoryStore(url: historyURL),
        snippets: snippets,
        settings: pasteOnlySettings(),
        liveTyper: LiveTyper(keyboard: SilentKeystrokes()))

    coordinator.hotkeyMayBegin()
    coordinator.hotkeyPressed()
    coordinator.hotkeyReleased()

    for _ in 0 ..< 300 where inserter.inserted == nil {
        try? await Task.sleep(for: .milliseconds(10))
    }

    let inserted = try #require(inserter.inserted)
    // Cleanup capitalised the sentence, expansion replaced the phrase, and the
    // word after the replacement was re-capitalised because the replacement
    // ended one.
    #expect(inserted == "Send them the 50% up front, the rest on launch. And I'll follow up")
    #expect(snippets.snippet(id: phrase.id)?.useCount == 1)
}

private final class FakeHotkey: HotkeyEngine {
    var delegate: HotkeyEngineDelegate?
    func start() -> Bool { true }
    func stop() {}
}

private final class FakeTranscriber: Transcriber {
    var delegate: TranscriberDelegate?
    var onLevel: ((Float) -> Void)?
    private let text: String
    init(text: String) { self.text = text }
    func prepare() async {}
    func start() async throws {}
    func stop() async -> String { text }
    func cancel() async {}
}

private final class RecordingInserter: TextInserting {
    private(set) var inserted: String?
    func insert(_ text: String) -> InsertionResult {
        inserted = text
        return .inserted
    }
}

private final class SilentOverlay: OverlayPresenting {
    func show(_ state: OverlayState) {}
    func hide() {}
}

// MARK: - Helpers

@MainActor private func allSubviews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
}
