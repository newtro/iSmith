import Foundation

/// A routing rule: links matching `pattern` open in `space`. Rules are ordered; the first match
/// wins.
public struct RoutingRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var pattern: URLPattern
    public var space: String

    public init(id: UUID = UUID(), pattern: URLPattern, space: String) {
        (self.id, self.pattern, self.space) = (id, pattern, space)
    }
}

/// Hosts whose address is the same for every tenant or account, so the URL alone can't say which
/// space a link belongs to (an Outlook link from Teams is just `outlook.office.com/mail/…`). With
/// no rule, these open in the space where you last used that host.
public enum SharedAddressHosts {
    public static let patterns: [URLPattern] = [
        "outlook.office.com", "outlook.office365.com", "*.office.com",
        "teams.microsoft.com", "*.cloud.microsoft", "mail.google.com",
    ].map { try! URLPattern(parsing: $0) }

    /// The key "last used" is kept under: the normalized host, if `url` is one of these hosts.
    public static func key(for url: URL) -> String? {
        guard let host = url.host, patterns.contains(where: { $0.matches(url) }) else { return nil }
        return URLPattern.normalizedHost(host)
    }
}

/// Where a link goes, and why.
public struct Route: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The first rule that matched.
        case rule(UUID)
        /// A shared-address host (Outlook, Teams, Gmail): the space it was last used in.
        case lastUsed
        /// The Default space (or the first space, when none is set).
        case defaultSpace
    }

    public var space: String
    public var reason: Reason
}

/// A rule iSmith offers after you moved links of one kind into one space twice.
public struct RuleSuggestion: Equatable, Hashable, Identifiable, Sendable {
    public var pattern: URLPattern
    public var space: String
    public var id: String { "\(pattern)→\(space)" }

    public init(pattern: URLPattern, space: String) {
        (self.pattern, self.space) = (pattern, space)
    }
}

/// A tab that came from another app and was moved into another space: what the learning counts.
public struct LearnedMove: Codable, Equatable, Sendable {
    /// The tab (one link counts once, wherever it ends up).
    public var link: UUID
    /// Normalized host.
    public var host: String
    /// First path segment, lowercased; nil at the site's root.
    public var segment: String?
    public var space: String
    public var at: Date
}

/// Everything in routing.json.
public struct RoutingState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Learned moves kept (oldest dropped first).
    public static let maxMoves = 200

    public var version = RoutingState.currentVersion
    public var rules: [RoutingRule] = []
    /// The space for links nothing else claims. nil, or a deleted space, means the first space.
    public var defaultSpace: String?
    /// Shared-address host → the space it was last used in.
    public var lastUsed: [String: String] = [:]
    public var moves: [LearnedMove] = []
    /// Suggestions turned off with "Never".
    public var neverSuggest: [URLPattern] = []
    /// The first-run "Make iSmith your default browser" bar was shown and answered.
    public var defaultBrowserOffered = false

    public init() {}

    // MARK: Routing

    /// The space a link opens in: the first matching rule, else the space a shared-address host was
    /// last used in, else the Default space, else the first space. Rules and saved spaces that
    /// point at a deleted space are skipped. nil only when `spaces` is empty.
    /// - Parameter spaces: the spaces that exist, in rail order.
    public func route(_ url: URL, spaces: [String]) -> Route? {
        if let rule = matchingRule(for: url, spaces: spaces) {
            return Route(space: rule.space, reason: .rule(rule.id))
        }
        if let key = SharedAddressHosts.key(for: url), let space = lastUsed[key], spaces.contains(space) {
            return Route(space: space, reason: .lastUsed)
        }
        return effectiveDefaultSpace(in: spaces).map { Route(space: $0, reason: .defaultSpace) }
    }

    public func matchingRule(for url: URL, spaces: [String]) -> RoutingRule? {
        rules.first { spaces.contains($0.space) && $0.pattern.matches(url) }
    }

    public func effectiveDefaultSpace(in spaces: [String]) -> String? {
        if let d = defaultSpace, spaces.contains(d) { return d }
        return spaces.first
    }

    // MARK: Last used

    /// Notes that a shared-address host was used in a space. Returns whether anything changed.
    @discardableResult
    public mutating func noteUse(_ url: URL, space: String) -> Bool {
        guard let key = SharedAddressHosts.key(for: url), lastUsed[key] != space else { return false }
        lastUsed[key] = space
        return true
    }

    // MARK: Learning

    /// Records that a tab which arrived from another app (opened at `url`) was moved into `space`.
    /// Returns a rule to offer once the same kind of link has been moved there twice:
    /// - the same host and first path segment twice → `host/segment` (`dev.azure.com/contoso-dev`);
    /// - the same host twice with different first segments, and never to another space → `host`.
    /// Shared-address hosts are never learned (the last-used space covers them), and nothing is
    /// offered that an existing rule already does, or that was answered "Never".
    public mutating func recordMove(link: UUID, url: URL, to space: String, spaces: [String],
                                    at now: Date = Date()) -> RuleSuggestion? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = url.host, !rawHost.isEmpty, SharedAddressHosts.key(for: url) == nil else { return nil }
        let host = URLPattern.normalizedHost(rawHost)
        let segment = Self.firstSegment(of: url)
        moves.removeAll { $0.link == link }
        // Whole seconds, as routing.json keeps them.
        let at = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        moves.append(LearnedMove(link: link, host: host, segment: segment, space: space, at: at))
        if moves.count > Self.maxMoves { moves.removeFirst(moves.count - Self.maxMoves) }
        return suggestion(host: host, segment: segment, space: space, url: url, spaces: spaces)
    }

    private func suggestion(host: String, segment: String?, space: String, url: URL, spaces: [String]) -> RuleSuggestion? {
        let hostMoves = moves.filter { $0.host == host }
        let candidate: URLPattern
        if hostMoves.filter({ $0.segment == segment && $0.space == space }).count >= 2 {
            candidate = URLPattern(host: host, pathPrefix: segment.map { "/" + $0 } ?? "")
        } else if hostMoves.filter({ $0.space == space }).count >= 2, hostMoves.allSatisfy({ $0.space == space }) {
            candidate = URLPattern(host: host)
        } else {
            return nil
        }
        guard !neverSuggest.contains(candidate),
              matchingRule(for: url, spaces: spaces)?.space != space,
              !rules.contains(where: { $0.pattern == candidate && $0.space == space }) else { return nil }
        return RuleSuggestion(pattern: candidate, space: space)
    }

    /// "Accept": adds the rule ahead of the first rule that would otherwise catch these links, so
    /// it takes effect; with none, at the end.
    public mutating func accept(_ suggestion: RuleSuggestion) -> RoutingRule {
        let rule = RoutingRule(pattern: suggestion.pattern, space: suggestion.space)
        let sample = URL(string: "https://\(suggestion.pattern.host)\(suggestion.pattern.pathPrefix)")
        let index = sample.flatMap { url in rules.firstIndex { $0.pattern.matches(url) } } ?? rules.endIndex
        rules.insert(rule, at: index)
        forgetMoves(for: suggestion)
        return rule
    }

    /// "Not now": the moves behind it are forgotten, so it's offered again only after two more.
    public mutating func postpone(_ suggestion: RuleSuggestion) {
        forgetMoves(for: suggestion)
    }

    /// "Never": this pattern isn't offered again (Settings can undo it).
    public mutating func never(_ suggestion: RuleSuggestion) {
        if !neverSuggest.contains(suggestion.pattern) { neverSuggest.append(suggestion.pattern) }
        forgetMoves(for: suggestion)
    }

    private mutating func forgetMoves(for suggestion: RuleSuggestion) {
        let p = suggestion.pattern
        moves.removeAll { move in
            move.host == p.host && move.space == suggestion.space
                && (p.pathPrefix.isEmpty || "/" + (move.segment ?? "") == p.pathPrefix)
        }
    }

    static func firstSegment(of url: URL) -> String? {
        url.pathComponents.first { $0 != "/" && !$0.isEmpty }.map { $0.lowercased() }
    }

    // MARK: Spaces

    /// A space was deleted: its rules, last-used entries and learned moves go, and the Default
    /// space falls back to the first space if it was this one.
    public mutating func removeSpace(_ id: String) {
        rules.removeAll { $0.space == id }
        lastUsed = lastUsed.filter { $0.value != id }
        moves.removeAll { $0.space == id }
        if defaultSpace == id { defaultSpace = nil }
    }

    // MARK: Codable (lenient: a rule that no longer parses is dropped, not the whole file)

    private enum CodingKeys: String, CodingKey {
        case version, rules, defaultSpace, lastUsed, moves, neverSuggest, defaultBrowserOffered
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        rules = (try c.decodeIfPresent([Lossy<RoutingRule>].self, forKey: .rules) ?? []).compactMap(\.value)
        defaultSpace = try c.decodeIfPresent(String.self, forKey: .defaultSpace)
        lastUsed = try c.decodeIfPresent([String: String].self, forKey: .lastUsed) ?? [:]
        moves = (try c.decodeIfPresent([Lossy<LearnedMove>].self, forKey: .moves) ?? []).compactMap(\.value)
        neverSuggest = (try c.decodeIfPresent([Lossy<URLPattern>].self, forKey: .neverSuggest) ?? []).compactMap(\.value)
        defaultBrowserOffered = try c.decodeIfPresent(Bool.self, forKey: .defaultBrowserOffered) ?? false
    }
}
