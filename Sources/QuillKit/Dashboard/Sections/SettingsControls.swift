import AppKit

// The three controls Settings needs and AppKit will not give without its own
// chrome: a switch, a menu button, and something that listens for a keypress.
// Each animates every state it can be in — there is no state here that changes
// on a hard cut.

// MARK: - Switch

/// The on/off switch, drawn rather than borrowed.
///
/// `NSSwitch` exists and is the correct control, but it paints in the system
/// accent colour and ignores the palette this window resolves for itself, so a
/// user with a pink accent gets one pink object on an otherwise monochrome
/// screen. The knob is a real sublayer moving between two positions — animating
/// a redraw instead would give the travel no motion at all.
public final class DashboardSwitch: NSView {

    public var isOn: Bool { didSet { if isOn != oldValue { reflect(animated: true) } } }
    public var style: DashboardStyle { didSet { reflect(animated: false) } }
    public var onToggle: ((Bool) -> Void)?

    private let track = CALayer()
    private let knob = CALayer()
    private var isHovered = false { didSet { reflect(animated: true) } }
    private var isPressed = false { didSet { reflect(animated: true) } }

    private static let size = NSSize(width: 38, height: 22)
    private static let inset: CGFloat = 2.5

    public override var isFlipped: Bool { true }

    public init(isOn: Bool, style: DashboardStyle) {
        self.isOn = isOn
        self.style = style
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        track.cornerRadius = Self.size.height / 2
        track.cornerCurve = .continuous
        knob.cornerRadius = (Self.size.height - Self.inset * 2) / 2
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.22
        knob.shadowRadius = 2
        knob.shadowOffset = CGSize(width: 0, height: -1)
        reflect(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { Self.size }

    public override func layout() {
        super.layout()
        reflect(animated: false)
    }

    private func reflect(animated: Bool) {
        let diameter = bounds.height - Self.inset * 2
        let x = isOn ? bounds.width - Self.inset - diameter : Self.inset
        let trackColor = isOn
            ? style.accent.withAlphaComponent(isHovered ? 1 : 0.92)
            : (isHovered ? style.hairlineStrong : style.hairline)

        let apply = {
            self.track.frame = self.bounds
            self.track.backgroundColor = trackColor.cgColor
            self.knob.frame = NSRect(x: x, y: Self.inset, width: diameter, height: diameter)
            self.knob.backgroundColor = (self.style.isDark ? NSColor.white : NSColor.white).cgColor
            // Presses squash the knob a touch. It is the smallest possible cue
            // that the pointer is on the control and not merely over it.
            self.knob.transform = CATransform3DMakeScale(self.isPressed ? 0.9 : 1,
                                                         self.isPressed ? 0.9 : 1, 1)
        }

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            apply()
            CATransaction.commit()
            return
        }
        DashboardMotion.run(DashboardMotion.standard, timing: DashboardMotion.snap) { _ in apply() }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
    }
    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        NSCursor.arrow.set()
    }
    public override func mouseDown(with event: NSEvent) { isPressed = true }
    public override func mouseUp(with event: NSEvent) {
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        onToggle?(isOn)
    }
}

// MARK: - Menu button

/// Current value, a chevron, and a real `NSMenu` on click.
///
/// The menu is the system's, deliberately: a hand-drawn dropdown would have to
/// re-implement keyboard traversal, type-select and scrolling for long device
/// lists, and would still land in the wrong place on a second display. The
/// button around it is ours so it matches the window; what opens is macOS's.
public final class DashboardMenuButton: NSView {

    public struct Item {
        public let title: String
        public let isSelected: Bool
        public let action: () -> Void
        public init(title: String, isSelected: Bool, action: @escaping () -> Void) {
            self.title = title
            self.isSelected = isSelected
            self.action = action
        }
    }

    public var style: DashboardStyle { didSet { rebuild() } }
    public var title: String { didSet { rebuild() } }
    /// Rebuilt on every click, so a microphone plugged in while the window is
    /// open appears without a refresh.
    public var itemsProvider: () -> [Item]

    private let label = NSTextField(labelWithString: "")
    private let chevron = DashboardIconView(image: nil)
    private var isHovered = false { didSet { reflect() } }
    private var isPressed = false { didSet { reflect() } }
    private var isOpen = false { didSet { reflect() } }

    public override var isFlipped: Bool { true }

    public init(title: String, style: DashboardStyle, items: @escaping () -> [Item]) {
        self.title = title
        self.style = style
        self.itemsProvider = items
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DashboardRadius.control
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        addSubview(label)
        addSubview(chevron)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public var intrinsicWidth: CGFloat {
        ceil(label.fittingSize.width) + DashboardSpace.sm * 2 + 20
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: intrinsicWidth, height: 30)
    }

    private func rebuild() {
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        label.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [.font: DashboardType.control, .foregroundColor: style.ink])
        chevron.image = DashboardIcon.image("chevron.up.chevron.down", pointSize: 9,
                                            weight: .semibold, color: style.inkTertiary)
        reflect()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func reflect() {
        let lit = isHovered || isOpen
        DashboardMotion.run(isPressed ? DashboardMotion.press : DashboardMotion.quick) { _ in
            // `style.fill` is the INVERTED surface — near-white in dark mode,
            // near-black in light — and belongs to primary buttons only. Using it
            // here put `style.ink` text on its own colour and the control rendered
            // as a blank white box in both themes.
            self.layer?.backgroundColor = (lit ? self.style.raisedTop : self.style.raised).cgColor
            self.layer?.borderColor = (lit ? self.style.hairlineStrong : self.style.hairline).cgColor
            self.animator().alphaValue = self.isPressed ? 0.82 : 1
        }
    }

    public override func layout() {
        super.layout()
        let chevronWidth: CGFloat = 14
        chevron.frame = NSRect(x: bounds.width - DashboardSpace.sm - chevronWidth,
                               y: (bounds.height - 16) / 2, width: chevronWidth, height: 16)
        let size = label.fittingSize
        let available = bounds.width - DashboardSpace.sm * 2 - chevronWidth - 6
        label.frame = NSRect(x: DashboardSpace.sm,
                             y: ((bounds.height - size.height) / 2).rounded(),
                             width: max(0, min(size.width, available)), height: size.height)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
    }
    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        NSCursor.arrow.set()
    }
    public override func mouseDown(with event: NSEvent) {
        isPressed = true
        present()
    }
    public override func mouseUp(with event: NSEvent) { isPressed = false }

    private func present() {
        let menu = NSMenu()
        menu.font = .systemFont(ofSize: 13)
        for item in itemsProvider() {
            let entry = NSMenuItem(title: item.title, action: #selector(pick(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = Box(item.action)
            entry.state = item.isSelected ? .on : .off
            menu.addItem(entry)
        }
        isOpen = true
        // Anchored to the button's bottom-left, which is where macOS puts a pop-up
        // menu; `popUpContextMenu` would open it under the pointer instead and the
        // list would jump around depending on where the click landed.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: bounds.height + 4),
                   in: self)
        isOpen = false
        isPressed = false
    }

    private final class Box: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    @objc private func pick(_ sender: NSMenuItem) {
        (sender.representedObject as? Box)?.action()
    }
}

// MARK: - Key recorder

/// Click it, press a modifier, that modifier becomes the dictation key.
///
/// Two things make this harder than it looks. The first is that the app's own
/// event tap is watching the same keyboard, so pressing the key you want to
/// assign would also start a dictation — hence `isCapturingHotkey`, which makes
/// the engine deaf for as long as this control is listening. The second is that
/// only bare modifiers are assignable, so this listens to `flagsChanged` rather
/// than `keyDown`, and a key going *down* is what counts: waiting for the release
/// would mean a key held for half a second registers only when let go.
public final class KeyRecorderControl: NSView {

    public var style: DashboardStyle { didSet { rebuild() } }
    public private(set) var binding: HotkeyBinding { didSet { rebuild() } }
    public var onPick: ((HotkeyBinding) -> Void)?

    private let cap = NSTextField(labelWithString: "")
    private var monitor: Any?
    private var isRecording = false { didSet { rebuild() } }
    private var isHovered = false { didSet { reflect() } }
    private var isPressed = false { didSet { reflect() } }

    public override var isFlipped: Bool { true }

    public init(binding: HotkeyBinding, style: DashboardStyle) {
        self.binding = binding
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DashboardRadius.chip
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        // A glow rather than a scale. Transforming the backing layer of a
        // layer-backed NSView fights AppKit, which reassigns `layer.frame` on
        // every layout pass and computes it *through* the transform — the control
        // ends up drifting a few points each time it is laid out. A shadow is
        // outside that calculation entirely.
        layer?.shadowColor = style.accent.cgColor
        layer?.shadowRadius = 6
        layer?.shadowOffset = .zero
        layer?.shadowOpacity = 0
        addSubview(cap)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // Not merely tidy: a live local monitor after this view is gone keeps
        // swallowing modifier presses for the whole app.
        if let monitor { NSEvent.removeMonitor(monitor) }
        QuillSettings.shared.isCapturingHotkey = false
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: max(64, ceil(cap.fittingSize.width) + 22), height: 28)
    }

    public func setBinding(_ new: HotkeyBinding) { binding = new }

    private func rebuild() {
        let text = isRecording ? "Press a key" : binding.displayName
        cap.isBezeled = false
        cap.drawsBackground = false
        cap.isEditable = false
        cap.isSelectable = false
        cap.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: isRecording ? style.accentInk : style.ink,
            ])
        reflect()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func reflect() {
        let lit = isHovered && !isRecording
        DashboardMotion.run(isPressed ? DashboardMotion.press : DashboardMotion.quick,
                            timing: DashboardMotion.snap) { _ in
            self.layer?.backgroundColor = (self.isRecording ? self.style.accentSoft
                                            : lit ? self.style.raisedTop : self.style.raised).cgColor
            self.layer?.borderColor = (self.isRecording ? self.style.accent
                                        : lit ? self.style.hairlineStrong : self.style.hairline).cgColor
            self.layer?.shadowColor = self.style.accent.cgColor
            // Lit while it is waiting for a key. A control that is listening must
            // not look identical to one that is not.
            self.layer?.shadowOpacity = self.isRecording ? 0.45 : 0
            self.animator().alphaValue = self.isPressed ? 0.8 : 1
        }
    }

    public override func layout() {
        super.layout()
        let size = cap.fittingSize
        cap.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                           y: ((bounds.height - size.height) / 2).rounded(),
                           width: size.width, height: size.height)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
    }
    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        NSCursor.arrow.set()
    }
    public override func mouseDown(with event: NSEvent) { isPressed = true }
    public override func mouseUp(with event: NSEvent) {
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isRecording ? stopRecording() : startRecording()
    }

    // MARK: - Recording

    private func startRecording() {
        guard monitor == nil else { return }
        QuillSettings.shared.isCapturingHotkey = true
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            guard let self else { return event }
            return self.consume(event)
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        QuillSettings.shared.isCapturingHotkey = false
        isRecording = false
    }

    private func consume(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            // Escape backs out. Anything else is not assignable, and swallowing it
            // is better than letting a stray letter type itself into the window
            // behind a control that is visibly waiting for a key.
            stopRecording()
            return nil
        }
        let keyCode = event.keyCode
        guard HotkeyBinding.isTrackedModifier(keyCode: keyCode) else { return nil }
        let candidate = HotkeyBinding(keyCode: keyCode)
        // Down, not up: `flagsChanged` fires for both, and the presence bit is
        // what tells them apart. Read from the CGEvent rather than
        // `NSEvent.modifierFlags`, because the left/right distinction lives in
        // the device-dependent low bits and AppKit does not promise to carry
        // them — without this, binding right ⌥ silently binds "some option key".
        guard let bits = event.cgEvent?.flags,
              bits.contains(candidate.presenceMask) else { return nil }
        stopRecording()
        binding = candidate
        onPick?(candidate)
        return nil
    }
}
