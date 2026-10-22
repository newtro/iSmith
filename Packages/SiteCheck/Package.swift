// swift-tools-version: 5.10
import PackageDescription

/// PHP2Shell site check: reads the response headers WebKit already received for a page and says
/// whether its server reports a PHP version vulnerable to PHP2Shell (CVE-2026-109618 and
/// CVE-2026-109619). Ported from github.com/newtro/php2shell-site-check. Never sends a request.
/// No UI.
let package = Package(
    name: "SiteCheck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SiteCheck", targets: ["SiteCheck"]),
    ],
    targets: [
        .target(name: "SiteCheck"),
        .testTarget(name: "SiteCheckTests", dependencies: ["SiteCheck"]),
    ]
)
