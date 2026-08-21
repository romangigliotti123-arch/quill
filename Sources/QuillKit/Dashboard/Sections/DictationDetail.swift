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

    /// "1 word", not "1 words".
    ///
    /// The record card said "1 words · 54 wpm" on any one-word dictation, which
    /// on this Mac is a large share of them ("hello?", "yes", "undo"). A grammar
    /// slip on the one line of a screen a person reads every time is not a small
    /// thing — it is the detail that makes the rest look unchecked.
    static func plural(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count(value)) \(value == 1 ? singular : (plural ?? singular + "s"))"
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

// MARK: - The open record

/// One record, opened — the hero at the top of the Dictation page.
///
/// This is the half of the screen Wispr Flow does not have. Their history is a
/// list of finished paragraphs — useful for finding something you said, useless
/// for deciding whether to trust it. Quill already stores what the recogniser
/// heard *and* what got typed, so the record leads with the difference between
/// them, and the raw text stops being a column nobody can see.
///
/// It **sizes itself**, and that is the load-bearing part. The view it replaced
/// was pinned to a half-window card with a metric band welded to its bottom
/// edge, so a four-word dictation left four hundred points of empty card under
/// it and there was nothing the layout could do about it. Here, `fittingHeight`
/// is the height, the page asks for it, and the list underneath takes whatever
/// is left. A short record makes a short hero. There is no state in which this
/// view is mostly empty, because there is no state in which it is bigger than
/// what it holds.
///
/// One container, not two. The old card put the transcript in a bordered well
/// *inside* the bordered card, which is two frames to say "this is the text" —
/// and empty space inside a border reads as a hole where the same space on a
/// plain surface reads as whitespace.
public final class DictationRecordView: NSView {

    /// The transcript is the most-read text on the screen and gets a size of its
    /// own. It went up from 15 to 19 with the width: at 1024 points a 15pt line
    /// runs to about 130 characters, which is roughly twice the measure anything
    /// is comfortable to read at.
    private static let transcriptFont = NSFont.systemFont(ofSize: 19, weight: .regular)
    private static let transcriptLeading: CGFloat = 28
    private static let transcriptMaxLines = 5
    /// Nothing is read at more than this. Full-bleed prose across 1024 points is
    /// a wall; every editorial page in the world sets a measure and this is one.
    private static let transcriptMaxWidth: CGFloat = 760
    private static let pad = DashboardSpace.lg

    private let record: DictationRecord
    private let diff: TranscriptDiff
    private let style: DashboardStyle

    private let title: NSTextField
    private let copyButton: DashboardButton
    private let insertButton: DashboardButton

    private let transcript: NSTextField
    private let legend: NSTextField?
    private let rule: DashboardRule?
    private var noteTags: [DashboardChip] = []
    private var noteTexts: [NSTextField] = []

    public override var isFlipped: Bool { true }

    public init(record: DictationRecord, style: DashboardStyle) {
        self.record = record
        self.style = style
        self.diff = TranscriptDiff.between(raw: record.rawText, inserted: record.insertedText)

        // Everything a person actually wants on this line, and nothing else.
        //
        // It used to read "1 words · 54 wpm · MacBook Air Microphone · Fast
        // cleanup". Words per minute is an Insights number; which microphone was
        // open is a Settings fact; and "Fast cleanup" versus "Thorough cleanup" is
        // the name of an internal deadline that no user has a decision to make
        // about. Three of the four were instrumentation from the latency work,
        // sitting permanently on a card about what somebody said.
        title = DashboardType.label(
            "\(DictationFormat.dayTitle(record.date)), \(DictationFormat.time(record.date))"
            + "   \u{00B7}   \(DictationFormat.plural(record.wordCount, "word"))",
            font: DashboardType.headline, color: style.inkTertiary)

        copyButton = DashboardButton(title: "Copy", symbol: "doc.on.doc", kind: .secondary, style: style)
        insertButton = DashboardButton(title: "Re-insert", symbol: "text.insert", kind: .primary, style: style)

        transcript = DictationRecordView.transcriptLabel(diff: diff, style: style)

        // The legend and the change summary only exist when something changed.
        // On a clean dictation they were a rule, a heading and a sentence saying
        // nothing happened — three rows of furniture to report an absence.
        let notes = Array(diff.notes.prefix(3))
        if notes.isEmpty {
            legend = nil
            rule = nil
        } else {
            legend = DictationRecordView.legendLabel(style: style)
            rule = DashboardRule(color: style.hairline)
        }

        super.init(frame: .zero)

        addSubview(title)
        addSubview(copyButton)
        addSubview(insertButton)
        addSubview(transcript)
        legend.map(addSubview)
        rule.map(addSubview)

        for note in notes {
            let tag = DashboardChip(text: note.tag, tone: .neutral, style: style, uppercase: false)
            let text = DashboardType.label(note.text, font: DashboardType.callout, color: style.inkSecondary)
            addSubview(tag)
            addSubview(text)
            noteTags.append(tag)
            noteTexts.append(text)
        }

        copyButton.onClick = { [weak self] in self?.copyToPasteboard() }
        insertButton.onClick = { [weak self] in self?.reinsert() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

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
        field.maximumNumberOfLines = transcriptMaxLines
        field.lineBreakMode = .byTruncatingTail
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

    /// The measure grows with the window, but slowly, and never to the edge.
    ///
    /// A fixed cap is the right typographic answer and the wrong one for a card:
    /// at 1700 points the text sat in the left half of a bordered box and the
    /// right half was empty, which reads as a layout that failed rather than as a
    /// column that was set. Scaling at 62% keeps the line inside a readable
    /// measure at every size the window can be dragged to, and the floor stops it
    /// getting narrower than it was at 1350.
    private func textWidth(for width: CGFloat) -> CGFloat {
        let inner = width - DictationRecordView.pad * 2
        return min(inner, max(DictationRecordView.transcriptMaxWidth, min(inner * 0.62, 980)))
    }

    private var noteRowHeight: CGFloat { 26 }

    /// The height this record wants. The page asks before it places it, so the
    /// same arithmetic decides the frame and the layout inside it.
    public func fittingHeight(width: CGFloat) -> CGFloat {
        let pad = DictationRecordView.pad
        var height = pad
            + ceil(title.fittingSize.height)
            + DashboardSpace.md
            + min(DashboardType.size(transcript, width: textWidth(for: width)).height,
                  CGFloat(DictationRecordView.transcriptMaxLines) * DictationRecordView.transcriptLeading)
        if !noteTexts.isEmpty {
            height += DashboardSpace.lg + 1 + DashboardSpace.md
                + CGFloat(noteTexts.count) * noteRowHeight - 4
        }
        return ceil(height + pad)
    }

    public override func layout() {
        super.layout()
        let pad = DictationRecordView.pad
        let width = bounds.width
        guard width > pad * 2 else { return }

        let insertWidth = insertButton.intrinsicWidth
        insertButton.frame = NSRect(x: width - pad - insertWidth, y: pad - 5, width: insertWidth, height: 30)
        let copyWidth = copyButton.intrinsicWidth
        copyButton.frame = NSRect(x: insertButton.frame.minX - DashboardSpace.xs - copyWidth,
                                  y: insertButton.frame.minY, width: copyWidth, height: 30)

        let titleSize = title.fittingSize
        title.frame = NSRect(x: pad, y: pad,
                             width: min(titleSize.width, copyButton.frame.minX - pad - DashboardSpace.md),
                             height: ceil(titleSize.height))

        var y = title.frame.maxY + DashboardSpace.md
        let text = textWidth(for: width)
        let transcriptHeight = min(DashboardType.size(transcript, width: text).height,
                                   CGFloat(DictationRecordView.transcriptMaxLines)
                                   * DictationRecordView.transcriptLeading)
        transcript.frame = NSRect(x: pad, y: y, width: text, height: transcriptHeight)
        y += transcriptHeight

        guard let rule else { return }
        y += DashboardSpace.lg
        rule.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: 1)
        y += 1 + DashboardSpace.md

        // The legend sits on the summary's first row, right-aligned. It explains
        // the two treatments in the transcript above and belongs beside the list
        // of what they were, not floating on its own line.
        if let legend {
            let size = legend.fittingSize
            legend.frame = NSRect(x: width - pad - size.width, y: y + 3,
                                  width: size.width, height: size.height)
        }

        let legendGutter = (legend?.fittingSize.width ?? 0) + DashboardSpace.lg
        for (index, tag) in noteTags.enumerated() {
            tag.frame = NSRect(x: pad, y: y + 2, width: tag.frame.width, height: tag.frame.height)
            let label = noteTexts[index]
            let size = label.fittingSize
            let available = width - pad * 2 - 70 - (index == 0 ? legendGutter : 0)
            label.frame = NSRect(x: pad + 70,
                                 y: y + ((tag.frame.height - size.height) / 2).rounded() + 2,
                                 width: min(size.width, max(40, available)), height: size.height)
            y += noteRowHeight
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        // A tint of the page, not a slab on it. `raised` at full width is a grey
        // rectangle the size of a paragraph; the card tint plus a hairline says
        // "this is one object" without competing with the text inside it.
        DashboardDraw.fill(bounds, radius: DashboardRadius.card, color: style.card)
        DashboardDraw.stroke(bounds, radius: DashboardRadius.card, color: style.hairline)
    }
}
