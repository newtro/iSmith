import Foundation
import WebKit

/// Keeps each account's provider cookies identical across every space bound to that account.
///
/// - On attach, a space's store is made to match the vault (or, the first time an account is seen,
///   its existing cookies are adopted into the vault).
/// - When a store's cookies change, the provider cookies for each bound account are compared with
///   the vault. A difference updates the vault and is pushed to the other attached spaces bound to
///   the same account.
/// - While a store is being written to, its own change notifications are ignored so a half-applied
///   set never flows back into the vault. One rescan runs after the write finishes.
@MainActor
final class CookieSync: ObservableObject {
    struct LogLine: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    @Published private(set) var log: [LogLine] = []
    @Published private(set) var attached: Set<String> = []

    let vault: Vault
    private let spaces: [Space]
    private var stores: [String: WKWebsiteDataStore] = [:]
    private var attaching: [String: Task<WKWebsiteDataStore, Never>] = [:]
    private var observers: [String: StoreObserver] = [:]
    private var suppress: [String: Int] = [:]
    private var pendingScan: [String: Task<Void, Never>] = [:]

    init(vault: Vault, spaces: [Space]) {
        self.vault = vault
        self.spaces = spaces
    }

    /// Opens the space's store and seeds it from the vault. Safe to call repeatedly; every caller
    /// waits for the same seeding to finish before loading pages.
    func attach(_ space: Space) async -> WKWebsiteDataStore {
        if let store = stores[space.id] { return store }
        if let task = attaching[space.id] { return await task.value }
        let task = Task { await self.performAttach(space) }
        attaching[space.id] = task
        let store = await task.value
        attaching[space.id] = nil
        return store
    }

    private func performAttach(_ space: Space) async -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore(forIdentifier: space.storeID)
        suppress[space.id, default: 0] += 1
        let cookies = await store.httpCookieStore.allCookies()
        for account in space.accounts {
            if let saved = vault.records(for: account.id) {
                let changed = await apply(saved, provider: account.provider, to: store, current: cookies)
                note("\(space.name): loaded \(account.label) from vault (\(saved.count) cookies, \(changed) written)")
            } else {
                let local = records(in: cookies, for: account.provider)
                if !local.isEmpty {
                    vault.set(local, for: account.id)
                    note("\(space.name): adopted \(local.count) existing \(account.label) cookies")
                }
            }
        }
        let observer = StoreObserver { [weak self] in self?.scheduleScan(space.id) }
        observers[space.id] = observer
        store.httpCookieStore.add(observer)
        stores[space.id] = store
        attached.insert(space.id)
        await release(space.id)
        return store
    }

    func rescanAll() {
        for id in stores.keys { scheduleScan(id) }
    }

    // MARK: - Change handling

    private func scheduleScan(_ spaceID: String) {
        guard suppress[spaceID, default: 0] == 0 else { return }
        pendingScan[spaceID]?.cancel()
        pendingScan[spaceID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.scan(spaceID)
        }
    }

    private func scan(_ spaceID: String) async {
        guard let space = spaces.first(where: { $0.id == spaceID }), let store = stores[spaceID],
              suppress[spaceID, default: 0] == 0 else { return }
        let cookies = await store.httpCookieStore.allCookies()
        guard suppress[spaceID, default: 0] == 0 else { return }
        for account in space.accounts {
            let current = records(in: cookies, for: account.provider)
            let saved = vault.records(for: account.id) ?? []
            let change = Diff(from: saved, to: current)
            guard !change.isEmpty else { continue }
            vault.set(current, for: account.id)
            let targets = spaces.filter { $0.id != spaceID && $0.accounts.contains(account) && stores[$0.id] != nil }
            let pushed = targets.isEmpty ? "" : " → pushed to \(targets.map(\.name).joined(separator: ", "))"
            note("\(account.label) changed in \(space.name): \(change.summary)\(pushed)")
            for target in targets {
                await push(current, provider: account.provider, to: target)
            }
        }
    }

    private func push(_ records: [CookieRecord], provider: Provider, to space: Space) async {
        guard let store = stores[space.id] else { return }
        suppress[space.id, default: 0] += 1
        let cookies = await store.httpCookieStore.allCookies()
        await apply(records, provider: provider, to: store, current: cookies)
        await release(space.id)
    }

    /// Ends one suppression after WebKit's change notifications for the write have arrived, then
    /// rescans once so a real change made by a page during the write is not lost.
    private func release(_ spaceID: String) async {
        try? await Task.sleep(nanoseconds: 700_000_000)
        suppress[spaceID, default: 1] -= 1
        if suppress[spaceID] == 0 { scheduleScan(spaceID) }
    }

    /// Makes the store's cookies for `provider` exactly equal to `records`. Returns how many
    /// cookies were written or deleted.
    @discardableResult
    private func apply(_ records: [CookieRecord], provider: Provider, to store: WKWebsiteDataStore,
                       current: [HTTPCookie]) async -> Int {
        let want = Dictionary(records.filter { !$0.isExpired }.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var have: [String: CookieRecord] = [:]
        var writes = 0
        for cookie in current where provider.owns(cookieDomain: cookie.domain) {
            let record = CookieRecord(cookie)
            have[record.key] = record
            if want[record.key] != record {
                await store.httpCookieStore.deleteCookie(cookie)
                writes += 1
            }
        }
        for (key, record) in want where have[key] != record {
            if let cookie = record.cookie {
                await store.httpCookieStore.setCookie(cookie)
                writes += 1
            }
        }
        return writes
    }

    private func records(in cookies: [HTTPCookie], for provider: Provider) -> [CookieRecord] {
        cookies.filter { provider.owns(cookieDomain: $0.domain) }.map(CookieRecord.init).filter { !$0.isExpired }
    }

    private func note(_ text: String) {
        log.append(LogLine(text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
        NSLog("iSmith sync: \(text)")
    }
}

private struct Diff {
    var added = 0, removed = 0, changed = 0

    init(from old: [CookieRecord], to new: [CookieRecord]) {
        let a = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { x, _ in x })
        let b = Dictionary(new.map { ($0.key, $0) }, uniquingKeysWith: { x, _ in x })
        for (key, value) in b {
            if let prior = a[key] { if prior != value { changed += 1 } } else { added += 1 }
        }
        removed = a.keys.filter { b[$0] == nil }.count
    }

    var isEmpty: Bool { added + removed + changed == 0 }
    var summary: String { "+\(added) −\(removed) ~\(changed)" }
}

private final class StoreObserver: NSObject, WKHTTPCookieStoreObserver {
    let onChange: @MainActor () -> Void

    init(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.onChange() }
    }
}
