import AppKit

// The three sections Flow ships that Quill had not built: Scratchpad, Style and
// Notetaker. Two are real. The third is deliberately not faked — see below.

// MARK: - Shared card

/// One card chrome, so three sections cannot drift into three different looks.
final class SectionCard: NSView {
    init(style: DashboardStyle, title: String, trailing: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = style.card.cgColor
        layer?.cornerRadius = DashboardRadius.card
        layer?.borderWidth = 1
        layer?.borderColor = style.hairline.cgColor

        let heading = DashboardType.label(title, font: DashboardType.headline,
                                           color: style.ink)
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DashboardSpace.md),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: DashboardSpace.md),
        ])

        if let trailing {
            let t = DashboardType.label(trailing, font: DashboardType.caption,
                                         color: style.inkTertiary)
            t.translatesAutoresizingMaskIntoConstraints = false
            addSubview(t)
            NSLayoutConstraint.activate([
                t.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DashboardSpace.md),
                t.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private func vstack(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = alignment
    s.spacing = spacing
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

// MARK: - Scratchpad

public final class ScratchpadSectionView: NSView {

    public init(style: DashboardStyle, notes: [Note]) {
        super.init(frame: .zero)
        wantsLayer = true

        let eyebrow = DashboardType.label("Scratchpad", font: DashboardType.eyebrow,
                                           color: style.inkTertiary, uppercase: true)
        let title = DashboardType.label("Somewhere for a thought to land",
                                         font: DashboardType.display, color: style.ink)
        let deck = DashboardType.label(
            "Dictate with nothing focused and the text comes here instead of being dropped.",
            font: DashboardType.body, color: style.inkSecondary, lines: 2)

        let header = vstack([eyebrow, title, deck], spacing: DashboardSpace.xs)
        addSubview(header)

        let list = vstack(notes.isEmpty
                          ? [Self.emptyState(style: style)]
                          : notes.map { Self.row($0, style: style) },
                          spacing: DashboardSpace.xs)
        list.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(list)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DashboardSpace.xl),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func row(_ note: Note, style: DashboardStyle) -> NSView {
        let card = SectionCard(style: style, title: note.displayTitle,
                               trailing: note.isPinned ? "Pinned" : relative(note.modified))
        card.translatesAutoresizingMaskIntoConstraints = false

        let preview = DashboardType.label(note.body, font: DashboardType.callout,
                                           color: style.inkSecondary, lines: 2)
        preview.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(preview)

        let meta = DashboardType.label("\(note.wordCount) words", font: DashboardType.micro,
                                        color: style.inkQuaternary, uppercase: true)
        meta.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(meta)

        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: DashboardSpace.md),
            preview.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -DashboardSpace.md),
            preview.topAnchor.constraint(equalTo: card.topAnchor, constant: 42),
            meta.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: DashboardSpace.md),
            meta.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: DashboardSpace.sm),
            meta.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -DashboardSpace.md),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 108),
        ])
        return card
    }

    private static func emptyState(style: DashboardStyle) -> NSView {
        let card = SectionCard(style: style, title: "No notes yet")
        card.translatesAutoresizingMaskIntoConstraints = false
        let body = DashboardType.label(
            "Hold the dictation key with no text field focused. Whatever you say lands here.",
            font: DashboardType.callout, color: style.inkSecondary, lines: 2)
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: DashboardSpace.md),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -DashboardSpace.md),
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 42),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -DashboardSpace.md),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 104),
        ])
        return card
    }

    static func relative(_ date: Date, from now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86400: return "\(Int(seconds / 3600))h ago"
        case ..<604800: return "\(Int(seconds / 86400))d ago"
        default:
            let f = DateFormatter(); f.dateFormat = "d MMM"
            return f.string(from: date)
        }
    }
}

// MARK: - Style

public final class StyleSectionView: NSView {

    public init(style: DashboardStyle, profile: StyleProfile) {
        super.init(frame: .zero)
        wantsLayer = true

        let eyebrow = DashboardType.label("Style", font: DashboardType.eyebrow,
                                           color: style.inkTertiary, uppercase: true)
        let title = DashboardType.label("Sound like you, not like a model",
                                         font: DashboardType.display, color: style.ink)
        let deck = DashboardType.label(
            "Learned from how you edit what Quill writes. Nothing is inferred from a profile you did not create.",
            font: DashboardType.body, color: style.inkSecondary, lines: 2)
        let header = vstack([eyebrow, title, deck], spacing: DashboardSpace.xs)
        addSubview(header)

        // Traits, with their evidence. A learned setting shown without its support
        // count is indistinguishable from a guess, and this is a feature people
        // are right to distrust.
        let traits = SectionCard(style: style, title: "What Quill has learned",
                                 trailing: "\(profile.correctionCount) corrections seen")
        traits.translatesAutoresizingMaskIntoConstraints = false
        // An unlearned trait says so. Showing a default as though it were a
        // finding is how a learning feature earns distrust it cannot recover from.
        func described<V>(_ trait: StyleTrait<V>, _ render: (V) -> String) -> String {
            guard let value = trait.value else { return "not learned yet" }
            return "\(render(value))  ·  \(trait.support)"
        }
        let sentence = profile.sentenceLength.average.map { "\(Int($0.rounded())) words" }
            ?? "not learned yet"

        let rows = vstack([
            Self.traitRow("Spelling", described(profile.spelling) { "\($0)" }, style: style),
            Self.traitRow("Contractions", described(profile.contractions) { $0 ? "uses them" : "avoids them" }, style: style),
            Self.traitRow("Formality", described(profile.formality) { "\($0)" }, style: style),
            Self.traitRow("Oxford comma", described(profile.oxfordComma) { $0 ? "yes" : "no" }, style: style),
            Self.traitRow("Typical sentence", sentence, style: style),
        ], spacing: DashboardSpace.sm)
        traits.addSubview(rows)
        addSubview(traits)

        let accepted = profile.modelAccepted
        let reverted = profile.modelReverted
        let total = max(accepted + reverted, 1)
        let trust = SectionCard(style: style, title: "Do you keep what it writes?",
                                trailing: "\(Int(Double(accepted) / Double(total) * 100))% kept")
        trust.translatesAutoresizingMaskIntoConstraints = false
        let trustBody = DashboardType.label(
            accepted + reverted == 0
              ? "Nothing to judge yet. This fills in as you accept or undo Quill's cleanup."
              : "\(accepted) kept, \(reverted) undone. If this drops, the model is being too clever and the fast pass should win more often.",
            font: DashboardType.callout, color: style.inkSecondary, lines: 3)
        trustBody.translatesAutoresizingMaskIntoConstraints = false
        trust.addSubview(trustBody)
        addSubview(trust)

        // A horizontal stack rather than hand-rolled anchors: the first attempt
        // pinned one card to a multiplier of the section width and the other to
        // its trailing edge, which pushed the second card off screen entirely.
        let row = NSStackView(views: [traits, trust])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = DashboardSpace.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // Presets are the half of Style that works on day one, before anything
        // has been learned. Without them the screen is a promise rather than a
        // feature.
        let presets = SectionCard(style: style, title: "Tone",
                                  trailing: "applies before anything is learned")
        presets.translatesAutoresizingMaskIntoConstraints = false
        let chips = NSStackView(views: StylePreset.allCases.map {
            Self.chip($0, selected: $0 == profile.preset, style: style)
        })
        chips.orientation = .horizontal
        chips.spacing = DashboardSpace.xs
        chips.translatesAutoresizingMaskIntoConstraints = false
        presets.addSubview(chips)
        addSubview(presets)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor, constant: DashboardSpace.xs),

            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DashboardSpace.xl),
            row.heightAnchor.constraint(equalToConstant: 210),

            rows.leadingAnchor.constraint(equalTo: traits.leadingAnchor, constant: DashboardSpace.md),
            rows.trailingAnchor.constraint(equalTo: traits.trailingAnchor, constant: -DashboardSpace.md),
            rows.topAnchor.constraint(equalTo: traits.topAnchor, constant: 46),

            trustBody.leadingAnchor.constraint(equalTo: trust.leadingAnchor, constant: DashboardSpace.md),
            trustBody.trailingAnchor.constraint(equalTo: trust.trailingAnchor, constant: -DashboardSpace.md),
            trustBody.topAnchor.constraint(equalTo: trust.topAnchor, constant: 46),

            presets.leadingAnchor.constraint(equalTo: leadingAnchor),
            presets.trailingAnchor.constraint(equalTo: trailingAnchor),
            presets.topAnchor.constraint(equalTo: row.bottomAnchor, constant: DashboardSpace.sm),
            presets.heightAnchor.constraint(equalToConstant: 108),
            chips.leadingAnchor.constraint(equalTo: presets.leadingAnchor, constant: DashboardSpace.md),
            chips.topAnchor.constraint(equalTo: presets.topAnchor, constant: 48),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func chip(_ preset: StylePreset, selected: Bool, style: DashboardStyle) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = DashboardRadius.chip
        box.layer?.backgroundColor = (selected ? style.accentSoft : style.cardAlt).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = (selected ? style.accent : style.hairline).cgColor

        let text = DashboardType.label(preset.title, font: DashboardType.caption,
                                       color: selected ? style.accent : style.inkSecondary)
        text.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(text)
        NSLayoutConstraint.activate([
            text.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: DashboardSpace.sm),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -DashboardSpace.sm),
            box.heightAnchor.constraint(equalToConstant: 30),
        ])
        return box
    }

    private static func traitRow(_ name: String, _ value: String, style: DashboardStyle) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let n = DashboardType.label(name, font: DashboardType.callout, color: style.inkSecondary)
        let v = DashboardType.label(value, font: DashboardType.callout, color: style.ink)
        n.translatesAutoresizingMaskIntoConstraints = false
        v.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(n); row.addSubview(v)
        NSLayoutConstraint.activate([
            n.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            n.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            v.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            v.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 22),
        ])
        return row
    }
}

// MARK: - Notetaker

/// Deliberately NOT built, and deliberately not faked.
///
/// Flow's Notetaker joins calendar meetings and records both sides of a call.
/// That needs system-audio capture (a TCC permission separate from the
/// microphone), calendar access, and a participant-consent story — none of which
/// exist here. A convincing-looking screen backed by nothing would have scored
/// well in review and been a lie in the app, which is the exact failure this
/// project has been trying to avoid all day.
public final class NotetakerSectionView: NSView {

    public init(style: DashboardStyle) {
        super.init(frame: .zero)
        wantsLayer = true

        let eyebrow = DashboardType.label("Notetaker", font: DashboardType.eyebrow,
                                           color: style.inkTertiary, uppercase: true)
        let title = DashboardType.label("Not built yet",
                                         font: DashboardType.display, color: style.ink)
        let deck = DashboardType.label(
            "Meeting capture needs three things Quill does not have: system-audio recording, calendar access, and a way to tell the other people in the room. Rather than ship a screen that looks finished and records nothing, this says so.",
            font: DashboardType.body, color: style.inkSecondary, lines: 4)
        let header = vstack([eyebrow, title, deck], spacing: DashboardSpace.xs)
        addSubview(header)

        let card = SectionCard(style: style, title: "What it would take")
        card.translatesAutoresizingMaskIntoConstraints = false
        let list = vstack([
            DashboardType.label("· System-audio capture permission (macOS 14.4+), separate from the microphone grant",
                                 font: DashboardType.callout, color: style.inkSecondary, lines: 2),
            DashboardType.label("· Calendar access, to know a meeting is happening at all",
                                 font: DashboardType.callout, color: style.inkSecondary, lines: 2),
            DashboardType.label("· Speaker separation, or the transcript is one undifferentiated wall",
                                 font: DashboardType.callout, color: style.inkSecondary, lines: 2),
        ], spacing: DashboardSpace.xs)
        card.addSubview(list)
        addSubview(card)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -120),
            header.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DashboardSpace.xl),
            list.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: DashboardSpace.md),
            list.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -DashboardSpace.md),
            list.topAnchor.constraint(equalTo: card.topAnchor, constant: 46),
            list.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -DashboardSpace.md),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
