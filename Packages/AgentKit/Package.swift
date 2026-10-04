// swift-tools-version: 5.10
import PackageDescription

/// Agent backends for the agent panel: the `AgentBackend` protocol and the Codex app server
/// (`codex app-server`, newline-delimited JSON-RPC over stdio). No UI and no browser code.
let package = Package(
    name: "AgentKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"]),
    ],
    targets: [
        .target(name: "AgentKit"),
        // A stand-in for `codex app-server` that the tests drive (no real Codex, no network).
        .executableTarget(name: "FakeCodexAppServer"),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit", "FakeCodexAppServer"]),
    ]
)
