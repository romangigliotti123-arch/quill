import AppKit
import QuartzCore

/// `QUILL_OVERLAY_STRESS=<seconds>` measures the real HUD under the real load
/// it runs against, and answers "does it hold 30fps" with numbers instead of a
/// guess.
///
/// # Why this exists rather than reading the code and trusting it
///
/// The waveform is already CALayer frames with implicit actions disabled, one
/// `CADisplayLink` drives everything in the HUD, and `sameContent` already
/// refuses to rebuild the content view on a level update. All of that is
/// correct by inspection — and inspection cannot see contention. The level
/// callback arrives from a real audio tap at `bufferSize: 1024` — roughly 43
/// times a second at 44.1kHz — and every one of those hops to the main queue
/// with `DispatchQueue.main.async`, landing on the exact run loop the display
/// link's own callback is scheduled on. Whether 43 extra main-thread hops a
/// second cost the display link a frame is an empirical question, not one the
/// source answers by itself.
///
/// # What it does
///
/// Builds the real `OverlayController` — real panel, real `CADisplayLink`,
/// real `NSVisualEffectView` — and shows `.listening`. A background queue then
/// posts level updates on the same cadence and through the same
/// `DispatchQueue.main.async` hop the real audio tap uses, for the requested
/// duration, while `OverlayHostView` reports the REAL gap between display-link
/// callbacks — before the physics clamp, which is what would hide a stall
/// rather than reveal one.
///
/// Not measured: real speech, real transcription, real text insertion running
/// at the same time. This isolates the HUD's own contribution, which is the
/// part a change here can actually move.
public enum OverlayFrameStressTest {

    public struct Result: Sendable {
        public let frames: Int
        public let meanFPS: Double
        public let p50Ms: Double
        public let p90Ms: Double
        public let p99Ms: Double
        public let maxMs: Double
        public let framesBelow30FPS: Int
    }

    @MainActor
    public static func run(seconds: Double) -> Result {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let overlay = OverlayController()
        var gaps: [CFTimeInterval] = []
        gaps.reserveCapacity(Int(seconds * 130)) // headroom for a 120Hz panel

        overlay.show(.listening(level: 0))
        overlay.frameObserverForTesting = { gap in gaps.append(gap) }

        // The real cadence: 1024 samples at 44.1kHz is ~23.2ms between audio
        // buffers, and the real callback arrives on a background queue and hops
        // to main exactly this way — see `AudioCapture.installTap` and
        // `DictationCoordinator`'s `onLevel` closure.
        let bufferInterval = 1024.0 / 44_100.0
        let audioQueue = DispatchQueue(label: "com.romangigliotti.quill.overlaystress.audio")
        var speakingPhase = 0.0
        let stop = DispatchWorkItem {}
        func scheduleNext() {
            guard !stop.isCancelled else { return }
            audioQueue.asyncAfter(deadline: .now() + bufferInterval) {
                guard !stop.isCancelled else { return }
                speakingPhase += bufferInterval
                // A plausible speaking envelope, not silence — silence would
                // under-count how often `present` actually reassigns `level`
                // and re-triggers `advance`.
                let level = Float(0.15 + 0.55 * abs(sin(speakingPhase * 2.4)))
                DispatchQueue.main.async { overlay.show(.listening(level: level)) }
                scheduleNext()
            }
        }
        scheduleNext()

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        stop.cancel()
        overlay.frameObserverForTesting = nil

        let ms = gaps.map { $0 * 1000 }.sorted()
        let frameTarget = 1000.0 / 30.0
        return Result(
            frames: ms.count,
            meanFPS: ms.isEmpty ? 0 : 1000.0 / (ms.reduce(0, +) / Double(ms.count)),
            p50Ms: percentile(ms, 0.50),
            p90Ms: percentile(ms, 0.90),
            p99Ms: percentile(ms, 0.99),
            maxMs: ms.last ?? 0,
            framesBelow30FPS: ms.filter { $0 > frameTarget }.count
        )
    }

    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((q * Double(sorted.count)).rounded(.down)))
        return sorted[index]
    }

    @MainActor
    @discardableResult
    public static func runIfRequested() -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["QUILL_OVERLAY_STRESS"],
              let seconds = Double(raw), seconds > 0
        else { return false }

        let result = run(seconds: seconds)
        // eslint has no opinion here, but the shape matches every other probe
        // in this app: readable on a terminal, greppable in CI.
        print("[quill/overlay-stress] \(result.frames) frames over \(seconds)s")
        print("  mean: \(String(format: "%.1f", result.meanFPS)) fps")
        print("  p50:  \(String(format: "%.2f", result.p50Ms)) ms")
        print("  p90:  \(String(format: "%.2f", result.p90Ms)) ms")
        print("  p99:  \(String(format: "%.2f", result.p99Ms)) ms")
        print("  max:  \(String(format: "%.2f", result.maxMs)) ms")
        print("  frames slower than 30fps (>33.33ms): \(result.framesBelow30FPS)")
        return true
    }
}
