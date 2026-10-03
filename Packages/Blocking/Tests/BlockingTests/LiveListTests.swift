@testable import Blocking
import Foundation
import WebKit
import XCTest

/// Downloads today's EasyList and EasyPrivacy, converts and compiles them, and prints rule counts
/// and timings. Needs the network, so it only runs with `BLOCKING_LIVE_TESTS=1`:
/// `BLOCKING_LIVE_TESTS=1 swift test --filter LiveListTests`.
@MainActor
final class LiveListTests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["BLOCKING_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set BLOCKING_LIVE_TESTS=1 to download and compile the live lists.")
        }
    }

    func testLiveListsConvertAndCompile() async throws {
        var texts: [(name: String, text: String)] = []
        for source in FilterSource.defaults {
            let data = try await BlockingController.download(source.url)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(BlockingController.looksLikeFilterList(text))
            texts.append((source.name, text))
            print("Live \(source.name): \(data.count) bytes, \(RuleListBuilder.rules(in: text).count) rule lines, "
                  + "version \(BlockingController.versions([(source.name, text)])[source.name] ?? "?")")
        }

        let convertStart = Date()
        let lists = try await Task.detached { try RuleListBuilder.build(sources: texts) }.value
        let convertSeconds = Date().timeIntervalSince(convertStart)

        let dir = try TempDir()
        let store = try WebKitRuleListStore(directory: dir.url)
        var compileSeconds: [String: Double] = [:]
        for list in lists {
            XCTAssertLessThanOrEqual(list.ruleCount, RuleListBuilder.webKitRuleLimit)
            let start = Date()
            _ = try await store.compile(identifier: list.name, json: list.json)
            compileSeconds[list.name] = Date().timeIntervalSince(start)
        }
        let sizes = try FileManager.default.contentsOfDirectory(at: dir.url, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        for list in lists {
            print("Live \(list.name): \(list.ruleCount) rules, \(list.skippedLines) lines skipped, "
                  + "JSON \(list.json.utf8.count) bytes, compiled in \(String(format: "%.2f", compileSeconds[list.name] ?? 0)) s")
        }
        print("Live conversion \(String(format: "%.2f", convertSeconds)) s; compiled store \(sizes) bytes")

        // The whole first-launch path through the controller, from download to lists in use.
        let controllerDir = try TempDir()
        let controller = try BlockingController(directory: controllerDir.url)
        let start = Date()
        let result = await controller.refresh(force: true)
        print("Live controller refresh: \(result) in \(String(format: "%.1f", Date().timeIntervalSince(start))) s "
              + "(includes compiling the bundled snapshot first), \(controller.status.ruleCounts)")
        XCTAssertTrue(result == .updated || result == .unchanged, "\(result)")
    }
}
