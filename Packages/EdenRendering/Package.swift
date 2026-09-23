// swift-tools-version: 6.2
import PackageDescription

/// What Eden draws from text: agent replies' Markdown, split into blocks,
/// and brand marks from SVG path data. No app state, so it tests on its own.
let package = Package(
    name: "EdenRendering",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EdenRendering", targets: ["EdenRendering"]),
    ],
    targets: [
        .target(name: "EdenRendering", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "EdenRenderingTests", dependencies: ["EdenRendering"]),
    ]
)
