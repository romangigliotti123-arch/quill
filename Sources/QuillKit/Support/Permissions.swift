import ApplicationServices
import AVFoundation
// IsSecureEventInputEnabled() is still Carbon-only in the macOS 27 SDK — there
// is no Swift-native replacement.
import Carbon.HIToolbox
import Foundation
import IOKit.hid

/// The four grants Quill needs, and honest answers about each.
///
/// None of these can be granted programmatically. What this type does is tell
/// the truth about the current state so the app can explain itself instead of
/// silently doing nothing — which is how every one of these failures presents.
public enum Permission: String, CaseIterable, Sendable {
    case microphone      = "Microphone"
    case accessibility   = "Accessibility"
    case inputMonitoring = "Input Monitoring"

    /// Where the user has to go to grant it, verbatim, so error messages can
    /// say something better than "permission denied".
    public var settingsPath: String {
        switch self {
        case .microphone:      return "System Settings ▸ Privacy & Security ▸ Microphone"
        case .accessibility:   return "System Settings ▸ Privacy & Security ▸ Accessibility"
        case .inputMonitoring: return "System Settings ▸ Privacy & Security ▸ Input Monitoring"
        }
    }

    public var whyQuillNeedsIt: String {
        switch self {
        case .microphone:
            return "to hear you while the dictation key is held"
        case .accessibility:
            return "to install the event tap that detects the hotkey, and to paste text into the focused app"
        case .inputMonitoring:
            return "some macOS builds require this in addition to Accessibility before an event tap will start"
        }
    }
}

public enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
}

public enum Permissions {

    public static func state(of permission: Permission) -> PermissionState {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:    return .granted
            case .notDetermined: return .notDetermined
            default:             return .denied
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeUnknown: return .notDetermined
            default:                      return .denied
            }
        }
    }

    /// Prompts where prompting is possible. Accessibility gets the system's own
    /// "Open System Settings" alert; Input Monitoring is only requested when
    /// Accessibility is already granted, because asking for both at once
    /// produces two stacked dialogs and users deny the second one.
    public static func request(_ permission: Permission) {
        switch permission {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .inputMonitoring:
            guard state(of: .accessibility) == .granted else { return }
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    public static var allGranted: Bool {
        Permission.allCases.allSatisfy { state(of: $0) == .granted }
    }

    public static var missing: [Permission] {
        Permission.allCases.filter { state(of: $0) != .granted }
    }

    /// Secure Input: when any app has Secure Keyboard Entry on (Ghostty has a
    /// setting for it; 1Password has been known to leak the flag), NO event tap
    /// can be installed at all. There is no permission to grant and no error
    /// returned — the hotkey simply never fires. Detecting it is the difference
    /// between a five-minute fix and an afternoon lost to a phantom TCC bug.
    public static var secureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}
