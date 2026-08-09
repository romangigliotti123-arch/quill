import AppKit

// Every number the HUD draws with, in one place. Scattering them across the
// view files is how a design drifts: one padding gets nudged during a fix and
// the optical rhythm quietly dies.

enum OverlayMetrics {
    /// The panel never resizes. A window that grows mid-morph flashes the
    /// desktop through its corners for a frame and gives the compositor a
    /// reason to drop the animation; the pill morphs *inside* this instead.
    static let panelSize = NSSize(width: 640, height: 156)

    static let pillHeight: CGFloat = 44
    static let pillRadius: CGFloat = 22
    static let minPillWidth: CGFloat = 148
    static let maxPillWidth: CGFloat = 452

    /// Pill baseline above the screen's usable area. High enough to clear a
    /// magnified Dock, low enough to stay out of the document you're dictating
    /// into.
    static let bottomGap: CGFloat = 72
}

/// Colours resolved eagerly rather than through dynamic `NSColor`s, because
/// almost everything here is a `CGColor` on a `CALayer` and layers do not
/// re-resolve on an appearance change — they keep the colour they were handed.
/// Rebuilding the palette on `viewDidChangeEffectiveAppearance` is the only way
/// the HUD actually follows the system.
struct OverlayPalette {
    let isDark: Bool

    /// Stands in for `NSVisualEffectView` in an offscreen render, where there
    /// is no backdrop to blur.
    let material: CGColor
    /// What is used when the effect view *is* live: a floor, not a background.
    /// The two cannot be the same value — stacking a stand-in on top of the real
    /// blur turns the glass opaque, which is the exact failure the material was
    /// chosen to avoid.
    let materialFloor: CGColor
    let tintTop: CGColor
    let tintMid: CGColor
    let tintBottom: CGColor
    let sheen: CGColor
    let hairline: CGColor
    let topEdge: CGColor

    let primary: NSColor
    let secondary: NSColor
    let wave: NSColor
    let accent: NSColor
    let warn: NSColor

    let shadow: CGColor
    let shadowNearOpacity: Float
    let shadowFarOpacity: Float

    static func resolve(_ appearance: NSAppearance?) -> OverlayPalette {
        let dark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? .dark : .light
    }

    static let dark = OverlayPalette(
        isDark: true,
        material: srgb(0.060, 0.065, 0.080, 0.58).cgColor,
        materialFloor: srgb(0.045, 0.048, 0.058, 0.20).cgColor,
        tintTop: srgb(1, 1, 1, 0.17).cgColor,
        tintMid: srgb(1, 1, 1, 0.02).cgColor,
        tintBottom: srgb(0, 0, 0, 0.14).cgColor,
        sheen: srgb(1, 1, 1, 0.075).cgColor,
        hairline: srgb(1, 1, 1, 0.09).cgColor,
        topEdge: srgb(1, 1, 1, 0.58).cgColor,
        primary: srgb(1, 1, 1, 0.95),
        secondary: srgb(1, 1, 1, 0.50),
        wave: srgb(1, 1, 1, 0.78),
        accent: srgb(0.44, 0.70, 0.66, 1),   // #6FB3A8 — matches DashboardStyle.dark
        warn: srgb(1.00, 0.76, 0.42, 1),
        shadow: srgb(0, 0, 0, 1).cgColor,
        shadowNearOpacity: 0.34,
        shadowFarOpacity: 0.46
    )

    static let light = OverlayPalette(
        isDark: false,
        material: srgb(0.965, 0.968, 0.976, 0.62).cgColor,
        materialFloor: srgb(0.98, 0.98, 0.99, 0.16).cgColor,
        tintTop: srgb(1, 1, 1, 0.72).cgColor,
        tintMid: srgb(1, 1, 1, 0.22).cgColor,
        tintBottom: srgb(0.30, 0.33, 0.40, 0.09).cgColor,
        sheen: srgb(1, 1, 1, 0.34).cgColor,
        hairline: srgb(0, 0, 0, 0.10).cgColor,
        topEdge: srgb(1, 1, 1, 0.95).cgColor,
        primary: srgb(0.07, 0.07, 0.08, 0.94),
        secondary: srgb(0.07, 0.07, 0.08, 0.46),
        wave: srgb(0.10, 0.10, 0.12, 0.66),
        accent: srgb(0.23, 0.43, 0.43, 1),   // #3B6D6E — matches DashboardStyle.light
        warn: srgb(0.72, 0.42, 0.03, 1),
        shadow: srgb(0, 0, 0, 1).cgColor,
        shadowNearOpacity: 0.14,
        shadowFarOpacity: 0.20
    )

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

enum OverlayType {
    static func label(_ size: CGFloat, _ weight: NSFont.Weight, monospacedDigits: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        return field
    }

    /// Ask the control, never `NSString.size(withAttributes:)`. The cell adds
    /// its own horizontal inset and the system's Bold Text / Increase Contrast
    /// settings change the face that actually gets drawn — measuring the string
    /// by hand under-reports on both counts, and the pill silently truncates.
    static func width(of field: NSTextField) -> CGFloat {
        ceil(field.fittingSize.width)
    }

    static func height(of field: NSTextField) -> CGFloat {
        ceil(field.fittingSize.height)
    }
}

/// Semi-implicit Euler on a damped spring. Used instead of `NSAnimationContext`
/// because every animation here shares one display link — a single integrator
/// keeps width, entry and content crossfade phase-locked to the same frame,
/// which is what stops a morph from looking like three separate things moving.
struct OverlaySpring {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    var stiffness: CGFloat
    var damping: CGFloat

    var isSettled: Bool { abs(value - target) < 0.01 && abs(velocity) < 0.05 }

    mutating func snap(to newValue: CGFloat) {
        value = newValue
        target = newValue
        velocity = 0
    }

    mutating func step(_ dt: CGFloat, reduceMotion: Bool) {
        if reduceMotion {
            value = target
            velocity = 0
            return
        }
        // Sub-stepping at 120 Hz keeps a stiff spring stable when the display
        // link stalls (window drag, app switch) and hands us a fat delta.
        let steps = max(1, Int((dt * 120).rounded(.up)))
        let h = dt / CGFloat(steps)
        for _ in 0..<steps {
            let acceleration = -stiffness * (value - target) - damping * velocity
            velocity += acceleration * h
            value += velocity * h
        }
    }
}

enum OverlayEasing {
    static func outCubic(_ t: CGFloat) -> CGFloat {
        let c = min(max(t, 0), 1)
        return 1 - pow(1 - c, 3)
    }

    static func smoothstep(_ t: CGFloat) -> CGFloat {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }
}
