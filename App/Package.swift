// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EdenApp",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Eden", targets: ["Eden"]),
    ],
    dependencies: [
        .package(path: "../Packages/AgentKit"),
        .package(path: "../Packages/EdenRendering"),
        // The terminal's emulator. Pure Swift, so Eden stays Swift-only.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "Eden",
            dependencies: [
                "AgentKit", "EdenRendering",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EdenTests",
            dependencies: ["Eden", "AgentKit", "EdenRendering"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
