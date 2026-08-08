import Testing
@testable import QuillKit

@Test func everyPermissionExplainsItself() {
    for p in Permission.allCases {
        #expect(!p.settingsPath.isEmpty)
        #expect(!p.whyQuillNeedsIt.isEmpty)
    }
}
