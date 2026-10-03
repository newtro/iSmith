@testable import Blocking
import Foundation
import WebKit
import XCTest

/// Weekly refresh: new lists replace the old ones only once they compile; any failure keeps the
/// lists in use.
@MainActor
final class RefreshTests: XCTestCase {
    private var dir: TempDir!
    private var harness: Harness!

    override func setUp() async throws {
        dir = try TempDir()
        harness = try Harness(dir: dir)
    }

    override func tearDown() async throws {
        harness = nil
        dir = nil
    }

    func testFirstRefreshIsDueThenWeekly() async throws {
        harness.serve(version: 2)
        let (controller, _) = try harness.launch()
        let value1 = await controller.refresh()
        XCTAssertEqual(value1, .updated, "the snapshot is never considered checked")
        harness.clock.advance(days: 6.9)
        let value2 = await controller.refresh()
        XCTAssertEqual(value2, .notDue)
        XCTAssertEqual(harness.fetcher.requests, 2)
        harness.clock.advance(days: 0.2)
        let value3 = await controller.refresh()
        XCTAssertEqual(value3, .unchanged)
        XCTAssertEqual(harness.fetcher.requests, 4)
        let value4 = await controller.refresh(force: true)
        XCTAssertEqual(value4, .unchanged)
    }

    func testSuccessfulRefreshSwapsListsSavesThemAndNotifies() async throws {
        let (controller, store) = try harness.launch()
        let old = await controller.ruleLists().map(\.identifier)
        XCTAssertEqual(controller.status.listVersions, ["alpha": "1", "beta": "1"])

        harness.serve(version: 2)
        let notified = expectation(forNotification: BlockingController.listsDidChange, object: controller)
        let value5 = await controller.refresh()
        XCTAssertEqual(value5, .updated)
        await fulfillment(of: [notified], timeout: 5)

        let new = await controller.ruleLists().map(\.identifier)
        XCTAssertEqual(new.count, 2)
        XCTAssertTrue(Set(new).isDisjoint(with: old))
        XCTAssertEqual(controller.status.origin, .downloaded)
        XCTAssertEqual(controller.status.listVersions, ["alpha": "2", "beta": "2"])
        XCTAssertNil(controller.status.lastError)
        // The old lists stay in the store while this launch's web views may still hold them.
        let value6 = await store.identifiers()
        XCTAssertEqual(Set(value6), Set(old + new))
        let saved = harness.configuration.directory.appendingPathComponent("lists/alpha.txt")
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), Fixtures.list(version: 2, prefix: "alpha"))

        // Next launch: the new lists load without compiling, and the old ones are removed.
        let (relaunched, relaunchStore) = try harness.launch()
        let value7 = await relaunched.ruleLists().map(\.identifier)
        XCTAssertEqual(value7, new)
        XCTAssertEqual(relaunchStore.compiles, [])
        let value8 = await relaunchStore.identifiers()
        XCTAssertEqual(Set(value8), Set(new))
    }

    func testFailedDownloadKeepsTheListsAndRetriesLater() async throws {
        let (controller, store) = try harness.launch()
        let old = await controller.ruleLists().map(\.identifier)
        harness.fetcher.set(harness.sources[0].url, Fixtures.list(version: 2, prefix: "alpha"))
        harness.fetcher.fail(harness.sources[1].url)

        guard case .failed = await controller.refresh() else { return XCTFail("expected a failure") }
        let value9 = await controller.ruleLists().map(\.identifier)
        XCTAssertEqual(value9, old)
        XCTAssertEqual(controller.status.origin, .bundled)
        XCTAssertNotNil(controller.status.lastError)
        XCTAssertEqual(store.compiles.count, 2, "nothing compiled for the failed refresh")

        harness.clock.advance(days: 0.1)
        let value10 = await controller.refresh()
        XCTAssertEqual(value10, .notDue, "waits the retry interval")
        harness.clock.advance(days: 0.25)
        harness.serve(version: 2)
        let value11 = await controller.refresh()
        XCTAssertEqual(value11, .updated)
        XCTAssertNil(controller.status.lastError)
    }

    func testRejectsADownloadThatIsNotAFilterList() async throws {
        let (controller, store) = try harness.launch()
        let old = await controller.ruleLists().map(\.identifier)
        harness.serve(version: 2)
        harness.fetcher.set(harness.sources[1].url, "<!doctype html><html><body>Captive portal</body></html>\n")

        guard case let .failed(message) = await controller.refresh() else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("beta"), message)
        let value12 = await controller.ruleLists().map(\.identifier)
        XCTAssertEqual(value12, old)
        XCTAssertEqual(store.compiles.count, 2)
    }

    func testRejectsATruncatedDownload() async throws {
        var config = harness.configuration
        config.minimumRulesPerSource = 3
        let store = try SpyStore(directory: config.directory)
        let controller = BlockingController(configuration: config, store: store)
        let old = await controller.ruleLists().map(\.identifier)
        harness.serve(version: 2)
        harness.fetcher.set(harness.sources[0].url, Fixtures.list(version: 2, prefix: "alpha", count: 1))

        guard case .failed = await controller.refresh() else { return XCTFail("expected a failure") }
        let value13 = await controller.ruleLists().map(\.identifier)
        XCTAssertEqual(value13, old)
    }

    /// The second list fails to compile: the first, already compiled, is removed, and web views
    /// keep the old lists.
    func testCompileFailureKeepsTheOldListsAndRemovesTheNewOnes() async throws {
        let (controller, store) = try harness.launch()
        let old = await controller.ruleLists().map(\.identifier)
        store.failAfter = 3
        harness.serve(version: 2)

        guard case .failed = await controller.refresh() else { return XCTFail("expected a failure") }
        XCTAssertEqual(store.compiles.count, 3, "one new list compiled before the failure")
        let value14 = await controller.ruleLists().map(\.identifier)
        XCTAssertEqual(value14, old)
        let value15 = await store.identifiers()
        XCTAssertEqual(Set(value15), Set(old), "the half-made generation is removed")
        XCTAssertEqual(controller.status.listVersions, ["alpha": "1", "beta": "1"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: harness.configuration.directory.appendingPathComponent("lists/alpha.txt").path))

        // A relaunch still uses the old lists.
        let (relaunched, relaunchStore) = try harness.launch()
        let value16 = await relaunched.ruleLists().map(\.identifier)
        XCTAssertEqual(value16, old)
        XCTAssertEqual(relaunchStore.compiles, [])
    }

    func testConcurrentRefreshesShareOneDownload() async throws {
        let (controller, _) = try harness.launch()
        _ = await controller.ruleLists()
        harness.serve(version: 2)
        harness.fetcher.delay = 200_000_000
        async let a = controller.refresh()
        async let b = controller.refresh()
        let (x, y) = await (a, b)
        XCTAssertEqual(x, .updated)
        XCTAssertEqual(y, .updated)
        XCTAssertEqual(harness.fetcher.requests, 2, "one request per source")
    }

    func testAutomaticRefreshRunsWhenDue() async throws {
        var config = harness.configuration
        config.checkInterval = 0.05
        let store = try SpyStore(directory: config.directory)
        let controller = BlockingController(configuration: config, store: store)
        harness.serve(version: 2)
        let notified = expectation(forNotification: BlockingController.listsDidChange, object: controller) { _ in
            MainActor.assumeIsolated { controller.status.origin == .downloaded }
        }
        controller.startAutomaticRefresh(initialDelay: 0)
        await fulfillment(of: [notified], timeout: 10)
        controller.stopAutomaticRefresh()
        XCTAssertEqual(controller.status.listVersions, ["alpha": "2", "beta": "2"])
    }

    /// A long session: each refresh removes the generation before the one it replaced, so the
    /// store holds at most two.
    func testRefreshRemovesOlderGenerations() async throws {
        let (controller, store) = try harness.launch()
        let v1: [String] = await controller.ruleLists().map(\.identifier)
        harness.serve(version: 2)
        let r2 = await controller.refresh()
        XCTAssertEqual(r2, .updated)
        let v2: [String] = await controller.ruleLists().map(\.identifier)
        harness.serve(version: 3)
        harness.clock.advance(days: 8)
        let r3 = await controller.refresh()
        XCTAssertEqual(r3, .updated)
        let v3: [String] = await controller.ruleLists().map(\.identifier)
        let remaining = Set(await store.identifiers())
        XCTAssertEqual(remaining, Set(v2 + v3))
        XCTAssertTrue(remaining.isDisjoint(with: v1))
    }

    /// "Update now" while an automatic check is still waiting for the lists to load: the forced
    /// refresh runs after it instead of taking its "not due".
    func testForcedRefreshDuringAnAutomaticOneStillDownloads() async throws {
        harness.serve(version: 2)
        let (first, _) = try harness.launch()
        let r1 = await first.refresh()
        XCTAssertEqual(r1, .updated)
        let requests = harness.fetcher.requests

        let (controller, _) = try harness.launch()
        let automatic = Task { await controller.refresh() }
        await Task.yield()
        let forced = await controller.refresh(force: true)
        let automaticResult = await automatic.value
        XCTAssertEqual(automaticResult, .notDue)
        XCTAssertEqual(forced, .unchanged)
        XCTAssertEqual(harness.fetcher.requests, requests + 2)
    }
}
