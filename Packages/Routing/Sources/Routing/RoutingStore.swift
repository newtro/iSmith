import Combine
import Foundation

/// routing.json: the rules, the Default space, last-used spaces and what's been learned. Every
/// change is written at once (the file is small), owner-only, through a temporary file and a
/// rename. A file that can't be read is kept aside as `routing.unreadable-<time>.json` and the
/// store starts empty; if it can't be kept aside, nothing is written over it.
@MainActor
public final class RoutingStore: ObservableObject {
    @Published public private(set) var state: RoutingState
    public let fileURL: URL
    /// Where an unreadable file was kept, if one was.
    public private(set) var movedAside: URL?
    /// False when an unreadable file couldn't be kept aside: changes then stay in memory.
    public private(set) var canSave = true

    public init(fileURL: URL) {
        self.fileURL = fileURL
        state = RoutingState()
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            // There but unreadable (permissions): never written over.
            canSave = false
            return
        }
        if let decoded = try? JSONDecoder.routing.decode(RoutingState.self, from: data) {
            state = decoded
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = fileURL.deletingLastPathComponent().appendingPathComponent("routing.unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
            movedAside = aside
        } catch {
            canSave = false
        }
    }

    // MARK: Reading

    public func route(_ url: URL, spaces: [String]) -> Route? { state.route(url, spaces: spaces) }

    // MARK: Rules

    public func addRule(_ rule: RoutingRule, at index: Int? = nil) {
        change { s in s.rules.insert(rule, at: min(max(index ?? s.rules.endIndex, 0), s.rules.endIndex)) }
    }

    public func updateRule(_ rule: RoutingRule) {
        change { s in
            guard let i = s.rules.firstIndex(where: { $0.id == rule.id }) else { return }
            s.rules[i] = rule
        }
    }

    public func removeRule(_ id: UUID) {
        change { $0.rules.removeAll { $0.id == id } }
    }

    /// Moves a rule up or down the list (`to` is its new index).
    public func moveRule(_ id: UUID, to index: Int) {
        change { s in
            guard let from = s.rules.firstIndex(where: { $0.id == id }) else { return }
            let rule = s.rules.remove(at: from)
            s.rules.insert(rule, at: min(max(index, 0), s.rules.endIndex))
        }
    }

    public func setDefaultSpace(_ id: String?) {
        change { $0.defaultSpace = id }
    }

    // MARK: Last used and learning

    public func noteUse(_ url: URL, space: String) {
        guard SharedAddressHosts.key(for: url).map({ state.lastUsed[$0] != space }) == true else { return }
        change { $0.noteUse(url, space: space) }
    }

    public func forgetLastUsed(host: String) {
        change { $0.lastUsed[host] = nil }
    }

    public func recordMove(link: UUID, url: URL, to space: String, spaces: [String]) -> RuleSuggestion? {
        var suggestion: RuleSuggestion?
        change { suggestion = $0.recordMove(link: link, url: url, to: space, spaces: spaces) }
        return suggestion
    }

    @discardableResult
    public func accept(_ suggestion: RuleSuggestion) -> RoutingRule {
        var rule: RoutingRule!
        change { rule = $0.accept(suggestion) }
        return rule
    }

    public func postpone(_ suggestion: RuleSuggestion) { change { $0.postpone(suggestion) } }
    public func never(_ suggestion: RuleSuggestion) { change { $0.never(suggestion) } }

    public func allowSuggestions(_ pattern: URLPattern) {
        change { $0.neverSuggest.removeAll { $0 == pattern } }
    }

    public func removeSpace(_ id: String) { change { $0.removeSpace(id) } }

    public func setDefaultBrowserOffered() {
        guard !state.defaultBrowserOffered else { return }
        change { $0.defaultBrowserOffered = true }
    }

    // MARK: Saving

    private func change(_ body: (inout RoutingState) -> Void) {
        var next = state
        body(&next)
        guard next != state else { return }
        state = next
        save()
    }

    private func save() {
        guard canSave else { return }
        do {
            let data = try JSONEncoder.routing.encode(state)
            let dir = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let temp = dir.appendingPathComponent(".routing-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard rename(temp.path, fileURL.path) == 0 else {
                try? FileManager.default.removeItem(at: temp)
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            NSLog("iSmith: routing.json couldn't be saved (\(error))")
        }
    }
}

extension JSONEncoder {
    static var routing: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var routing: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
