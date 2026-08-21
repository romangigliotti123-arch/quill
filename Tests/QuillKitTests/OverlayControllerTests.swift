import AppKit
import Testing
@testable import QuillKit

/// Roman: *"as I'm transcribing this whole prompt, I don't see the little
/// animation overlay at the bottom."* Everything else about those dictations was
/// healthy — the text arrived, the timings in history are ordinary — so the only
/// thing that failed was the HUD getting onto the screen.
///
/// These pin the part of that which is the controller's job: putting the panel
/// where it belongs, and taking it away again, without depending on an animation
/// frame that may never be delivered. The exit is driven by the view's display
/// link and AppKit pauses that link whenever the window stops being visible, so
/// "the frames stopped" is a real state and not a hypothetical one.
///
/// No runloop is spun on purpose. A test that does not deliver frames IS the
/// interrupted-exit case.
@Suite(.serialized)
struct OverlayControllerTests {

    @Test @MainActor func everyPresentationPlacesAndRaisesTheHUD() throws {
        let controller = OverlayController()
        controller.show(.listening(level: 0))
        let panel = try #require(controller.panelForTesting)
        defer { panel.orderOut(nil) }

        let home = panel.frame.origin
        #expect(panel.isVisible)

        // The dictation ends. The exit animation starts and then never gets
        // another frame — a Space switch across the fade-out does exactly this.
        controller.hide()
        #expect(panel.isVisible, "the exit never finished, so nothing ordered it out")

        // Something moved it, or something was ordered above it. Either way the
        // panel is no longer where a HUD should be.
        panel.setFrameOrigin(NSPoint(x: home.x + 400, y: home.y + 400))

        // Next dictation. This used to be skipped entirely, because the panel was
        // still `isVisible` and that was read as "already in place".
        controller.show(.listening(level: 0))
        #expect(panel.frame.origin == home)
    }

    /// The backstop that takes a stalled fade-out off the screen must not take a
    /// live one with it. This is the half of that code a test can actually reach:
    /// the timer is armed on every hide, so a dictation starting inside the grace
    /// has one ticking underneath it.
    @Test @MainActor func theExitBackstopDoesNotEatTheNextDictation() async throws {
        let controller = OverlayController()
        controller.show(.listening(level: 0))
        let panel = try #require(controller.panelForTesting)
        defer { panel.orderOut(nil) }

        controller.hide()
        controller.show(.listening(level: 0))
        // Past the grace armed by that hide.
        try await Task.sleep(for: .milliseconds(1_400))
        #expect(panel.isVisible, "the previous dictation's backstop hid the current one's HUD")
    }

    @Test @MainActor func anOrdinaryDismissalStillTakesTheHUDOffScreen() async throws {
        let controller = OverlayController()
        controller.show(.listening(level: 0))
        let panel = try #require(controller.panelForTesting)
        defer { panel.orderOut(nil) }

        controller.hide()
        try await Task.sleep(for: .milliseconds(1_400))
        #expect(!panel.isVisible)
    }

    /// The ordinary case must not regress into a hard cut: a `show` arriving
    /// while the previous pill is still fading out has to keep the same panel and
    /// the same position, not tear it down and rebuild it.
    @Test @MainActor func showDuringAnExitKeepsTheSamePanel() throws {
        let controller = OverlayController()
        controller.show(.listening(level: 0))
        let panel = try #require(controller.panelForTesting)
        defer { panel.orderOut(nil) }
        let home = panel.frame.origin

        controller.hide()
        controller.show(.transcribing)
        #expect(controller.panelForTesting === panel)
        #expect(panel.isVisible)
        #expect(panel.frame.origin == home)
    }
}
