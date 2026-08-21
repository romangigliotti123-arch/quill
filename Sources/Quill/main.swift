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

// QUILL_CLEAN_FILE=/path runs the deterministic cleanup over every line and
// prints the result, one line in, one line out.
//
// This is what makes the vocabulary work measurable. Word error rate is scored
// on raw recogniser output, so the corrector's effect is invisible to the rig —
// and the only honest way to tune a repair pass is to run it over the transcripts
// it will actually see and count what it fixed against what it broke. Fifty real
// transcripts, in under a second, instead of a 25-minute run of the whole rig.
if let path = ProcessInfo.processInfo.environment["QUILL_CLEAN_FILE"] {
    let cleaner = FastCleaner()
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        print(cleaner.cleanFast(String(line)))
    }
    exit(0)
}

// Transcription harness: QUILL_TRANSCRIBE_FILE=/path/to.wav runs the real
// transcription path against a file and prints what it measured. Needs no
// microphone and no TCC grant, which is what makes "the engine works, and here
// is how fast" a checkable claim rather than an assertion.
if ProcessInfo.processInfo.environment["QUILL_TRANSCRIBE_DIR"] != nil {
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        _ = await TranscriptionHarness.runDirectoryIfRequested()
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

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

// QUILL_DICTATION_SHOTS=/dir renders the Dictation section's four states against
// the fixture set. This entry point existed, was documented, and was never
// called from here — so asking for it launched the app and rendered nothing,
// silently, which is how the four states hardest to reach by hand went unlooked
// at for the life of the screen.
if DictationSectionShots.runIfRequested() {
    exit(0)
}

// QUILL_LAYOUT_PROBE=1 prints the numbers a render can only hint at — where each
// section puts its title, how far its content reaches, and how much of the panel
// nothing ever touches. The title alignment was fixed once from screenshots and
// drifted straight back on the sections nobody rendered; this is what makes that
// checkable in one second rather than by eye.
if ProcessInfo.processInfo.environment["QUILL_LAYOUT_PROBE"] != nil {
    let probeApp = NSApplication.shared
    probeApp.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { _ = DashboardLayoutProbe.runIfRequested() }
    exit(0)
}

// QUILL_RESIZE_SWEEP=/dir drives the REAL window through a range of sizes and
// captures each one. The renderer above builds a fresh tree at a fixed size, so
// it can only ever say a layout is right at that size — a control left lit by a
// stale tracking area, or a frame that survives a shrink, needs the window to
// actually change size. This needs an NSApplication, hence the ordering.
if ProcessInfo.processInfo.environment["QUILL_RESIZE_SWEEP"] != nil {
    let sweepApp = NSApplication.shared
    sweepApp.setActivationPolicy(.accessory)
    sweepApp.finishLaunching()
    MainActor.assumeIsolated { _ = DashboardResizeSweep.runIfRequested() }
    exit(0)
}

// QUILL_OVERLAY_SHOTS=/dir renders every overlay state to PNG. The HUD is the
// surface a user sees most and the one hardest to inspect while it is on screen,
// which is exactly why it needs to be reviewable offline.
if let dir = ProcessInfo.processInfo.environment["QUILL_OVERLAY_SHOTS"] {
    let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    if let written = try? OverlayPreviewRenderer.renderAll(into: url) {
        written.forEach { print($0.lastPathComponent) }
    }
    exit(0)
}

// One Quill at a time.
//
// Two copies can exist — the build output and the installed one — and macOS will
// happily run both, each with its own event tap fighting for the same hotkey and
// its own writer on the same history file. Bundle identifier rather than path is
// the right test: it is still the same app wherever it was launched from.
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let existing = others.first {
        // Hand over rather than dying quietly: whoever double-clicked expects a
        // window, and a launcher that appears to do nothing reads as broken.
        existing.activate(options: [])
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.romangigliotti.quill.showWindow"), object: nil, deliverImmediately: true)
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
