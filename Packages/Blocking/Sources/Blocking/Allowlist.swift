import Foundation
import PublicSuffixList

/// Sites where blocking is off, saved as `allowlist.json`. A site is a registrable domain
/// (eTLD+1), so allowing `www.cnn.com` also covers `edition.cnn.com`, as Brave's Shields do.
/// IP addresses and single-label hosts such as `localhost` are their own site.
struct Allowlist {
    let fileURL: URL
    private(set) var sites: Set<String> = []

    private struct File: Codable {
        var version = 1
        var sites: [String]
    }

    /// Loads the file. One that can't be read is copied aside (`allowlist.unreadable-<time>.json`)
    /// and the allowlist starts empty, so a damaged file never blocks a launch.
    init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let file = try? JSONDecoder().decode(File.self, from: data) {
            sites = Set(file.sites.compactMap(Self.site(for:)))
        } else {
            _ = try? DiskFile.backUp(fileURL, reason: "unreadable")
        }
    }

    func contains(host: String) -> Bool {
        guard let site = Self.site(for: host) else { return false }
        return sites.contains(site)
    }

    /// Adds or removes the host's site and saves. Returns false if nothing changed.
    mutating func set(host: String, allowed: Bool) throws -> Bool {
        guard let site = Self.site(for: host) else { return false }
        let changed = allowed ? sites.insert(site).inserted : sites.remove(site) != nil
        guard changed else { return false }
        let data = try JSONEncoder.sorted.encode(File(sites: sites.sorted()))
        try DiskFile.write(data, to: fileURL)
        return true
    }

    /// The site key for a host: lowercased, without a trailing dot or IPv6 brackets, then reduced
    /// to its registrable domain. Nil for an empty host.
    static func site(for host: String) -> String? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        guard !h.isEmpty else { return nil }
        if h.contains(":") || isIPv4(h) || !h.contains(".") { return h }
        return PublicSuffixList.effectiveTLDPlusOne(h) ?? h
    }

    private static func isIPv4(_ h: String) -> Bool {
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
