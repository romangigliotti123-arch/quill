import AppKit
import QuartzCore

/// One place for every duration and curve in the dashboard.
///
/// Scattered `NSAnimationContext.duration = 0.15` calls are how an interface
/// ends up with six slightly different speeds and feels assembled rather than
/// designed. These are the four speeds anything here is allowed to move at.
public enum DashboardMotion {
    /// Pointer-attached feedback. Anything slower stops feeling like a press.
    public static let press: TimeInterval = 0.055
    /// Hover, selection, colour changes.
    public static let quick: TimeInterval = 0.13
    /// Something moving or resizing.
    public static let standard: TimeInterval = 0.2
    /// A whole view arriving or leaving.
    public static let entrance: TimeInterval = 0.26

    public static var easeOut: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
    public static var easeInOut: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
    /// Overshoots slightly then settles. For a control that snaps to a position —
    /// a switch knob, a selected tab — where a linear ease reads as sluggish.
    public static var snap: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.34, 1.32, 0.5, 1)
    }

    /// True when the user has asked the system for less movement. Every animated
    /// thing in this app routes through here or through `DashboardTween`, so one
    /// accessibility switch turns all of it off rather than leaving stragglers.
    public static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Springs

    /// A spring described the way Apple describes one: how long it takes, and how
    /// much it overshoots.
    ///
    /// From WWDC23 "Animate with springs" and the HIG's Motion page. The whole
    /// argument for springs over Bezier curves here is interruption: a cubic
    /// curve started from rest and cannot be redirected, so clicking a second row
    /// while the first is still animating either snaps or restarts. A spring
    /// carries its current velocity into the new target, which is why every
    /// system control that a person can touch uses one.
    ///
    /// Bounce, per Apple's own table:
    ///   0     smooth, no overshoot — the recommended default and what this app uses
    ///   0.15  slightly brisk with a longer tail
    ///   0.30  visibly playful, for gesture ends
    ///   >0.4  avoid, reads as exaggerated
    ///
    /// Quill is an instrument you dictate into at speed. It gets 0.
    public struct Spring {
        public let duration: TimeInterval
        public let bounce: Double

        public init(duration: TimeInterval, bounce: Double = 0) {
            self.duration = duration
            self.bounce = bounce
        }

        /// SwiftUI's own mapping, so these numbers mean the same thing here as in
        /// a `.spring(duration:bounce:)` anywhere else: damping ratio is
        /// 1 - bounce, stiffness is (2π/duration)² and damping is 4π·ratio/duration
        /// for unit mass.
        public var animation: CASpringAnimation {
            let ratio = max(0.1, 1 - bounce)
            let a = CASpringAnimation(keyPath: nil)
            a.mass = 1
            a.stiffness = pow(2 * .pi / duration, 2)
            a.damping = 4 * .pi * ratio / duration
            a.duration = a.settlingDuration
            return a
        }
    }

    /// Hover, and anything else the pointer does constantly.
    ///
    /// The HIG is explicit that frequent interactions should not be given much
    /// motion — the movement stops reading as feedback and starts reading as lag.
    /// Under 200ms is the band for a light in-page change.
    public static let hoverSpring = Spring(duration: 0.16)
    /// Selecting a row, a tab, a section — something the user aimed at and can
    /// aim at again before it finishes.
    public static let selectSpring = Spring(duration: 0.32)
    /// A whole view arriving. Slower, because there is more to read.
    public static let viewSpring = Spring(duration: 0.42)

    /// Runs a block with a spring, honouring reduced motion.
    public static func spring(_ spring: Spring,
                              _ body: @escaping (NSAnimationContext) -> Void,
                              completion: (() -> Void)? = nil) {
        guard !isReduced else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = true
                body(context)
            } completionHandler: { completion?() }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            let s = spring.animation
            context.duration = s.settlingDuration
            context.timingFunction = nil
            context.allowsImplicitAnimation = true
            body(context)
        } completionHandler: {
            completion?()
        }
    }

    public static func run(_ duration: TimeInterval,
                           timing: CAMediaTimingFunction? = nil,
                           _ body: @escaping (NSAnimationContext) -> Void,
                           completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = isReduced ? 0 : duration
            context.timingFunction = timing ?? easeOut
            context.allowsImplicitAnimation = true
            body(context)
        } completionHandler: {
            completion?()
        }
    }
}

/// Turns an interaction state into a number that moves, for views that draw
/// themselves.
///
/// Most controls in this window paint in `draw(_:)` rather than in layers,
/// because a raised pill with a gradient, a contact shadow and a lit top edge is
/// four lines of Cocoa drawing and a small pile of nested layers. The cost is
/// that `isHovered = true; needsDisplay = true` is a hard cut — the interface
/// works perfectly and feels like a slideshow.
///
/// This is the missing half: hold a `DashboardTween` instead of a `Bool`, ask it
/// to travel, and draw with `tween.value` wherever the Bool used to be. It ticks
/// a display link only while it is actually moving, so an idle window costs
/// nothing.
public final class DashboardTween {

    public private(set) var value: CGFloat

    private var from: CGFloat
    private var to: CGFloat
    private var startedAt: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var link: CADisplayLink?
    private weak var view: NSView?

    public init(view: NSView, initial: CGFloat = 0) {
        self.view = view
        self.value = initial
        self.from = initial
        self.to = initial
    }

    deinit { link?.invalidate() }

    /// Eased travel from wherever it currently is. Interrupting mid-flight starts
    /// from the current value rather than snapping back, which is what makes a
    /// pointer swept across a list leave a trail of settling rows instead of a
    /// row of flickers.
    public func animate(to target: CGFloat, duration: TimeInterval = DashboardMotion.quick) {
        guard target != to || value != target else { return }
        guard !DashboardMotion.isReduced, let view, view.window != nil else {
            stop()
            value = target
            from = target
            to = target
            view?.needsDisplay = true
            return
        }
        from = value
        to = target
        self.duration = duration
        startedAt = CACurrentMediaTime()
        guard link == nil else { return }
        let created = view.displayLink(target: self, selector: #selector(tick))
        created.add(to: .current, forMode: .common)
        link = created
    }

    /// Jump, no travel. For a view being built or restyled, where an animation
    /// from zero would play on every rebuild.
    public func set(_ target: CGFloat) {
        stop()
        value = target
        from = target
        to = target
    }

    @objc private func tick() {
        let elapsed = CACurrentMediaTime() - startedAt
        let raw = duration <= 0 ? 1 : min(1, CGFloat(elapsed / duration))
        // Cubic ease-out. Matches the curve `DashboardMotion.easeOut` gives the
        // layer-backed controls, so a screen that mixes both does not have two
        // different senses of deceleration on it.
        let eased = 1 - pow(1 - raw, 3)
        value = from + (to - from) * eased
        view?.needsDisplay = true
        if raw >= 1 { stop() }
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }
}

public extension NSColor {
    /// Straight-line blend in the current colour space, for tweened drawing.
    /// `blended(withFraction:of:)` returns an optional and can fail across colour
    /// spaces, which in a draw call means a control that silently stops painting.
    func mixed(with other: NSColor, _ amount: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self
        let b = other.usingColorSpace(.sRGB) ?? other
        let t = max(0, min(1, amount))
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                       alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
    }

    /// The same colour at a fraction of its own opacity. Used to fade a hover
    /// fill in rather than switching it on.
    func faded(_ amount: CGFloat) -> NSColor {
        withAlphaComponent(alphaComponent * max(0, min(1, amount)))
    }
}

public extension NSRect {
    /// Linear interpolation between two frames, for a selection pill sliding
    /// between segments.
    func lerp(to other: NSRect, _ t: CGFloat) -> NSRect {
        let f = max(0, min(1, t))
        return NSRect(x: minX + (other.minX - minX) * f,
                      y: minY + (other.minY - minY) * f,
                      width: width + (other.width - width) * f,
                      height: height + (other.height - height) * f)
    }
}
