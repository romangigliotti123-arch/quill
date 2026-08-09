import AppKit
import QuillKit

// Thin executable. Everything real lives in QuillKit so it can be tested
// without booting an NSApplication.

// Diagnostics path: launched as `open --env QUILL_DIAGNOSE=1 build/Quill.app`,
// so the checks run under the app's own TCC identity rather than the terminal's.
// This distinction is not pedantry — a binary run from a shell inherits the
// shell's Accessibility grant and will cheerfully report that everything works.
if ProcessInfo.processInfo.environment["QUILL_DIAGNOSE"] == "1" {
    Diagnostics.runAndExit()
}

// Cleanup probe: QUILL_CLEAN_TEXT="..." prints the cleaned form and exits, so
// the full pass chain can be checked against real recogniser output rather than
// against strings someone imagined it would produce.
if let raw = ProcessInfo.processInfo.environment["QUILL_CLEAN_TEXT"] {
    print(FastCleaner().cleanFast(raw))
    exit(0)
}

// Transcription harness: QUILL_TRANSCRIBE_FILE=/path/to.wav runs the real
// transcription path against a file and prints what it measured. Needs no
// microphone and no TCC grant, which is what makes "the engine works, and here
// is how fast" a checkable claim rather than an assertion.
if ProcessInfo.processInfo.environment["QUILL_TRANSCRIBE_FILE"] != nil {
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        await TranscriptionHarness.runIfRequested()
        done.signal()
    }
    // The harness hops to the main actor, so this thread has to keep the runloop
    // alive rather than block on the semaphore.
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

// Dashboard shots: QUILL_DASHBOARD_SHOTS=/dir renders every section to PNG at
// Flow's exact window size and exits. Same reasoning as the overlay renderer —
// a UI that can only be reviewed by launching the app is a UI nobody reviews,
// and this one is 1350x850 of surface area to get wrong.
if DashboardPreviewRenderer.runIfRequested() {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
