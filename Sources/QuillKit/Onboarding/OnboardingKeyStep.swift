import AppKit

/// The AI key panel: Settings ▸ Dictation ▸ AI cleanup key, and the prompt shown
/// when a transform that needs a model is run without one.
///
/// This used to be a step in first-run onboarding and is not any more. It asked
/// the most work of anyone — leave the app, sign up at build.nvidia.com, generate
/// a key, come back and paste it — at the moment they had least reason to care,
/// standing next to three permissions that genuinely are required, which made an
/// optional thing read as mandatory. Worse, its own copy credited the key with
/// spoken self-correction, which `SelfCorrection.resolve` does offline and has a
/// test proving it, so skipping the step looked like giving up a feature you
/// still had. It now appears where the user is already trying to do the thing it
/// unlocks.
///
/// The field is checked against the real endpoint rather than accepted on the
/// strength of looking like a key.
final class OnboardingKeyStep: NSView, OnboardingSizing {

    private let style: DashboardStyle
    private let field: SnippetsField
    private let test: DashboardButton
    private let remove: DashboardButton
    private let getOne: DashboardButton
    private var status: NSTextField
    private let what: NSTextField
    private var checking = false

    override var isFlipped: Bool { true }

    init(style: DashboardStyle) {
        self.style = style
        field = SnippetsField(style: style, placeholder: "nvapi-…", badgeSymbol: "key", isSecure: true)
        test = DashboardButton(title: "Check", kind: .secondary, style: style)
        remove = DashboardButton(title: "Remove", kind: .ghost, style: style)
        getOne = DashboardButton(title: "Get a free key", kind: .ghost, style: style)
        what = DashboardType.label(
            "Taking something back already works without a key — say “send it to Noah, no wait, "
                + "Carlo” and only Carlo is typed, offline. A key adds the tangled cases the rules "
                + "won’t guess at, and four transforms that need a model: Shorter, Summarise, "
                + "More casual and Email. Only the sentence being worked on is ever sent.",
            font: DashboardType.body, color: style.inkSecondary, lines: 5, lineHeight: 18)
        status = DashboardType.label("", font: DashboardType.caption,
                                     color: style.inkTertiary, lines: 2, lineHeight: 16)
        super.init(frame: .zero)

        // The saved key is NEVER put back into the field.
        //
        // It was, for about one build, and the screenshot taken to check the
        // layout has a live NVIDIA credential in it in 40-point type. That is the
        // whole argument: a secret rendered anywhere is a secret in every
        // screenshot, screen share and shoulder-glance from then on, and nobody
        // needs to READ their own key — they need to know whether one is set and
        // to be able to replace it. So: a fingerprint, which identifies the key
        // and reverses to nothing, and an empty field.
        addSubview(what)
        addSubview(field)
        addSubview(test)
        addSubview(remove)
        addSubview(getOne)
        addSubview(status)
        remove.isHidden = true
        remove.onClick = { [weak self] in
            guard let self else { return }
            NIMKey.save("")
            self.field.text = ""
            self.remove.isHidden = true
            self.setStatus("Removed. Quill will use the on-device cleanup only.",
                           color: self.style.inkTertiary)
        }

        getOne.onClick = {
            // The page that mints one. Named rather than hidden behind "learn
            // more": someone at this step wants the key, not an explanation.
            if let url = URL(string: "https://build.nvidia.com/") {
                NSWorkspace.shared.open(url)
            }
        }
        test.onClick = { [weak self] in self?.check() }
        field.onCommit = { [weak self] in self?.check() }
        field.onChange = { [weak self] _ in self?.setStatus("", color: style.inkTertiary) }

        if let existing = NIMKey.load() {
            remove.isHidden = false
            setStatus("A key is saved on this Mac (\(NIMKey.fingerprint(existing))). "
                        + "Paste another to replace it.", color: style.inkTertiary)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Saved only once NVIDIA has agreed it is a key.
    ///
    /// Accepting it on shape alone would mean the setup says "done" and the
    /// feature silently never runs — which is precisely the class of failure
    /// this whole window exists to stop happening three separate times.
    private func check() {
        guard !checking else { return }
        let typed = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            // An empty field means "I did not type anything", not "delete what I
            // have". Removing is its own button, because the field no longer
            // shows the saved key and an empty box must not silently mean gone.
            setStatus("Nothing to check. Paste a key, or Skip.", color: style.inkTertiary)
            return
        }
        checking = true
        test.title = "Checking…"
        setStatus("Asking NVIDIA whether this key works…", color: style.inkTertiary)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let client = NIMClient(key: typed)
            let outcome: String
            let colour: NSColor
            do {
                _ = try await client.complete(system: "Reply with the word ok.",
                                              user: "ok",
                                              model: nil,
                                              deadline: .seconds(12))
                NIMKey.save(typed)
                self.field.text = ""
                self.remove.isHidden = false
                outcome = "Working, and saved (\(NIMKey.fingerprint(typed))). Shorter, Summarise, More casual and Email are on."
                colour = self.style.accentInk
            } catch let error as NIMError {
                outcome = Self.explain(error)
                colour = self.style.inkSecondary
            } catch {
                outcome = error.localizedDescription
                colour = self.style.inkSecondary
            }
            self.checking = false
            self.test.title = "Check"
            self.setStatus(outcome, color: colour)
        }
    }

    /// Said in the words of someone who has just pasted something, not in the
    /// words of the API.
    private static func explain(_ error: NIMError) -> String {
        switch error {
        case .unauthorized:
            return "NVIDIA rejected that key. Check it was copied whole — they start with “nvapi-”."
        case .offline:
            return "Could not reach NVIDIA. That may be the network rather than the key — Skip and try later from Settings."
        case .rateLimited:
            return "The key works, but the account is rate-limited right now. Try again shortly."
        case .modelUnavailable:
            return "The key works, but this account cannot use the model Quill asks for."
        case .deadlineExceeded:
            return "No answer in twelve seconds. Probably the network; the key may still be fine."
        default:
            return error.errorDescription ?? "That did not work."
        }
    }

    private func setStatus(_ text: String, color: NSColor) {
        status.removeFromSuperview()
        status = DashboardType.label(text, font: DashboardType.caption,
                                     color: color, lines: 2, lineHeight: 16)
        addSubview(status)
        needsLayout = true
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        DashboardType.size(what, width: width).height + 18 + 34 + 10
            + DashboardType.size(status, width: width).height
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        let whatHeight = DashboardType.size(what, width: bounds.width).height
        what.frame = NSRect(x: 0, y: y, width: bounds.width, height: whatHeight)
        y += whatHeight + 18

        let buttonWidth = test.intrinsicWidth
        field.frame = NSRect(x: 0, y: y, width: bounds.width - buttonWidth - 8, height: 34)
        test.frame = NSRect(x: bounds.width - buttonWidth, y: y + 3, width: buttonWidth, height: 28)
        y += 34 + 10

        let trailing = getOne.intrinsicWidth + (remove.isHidden ? 0 : remove.intrinsicWidth + 6)
        status.frame = NSRect(x: 2, y: y, width: max(0, bounds.width - trailing - 12),
                              height: DashboardType.size(status, width: bounds.width - trailing - 12).height)
        getOne.frame = NSRect(x: bounds.width - getOne.intrinsicWidth, y: y - 4,
                              width: getOne.intrinsicWidth, height: 26)
        remove.frame = NSRect(x: getOne.frame.minX - 6 - remove.intrinsicWidth, y: y - 4,
                              width: remove.intrinsicWidth, height: 26)
    }
}

/// Which step you are on, as four dots. The only thing in this window that says
/// how much is left, which is the question anyone in a setup flow is asking.
final class OnboardingDots: NSView {
    var count = 4 { didSet { needsDisplay = true } }

    /// How wide the dots need to be drawn, so the footer can decide whether
    /// there is room for them rather than drawing them under a button.
    var intrinsicWidth: CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count - 1) * 6 + 16 + CGFloat(count - 1) * 7
    }
    var index = 0 { didSet { needsDisplay = true } }
    var tint: DashboardStyle? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let tint, count > 0 else { return }
        // The current step is a capsule rather than a brighter dot: at six points
        // a colour difference is most of what a dot can say, and it is the first
        // thing to disappear for anyone who cannot see the difference. Shape
        // survives that.
        let diameter: CGFloat = 6
        let currentWidth: CGFloat = 16
        let gap: CGFloat = 7
        let total = CGFloat(count - 1) * diameter + currentWidth + CGFloat(count - 1) * gap
        var x = (bounds.width - total) / 2
        let y = (bounds.height - diameter) / 2
        for i in 0 ..< count {
            let isCurrent = i == index
            (isCurrent ? tint.accent : tint.inkQuaternary).setFill()
            let width = isCurrent ? currentWidth : diameter
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: diameter),
                         xRadius: diameter / 2, yRadius: diameter / 2).fill()
            x += width + gap
        }
    }
}
