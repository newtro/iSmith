// swift-tools-version: 5.10
import PackageDescription

/// Reads a Brave install: finds its profiles, parses bookmarks into a neutral tree, and reads and
/// decrypts saved passwords from copies of its login databases. Read-only towards Brave; no UI.
/// SQLite is the system library (the SDK's `SQLite3` module), so there is no package dependency.
let package = Package(
    name: "BraveImport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BraveImport", targets: ["BraveImport"]),
    ],
    targets: [
        .target(name: "BraveImport", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "BraveImportTests", dependencies: ["BraveImport"],
                    resources: [.copy("Fixtures")],
                    linkerSettings: [.linkedLibrary("sqlite3")]),
    ]
)
