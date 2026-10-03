// swift-tools-version: 5.10
import PackageDescription

/// Ad and tracker blocking: EasyList and EasyPrivacy converted to WebKit content-rule lists with
/// AdGuard's SafariConverterLib, compiled into a store, refreshed weekly, and attached per web view
/// with a per-site allowlist. No UI.
let package = Package(
    name: "Blocking",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Blocking", targets: ["Blocking"]),
    ],
    dependencies: [
        // Exact pins: a converter change changes what gets blocked, so it's a deliberate update.
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib", exact: "4.3.0"),
        // Already in the graph through SafariConverterLib (1.1.0..<2.0.0); pinned here so the
        // public-suffix data behind the per-site allowlist doesn't drift between builds.
        .package(url: "https://github.com/ameshkov/swift-psl", exact: "1.1.182"),
    ],
    targets: [
        .target(
            name: "Blocking",
            dependencies: [
                .product(name: "ContentBlockerConverter", package: "SafariConverterLib"),
                .product(name: "PublicSuffixList", package: "swift-psl"),
            ],
            resources: [.copy("Snapshot")]
        ),
        .testTarget(
            name: "BlockingTests",
            dependencies: ["Blocking"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
