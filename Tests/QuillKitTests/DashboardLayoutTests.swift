import AppKit
import Testing
@testable import QuillKit

// The invariants the whole window depends on, pinned once rather than
// re-litigated per section.
//
// Every one of these exists because something shipped broken and nothing could
// see it. They are deliberately cheap — no rendering, no window server, a couple
// of hundred milliseconds for the lot — so there is no reason not to run them.

// MARK: - Controls that are actually controls

/// Roman, on the Dictionary tab: *"when you click All, Added by you or Learned,
/// none of those buttons actually work, or even just hovering over them, nothing
/// happens."*
///
/// He was exactly right. `DictionarySegmented` drew a perfect three-way filter —
/// hairline capsule, raised pill on the selected segment, correct type — and had
/// no tracking area, no `mouseDown`, no `mouseUp` and no callback. It was a
/// *picture* of a control, and the only way to find out was to click it.
///
/// Nothing in this project could have caught it. The screenshot harness passed:
/// it draws, and draws correctly. The layout tests passed: its frame is right.
/// Only a person clicking it could tell, and only after wasting the click.
///
/// So this is the check that can: walk every section's real view tree and assert
/// that anything which *looks* like a control *behaves* like one. It is a static
/// test of a dynamic property, which is what makes it cheap enough to keep.
@Test @MainActor func everyControlOnEveryScreenRespondsToTheMouse() {
    // Types that draw a control-shaped surface. Adding a new drawn control means
    // adding it here — which is the point: the list is the register of things that
    // must work, and a control absent from it is a control nobody promised about.
    let mustRespond: [NSView.Type] = [
        DashboardButton.self,
        DictationRowView.self,
        DictationSearchField.self,
        DictationClearButton.self,
        DictionarySegmented.self,
        DictionaryTermRow.self,
        DictionaryTextControl.self,
        SidebarRowView.self,
        InsightsSegmented.self,
        StyleToneRow.self,
        ScratchpadRow.self,
        TransformRowView.self,
        DashboardSwitch.self,
        HoverControl.self,
    ]

    func responds(_ view: NSView, to selector: Selector) -> Bool {
        // `NSResponder` implements all of these, so `responds(to:)` is always true.
        // The question is whether the view's OWN class (or a subclass of it below
        // NSView) overrides them — which is exactly what `DictionarySegmented`
        // did not do.
        var type: AnyClass? = object_getClass(view)
        while let current = type, current != NSView.self {
            if class_getInstanceMethod(current, selector) != nil,
               class_getInstanceMethod(current, selector)
                   != class_getInstanceMethod(NSView.self, selector) {
                return true
            }
            type = class_getSuperclass(current)
        }
        return false
    }

    func walk(_ view: NSView, into found: inout [NSView]) {
        for child in view.subviews {
            if mustRespond.contains(where: { child.isKind(of: $0) }) { found.append(child) }
            walk(child, into: &found)
        }
    }

    var checked = 0
    for section in DashboardSection.allCases {
        guard let view = DashboardSectionRegistry.shared.dashboardView(for: section, style: .dark)
        else { continue }
        view.frame = NSRect(origin: .zero,
                            size: DashboardMetrics.sectionFrame(
                                in: DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize)).size)
        view.layoutSubtreeIfNeeded()

        var controls: [NSView] = []
        walk(view, into: &controls)
        for control in controls {
            let name = "\(section.rawValue)/\(type(of: control))"
            // The pointer has to be able to reach it at all.
            #expect(responds(control, to: #selector(NSView.updateTrackingAreas)),
                    "\(name) draws a control and installs no tracking area")
            // And clicking it has to do something. `mouseUp` rather than
            // `mouseDown`, because a click is only committed on the way up — and
            // it is `mouseUp` that has to check the pointer is still inside, which
            // is how a person cancels a click they changed their mind about.
            #expect(responds(control, to: #selector(NSView.mouseUp(with:))),
                    "\(name) draws a control and handles no click")
            checked += 1
        }
    }

    // The finder itself must not be able to come back empty and call that a pass.
    // The alignment test in DashboardShellTests spent its whole life doing exactly
    // that, and this file is not repeating it.
    #expect(checked > 40, "only found \(checked) controls across ten sections — the walk is broken")
}

/// A control that lights under the pointer is how a person knows it is a control
/// *before* spending a click on it. Roman named it in the same breath as the dead
/// filter — "or even just hovering over them, nothing happens" — because the two
/// failures are indistinguishable until you commit.
@Test @MainActor func everyRowAndChipHasAHoverState() {
    // Types whose whole job is to be a row or a chip in a list. A hover state is
    // not optional on these; it is the affordance.
    let hoverable: [NSView.Type] = [
        DictationRowView.self,
        DictionaryTermRow.self,
        SidebarRowView.self,
        ScratchpadRow.self,
        TransformRowView.self,
        StyleToneRow.self,
    ]

    for type in hoverable {
        let mirror = "\(type)"
        // `mouseEntered` is what a hover state is built on. Without it the view
        // can only ever change on click.
        var found = false
        var cls: AnyClass? = type
        while let current = cls, current != NSView.self {
            if class_getInstanceMethod(current, #selector(NSView.mouseEntered(with:))) != nil,
               class_getInstanceMethod(current, #selector(NSView.mouseEntered(with:)))
                   != class_getInstanceMethod(NSView.self, #selector(NSView.mouseEntered(with:))) {
                found = true
                break
            }
            cls = class_getSuperclass(current)
        }
        #expect(found, "\(mirror) is a row or chip with no hover state")
    }
}

// MARK: - Nothing hangs off the panel

/// The panel clips to its corner radius, so a subview past its edge is invisibly
/// cut rather than obviously wrong — which is the version of this bug that ships.
///
/// Checked at BOTH sizes on purpose. A layout is only ever proved correct at the
/// size it was tested at, and the documented minimum is where things break: two
/// sections once had content cut clean off at 1060x700 while looking perfect at
/// 1350x850, and Roman found it by dragging the window.
@Test @MainActor func nothingOverhangsThePanelAtEitherSize() {
    for size in [DashboardMetrics.windowSize, DashboardMetrics.minWindowSize] {
        let frame = DashboardMetrics.sectionFrame(in: DashboardMetrics.panelFrame(in: size))
        for section in DashboardSection.allCases {
            guard let view = DashboardSectionRegistry.shared.dashboardView(for: section, style: .dark)
            else { continue }
            view.frame = NSRect(origin: .zero, size: frame.size)
            view.layoutSubtreeIfNeeded()

            let label = "\(section.rawValue)@\(Int(size.width))"
            for child in view.subviews where !child.isHidden {
                #expect(child.frame.maxX <= frame.width + 0.5,
                        "\(label): \(type(of: child)) overhangs right by \(Int(child.frame.maxX - frame.width))")
                #expect(child.frame.minX >= -0.5,
                        "\(label): \(type(of: child)) starts off-panel")
                #expect(child.frame.minY >= -0.5,
                        "\(label): \(type(of: child)) starts above the panel")
            }
        }
    }
}

// MARK: - The header contract

/// Every section gets its heading from one component, so the alignment cannot be
/// a matter of ten separate opinions. This pins that the component is actually
/// being used rather than merely existing.
@Test @MainActor func everySectionUsesTheSharedHeader() {
    for section in DashboardSection.allCases {
        guard let view = DashboardSectionRegistry.shared.dashboardView(for: section, style: .dark)
        else { continue }
        view.frame = NSRect(origin: .zero,
                            size: DashboardMetrics.sectionFrame(
                                in: DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize)).size)
        view.layoutSubtreeIfNeeded()

        func hasHeader(_ v: NSView) -> Bool {
            v.subviews.contains { $0 is DashboardSectionHeader || hasHeader($0) }
        }
        #expect(hasHeader(view), "\(section.rawValue) builds its own header instead of using the shared one")
    }
}

/// A header's buttons are 34 points tall, and that is load-bearing rather than
/// cosmetic. `DashboardButton` owns no constraints — it draws its own pill — so
/// `fittingSize` returns the height of the LABEL inside it, about seventeen
/// points. A header laid out from fitting sizes drew its pill behind its own text:
/// invisible in dark mode, and it lost the primary action outright in light.
@Test @MainActor func headerButtonsAreGivenARealHeight() {
    let primary = DashboardButton(title: "Start dictating", symbol: "waveform", kind: .primary, style: .dark)
    let header = DashboardSectionHeader(title: "Dictation", trailing: [primary], style: .dark)
    header.frame = NSRect(x: 0, y: 0, width: 900, height: header.height)
    header.layoutSubtreeIfNeeded()

    #expect(primary.frame.height == DashboardSectionHeader.controlHeight)
    #expect(primary.frame.width > 100, "the button collapsed to \(Int(primary.frame.width))pt wide")
    #expect(primary.frame.maxX <= 900.5, "the button hangs off the header")
    // And it is on the title's row, not below it.
    #expect(primary.frame.minY < 12)
}

// MARK: - Dictation's new shape

/// The hero is as tall as what is in it, and that is the single decision that
/// removed the void from this screen. A record card pinned to half the window
/// left four hundred points of empty card under a four-word dictation, and no
/// amount of tuning inside it could fix that.
@Test @MainActor func theOpenRecordIsAsTallAsItsContents() {
    let short = DictationRecord(
        id: UUID(), date: Date(),
        rawText: "hello", insertedText: "Hello?",
        wordCount: 1, inputDevice: "MacBook Air Microphone",
        timings: .init(timeToFirstWordMs: 100, finalToInsertedMs: 10,
                       endToEndMs: 900, audioDurationMs: 800, usedThoroughCleanup: false))
    let long = DictationFixtures.records().max { $0.wordCount < $1.wordCount }!

    let width: CGFloat = 1024
    let shortHeight = DictationRecordView(record: short, style: .dark).fittingHeight(width: width)
    let longHeight = DictationRecordView(record: long, style: .dark).fittingHeight(width: width)

    #expect(shortHeight < longHeight,
            "a one-word record wants the same height as a \(long.wordCount)-word one")
    // And neither is anywhere near half a window. The card it replaced was ~700.
    #expect(longHeight < 340, "the hero grew to \(Int(longHeight))pt — it is a document again")
    #expect(shortHeight > 60)
}

/// Search reads both columns. "fire store" exists only in the raw transcript, and
/// searching the inserted text alone would miss the record whose mishearing you
/// are trying to find — which is the one reason to search this screen at all.
@Test @MainActor func searchStillReadsTheRawTranscript() {
    let records = DictationFixtures.records()
    let panel = DashboardMetrics.sectionFrame(in: DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize))

    let hit = DictationSectionView(style: .light, records: records, query: "fire store")
    hit.frame = NSRect(origin: .zero, size: panel.size)
    hit.layoutSubtreeIfNeeded()
    #expect(hit.visibleRecordCount > 0)
    #expect(hit.visibleRecordCount < records.count)

    let miss = DictationSectionView(style: .light, records: records, query: "zzzzz")
    miss.frame = hit.frame
    miss.layoutSubtreeIfNeeded()
    #expect(miss.visibleRecordCount == 0)
}

// MARK: - The words chart

/// Thirty daily columns against a real dictation habit is twenty-four empty slots
/// and one spike — a chart that reads as broken rather than as sparse. The bucket
/// has to widen with the window, which is what every Apple health chart does and
/// what the first version of this card did not.
@Test @MainActor func theWordsChartBucketsToFitItsRange() {
    let calendar = Calendar.current
    let now = Date()
    let days = (0..<30).reversed().map { offset in
        InsightsMetrics.Day(date: calendar.date(byAdding: .day, value: -offset, to: now)!,
                            words: offset % 7 == 0 ? 400 : 0,
                            sessions: offset % 7 == 0 ? 3 : 0)
    }

    let daily = InsightsActivityCard.bucket(days, by: .day)
    #expect(daily.count == 30)

    let weekly = InsightsActivityCard.bucket(days, by: .week)
    #expect(weekly.count == 5, "30 days made \(weekly.count) weekly buckets")
    // Nothing is lost or double-counted on the way in.
    #expect(weekly.reduce(0) { $0 + $1.words } == days.reduce(0) { $0 + $1.words })
    #expect(weekly.reduce(0) { $0 + $1.sessions } == days.reduce(0) { $0 + $1.sessions })

    // Filled from the END backwards, so the newest column is a whole period.
    // Filling forwards leaves the one column a person actually looks at drawn
    // short for a reason that has nothing to do with how much they said.
    #expect(weekly.last?.start == days[days.count - 7].date)
}

@Test @MainActor func theWordsChartPicksItsBucketFromTheRange() {
    #expect(InsightsActivityCard.bucketing(for: .week) == .day)
    #expect(InsightsActivityCard.bucketing(for: .month) == .week)
    #expect(InsightsActivityCard.bucketing(for: .all) == .month)
}

// MARK: - Lists that hold more than fits

/// A list that silently stops is worse than a short list, because the number it
/// prints beside itself says otherwise.
///
/// The Dictionary showed as many whole rows as fitted and set `isHidden = true`
/// on the rest — with 142 terms, 135 of them could not be reached by any means,
/// on the one screen whose entire argument is "here is the evidence". The
/// Scratchpad had the same shape: no scroll view, so the eighth note onward was
/// laid out past the bottom of the section and never seen.
@Test @MainActor func everyLongListCanReachItsLastRow() {
    let frame = DashboardMetrics.sectionFrame(
        in: DashboardMetrics.panelFrame(in: DashboardMetrics.minWindowSize))

    func scrollers(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { ($0 as? NSScrollView).map { [$0] } ?? scrollers(in: $0) }
    }

    // Deliberately more entries than could ever fit, so a section that clips
    // rather than scrolls is caught by the document height rather than by taste.
    let entries = (0..<60).map { index in
        DictionaryEntry(term: "term\(index)", substitutions: index, added: "today")
    }
    let dictionary = DictionarySectionView(style: .dark, entries: entries)
    dictionary.frame = NSRect(origin: .zero, size: frame.size)
    dictionary.layoutSubtreeIfNeeded()

    let lists = scrollers(in: dictionary)
    let list = try! #require(lists.first, "the dictionary list does not scroll")
    let document = try! #require(list.documentView)
    #expect(document.frame.height > list.frame.height,
            "60 terms fitted in \(Int(list.frame.height))pt without scrolling — rows are being dropped")
    // Every row is in the document, not hidden.
    #expect(document.subviews.filter { $0 is DictionaryTermRow }.count == entries.count)
    #expect(document.subviews.allSatisfy { !$0.isHidden })

    let notes = (0..<30).map { Note(title: "Note \($0)", body: "body \($0)") }
    let scratchpad = ScratchpadSectionView(style: .dark, notes: notes)
    scratchpad.frame = NSRect(origin: .zero, size: frame.size)
    scratchpad.layoutSubtreeIfNeeded()

    let noteList = try! #require(scrollers(in: scratchpad).first, "the note list does not scroll")
    let noteDocument = try! #require(noteList.documentView)
    #expect(noteDocument.frame.height > noteList.frame.height,
            "30 notes fitted without scrolling")
}

/// The column carrying the evidence must not be the one that collapses.
///
/// Every column but "Heard instead" took a fixed share and that one took the
/// remainder, so at the documented minimum window it fell to 34 points and the
/// heading and every value in it truncated to three characters.
@Test func theHeardColumnKeepsAReadableWidthAtEverySize() {
    // 344 is the narrowest list the app can produce: at the documented minimum
    // window the section is 826pt, content 734, and the inspector takes a fixed
    // 366 plus a 24pt gap. Sweeping below that would be asserting against sizes
    // the layout never hands out.
    let narrowest = DashboardMetrics.sectionFrame(
        in: DashboardMetrics.panelFrame(in: DashboardMetrics.minWindowSize)).width
        - DashboardMetrics.contentPaddingX * 2 - 366 - DashboardSpace.lg
    #expect(narrowest <= 350, "the narrowest list is \(Int(narrowest))pt — update this test")

    for width in stride(from: Double(narrowest), through: 900.0, by: 10.0) {
        let columns = DictionaryColumns(width: CGFloat(width))
        #expect(columns.heardW >= 96,
                "at \(Int(width))pt the heard column is \(Int(columns.heardW))pt")
        // And the bar it borrows from never goes negative or crosses the count.
        #expect(columns.barW >= 0)
        #expect(columns.barX >= columns.heardX + columns.heardW)
        #expect(columns.barX + columns.barW <= columns.countX)
    }
}
