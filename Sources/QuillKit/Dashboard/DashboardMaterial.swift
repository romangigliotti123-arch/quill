import AppKit

/// A real macOS material, with something solid behind it.
///
/// Quill's window was drawn from scratch — every surface an opaque colour, a
/// floating content panel with a gap and a large radius, its own shadow. It is
/// competently done and it reads as a web dashboard, because those are web
/// devices. A Mac app of this kind is a translucent sidebar and a content area
/// running edge to edge under a transparent titlebar, and the translucency is
/// not decoration: it is what makes the window sit *in* the desktop rather than
/// on top of a screenshot of one.
///
/// The fallback colour is the load-bearing part of this file.
/// `NSVisualEffectView` draws nothing at all through `CALayer.render(in:)`,
/// which is how `DashboardPreviewRenderer` takes every screenshot this project
/// reviews designs from. Swapping drawn surfaces for materials without this
/// would have made every future render come back showing the desktop through a
/// hole — the same failure as the blank-screenshot harness in the notes, arrived
/// at from the opposite direction.
///
/// So the material sits on top of an opaque layer of the colour it approximates.
/// On screen the material wins and you see the desktop through it; offscreen the
/// material contributes nothing and the fallback is what lands in the PNG. Both
/// are honest, and neither can silently become nothing.
public final class DashboardMaterialView: NSView {

    private let effect = NSVisualEffectView()
    private var fallback: NSColor

    public init(material: NSVisualEffectView.Material,
                blending: NSVisualEffectView.BlendingMode,
                fallback: NSColor) {
        self.fallback = fallback
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fallback.cgColor
        effect.material = material
        effect.blendingMode = blending
        // `.followsWindowActiveState` is the default and it dims the sidebar the
        // moment focus moves to another app — correct for a document window,
        // wrong for a HUD-ish utility whose sidebar is the only navigation.
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    public func restyle(fallback: NSColor) {
        self.fallback = fallback
        layer?.backgroundColor = fallback.cgColor
    }

    public override func layout() {
        super.layout()
        effect.frame = bounds
    }

    /// Rounds only the corners a given edge needs, so the content area can meet
    /// the sidebar square and still round away from the window's own corners.
    public func round(corners: CACornerMask, radius: CGFloat) {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = corners
        layer?.masksToBounds = true
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.maskedCorners = corners
        effect.layer?.masksToBounds = true
    }
}
