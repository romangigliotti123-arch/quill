import AppKit

/// A control that actually responds to a pointer.
///
/// AppKit gives you NSButton, whose stock look is exactly the default chrome this
/// window exists to avoid, and whose bezel cannot be talked out of. So the
/// hit-testing, hover tracking and press feedback live here and the drawing is
/// left to the caller.
///
/// The details that separate this from a coloured rectangle: the tracking area is
/// rebuilt on every bounds change (a stale one leaves a control permanently
/// "hovered" after a window resize), the press state is driven by a real
/// mouseDown/mouseUp pair rather than a click action so the control depresses
/// under the finger, and the cursor becomes a pointing hand — macOS users read
/// that as "this is clickable" before they read anything else.
public final class HoverControl: NSView {

    public enum Feedback {
        /// Background lightens on hover. For rows and chips.
        case fill
        /// Whole control dims on press. For solid buttons where a lighter fill
        /// would fight the label.
        case dim
    }

    private let onClick: () -> Void
    private let feedback: Feedback
    private let baseColor: NSColor
    private let hoverColor: NSColor

    private var isHovered = false { didSet { if isHovered != oldValue { reflectState() } } }
    private var isPressed = false { didSet { if isPressed != oldValue { reflectState() } } }
    private var tracking: NSTrackingArea?

    public init(base: NSColor,
                hover: NSColor,
                cornerRadius: CGFloat,
                feedback: Feedback = .fill,
                onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.feedback = feedback
        self.baseColor = base
        self.hoverColor = hover
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = base.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // A tracking area holds onto the bounds it was made with. Rebuild it whenever
    // those change, or a resized window leaves controls stuck in a hover state.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
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
        let wasInside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        // Only fire if the pointer is still inside — dragging off a control is how
        // people cancel a click they changed their mind about.
        if wasInside { onClick() }
    }

    private func reflectState() {
        // Fast enough to feel attached to the pointer. Anything past ~0.15s reads
        // as lag rather than as animation — and a press has to be quicker again,
        // because the finger is already there when the frame lands.
        DashboardMotion.run(isPressed ? DashboardMotion.press : DashboardMotion.quick) { _ in
            switch self.feedback {
            case .fill:
                self.layer?.backgroundColor = (self.isHovered ? self.hoverColor : self.baseColor).cgColor
                self.animator().alphaValue = self.isPressed ? 0.75 : 1
            case .dim:
                self.animator().alphaValue = self.isPressed ? 0.7 : (self.isHovered ? 0.88 : 1)
            }
        }
    }
}

public extension Notification.Name {
    /// Posted when a section mutates something the dashboard is displaying.
    /// The window rebuilds the visible section rather than every section trying
    /// to reload itself — a screen that only refreshes the part you touched is
    /// how you end up with two views disagreeing about the same data.
    static let quillDashboardNeedsReload = Notification.Name("com.romangigliotti.quill.dashboardNeedsReload")
}
