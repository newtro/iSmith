import Foundation
import WebKit

/// Compiled content-rule lists on disk. `WebKitRuleListStore` is the real one; tests wrap it to
/// fail a compile on purpose.
@MainActor
protocol RuleListStoring: AnyObject {
    func compile(identifier: String, json: String) async throws -> WKContentRuleList
    /// The compiled list, or an error if it's missing or WebKit can no longer read it (its
    /// compiled format changes with WebKit updates).
    func lookUp(identifier: String) async throws -> WKContentRuleList
    func identifiers() async -> [String]
    func remove(identifier: String) async throws
}

@MainActor
final class WebKitRuleListStore: RuleListStoring {
    enum StoreError: Error { case unavailable(URL), noList(String) }

    private let store: WKContentRuleListStore

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: directory) else { throw StoreError.unavailable(directory) }
        self.store = store
    }

    func compile(identifier: String, json: String) async throws -> WKContentRuleList {
        guard let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
        else { throw StoreError.noList(identifier) }
        return list
    }

    func lookUp(identifier: String) async throws -> WKContentRuleList {
        guard let list = try await store.contentRuleList(forIdentifier: identifier) else {
            throw StoreError.noList(identifier)
        }
        return list
    }

    func identifiers() async -> [String] {
        await store.availableIdentifiers() ?? []
    }

    func remove(identifier: String) async throws {
        try await store.removeContentRuleList(forIdentifier: identifier)
    }
}
