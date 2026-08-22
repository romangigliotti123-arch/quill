import Foundation
import Testing
@testable import QuillKit

@Test func everyPermissionExplainsItself() {
    for p in Permission.allCases {
        #expect(!p.settingsPath.isEmpty)
        #expect(!p.whyQuillNeedsIt.isEmpty)
    }
}

// MARK: - A "Grant" button that does something

/// macOS prompts for a permission exactly once. After that `requestAccess` and
/// `IOHIDRequestAccess` return the stored answer immediately and put nothing on
/// screen — so the Help screen's "Grant" button and the menu's permission item
/// did nothing at all, for precisely the people who needed them. A granted
/// permission does not show a button.
@Test func everyPermissionHasASettingsPaneToFallBackTo() {
    // The pane id changed with System Settings, and a URL that does not resolve
    // opens nothing and reports nothing — which would leave the button as dead as
    // it was. Every candidate must at least be a well-formed URL.
    for permission in Permission.allCases {
        let anchor: String
        switch permission {
        case .microphone:      anchor = "Privacy_Microphone"
        case .accessibility:   anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        for string in [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:",
        ] {
            #expect(URL(string: string) != nil, "malformed settings URL: \(string)")
        }
        // And the app names a place to go for each one, which the Help copy uses.
        #expect(!permission.settingsPath.isEmpty)
    }
}
