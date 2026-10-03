@testable import Blocking
import Foundation
import WebKit
import XCTest

enum Fixtures {
    static var fixtureURL: URL {
        Bundle.module.url(forResource: "fixture", withExtension: "txt", subdirectory: "Fixtures")!
    }

    static var fixtureText: String { try! String(contentsOf: fixtureURL, encoding: .utf8) }

    /// A small list in Adblock Plus syntax: a header, a version, and `||<prefix><n>.example^`
    /// rules, plus one exception.
    static func list(version: Int, prefix: String = "ad", count: Int = 5) -> String {
        var lines = ["[Adblock Plus 2.0]", "! Title: test list", "! Version: \(version)"]
        lines += (0..<count).map { "||\(prefix)\($0).example^" }
        lines.append("@@||\(prefix)0.example/ok.js")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A fresh folder per test, deleted afterwards.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// The real WebKit store, counting compiles and able to fail them on purpose.
@MainActor
final class SpyStore: RuleListStoring {
    let real: WebKitRuleListStore
    var compiles: [String] = []
    /// Compiles fail once this many have succeeded (nil: never).
    var failAfter: Int?
    struct InjectedFailure: Error {}

    init(directory: URL) throws {
        real = try WebKitRuleListStore(directory: directory.appendingPathComponent("Store", isDirectory: true))
    }

    func compile(identifier: String, json: String) async throws -> WKContentRuleList {
        if let failAfter, compiles.count >= failAfter { throw InjectedFailure() }
        let list = try await real.compile(identifier: identifier, json: json)
        compiles.append(identifier)
        return list
    }

    func lookUp(identifier: String) async throws -> WKContentRuleList { try await real.lookUp(identifier: identifier) }
    func identifiers() async -> [String] { await real.identifiers() }
    func remove(identifier: String) async throws { try await real.remove(identifier: identifier) }
}

/// Serves canned downloads and counts requests.
final class FakeFetcher: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: Result<String, Error>] = [:]
    private var _requests = 0
    var delay: UInt64 = 0

    var requests: Int { lock.withLock { _requests } }

    func set(_ url: URL, _ text: String) { lock.withLock { responses[url] = .success(text) } }
    func fail(_ url: URL, _ error: Error = URLError(.notConnectedToInternet)) { lock.withLock { responses[url] = .failure(error) } }

    func fetch(_ url: URL) async throws -> Data {
        let (response, delay) = lock.withLock { () -> (Result<String, Error>?, UInt64) in
            _requests += 1
            return (responses[url], self.delay)
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        guard let response else { throw URLError(.fileDoesNotExist) }
        return Data(try response.get().utf8)
    }
}

/// A mutable clock for refresh scheduling.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    func advance(days: Double) { now = now.addingTimeInterval(days * 24 * 3600) }
}

/// A controller on small test lists with an injected store, fetcher and clock.
@MainActor
struct Harness {
    let dir: TempDir
    let sources: [FilterSource]
    let fetcher = FakeFetcher()
    let clock = TestClock()

    /// Two sources (`alpha`, `beta`) whose bundled copies are version-1 lists.
    init(dir: TempDir) throws {
        self.dir = dir
        sources = [
            FilterSource(name: "alpha", url: URL(string: "https://lists.test/alpha.txt")!,
                         bundled: try dir.file("alpha-bundled.txt", Fixtures.list(version: 1, prefix: "alpha"))),
            FilterSource(name: "beta", url: URL(string: "https://lists.test/beta.txt")!,
                         bundled: try dir.file("beta-bundled.txt", Fixtures.list(version: 1, prefix: "beta"))),
        ]
    }

    var configuration: BlockingController.Configuration {
        var config = BlockingController.Configuration(directory: dir.url.appendingPathComponent("Blocking"), sources: sources)
        config.minimumRulesPerSource = 1
        let fetcher = fetcher, clock = clock
        config.fetch = { try await fetcher.fetch($0) }
        config.now = { clock.now }
        return config
    }

    /// A new controller on the same folder, as a relaunch of the app would make.
    func launch() throws -> (BlockingController, SpyStore) {
        let store = try SpyStore(directory: configuration.directory)
        return (BlockingController(configuration: configuration, store: store), store)
    }

    func serve(version: Int) {
        for source in sources { fetcher.set(source.url, Fixtures.list(version: version, prefix: source.name)) }
    }
}
