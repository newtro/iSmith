// swift-tools-version: 5.10
import PackageDescription

/// 2FASync on the Mac, with no UI: SMS verification codes sealed by the phone, carried by the
/// relay and opened here. See INTEGRATION.md for how the app, the iSmith Agent and the relay fit.
///
/// - `CodesXPC`: the agent's XPC interface and the plain values it passes. The app links only
///   this (no libsodium, no relay code).
/// - `Codes`: the agent's engine: the v1 wire types, libsodium `crypto_box`, pairing, the relay
///   client (HTTP and the WebSocket stream), the receiver rules and the recent-codes list.
let package = Package(
    name: "Codes",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Codes", targets: ["Codes"]),
        .library(name: "CodesXPC", targets: ["CodesXPC"]),
    ],
    dependencies: [
        // libsodium itself (a prebuilt xcframework on Apple platforms); crypto_box is called directly.
        .package(url: "https://github.com/jedisct1/swift-sodium", exact: "0.9.1"),
    ],
    targets: [
        .target(name: "CodesXPC"),
        .target(
            name: "Codes",
            dependencies: [
                "CodesXPC",
                .product(name: "Clibsodium", package: "swift-sodium"),
            ]
        ),
        // A stand-in relay (HTTP and WebSocket on 127.0.0.1) and phone, for the tests and for a
        // local end-to-end run of the real agent (`swift run FakeRelay`).
        .target(name: "FakeRelayKit", dependencies: ["Codes"]),
        .executableTarget(name: "FakeRelay", dependencies: ["FakeRelayKit"]),
        .testTarget(
            name: "CodesTests",
            dependencies: ["Codes", "CodesXPC", "FakeRelayKit"],
            resources: [.copy("Resources")]
        ),
    ]
)
