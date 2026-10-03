@testable import Blocking
import Foundation
import WebKit
import XCTest

/// The per-site allowlist: site keys, persistence, and attaching or removing lists.
@MainActor
final class AllowlistTests: XCTestCase {
    func testSiteKeys() {
        XCTAssertEqual(BlockingController.site(for: "www.cnn.com"), "cnn.com")
        XCTAssertEqual(BlockingController.site(for: "Edition.CNN.com."), "cnn.com")
        XCTAssertEqual(BlockingController.site(for: "news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(BlockingController.site(for: "contoso.sharepoint.com"), "sharepoint.com")
        XCTAssertEqual(BlockingController.site(for: "www.myapp.azurewebsites.net"), "myapp.azurewebsites.net",
                       "azurewebsites.net is a public suffix, so each app is its own site")
        XCTAssertEqual(BlockingController.site(for: "user.github.io"), "user.github.io")
        XCTAssertEqual(BlockingController.site(for: "localhost"), "localhost")
        XCTAssertEqual(BlockingController.site(for: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(BlockingController.site(for: "[::1]"), "::1")
        XCTAssertNil(BlockingController.site(for: "  "))
    }

    func testAllowingASiteCoversItsSubdomainsAndPersists() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir: dir)
        let (controller, _) = try harness.launch()
        XCTAssertTrue(controller.isBlocked(host: "www.cnn.com"))

        let notified = expectation(forNotification: BlockingController.allowlistDidChange, object: controller) { note in
            note.userInfo?["site"] as? String == "cnn.com"
        }
        try controller.setAllowed(host: "www.cnn.com", true)
        await fulfillment(of: [notified], timeout: 1)
        XCTAssertFalse(controller.isBlocked(host: "edition.cnn.com"))
        XCTAssertFalse(controller.isBlocked(url: URL(string: "https://cnn.com/live")!))
        XCTAssertTrue(controller.isBlocked(host: "cnn.co.uk"))
        XCTAssertEqual(controller.allowedSites, ["cnn.com"])

        let (relaunched, _) = try harness.launch()
        XCTAssertFalse(relaunched.isBlocked(host: "www.cnn.com"))
        try relaunched.setAllowed(host: "cnn.com", false)
        XCTAssertTrue(relaunched.isBlocked(host: "www.cnn.com"))

        let (third, _) = try harness.launch()
        XCTAssertTrue(third.isBlocked(host: "www.cnn.com"))
        XCTAssertEqual(third.allowedSites, [])
    }

    func testUnreadableAllowlistIsSetAsideAndStartsEmpty() throws {
        let dir = try TempDir()
        let harness = try Harness(dir: dir)
        let folder = harness.configuration.directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("allowlist.json"))

        let (controller, _) = try harness.launch()
        XCTAssertEqual(controller.allowedSites, [])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("allowlist.unreadable-") }, "\(files)")
        try controller.setAllowed(host: "example.com", true)
        XCTAssertEqual(try harness.launch().0.allowedSites, ["example.com"])
    }

    func testFailedSaveChangesNothing() throws {
        let dir = try TempDir()
        let harness = try Harness(dir: dir)
        let (controller, _) = try harness.launch()
        // A folder where the file should be makes the save fail.
        try FileManager.default.createDirectory(at: harness.configuration.directory.appendingPathComponent("allowlist.json"),
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try controller.setAllowed(host: "example.com", true))
        XCTAssertTrue(controller.isBlocked(host: "example.com"))
    }

    /// `applyIfLoaded` does nothing until the lists have loaded. What `apply` does to page loads
    /// is checked in WebViewTests.
    func testApplyIfLoadedWaitsForTheLists() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir: dir)
        let (controller, _) = try harness.launch()
        let content = WKUserContentController()
        XCTAssertNil(controller.loadedRuleLists)
        XCTAssertFalse(controller.applyIfLoaded(to: content, host: "news.example"))
        await controller.apply(to: content, host: "news.example")
        XCTAssertEqual(controller.loadedRuleLists?.count, 2)
        XCTAssertTrue(controller.applyIfLoaded(to: content, host: "news.example"))
    }
}
