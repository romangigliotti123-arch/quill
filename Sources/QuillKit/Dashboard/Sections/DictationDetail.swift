import AppKit

// MARK: - Formatting

/// One place for every string the section formats. Two views formatting the
/// same timestamp with two formatters is how "9:41 AM" and "9:41 am" end up on
/// the same screen.
enum DictationFormat {

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        // Lowercase, because a capitalised AM in 11pt monospace next to body
        // text reads as an abbreviation for something else.
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    private static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    static func dayTitle(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return shortDay.string(from: date)
    }

    static func count(_ value: Int) -> String {
        decimal.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Milliseconds as seconds, to two places under ten and one above. "19.4 s"
    /// of audio does not need hundredths; "0.42 s" of latency is the whole point.
    static func seconds(_ ms: Int?) -> String {
        guard let ms else { return "\u{2014}" }
        let value = Double(ms) / 1000
        return value < 10 ? String(format: "%.2f", value) : String(format: "%.1f", value)
    }

    static func wordsPerMinute(_ record: DictationRecord) -> Int? {
        guard let audio = record.timings.audioDurationMs, audio > 500 else { return nil }
        return Int((Double(record.wordCount) / (Double(audio) / 60_000)).rounded())
    }
}

// MARK: - Detail

/// One record, opened.
///
/// This is the half of the screen Wispr Flow does not have. Their history is a
/// list of finished paragraphs — useful for finding something you said, useless
/// for deciding whether to trust it. Quill already stores what the recogniser
/// heard *and* what got typed, so the record view leads with the difference
/// between them, and the raw text stops being a column nobody can see.
public final class DictationDetailView: NSView {

    /// The transcript is the most-read text on the screen and gets a size of its
    /// own, one step above body. Everything else here comes from `DashboardType`.
    private static let transcriptFont = NSFont.systemFont(ofSize: 15, weight: .regular)
    private static let transcriptLeading: CGFloat = 27

    private let record: DictationRecord
    private let diff: TranscriptDiff
    private let style: DashboardStyle

    private let title: NSTextField
    private let meta: NSTextField
    private let copyButton: DashboardButton
    private let insertButton: DashboardButton
    private let headerRule: DashboardRule

    private let eyebrow: NSTextField
    private let legend: NSTextField

    private let well: DashboardCardView
    private let transcript: NSTextField
    private let wellRule: DashboardRule
    private let notesEyebrow: NSTextField
    private var noteTags: [DashboardChip] = []
    private var noteTexts: [NSTextField] = []

    private let footerRule: DashboardRule
    private var metrics: [DictationMetricView] = []
    private var metricRules: [DashboardRule] = []

    public override var isFlipped: Bool { true }

    public init(record: DictationRecord, style: DashboardStyle) {
        self.record = record
        self.style = style
        self.diff = TranscriptDiff.between(raw: record.rawText, inserted: record.insertedText)

        title = DashboardType.label("\(DictationFormat.dayTitle(record.date)), \(DictationFormat.time(record.date))",
                                    font: DashboardType.headline, color: style.ink)

        var metaParts = ["\(record.wordCount) words"]
        if let wpm = DictationFormat.wordsPerMinute(record) { metaParts.append("\(wpm) wpm") }
        metaParts.append(record.inputDevice ?? "Unknown input")
        metaParts.append(record.timings.usedThoroughCleanup ? "Thorough cleanup" : "Fast cleanup")
        meta = DashboardType.label(metaParts.joined(separator: "  \u{00B7}  "),
                                   font: DashboardType.caption, color: style.inkTertiary)

        copyButton = DashboardButton(title: "Copy", symbol: "doc.on.doc", kind: .secondary, style: style)
        insertButton = DashboardButton(title: "Re-insert", symbol: "text.insert", kind: .primary, style: style)
        headerRule = DashboardRule(color: style.hairline)

        eyebrow = DashboardType.label("Heard vs inserted", font: DashboardType.eyebrow,
                                      color: style.inkTertiary)
        legend = DictationDetailView.legendLabel(style: style)

        well = DashboardCardView(style: style, elevation: .sunken, radius: DashboardRadius.card)
        transcript = DictationDetailView.transcriptLabel(diff: diff, style: style)
        wellRule = DashboardRule(color: style.hairline)
        notesEyebrow = DashboardType.label(diff.isClean ? "Nothing to fix" : "\(diff.editCount) edits",
                                           font: DashboardType.eyebrow,
                                           color: style.inkTertiary)
        footerRule = DashboardRule(color: style.hairline)

        super.init(frame: .zero)

        addSubview(title)
        addSubview(meta)
        addSubview(copyButton)
        addSubview(insertButton)
        addSubview(headerRule)
        addSubview(eyebrow)
        addSubview(legend)
        addSubview(well)
        well.addSubview(transcript)
        well.addSubview(wellRule)
        well.addSubview(notesEyebrow)

        for note in diff.notes.prefix(3) {
            let tag = DashboardChip(text: note.tag, tone: .neutral, style: style)
            let text = DashboardType.label(note.text, font: DashboardType.callout, color: style.inkSecondary)
            well.addSubview(tag)
            well.addSubview(text)
            noteTags.append(tag)
            noteTexts.append(text)
        }
        if diff.notes.isEmpty {
            let text = DashboardType.label("The recogniser got this one exactly right \u{2014} nothing was dropped, corrected or recased.",
                                           font: DashboardType.callout, color: style.inkSecondary, lines: 2, lineHeight: 18)
            well.addSubview(text)
            noteTexts.append(text)
        }

        addSubview(footerRule)
        for (index, spec) in footerSpecs.enumerated() {
            let view = DictationMetricView(value: spec.value, unit: spec.unit, caption: spec.caption,
                                           accent: spec.accent, style: style)
            addSubview(view)
            metrics.append(view)
            if index > 0 {
                let rule = DashboardRule(color: style.hairline)
                addSubview(rule)
                metricRules.append(rule)
            }
        }

        copyButton.onClick = { [weak self] in self?.copyToPasteboard() }
        insertButton.onClick = { [weak self] in self?.reinsert() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    private var footerSpecs: [(value: String, unit: String, caption: String, accent: Bool)] {
        // Four readings that do not repeat each other, and none that repeats the
        // meta line above. The edit count was here first and had already been
        // said twice on the same card.
        [
            (DictationFormat.seconds(record.timings.endToEndMs), "s", "release to text", true),
            (DictationFormat.seconds(record.timings.timeToFirstWordMs), "s", "first word", false),
            (DictationFormat.seconds(record.timings.finalToInsertedMs), "s", "cleanup pass", false),
            (DictationFormat.seconds(record.timings.audioDurationMs), "s", "audio captured", false),
        ]
    }

    /// The two treatments, shown once, using the exact attributes the transcript
    /// uses. A legend drawn from a second set of constants is a legend that goes
    /// out of date.
    private static func legendLabel(style: DashboardStyle) -> NSTextField {
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: "heard", attributes: removedAttributes(style: style, font: DashboardType.caption)))
        line.append(NSAttributedString(string: "   ", attributes: [.font: DashboardType.caption]))
        line.append(NSAttributedString(string: "inserted", attributes: addedAttributes(style: style, font: DashboardType.caption)))
        let field = NSTextField(labelWithString: "")
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.attributedStringValue = line
        return field
    }

    private static func removedAttributes(style: DashboardStyle, font: NSFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: style.inkQuaternary,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: style.inkQuaternary,
        ]
    }

    /// Ink, not accent. A whole sentence of coloured text is unreadable and
    /// spends the one accent this screen is allowed; a wash behind black text is
    /// a highlighter, which is what the gesture actually is.
    private static func addedAttributes(style: DashboardStyle, font: NSFont) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: font.pointSize, weight: .medium),
            .foregroundColor: style.ink,
            .backgroundColor: style.accentSoft,
        ]
    }

    private static func transcriptLabel(diff: TranscriptDiff, style: DashboardStyle) -> NSTextField {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = transcriptLeading
        paragraph.maximumLineHeight = transcriptLeading
        paragraph.lineBreakMode = .byWordWrapping

        let base: [NSAttributedString.Key: Any] = [
            .font: transcriptFont,
            .foregroundColor: style.ink,
            .paragraphStyle: paragraph,
        ]

        let line = NSMutableAttributedString()
        for (index, segment) in diff.segments.enumerated() {
            if index > 0 { line.append(NSAttributedString(string: " ", attributes: base)) }
            switch segment.kind {
            case .unchanged:
                line.append(NSAttributedString(string: segment.text, attributes: base))
            case .removed:
                var attributes = removedAttributes(style: style, font: transcriptFont)
                attributes[.paragraphStyle] = paragraph
                line.append(NSAttributedString(string: segment.text, attributes: attributes))
            case .added:
                var attributes = addedAttributes(style: style, font: transcriptFont)
                attributes[.paragraphStyle] = paragraph
                // The wash hugs the word with no padding characters. Hair spaces
                // inside the run looked better mid-line and terrible at one: a
                // hair space is a legal break opportunity, so a wrap could leave
                // a stub of highlight hanging off the right margin.
                line.append(NSAttributedString(string: segment.text, attributes: attributes))
            }
        }

        let field = NSTextField(labelWithString: "")
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = true
        field.maximumNumberOfLines = 24
        field.lineBreakMode = .byWordWrapping
        field.cell?.usesSingleLineMode = false
        field.attributedStringValue = line
        return field
    }

    // MARK: - Actions

    private static func say(_ message: String) {
        NotificationCenter.default.post(name: .quillOverlayMessage, object: message)
    }

    /// What is on screen, or the raw transcript when nothing was inserted.
    ///
    /// A rescued dictation has an empty insertedText — the words exist, they just
    /// never reached an application. Copy used to clear the clipboard and then
    /// write that empty string, so pressing Copy on exactly the dictation most
    /// worth rescuing destroyed whatever the user had on their clipboard and gave
    /// them nothing in return.
    private var copyableText: String {
        record.insertedText.isEmpty ? record.rawText : record.insertedText
    }

    private func copyToPasteboard() {
        let text = copyableText
        guard !text.isEmpty else {
            Self.say("There is nothing in this dictation to copy.")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Insertion targets whatever is frontmost, and while the dashboard is open
    /// that is the dashboard. Hiding first is not a flourish — without it the
    /// text lands in this window's search field.
    private func reinsert() {
        let text = copyableText
        guard !text.isEmpty else {
            Self.say("There is nothing in this dictation to insert.")
            return
        }
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // The result was thrown away, so every failure TextInserter exists to
            // report — no Accessibility grant, secure input, a fallback to the
            // clipboard — arrived as nothing happening. The user hid their
            // dashboard, watched no text appear, and had no way to tell a refusal
            // from a slow paste.
            switch TextInserter().insert(text) {
            case .inserted:
                break
            case .fellBackToClipboard(let reason):
                Self.say("Copied to the clipboard instead — \(reason)")
            case .failed(let reason):
                Self.say("Could not insert it — \(reason)")
            }
        }
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        let pad = DashboardSpace.lg
        let width = bounds.width

        let titleSize = title.fittingSize
        title.frame = NSRect(x: pad, y: pad, width: min(titleSize.width, width - 260), height: titleSize.height)

        let insertWidth = insertButton.intrinsicWidth
        insertButton.frame = NSRect(x: width - pad - insertWidth, y: pad - 4, width: insertWidth, height: 30)
        let copyWidth = copyButton.intrinsicWidth
        copyButton.frame = NSRect(x: insertButton.frame.minX - DashboardSpace.xs - copyWidth,
                                  y: insertButton.frame.minY, width: copyWidth, height: 30)

        let metaSize = meta.fittingSize
        meta.frame = NSRect(x: pad, y: pad + titleSize.height + 7,
                            width: min(metaSize.width, width - pad * 2), height: metaSize.height)

        let headerBottom = meta.frame.maxY + DashboardSpace.md + 2
        headerRule.frame = NSRect(x: 0, y: headerBottom, width: width, height: 1)

        let eyebrowSize = eyebrow.fittingSize
        eyebrow.frame = NSRect(x: pad, y: headerBottom + DashboardSpace.lg,
                               width: eyebrowSize.width, height: eyebrowSize.height)
        let legendSize = legend.fittingSize
        legend.frame = NSRect(x: width - pad - legendSize.width,
                              y: eyebrow.frame.midY - legendSize.height / 2,
                              width: legendSize.width, height: legendSize.height)

        // The metric band is pinned to the bottom edge; everything between it
        // and the eyebrow belongs to the well.
        let bandHeight: CGFloat = 84
        let bandTop = bounds.height - bandHeight
        footerRule.frame = NSRect(x: 0, y: bandTop, width: width, height: 1)

        let count = CGFloat(metrics.count)
        let inner = width - pad * 2
        let cell = inner / count
        for (index, metric) in metrics.enumerated() {
            metric.frame = NSRect(x: pad + cell * CGFloat(index), y: bandTop + DashboardSpace.lg,
                                  width: cell, height: bandHeight - DashboardSpace.lg * 2 + 8)
        }
        for (index, rule) in metricRules.enumerated() {
            rule.frame = NSRect(x: (pad + cell * CGFloat(index + 1)).rounded() - 8,
                                y: bandTop + 26, width: 1, height: 34)
        }

        let wellTop = eyebrow.frame.maxY + DashboardSpace.md
        let wellCeiling = bandTop - DashboardSpace.lg - wellTop
        // The well hugs its content rather than stretching to the band. A
        // stretched well puts its slack *inside* a bordered container, and empty
        // space inside a border reads as a hole; the same slack below the well,
        // on the card's own surface, reads as whitespace. Same pixels, opposite
        // impressions.
        let wellHeight = min(wellCeiling, wellContentHeight(width: inner))
        well.frame = NSRect(x: pad, y: wellTop, width: inner, height: max(140, wellHeight))
        layoutWell()
    }

    private var wellPad: CGFloat { DashboardSpace.md + 2 }

    private func noteBlockHeight(textWidth: CGFloat) -> CGFloat {
        let rows: CGFloat = noteTags.isEmpty
            ? (noteTexts.first.map { DashboardType.size($0, width: textWidth).height } ?? 0)
            : CGFloat(noteTags.count) * 26
        return notesEyebrow.fittingSize.height + 10 + rows
    }

    private func wellContentHeight(width: CGFloat) -> CGFloat {
        let textWidth = width - wellPad * 2
        return wellPad
            + DashboardType.size(transcript, width: textWidth).height
            + DashboardSpace.md + 1 + DashboardSpace.md
            + noteBlockHeight(textWidth: textWidth)
            + wellPad
    }

    private func layoutWell() {
        let pad = wellPad
        let width = well.bounds.width
        let height = well.bounds.height
        let textWidth = width - pad * 2

        let notesHeight = noteBlockHeight(textWidth: textWidth)
        // Clamped, so a very long dictation truncates its transcript rather than
        // pushing the change summary out of the card.
        let transcriptHeight = min(DashboardType.size(transcript, width: textWidth).height,
                                   height - pad * 2 - DashboardSpace.md * 2 - 1 - notesHeight)
        transcript.frame = NSRect(x: pad, y: pad, width: textWidth, height: max(0, transcriptHeight))

        wellRule.frame = NSRect(x: pad, y: transcript.frame.maxY + DashboardSpace.md, width: textWidth, height: 1)

        let notesTop = wellRule.frame.maxY + DashboardSpace.md
        let notesEyebrowSize = notesEyebrow.fittingSize
        notesEyebrow.frame = NSRect(x: pad, y: notesTop, width: notesEyebrowSize.width, height: notesEyebrowSize.height)

        var noteY = notesTop + notesEyebrowSize.height + 10
        for (index, tag) in noteTags.enumerated() {
            tag.frame = NSRect(x: pad, y: noteY + 2, width: tag.frame.width, height: tag.frame.height)
            let text = noteTexts[index]
            let size = text.fittingSize
            text.frame = NSRect(x: pad + 66, y: noteY + ((tag.frame.height - size.height) / 2).rounded() + 2,
                                width: min(size.width, textWidth - 66), height: size.height)
            noteY += 26
        }
        if noteTags.isEmpty, let text = noteTexts.first {
            text.frame = NSRect(x: pad, y: noteY, width: textWidth,
                                height: DashboardType.size(text, width: textWidth).height)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        // Raised, against the list's sunken well. The open record is the thing
        // in focus, and depth is how a screen says that without a border colour.
        DashboardDraw.raisedSurface(bounds, radius: DashboardRadius.card,
                                    fillColor: style.raised, topColor: style.raisedTop,
                                    style: style, shadow: style.shadowCard, flipped: true)
    }
}

// MARK: - Metric

/// One number in the record's footer band. Borderless on purpose — four framed
/// tiles inside an already-framed card is three frames too many; hairline
/// dividers say "one instrument, four readings".
final class DictationMetricView: NSView {

    private let value: NSTextField
    private let caption: NSTextField

    override var isFlipped: Bool { true }

    init(value: String, unit: String, caption: String, accent: Bool, style: DashboardStyle) {
        let line = NSMutableAttributedString(string: value, attributes: [
            .font: DashboardType.metricSmall,
            // Emphasis by weight, not by hue.
            //
            // This was `style.accent`, and the accent now follows the system —
            // which on Roman's Mac is Graphite. The one number meant to stand out
            // came out grey while its three neighbours were white, so the
            // emphasised metric read as the DISABLED one. Exactly backwards, and
            // invisible until it was looked at on screen.
            //
            // A hue that can be turned off cannot carry meaning. The other three
            // step back instead.
            .foregroundColor: accent ? style.ink : style.inkSecondary,
            .kern: -0.4,
        ])
        line.append(NSAttributedString(string: " " + unit, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: style.inkTertiary,
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
        self.caption = DashboardType.label(caption, font: DashboardType.caption, color: style.inkTertiary)

        super.init(frame: .zero)
        addSubview(field)
        addSubview(self.caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let valueSize = value.fittingSize
        value.frame = NSRect(x: 0, y: 0, width: min(valueSize.width, bounds.width), height: valueSize.height)
        let captionSize = caption.fittingSize
        caption.frame = NSRect(x: 0, y: valueSize.height + 4,
                               width: min(captionSize.width, bounds.width), height: captionSize.height)
    }
}
