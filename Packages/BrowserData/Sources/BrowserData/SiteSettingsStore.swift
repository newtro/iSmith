import Foundation
import GRDB

/// Per-site settings, shared by every space: permission decisions (keyed by origin), page zoom
/// (keyed by host) and what to do with links to other apps (keyed by URL scheme).
///
/// Origins are strings like "https://teams.microsoft.com" or "https://localhost:8443": lowercase
/// scheme and host, the port only when it isn't the scheme's default. Use `originKey` to make
/// them. Posts `SiteSettingsStore.didChange` on the main queue after each change.
public final class SiteSettingsStore: @unchecked Sendable {
    /// Posted on the main queue after any site setting changes.
    public static let didChange = Notification.Name("BrowserData.SiteSettingsStore.didChange")

    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: Origins

    /// "scheme://host[:port]", lowercased, without the scheme's default port. A port of 0 or less
    /// means none (WebKit's `WKSecurityOrigin.port` is 0 for the default). IPv6 hosts get brackets.
    public static func originKey(scheme: String, host: String, port: Int) -> String {
        let scheme = scheme.lowercased()
        var host = host.lowercased()
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        let defaults = ["http": 80, "https": 443, "ws": 80, "wss": 443]
        if port > 0, defaults[scheme] != port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// The origin key of a URL, or nil when it has no scheme or host.
    public static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host, !host.isEmpty else { return nil }
        return originKey(scheme: scheme, host: host, port: url.port ?? 0)
    }

    // MARK: Permissions

    /// The saved decision for a permission on an origin, or nil to ask.
    public func decision(_ permission: SitePermission, origin: String) throws -> PermissionDecision? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT decision FROM site_permission WHERE origin = ? AND permission = ?",
                                arguments: [origin, permission.rawValue])
                .flatMap(PermissionDecision.init(rawValue:))
        }
    }

    /// Saves a decision; nil removes it (the site will be asked again).
    public func setDecision(_ decision: PermissionDecision?, for permission: SitePermission, origin: String) throws {
        try writer.write { db in
            if let decision {
                try db.execute(sql: """
                    INSERT INTO site_permission (origin, permission, decision, updated) VALUES (?, ?, ?, ?)
                    ON CONFLICT (origin, permission) DO UPDATE SET decision = excluded.decision, updated = excluded.updated
                    """, arguments: [origin, permission.rawValue, decision.rawValue, Date().seconds])
            } else {
                try db.execute(sql: "DELETE FROM site_permission WHERE origin = ? AND permission = ?",
                               arguments: [origin, permission.rawValue])
            }
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: nil)
    }

    /// Every saved permission decision, by origin and then permission, for the settings list.
    public func allDecisions() throws -> [SitePermissionEntry] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM site_permission ORDER BY origin, permission").compactMap { row in
                guard let p = SitePermission(rawValue: row["permission"]),
                      let d = PermissionDecision(rawValue: row["decision"]) else { return nil }
                return SitePermissionEntry(origin: row["origin"], permission: p, decision: d,
                                           updated: Date(seconds: row["updated"]))
            }
        }
    }

    // MARK: Zoom

    /// The saved page zoom for a host (case-insensitive), or nil for 100%.
    public func zoom(host: String) throws -> Double? {
        try writer.read { db in
            try Double.fetchOne(db, sql: "SELECT factor FROM site_zoom WHERE host = ?", arguments: [host.lowercased()])
        }
    }

    /// Saves a host's page zoom. Nil or 1.0 removes it; zero, negative or non-finite throws
    /// `.invalidValue`.
    public func setZoom(_ factor: Double?, host: String) throws {
        if let factor, !(factor.isFinite && factor > 0) { throw BrowserDataError.invalidValue }
        try writer.write { db in
            if let factor, abs(factor - 1) > 0.0001 {
                try db.execute(sql: """
                    INSERT INTO site_zoom (host, factor) VALUES (?, ?)
                    ON CONFLICT (host) DO UPDATE SET factor = excluded.factor
                    """, arguments: [host.lowercased(), factor])
            } else {
                try db.execute(sql: "DELETE FROM site_zoom WHERE host = ?", arguments: [host.lowercased()])
            }
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: nil)
    }

    /// Every saved zoom, by host.
    public func allZooms() throws -> [String: Double] {
        try writer.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT host, factor FROM site_zoom")
                .map { ($0["host"] as String, $0["factor"] as Double) })
        }
    }

    // MARK: App links

    /// What to do with links to `scheme` (case-insensitive, with or without the colon), or nil to ask.
    public func appLinkDecision(scheme: String) throws -> AppLinkDecision? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT decision FROM app_link WHERE scheme = ?",
                                arguments: [Self.normalize(scheme: scheme)])
                .flatMap(AppLinkDecision.init(rawValue:))
        }
    }

    /// Saves what to do with links to `scheme`; nil removes it.
    public func setAppLinkDecision(_ decision: AppLinkDecision?, scheme: String) throws {
        let scheme = Self.normalize(scheme: scheme)
        try writer.write { db in
            if let decision {
                try db.execute(sql: """
                    INSERT INTO app_link (scheme, decision, updated) VALUES (?, ?, ?)
                    ON CONFLICT (scheme) DO UPDATE SET decision = excluded.decision, updated = excluded.updated
                    """, arguments: [scheme, decision.rawValue, Date().seconds])
            } else {
                try db.execute(sql: "DELETE FROM app_link WHERE scheme = ?", arguments: [scheme])
            }
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: nil)
    }

    /// Every saved app link decision, by lowercase scheme.
    public func allAppLinkDecisions() throws -> [String: AppLinkDecision] {
        try writer.read { db in
            var result: [String: AppLinkDecision] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT scheme, decision FROM app_link") {
                if let d = AppLinkDecision(rawValue: row["decision"]) { result[row["scheme"]] = d }
            }
            return result
        }
    }

    private static func normalize(scheme: String) -> String {
        var s = scheme.lowercased().trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(":") { s.removeLast() }
        return s
    }
}

/// A permission a site can ask for.
public enum SitePermission: String, CaseIterable, Sendable {
    case camera, microphone, cameraAndMicrophone, location, notifications
}

public enum PermissionDecision: String, CaseIterable, Sendable {
    case allow, deny
}

/// What to do with a link that opens another app (msteams:, mailto:, zoommtg: ...).
public enum AppLinkDecision: String, CaseIterable, Sendable {
    case open, block
}

/// One saved permission decision.
public struct SitePermissionEntry: Equatable, Sendable {
    public let origin: String
    public let permission: SitePermission
    public let decision: PermissionDecision
    public let updated: Date
}
