// swift-tools-version: 5.10
import PackageDescription

/// Link routing: which space a link from another app opens in. Ordered URL rules, the space last
/// used for hosts whose address is the same in every tenant (Outlook, Teams, Gmail), the Default
/// space, and rules learned from tabs you move. Saved in `routing.json`. No UI.
let package = Package(
    name: "Routing",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Routing", targets: ["Routing"]),
    ],
    targets: [
        .target(name: "Routing"),
        .testTarget(name: "RoutingTests", dependencies: ["Routing"]),
    ]
)
