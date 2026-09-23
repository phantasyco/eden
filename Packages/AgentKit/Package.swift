// swift-tools-version: 6.2
import PackageDescription

/// How Eden runs agents and tools: processes speaking JSON lines (Claude
/// Code's stream-json, JSON-RPC for Codex and ACP), the login-shell PATH,
/// this Mac or an SSH host, and git. No UI, so it tests on its own.
let package = Package(
    name: "AgentKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"]),
    ],
    targets: [
        .target(name: "AgentKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
    ]
)
