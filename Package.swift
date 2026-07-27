// swift-tools-version: 5.10
import PackageDescription

// This manifest is optional; the Xcode project is the primary deliverable. It makes the
// same source tree available to `swift build` on a macOS machine with Xcode installed.
let package = Package(
    name: "WhisperKeys",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WhisperKeys", targets: ["WhisperKeys"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "WhisperKeys",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
            path: ".",
            exclude: [
                "Assets",
                "Assets.xcassets",
                "CONTRIBUTING.md",
                "LICENSE",
                "README.md",
                "SECURITY.md",
                "Tests",
                // The Xcode project has a mirrored application bundle beneath the package
                // root. Exclude it so SwiftPM does not compile every source file twice.
                "WhisperKeys",
                "WhisperKeys.entitlements",
                "WhisperKeys-Info.plist",
                "WhisperKeys.xcodeproj"
            ]
        ),
        .testTarget(
            name: "WhisperKeysTests",
            dependencies: ["WhisperKeys"],
            path: "Tests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
