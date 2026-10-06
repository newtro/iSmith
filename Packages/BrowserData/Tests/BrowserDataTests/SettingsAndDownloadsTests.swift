@testable import BrowserData
import XCTest

/// Site settings (origin keys, permissions, zoom, app links) and the downloads list.
final class SettingsAndDownloadsTests: XCTestCase {
    private var db: BrowserDatabase!

    override func setUpWithError() throws {
        db = try BrowserDatabase.inMemory()
    }

    func testOriginKeys() {
        XCTAssertEqual(SiteSettingsStore.originKey(scheme: "HTTPS", host: "Teams.Microsoft.com", port: 443), "https://teams.microsoft.com")
        XCTAssertEqual(SiteSettingsStore.originKey(scheme: "https", host: "localhost", port: 8443), "https://localhost:8443")
        XCTAssertEqual(SiteSettingsStore.originKey(scheme: "http", host: "example.com", port: 80), "http://example.com")
        XCTAssertEqual(SiteSettingsStore.originKey(scheme: "http", host: "example.com", port: 443), "http://example.com:443")
        XCTAssertEqual(SiteSettingsStore.originKey(scheme: "https", host: "example.com", port: 0), "https://example.com")
        XCTAssertEqual(SiteSettingsStore.originKey(scheme: "https", host: "::1", port: 8443), "https://[::1]:8443")
        XCTAssertEqual(SiteSettingsStore.originKey(for: URL(string: "HTTPS://Example.COM:443/path?q#f")!), "https://example.com")
        XCTAssertEqual(SiteSettingsStore.originKey(for: URL(string: "http://localhost:3000/")!), "http://localhost:3000")
        XCTAssertEqual(SiteSettingsStore.originKey(for: URL(string: "https://[::1]:8443/")!), "https://[::1]:8443")
        XCTAssertNil(SiteSettingsStore.originKey(for: URL(string: "about:blank")!))
    }

    func testPermissions() throws {
        let sites = db.sites
        let teams = "https://teams.microsoft.com"
        XCTAssertNil(try sites.decision(.camera, origin: teams))
        try sites.setDecision(.allow, for: .cameraAndMicrophone, origin: teams)
        try sites.setDecision(.deny, for: .location, origin: teams)
        try sites.setDecision(.allow, for: .notifications, origin: "https://a.com")
        XCTAssertEqual(try sites.decision(.cameraAndMicrophone, origin: teams), .allow)
        XCTAssertNil(try sites.decision(.camera, origin: teams), "separate permission")
        XCTAssertNil(try sites.decision(.cameraAndMicrophone, origin: "https://teams.microsoft.com:8443"), "separate origin")
        try sites.setDecision(.deny, for: .cameraAndMicrophone, origin: teams)
        XCTAssertEqual(try sites.decision(.cameraAndMicrophone, origin: teams), .deny, "replaced")
        let all = try sites.allDecisions()
        XCTAssertEqual(all.map(\.origin), ["https://a.com", teams, teams])
        XCTAssertEqual(all.map(\.permission), [.notifications, .cameraAndMicrophone, .location])
        try sites.setDecision(nil, for: .location, origin: teams)
        XCTAssertNil(try sites.decision(.location, origin: teams))
        XCTAssertEqual(try sites.allDecisions().count, 2)
    }

    func testZoom() throws {
        let sites = db.sites
        XCTAssertNil(try sites.zoom(host: "example.com"))
        try sites.setZoom(1.25, host: "Example.com")
        XCTAssertEqual(try sites.zoom(host: "example.COM"), 1.25)
        try sites.setZoom(0.9, host: "example.com")
        XCTAssertEqual(try sites.zoom(host: "example.com"), 0.9)
        XCTAssertEqual(try sites.allZooms(), ["example.com": 0.9])
        try sites.setZoom(1.0, host: "example.com")
        XCTAssertNil(try sites.zoom(host: "example.com"), "100% is not stored")
        try sites.setZoom(2, host: "example.com")
        try sites.setZoom(nil, host: "example.com")
        XCTAssertNil(try sites.zoom(host: "example.com"))
        XCTAssertThrowsError(try sites.setZoom(0, host: "example.com"))
        XCTAssertThrowsError(try sites.setZoom(.nan, host: "example.com"))
    }

    func testAppLinks() throws {
        let sites = db.sites
        XCTAssertNil(try sites.appLinkDecision(scheme: "msteams"))
        try sites.setAppLinkDecision(.open, scheme: "MSTeams")
        try sites.setAppLinkDecision(.block, scheme: "zoommtg:")
        XCTAssertEqual(try sites.appLinkDecision(scheme: "msteams:"), .open)
        XCTAssertEqual(try sites.allAppLinkDecisions(), ["msteams": .open, "zoommtg": .block])
        try sites.setAppLinkDecision(.block, scheme: "msteams")
        XCTAssertEqual(try sites.appLinkDecision(scheme: "msteams"), .block)
        try sites.setAppLinkDecision(nil, scheme: "msteams")
        XCTAssertEqual(try sites.allAppLinkDecisions(), ["zoommtg": .block])
    }

    func testSiteMayOpenApp() throws {
        let sites = db.sites
        XCTAssertFalse(try sites.siteMayOpenApp(scheme: "claude", site: "claude.ai"))
        try sites.setSiteMayOpenApp(true, scheme: "Claude:", site: "Claude.AI")
        XCTAssertTrue(try sites.siteMayOpenApp(scheme: "claude", site: "claude.ai"))
        XCTAssertFalse(try sites.siteMayOpenApp(scheme: "claude", site: "evil.example"), "only the site that was allowed")
        XCTAssertFalse(try sites.siteMayOpenApp(scheme: "msteams", site: "claude.ai"), "only the scheme that was allowed")
        XCTAssertEqual(try sites.allSiteAppLinks().map { "\($0.site) \($0.scheme)" }, ["claude.ai claude"])
        try sites.setSiteMayOpenApp(false, scheme: "claude", site: "claude.ai")
        XCTAssertFalse(try sites.siteMayOpenApp(scheme: "claude", site: "claude.ai"))
    }

    func testDownloads() throws {
        let store = db.downloads
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var a = DownloadRecord(space: "home", sourceURL: "https://a.com/a.zip", filePath: "/tmp/a.zip", fileName: "a.zip",
                               bytesExpected: 100, startedAt: t0)
        let b = DownloadRecord(space: "work", sourceURL: nil, filePath: nil, fileName: "b.pdf", state: .finished,
                               bytesReceived: 5, bytesExpected: 5, startedAt: t0.addingTimeInterval(10),
                               finishedAt: t0.addingTimeInterval(11))
        let c = DownloadRecord(space: "work", sourceURL: "https://c.com/c", filePath: nil, fileName: "c", state: .cancelled,
                               startedAt: t0.addingTimeInterval(20))
        try store.upsert(a)
        try store.upsert(b)
        try store.upsert(c)
        XCTAssertEqual(try store.all(limit: 10).map(\.fileName), ["c", "b.pdf", "a.zip"], "newest first")
        XCTAssertEqual(try store.all(limit: 10)[1], b, "round trip")
        XCTAssertEqual(try store.all(limit: 2).count, 2)

        a.bytesReceived = 40
        try store.upsert(a)
        XCTAssertEqual(try store.record(id: a.id)?.bytesReceived, 40)
        XCTAssertEqual(try store.all(limit: 10).count, 3, "upsert replaces")

        try store.markInterruptedAsFailed(at: t0.addingTimeInterval(100))
        let failed = try XCTUnwrap(try store.record(id: a.id))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error, "Interrupted when iSmith quit")
        XCTAssertEqual(failed.finishedAt, t0.addingTimeInterval(100))
        XCTAssertEqual(try store.record(id: b.id)?.state, .finished, "others untouched")

        let d = DownloadRecord(space: "home", sourceURL: nil, filePath: nil, fileName: "d", startedAt: t0.addingTimeInterval(30))
        try store.upsert(d)
        try store.clearFinished()
        XCTAssertEqual(try store.all(limit: 10).map(\.fileName), ["d"], "only in-progress downloads stay")
        try store.remove(d.id)
        XCTAssertEqual(try store.all(limit: 10), [])
    }
}
