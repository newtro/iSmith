import CodesXPC
import Foundation

/// The codes received in the last 10 minutes, in memory only (never written to disk), newest
/// first. What may be offered on a page follows PROTOCOL.md §5.
public final class RecentCodes {
    /// How long a code is kept at all.
    public static let lifetime: TimeInterval = 10 * 60
    /// How long a code with no WebOTP domain is offered on any one-time-code field.
    public static let unboundOfferWindow: TimeInterval = 2 * 60

    struct Item {
        var offer: CodeOffer
        var used = false
    }

    private var items: [Item] = []

    public init() {}

    public func add(_ message: CodeMessage, receivedAt: Date) {
        items.removeAll { $0.offer.id == message.id }
        items.insert(Item(offer: CodeOffer(id: message.id, code: message.code, sender: message.sender,
                                           domain: message.domain, receivedAt: receivedAt)), at: 0)
    }

    /// The code with this id, if it's still kept (the notification's Copy).
    public func code(id: String, now: Date = Date()) -> CodeOffer? {
        expire(now: now)
        return items.first { $0.offer.id == id }?.offer
    }

    /// With a host: unused codes that may be offered on a page whose top-level host is `host`.
    /// A domain-bound code only when the host is the domain or a subdomain of it; an unbound code
    /// for 2 minutes after it arrived. With nil: every code still kept, used or not.
    public func offers(for host: String?, now: Date = Date()) -> [CodeOffer] {
        expire(now: now)
        guard let host else { return items.map(\.offer) }
        let page = Self.normalize(host)
        guard !page.isEmpty else { return [] }
        return items.filter { item in
            guard !item.used else { return false }
            if let domain = item.offer.domain {
                return Self.host(page, isWithin: Self.normalize(domain))
            }
            return now.timeIntervalSince(item.offer.receivedAt) <= Self.unboundOfferWindow
        }.map(\.offer)
    }

    public func markUsed(_ id: String) {
        for i in items.indices where items[i].offer.id == id { items[i].used = true }
    }

    public func removeAll() { items.removeAll() }

    func expire(now: Date) {
        items.removeAll { now.timeIntervalSince($0.offer.receivedAt) > Self.lifetime }
    }

    /// Lowercased, without a trailing dot.
    static func normalize(_ host: String) -> String {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// `login.chase.com` is within `chase.com`; `evilchase.com` and `chase.com.evil.net` are not.
    public static func host(_ host: String, isWithin domain: String) -> Bool {
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
}
