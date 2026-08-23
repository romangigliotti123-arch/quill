// swift-tools-version: 6.0
import PackageDescription

// Quill — an offline, on-device dictation app for macOS.
//
// Shape: a fat library (QuillKit) plus a thin executable, so every behaviour is
// reachable from tests. The executable does nothing but boot NSApplication.
let package = Package(
    name: "Quill",
    platforms: [
        // SpeechAnalyzer/SpeechTranscriber are macOS 26+. The genuinely nice
        // conveniences (CaptureInputSequenceProvider, AnalyzerInputConverter)
        // are 27+ and sit behind availability checks rather than raising the
        // floor for everyone.
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Quill", targets: ["Quill"]),
        .executable(name: "QuillMCP", targets: ["QuillMCP"]),
        .library(name: "QuillKit", targets: ["QuillKit"]),
    ],
    targets: [
        .target(
            name: "QuillKit",
            path: "Sources/QuillKit",
            resources: [.copy("Resources/GoogleService-Info.plist")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Quill",
            dependencies: ["QuillKit"],
            path: "Sources/Quill",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Temporary: measures what live typing costs the main thread over one
        // long dictation. Not shipped; delete once the finding is settled.
        .executableTarget(
            name: "LiveTypeProbe",
            dependencies: ["QuillKit"],
            path: "Sources/LiveTypeProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Claude Desktop's MCP connection to Quill — a real stdio JSON-RPC
        // server, not a description of one. See its own file for the shape
        // and the boundary (voice/style data only, never email).
        .executableTarget(
            name: "QuillMCP",
            dependencies: ["QuillKit"],
            path: "Sources/QuillMCP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QuillKitTests",
            dependencies: ["QuillKit"],
            path: "Tests/QuillKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
