// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Ember",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ember", targets: ["Ember"]),
    ],
    targets: [
        // Everything that can be wrong without a screen: transcript parsing,
        // bucketing, pace math and the guidance pick. No AppKit in here.
        .target(name: "EmberCore"),
        .executableTarget(name: "Ember", dependencies: ["EmberCore"]),
        // XCTest and swift-testing need a full Xcode; this runs on the
        // Command Line Tools alone: `swift run ember-checks`.
        .executableTarget(name: "ember-checks", dependencies: ["EmberCore"], path: "Sources/EmberChecks"),
    ]
)
