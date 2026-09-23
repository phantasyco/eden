// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Eden",
    platforms: [.macOS(.v26)],
    dependencies: [
        // The terminal drawer's emulator. Pure Swift, so Eden stays Swift-only.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "Eden",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Eden",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
