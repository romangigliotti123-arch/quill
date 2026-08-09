import AppKit
import Testing
@testable import QuillKit

// The diff is the one part of this section that is logic rather than layout, so
// it is pinned here. Everything else is checked by rendering the section and
// looking at it — but "did the recogniser mishear you" is a claim the UI makes
// on the app's behalf, and a wrong diff is a lie rather than an ugly screen.

@Test func diffKeepsRecasedAndRepunctuatedWordsOutOfTheHighlights() {
    let diff = TranscriptDiff.between(raw: "push the build once the rules land",
                                      inserted: "Push the build once the rules land.")
    // Every word survived; only capitalisation and a full stop changed. If those
    // counted as edits the diff would light up on every single dictation and
    // stop meaning anything.
    #expect(diff.segments.allSatisfy { $0.kind == .unchanged })
    #expect(diff.removedWords == 0)
    #expect(diff.addedWords == 0)
    #expect(diff.reshapedWords == 2)
    #expect(diff.editCount == 0)
}

@Test func diffReportsASplitCompoundAsOneSubstitution() {
    let diff = TranscriptDiff.between(raw: "push the net lify build",
                                      inserted: "Push the Netlify build.")
    #expect(diff.replacements == [.init(from: "net lify", to: "Netlify")])
    // Two words out, one word in, but a person reading this made *one* fix.
    #expect(diff.editCount == 1)
    #expect(diff.removedWords == 2)
    #expect(diff.addedWords == 1)
}

@Test func diffSeparatesDroppedFillerFromCorrectedTerms() {
    let diff = TranscriptDiff.between(
        raw: "um push the fire store rules uh now",
        inserted: "Push the Firestore rules now.")
    #expect(diff.replacements == [.init(from: "fire store", to: "Firestore")])
    #expect(diff.filler == ["um", "uh"])
    #expect(diff.trimmedWords == 0)
    let tags = diff.notes.map(\.tag)
    #expect(tags.contains("Terms"))
    #expect(tags.contains("Filler"))
}

@Test func diffRendersTheInsertedSpellingForWordsThatSurvived() {
    let diff = TranscriptDiff.between(raw: "send carlo the swatch list",
                                      inserted: "Send Carlo the swatch list.")
    // The document says "Send Carlo"; the transcript pane must not quietly show
    // the recogniser's lowercase version as if that were what was typed.
    let text = diff.segments.map(\.text).joined(separator: " ")
    #expect(text == "Send Carlo the swatch list.")
}

@Test func diffSurvivesAMissingRawColumn() {
    // Records written before raw text was captured, and any record whose
    // recogniser output was empty. Neither may render as "Quill invented all of
    // this", and neither may crash the section.
    let diff = TranscriptDiff.between(raw: "", inserted: "Something was typed.")
    #expect(diff.addedWords == 0)
    #expect(diff.removedWords == 0)
    #expect(diff.segments.map(\.text).joined() == "Something was typed.")
}

@Test func fixturesAreRawOnTheRawSideAndCleanOnTheOther() {
    // A fixture set where both columns are already tidy renders the diff as one
    // solid block of "unchanged", which is exactly the screen the section exists
    // to avoid shipping.
    let records = DictationFixtures.records()
    #expect(records.count >= 10)
    let diffs = records.map { TranscriptDiff.between(raw: $0.rawText, inserted: $0.insertedText) }
    #expect(diffs.contains { $0.editCount >= 3 })
    #expect(diffs.allSatisfy { $0.reshapedWords > 0 })
    for record in records {
        #expect(record.wordCount == record.insertedText.split(whereSeparator: \.isWhitespace).count)
        #expect(!record.rawText.contains("."), "raw fixture \(record.id) has punctuation the recogniser would not emit")
    }
}

@Test @MainActor func theSectionLaysOutAllThreeStatesInsideThePanel() {
    let panel = DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize)

    for (label, records, query) in [
        ("history", DictationFixtures.records(), ""),
        ("no match", DictationFixtures.records(), "zzzzz"),
        ("first run", [], ""),
    ] as [(String, [DictationRecord], String)] {
        let view = DictationSectionView(style: .light, records: records, query: query)
        view.frame = NSRect(origin: .zero, size: panel.size)
        view.layoutSubtreeIfNeeded()

        // Nothing may hang outside the panel: the panel clips to its corner
        // radius, so an overhanging subview is invisibly cut rather than
        // obviously wrong, and that is the bug that ships.
        for child in view.subviews where !child.isHidden {
            #expect(child.frame.maxX <= panel.width + 0.5, "\(label): \(type(of: child)) overhangs right")
            #expect(child.frame.maxY <= panel.height + 0.5, "\(label): \(type(of: child)) overhangs bottom")
            #expect(child.frame.minX >= -0.5 && child.frame.minY >= -0.5, "\(label): \(type(of: child)) starts off-panel")
        }
    }
}

@Test @MainActor func searchFiltersOnBothColumnsAndTheDetailFollowsIt() {
    // "fire store" exists only in the raw column — searching the inserted text
    // alone would miss the record whose mishearing you are trying to find.
    let records = DictationFixtures.records()
    let view = DictationSectionView(style: .light, records: records, query: "fire store")
    view.frame = NSRect(origin: .zero, size: DashboardMetrics.panelFrame(in: DashboardMetrics.windowSize).size)
    view.layoutSubtreeIfNeeded()
    #expect(view.visibleRecordCount > 0)
    #expect(view.visibleRecordCount < records.count)

    let miss = DictationSectionView(style: .light, records: records, query: "zzzzz")
    miss.frame = view.frame
    miss.layoutSubtreeIfNeeded()
    #expect(miss.visibleRecordCount == 0)
}

@Test @MainActor func everySymbolTheSectionAsksForExists() {
    // A missing SF Symbol is a silently blank icon, which reads as a rendering
    // bug rather than a typo.
    for name in ["magnifyingglass", "xmark.circle", "doc.on.doc", "text.insert",
                 "waveform", "doc.text", "xmark", "arrow.down.circle", "square.and.arrow.up"] {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing symbol \(name)")
    }
}
