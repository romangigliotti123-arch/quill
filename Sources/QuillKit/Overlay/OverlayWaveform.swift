import AppKit

/// A scrolling record of what the microphone actually heard: the newest sample
/// enters at the right edge and every older one slides left until it fades out.
///
/// The alternative — bars that all wobble to the same sine and get *scaled* by
/// the level — is what most dictation HUDs ship, and it reads as decoration
/// within about two seconds because the shape never depends on what you said.
/// Here the silhouette is history, so a pause leaves a visible flat stretch.
final class OverlayWaveform: NSView {

    // Bar count and pitch are the whole legibility argument. Packed thin bars
    // are objectively more data and subjectively a barcode — at this size the
    // eye reads silhouette, not samples, and a silhouette needs air.
    private let barCount = 19
    private let barWidth: CGFloat = 3
    private let pitch: CGFloat = 7
    private let minBar: CGFloat = 3
    private let maxBar: CGFloat = 24
    /// ~16 columns a second, which keeps the scroll speed the same as a denser
    /// bar would give: syllables stay separable, the motion stays calm.
    private let sampleInterval: CGFloat = 1.0 / 16.0
    /// Newest bars carry the accent and fade to plain ink over this many
    /// columns, which is what makes the right edge legible as "live".
    private let accentRun = 4
    /// Columns over which the oldest end dissolves, so nothing pops out of
    /// existence at the left boundary.
    private let fadeRun: CGFloat = 7

    /// Index 0 is the newest column.
    private var samples: [CGFloat]
    private var bars: [CALayer] = []
    private var carry: CGFloat = 0
    private var envelope: CGFloat = 0
    private var idlePhase: CGFloat = 0
    private var barColors: [CGColor] = []

    var level: CGFloat = 0

    var intrinsicWidth: CGFloat { CGFloat(barCount - 1) * pitch + barWidth }

    override init(frame frameRect: NSRect) {
        samples = Array(repeating: 0, count: barCount)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        bars = (0..<barCount).map { _ in
            let bar = CALayer()
            bar.cornerRadius = barWidth / 2
            bar.anchorPoint = .zero
            layer?.addSublayer(bar)
            return bar
        }
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ palette: OverlayPalette) {
        // Blend once per appearance change rather than per bar per frame; this
        // would otherwise run for every bar at the display's refresh rate.
        barColors = (0..<barCount).map { index in
            let t = min(CGFloat(index) / CGFloat(accentRun), 1)
            let mixed = palette.accent.blended(withFraction: t, of: palette.wave) ?? palette.wave
            let fade = min(max((CGFloat(barCount) - CGFloat(index)) / fadeRun, 0), 1)
            return mixed.withAlphaComponent(mixed.alphaComponent * OverlayEasing.smoothstep(fade)).cgColor
        }
        redraw()
    }

    func advance(dt: CGFloat) {
        // Asymmetric envelope, borrowed from how a VU meter behaves: a plosive
        // has to register on the frame it happens, but the decay has to be slow
        // or every bar flickers between columns.
        let target = pow(min(max(level, 0), 1), 0.72)
        let rate: CGFloat = target > envelope ? 26 : 10
        envelope += (target - envelope) * min(1, rate * dt)

        idlePhase += dt

        // Silence should look quiet, not dead — a perfectly flat line reads as
        // "the mic is broken". The floor is small enough that it can never be
        // mistaken for speech.
        let floorLevel = 0.030 + 0.022 * (0.5 + 0.5 * sin(idlePhase * 2.1))
        let sample = max(envelope, floorLevel)

        samples[0] = sample
        carry += dt
        while carry >= sampleInterval {
            carry -= sampleInterval
            samples.removeLast()
            samples.insert(sample, at: 0)
        }

        redraw()
    }

    override func layout() {
        super.layout()
        redraw()
    }

    private func redraw() {
        guard !barColors.isEmpty else { return }
        let fraction = carry / sampleInterval
        let height = bounds.height
        let rightEdge = bounds.width - barWidth

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            // The newest column grows in as it slides, so it emerges from the
            // edge instead of appearing at full height a pixel inside it.
            let emergence = index == 0 ? OverlayEasing.smoothstep(fraction) : 1
            let value = samples[index] * emergence
            let h = max(minBar, minBar + (maxBar - minBar) * value)
            let x = rightEdge - (CGFloat(index) + fraction) * pitch
            bar.frame = CGRect(x: x, y: (height - h) / 2, width: barWidth, height: h)
            bar.backgroundColor = barColors[index]
        }
        CATransaction.commit()
    }
}
