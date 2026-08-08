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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
