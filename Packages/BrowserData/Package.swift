// swift-tools-version: 5.10
import PackageDescription

/// iSmith's browsing data in one SQLite file (`browser.sqlite`): history per space, bookmarks (shared
/// by every space), site settings (permissions, zoom, app links) and the downloads list. No UI.
let package = Package(
    name: "BrowserData",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BrowserData", targets: ["BrowserData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "BrowserData",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "BrowserDataTests",
            dependencies: ["BrowserData"]
        ),
    ]
)
