@testable import Blocking
import Foundation
import WebKit
import XCTest

/// Compiling into the store, loading from it on the next launch, and recompiling when WebKit
/// can't read it any more.
@MainActor
final class StoreTests: XCTestCase {
    /// The real bundled EasyList and EasyPrivacy, converted and compiled in this process: what
    /// first launch does. A second launch finds them in the store without compiling.
    func testCompilesBundledSnapshotThenLoadsItFromTheStore() async throws {
        let dir = try TempDir()
        let config = BlockingController.Configuration(directory: dir.url)
        let store = try SpyStore(directory: dir.url)
        let first = BlockingController(configuration: config, store: store)
        let start = Date()
        let lists = await first.ruleLists()
        let seconds = Date().timeIntervalSince(start)
        XCTAssertNil(first.status.lastError)
        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(first.status.origin, .bundled)
        let counts = first.status.ruleCounts
        XCTAssertGreaterThan(counts["easylist-1"] ?? 0, 30_000)
        XCTAssertGreaterThan(counts["easyprivacy-1"] ?? 0, 30_000)
        XCTAssertNotNil(first.status.listVersions["easylist"])
        print("Bundled snapshot: \(counts), versions \(first.status.listVersions), converted and compiled in \(String(format: "%.1f", seconds)) s")

        let secondStore = try SpyStore(directory: dir.url)
        let second = BlockingController(configuration: config, store: secondStore)
        let reloaded = await second.ruleLists()
        XCTAssertEqual(secondStore.compiles, [])
        XCTAssertEqual(reloaded.map(\.identifier), lists.map(\.identifier))
    }

    /// After an OS update WebKit may refuse the compiled store. The lists are compiled again from
    /// the same source and the unreadable ones are removed.
    func testRecompilesWhenTheCompiledStoreIsUnreadable() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir: dir)
        let (first, _) = try harness.launch()
        let old = await first.ruleLists().map(\.identifier)
        XCTAssertEqual(old.count, 2)

        let storeDir = harness.configuration.directory.appendingPathComponent("Store")
        let files = try FileManager.default.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files { try Data("not a compiled list".utf8).write(to: file) }

        let (second, store) = try harness.launch()
        let lists = await second.ruleLists()
        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(store.compiles.count, 2)
        XCTAssertTrue(Set(lists.map(\.identifier)).isDisjoint(with: old))
        let remaining = await store.identifiers()
        XCTAssertEqual(Set(remaining), Set(lists.map(\.identifier)), "the unreadable lists are removed")
    }

    /// A converter or OS update that changes the conversion (the state's fingerprint) recompiles.
    func testRecompilesWhenTheFingerprintChanges() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir: dir)
        let (first, _) = try harness.launch()
        _ = await first.ruleLists()

        let stateURL = harness.configuration.directory.appendingPathComponent("state.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        json["fingerprint"] = "format 1; converter 0.0.1"
        try JSONSerialization.data(withJSONObject: json).write(to: stateURL)

        let (second, store) = try harness.launch()
        let lists = await second.ruleLists()
        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(store.compiles.count, 2)
    }

    /// A damaged state file is the same as none: compile from the snapshot.
    func testDamagedStateFileRecompiles() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir: dir)
        let (first, _) = try harness.launch()
        _ = await first.ruleLists()
        try Data("{".utf8).write(to: harness.configuration.directory.appendingPathComponent("state.json"))

        let (second, store) = try harness.launch()
        let value1 = await second.ruleLists().count
        XCTAssertEqual(value1, 2)
        XCTAssertEqual(store.compiles.count, 2)
        let value2 = await store.identifiers().count
        XCTAssertEqual(value2, 2, "the old lists are removed")
    }

    /// If the downloaded lists in use can't be read from the store, they're recompiled (not the
    /// older snapshot), and the refresh schedule is kept.
    func testRecompilesDownloadedListsRatherThanTheSnapshot() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir: dir)
        harness.serve(version: 2)
        let (first, _) = try harness.launch()
        let value3 = await first.refresh()
        XCTAssertEqual(value3, .updated)
        let checked = first.status.lastChecked

        let storeDir = harness.configuration.directory.appendingPathComponent("Store")
        for file in try FileManager.default.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        let (second, store) = try harness.launch()
        let value4 = await second.ruleLists().count
        XCTAssertEqual(value4, 2)
        XCTAssertEqual(store.compiles.count, 2)
        XCTAssertEqual(second.status.origin, .downloaded)
        XCTAssertEqual(second.status.listVersions, ["alpha": "2", "beta": "2"])
        XCTAssertEqual(second.status.lastChecked, checked)
        let value5 = await second.refresh()
        XCTAssertEqual(value5, .notDue)
    }

    /// Concurrent first calls share one load.
    func testConcurrentFirstCallsCompileOnce() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir: dir)
        let (controller, store) = try harness.launch()
        async let a = controller.ruleLists()
        async let b = controller.ruleLists()
        let (x, y) = await (a, b)
        XCTAssertEqual(x.map(\.identifier), y.map(\.identifier))
        XCTAssertEqual(store.compiles.count, 2)
    }
}
