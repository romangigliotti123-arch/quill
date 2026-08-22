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

    /// One check, in a shape a screen can draw and a text report can print.
    ///
    /// The Help section and this file's report run the *same* checks through
    /// `run()`. Two implementations of "is the event tap installable" would drift
    /// within a week, and the moment they disagree neither can be trusted — which
    /// defeats the point of having a diagnostic at all.
    public struct Check: Sendable, Equatable {
        public enum Status: Sendable, Equatable { case pass, warn, fail }
        public let title: String
        public let status: Status
        /// What is true right now.
        public let detail: String
        /// What to do about it. Nil when there is nothing to do.
        public let remedy: String?
    }

    /// Runs every check and returns the findings. Cheap enough to call when a
    /// screen appears; the event-tap probe is the only slow part and it is a
    /// single syscall.
    public static func run() -> [Check] {
        var checks: [Check] = []

        for permission in Permission.allCases {
            switch Permissions.state(of: permission) {
            case .granted:
                checks.append(Check(title: permission.rawValue, status: .pass,
                                    detail: "Granted.", remedy: nil))
            case .denied:
                checks.append(Check(title: permission.rawValue, status: .fail,
                                    detail: "Denied — Quill needs this \(permission.whyQuillNeedsIt).",
                                    remedy: permission.settingsPath))
            case .notDetermined:
                checks.append(Check(title: permission.rawValue, status: .warn,
                                    detail: "Not asked for yet. Quill needs this \(permission.whyQuillNeedsIt).",
                                    remedy: permission.settingsPath))
            }
        }

        checks.append(Permissions.secureInputEnabled
            ? Check(title: "Secure Input", status: .fail,
                    detail: "On. While it is, macOS refuses every event tap — the dictation key cannot fire and there is no permission that fixes it.",
                    remedy: "Quit whatever turned it on: a terminal with Secure Keyboard Entry, or a password manager that left the flag set.")
            : Check(title: "Secure Input", status: .pass,
                    detail: "Off, so event taps are allowed.", remedy: nil))

        checks.append(canCreateTap()
            ? Check(title: "Event tap", status: .pass,
                    detail: "Installs. This is the real test — the one that fails silently.", remedy: nil)
            : Check(title: "Event tap", status: .fail,
                    detail: "The system refused it. No error is raised for this; the key simply never fires.",
                    remedy: "Remove Quill from \(Permission.accessibility.settingsPath) and add it back — the grant is tied to the code signature."))

        let device = AudioDeviceInfo.activeInputName()
        let loopback = device.map(AudioDeviceInfo.isLoopback) ?? false
        // A loopback selected as the input used to report "OK". It carries only
        // what other apps play into it, so every dictation through one records
        // silence — a green tick on the single check that would have explained
        // the failure.
        checks.append(Check(
            title: "Input device",
            status: device == nil ? .warn : (loopback ? .warn : .pass),
            detail: device.map {
                loopback
                    ? "\($0) is a loopback device. It carries what other apps play, not your voice, so dictation will record silence."
                    : "Listening to \($0)."
            } ?? "CoreAudio will not name an input device.",
            remedy: device == nil
                ? "Check a microphone is connected and selected in Settings."
                : (loopback ? "Pick a real microphone in Settings, or change the system input in Sound." : nil)))

        return checks
    }

    /// The one check that cannot be inferred from a permission API: whether the
    /// system will actually hand over a tap right now.
    private static func canCreateTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
        else { return false }
        CFMachPortInvalidate(tap)
        return true
    }

    /// Whether this process was started by `open` rather than run from a shell.
    ///
    /// It used to test `QUILL_DIAGNOSE == "1"` — which is the flag that asks for
    /// this report in the first place, so it was always set, and the line always
    /// read "open --env (correct)" including on the exact run it exists to catch.
    /// The report that only ever answers one way is worse than no report: it
    /// certifies the run whose numbers are the ones that lie.
    ///
    /// `open` hands the app to launchd, which is pid 1 and stays the parent. A
    /// shell stays the parent of what it runs. That is the difference, and it is
    /// the difference that decides whose Accessibility grant is being measured.
    static var launchedViaOpen: Bool { getppid() == 1 }

    static var launchDescription: String {
        if launchedViaOpen { return "open (correct — this report is about Quill)" }
        let parent = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        let inherited = parent == Bundle.main.bundleIdentifier ? "" : " — inherited from pid \(getppid())"
        return "run directly (WRONG\(inherited))"
    }

    public static func runAndExit() -> Never {
        var out: [String] = []
        func say(_ s: String) { out.append(s) }

        say("Quill diagnostics — \(Date().formatted(date: .abbreviated, time: .standard))")
        say(String(repeating: "─", count: 60))

        let bundle = Bundle.main
        say("bundle id      : \(bundle.bundleIdentifier ?? "nil")")
        say("bundle path    : \(bundle.bundlePath)")
        say("launched via   : \(launchDescription)")
        if !launchedViaOpen {
            say("")
            say("⚠️  EVERYTHING BELOW THIS LINE IS UNTRUSTWORTHY.")
            say("    This process was not started by `open`, so it inherited the")
            say("    Accessibility grant of whatever started it — usually a terminal,")
            say("    which has one. The permission and tap results below will say")
            say("    granted and created whether or not Quill itself can do either.")
            say("    Re-run it the only way that measures Quill:")
            say("")
            say("      open -a \(bundle.bundlePath) --env QUILL_DIAGNOSE=1")
        }
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
