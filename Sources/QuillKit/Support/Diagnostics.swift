import AppKit
import ApplicationServices
import Foundation

/// Runs under the app's own TCC identity via
///   open --env QUILL_DIAGNOSE=1 build/Quill.app
/// and writes its findings to a file, because a menu-bar app has no stdout you
/// can read.
///
/// The reason this exists at all: the same signed bundle reports
/// AXIsProcessTrusted() == true and creates an event tap successfully when its
/// executable is run from a shell (inheriting the shell's grants), while
/// reporting false and returning a nil tap when launched with `open`. Only the
/// second one tells you the truth about what users will experience.
public enum Diagnostics {

    public static let reportPath = NSString(string: "~/Documents/Work/Projects/quill/build/diagnostics.txt")
        .expandingTildeInPath

    public static func runAndExit() -> Never {
        var out: [String] = []
        func say(_ s: String) { out.append(s) }

        say("Quill diagnostics — \(Date().formatted(date: .abbreviated, time: .standard))")
        say(String(repeating: "─", count: 60))

        let bundle = Bundle.main
        say("bundle id      : \(bundle.bundleIdentifier ?? "nil")")
        say("bundle path    : \(bundle.bundlePath)")
        say("launched via   : \(ProcessInfo.processInfo.environment["QUILL_DIAGNOSE"] == "1" ? "open --env (correct)" : "unknown")")
        say("")

        say("PERMISSIONS")
        for p in Permission.allCases {
            let mark: String
            switch Permissions.state(of: p) {
            case .granted:       mark = "✅ granted"
            case .denied:        mark = "❌ denied"
            case .notDetermined: mark = "◻️  not determined"
            }
            say("  \(p.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)) \(mark)")
            if Permissions.state(of: p) != .granted {
                say("      → \(p.settingsPath)")
                say("      → needed \(p.whyQuillNeedsIt)")
            }
        }
        say("")

        say("SECURE INPUT")
        if Permissions.secureInputEnabled {
            say("  ⚠️  ENABLED — no event tap can be installed while this is on.")
            say("      Usual culprits: a terminal with Secure Keyboard Entry on, or a")
            say("      password manager that leaked the flag. The hotkey will look")
            say("      broken with no error until this is off.")
        } else {
            say("  ✅ off — event taps can be installed")
        }
        say("")

        say("EVENT TAP (the real test — does it actually create?)")
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        if let tap {
            say("  ✅ tap created")
            CFMachPortInvalidate(tap)
        } else {
            say("  ❌ tapCreate returned nil.")
            say("      This is the silent failure: no error, no exception, hotkey just")
            say("      never fires. Cause is almost always Accessibility not truly")
            say("      granted for THIS signed bundle, or Secure Input above.")
        }
        say("")

        say("CODE SIGNATURE")
        say("  (compare 'designated =>' across builds — if it changes, TCC grants drop)")

        let text = out.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(
            atPath: (reportPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? text.write(toFile: reportPath, atomically: true, encoding: .utf8)
        exit(0)
    }
}
