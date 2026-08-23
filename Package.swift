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
    dependencies: [
        // The one external dependency in an otherwise dependency-free app —
        // see the account section in AccountStore.swift for why this is
        // opt-in rather than load-bearing for anything the app does without
        // it. Pinned to a major version rather than exact, same as every
        // other SPM dependency anyone ships.
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "11.0.0"),
    ],
    targets: [
        .target(
            name: "QuillKit",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
            ],
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
        .testTarget(
            name: "QuillKitTests",
            dependencies: ["QuillKit"],
            path: "Tests/QuillKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
