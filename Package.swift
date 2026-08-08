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
        .library(name: "QuillKit", targets: ["QuillKit"]),
    ],
    targets: [
        .target(
            name: "QuillKit",
            path: "Sources/QuillKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Quill",
            dependencies: ["QuillKit"],
            path: "Sources/Quill",
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
