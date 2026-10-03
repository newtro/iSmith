// swift-tools-version: 5.10
import PackageDescription

/// The sign-in engine: providers, accounts and spaces (config), the encrypted vault, and the
/// cookie sync between per-space WebKit stores. No UI.
let package = Package(
    name: "SignInSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SignInSync", targets: ["SignInSync"]),
    ],
    targets: [
        .target(name: "SignInSync"),
        .testTarget(name: "SignInSyncTests", dependencies: ["SignInSync"]),
    ]
)
