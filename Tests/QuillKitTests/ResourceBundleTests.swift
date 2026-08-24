import Foundation
import Testing
@testable import QuillKit

/// v1.0.0 shipped an app that killed itself the moment anyone tried to sign in.
///
/// `Bundle.module` is generated code, and its failure path is not `nil` — it is
/// `fatalError`. Which is survivable only if it can find the bundle, and the
/// accessor SwiftPM generated for the release build looks in exactly two
/// places: `Bundle.main.bundleURL/Quill_QuillKit.bundle` — the .app root, NOT
/// `Contents/Resources` where `Scripts/build.sh` puts it — and the absolute
/// path of the build directory on whichever machine compiled it.
///
/// So the shipped app looked for its Firebase config at
/// `/Users/runner/Library/.../release/Quill_QuillKit.bundle`, a path that
/// exists on a GitHub Actions runner and nowhere else, and trapped. It could
/// only ever have worked on the machine that built it — which is precisely why
/// it survived testing.
///
/// These tests are about the lookup that replaced it: it has to find the file
/// in either shape, and it has to answer `nil` rather than trap when there is
/// no file at all.
@Suite struct ResourceBundleTests {

    private func makePlist(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let dict: NSDictionary = ["API_KEY": "test-key", "PROJECT_ID": "test-project"]
        try dict.write(to: url)
    }

    @Test func findsThePlistInAFlatBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quill-flat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Quill_QuillKit.bundle")
        try makePlist(at: bundle.appendingPathComponent("GoogleService-Info.plist"))

        #expect(AccountStore.plistURL(searchingResourcesAt: root) != nil)
    }

    @Test func findsThePlistInAStructuredBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quill-structured-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Quill_QuillKit.bundle")
        try makePlist(at: bundle.appendingPathComponent("Contents/Resources/GoogleService-Info.plist"))

        #expect(AccountStore.plistURL(searchingResourcesAt: root) != nil)
    }

    @Test func answersNilRatherThanTrappingWhenThereIsNoPlistAnywhere() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quill-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Something_Else.bundle"), withIntermediateDirectories: true)

        // The whole point. Reaching Bundle.module here would end the process.
        #expect(AccountStore.plistURL(searchingResourcesAt: root) == nil)
    }

    /// The app that ships has to actually carry the file, in a shape the lookup
    /// above can read. This is the assertion that would have caught v1.0.0.
    @Test func theBuiltAppCarriesALoadableResourceBundle() throws {
        let app = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Quill/build/Quill.app")
        try #require(FileManager.default.fileExists(atPath: app.path),
                     "no assembled app to check — run Scripts/build.sh first")
        let resources = app.appendingPathComponent("Contents/Resources")
        #expect(AccountStore.plistURL(searchingResourcesAt: resources) != nil,
                "the assembled app has no readable GoogleService-Info.plist, so signing in fails")
    }
}
