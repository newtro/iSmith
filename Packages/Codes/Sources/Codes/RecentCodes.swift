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
        /// Its WebOTP domain couldn't be used (PROTOCOL.md §5 fails closed): never offered.
        var neverOffer = false
    }

    private var items: [Item] = []

    public init() {}

    public func add(_ message: CodeMessage, receivedAt: Date) {
        items.removeAll { $0.offer.id == message.id }
        items.insert(Item(offer: CodeOffer(id: message.id, code: message.code, sender: message.sender,
                                           domain: message.domain, receivedAt: receivedAt),
                          neverOffer: message.bindingUnusable), at: 0)
    }

    /// The code with this id, if it's still kept (the notification's Copy).
    public func code(id: String, now: Date = Date()) -> CodeOffer? {
        expire(now: now)
        return items.first { $0.offer.id == id }?.offer
    }

    /// Unused codes that may be offered on a page whose top-level host is `host`: a domain-bound
    /// code only when the host is the domain or a subdomain of it; an unbound code for 2 minutes
    /// after it arrived. A host that isn't a plain host name (see `Hostname.normalize`) gets none.
    public func offers(for host: String, now: Date = Date()) -> [CodeOffer] {
        expire(now: now)
        guard let page = Hostname.normalize(host) else { return [] }
        return items.filter { item in
            guard !item.used, !item.neverOffer else { return false }
            if let domain = item.offer.domain {
                return Self.host(page, isWithin: domain)
            }
            return now.timeIntervalSince(item.offer.receivedAt) <= Self.unboundOfferWindow
        }.map(\.offer)
    }

    /// Every code still kept, used or not (in the agent only: the notification's Copy, tests).
    public func all(now: Date = Date()) -> [CodeOffer] {
        expire(now: now)
        return items.map(\.offer)
    }

    public func markUsed(_ id: String) {
        for i in items.indices where items[i].offer.id == id { items[i].used = true }
    }

    public func removeAll() { items.removeAll() }

    func expire(now: Date) {
        items.removeAll { now.timeIntervalSince($0.offer.receivedAt) > Self.lifetime }
    }

    /// `login.chase.com` is within `chase.com`; `evilchase.com` and `chase.com.evil.net` are not.
    public static func host(_ host: String, isWithin domain: String) -> Bool {
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
}
