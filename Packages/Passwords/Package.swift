// swift-tools-version: 5.10
import PackageDescription

/// iSmith's password store and autofill: encrypted logins in SQLite, origin matching, the capture
/// and fill scripts that run in their own WebKit content world, and the controller the app drives.
/// No UI; see INTEGRATION.md for what the app adds.
let package = Package(
    name: "Passwords",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Passwords", targets: ["Passwords"]),
    ],
    dependencies: [
        // The Keychain key store (file-based login Keychain) is shared with the sign-in vault.
        .package(path: "../SignInSync"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "Passwords",
            dependencies: [
                .product(name: "SignInSync", package: "SignInSync"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .copy("Resources/autofill.js"),
                .copy("Resources/public_suffix_list.dat"),
            ]
        ),
        .testTarget(
            name: "PasswordsTests",
            dependencies: ["Passwords"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
