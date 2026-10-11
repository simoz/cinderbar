// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CinderBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CinderBar", targets: ["CinderBar"]),
    ],
    targets: [
        // Everything that can be wrong without a screen: transcript parsing,
        // bucketing, pace math and the guidance pick. No AppKit in here.
        .target(name: "CinderBarCore"),
        .executableTarget(name: "CinderBar", dependencies: ["CinderBarCore"]),
        // XCTest and swift-testing need a full Xcode; this runs on the
        // Command Line Tools alone: `swift run cinderbar-checks`.
        .executableTarget(name: "cinderbar-checks", dependencies: ["CinderBarCore"], path: "Sources/CinderBarChecks"),
    ]
)
