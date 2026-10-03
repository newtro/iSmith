import Foundation
import WebKit

/// Keeps each account's sign-in cookies the same across every open space bound to that account.
///
/// All work runs through one serial queue, so a scan, a push and an attach never interleave.
/// For each open space and account, `baseline` holds the cookies that space had right after it was
/// last synced. A reconcile merges only what each space changed since its baseline (its delta)
/// into the vault, writes the result to every open space bound to the account, and re-reads each
/// space to set its new baseline. As a result:
/// - a stale snapshot can't overwrite a newer sign-in: unchanged cookies aren't part of a delta;
/// - a cookie WebKit refuses to store is logged, not read back as a deletion and spread;
/// - change notifications caused by our own writes find no delta and do nothing.
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
    private var observers: [String: StoreObserver] = [:]
    private var attachTasks: [String: Task<WKWebsiteDataStore, Never>] = [:]
    private var pendingScan: [String: Task<Void, Never>] = [:]
    private var baseline: [String: [String: [String: CookieRecord]]] = [:]
    private var tail: Task<Void, Never>?

    init(vault: Vault, spaces: [Space]) {
        self.vault = vault
        self.spaces = spaces
    }

    /// Opens the space's store and seeds it from the vault. Every caller waits for seeding to
    /// finish, so no page loads signed out.
    func attach(_ space: Space) async -> WKWebsiteDataStore {
        if let store = stores[space.id] { return store }
        if let task = attachTasks[space.id] { return await task.value }
        let task = Task { await self.enqueue { await self.performAttach(space) } }
        attachTasks[space.id] = task
        let store = await task.value
        attachTasks[space.id] = nil
        // Adopts cookies for accounts the vault hasn't seen yet and shares them with open spaces.
        scheduleScan(space.id)
        return store
    }

    /// Merges every open space's latest changes into the vault. Called before quitting.
    func flush() async {
        await enqueue {
            for account in Seed.accounts { await self.reconcile(account) }
        }
    }

    func rescanAll() {
        for id in stores.keys { scheduleScan(id) }
    }

    // MARK: - Queue

    private func enqueue<T>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func scheduleScan(_ spaceID: String) {
        pendingScan[spaceID]?.cancel()
        pendingScan[spaceID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self,
                  let space = self.spaces.first(where: { $0.id == spaceID }) else { return }
            await self.enqueue {
                for account in space.accounts { await self.reconcile(account) }
            }
        }
    }

    // MARK: - Work (only ever runs on the queue)

    private func performAttach(_ space: Space) async -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore(forIdentifier: space.storeID)
        for account in space.accounts {
            guard let saved = vault.records(for: account.id) else { continue }
            let writes = await apply(keyed(saved), removing: [], provider: account.provider, to: store)
            note("\(space.name): loaded \(account.label) from vault (\(saved.count) cookies, \(writes) written)")
        }
        let cookies = await store.httpCookieStore.allCookies()
        for account in space.accounts {
            // An account the vault hasn't seen gets an empty baseline, so the next reconcile treats
            // the store's existing cookies as new and adopts them.
            baseline[space.id, default: [:]][account.id] =
                vault.records(for: account.id) == nil ? [:] : keyed(records(in: cookies, for: account.provider))
        }
        let observer = StoreObserver { [weak self] in self?.scheduleScan(space.id) }
        observers[space.id] = observer
        store.httpCookieStore.add(observer)
        stores[space.id] = store
        attached.insert(space.id)
        return store
    }

    private func reconcile(_ account: Account) async {
        let members = spaces.filter { $0.accounts.contains(account) && stores[$0.id] != nil }
        guard !members.isEmpty else { return }
        let before = keyed(vault.records(for: account.id) ?? [])
        var merged = before
        var removed = Set<String>()
        var changedIn: [String] = []

        for space in members {
            let current = keyed(records(in: await stores[space.id]!.httpCookieStore.allCookies(), for: account.provider))
            let base = baseline[space.id]?[account.id] ?? [:]
            var touched = false
            for (key, record) in current where base[key] != record {
                merged[key] = record
                removed.remove(key)
                touched = true
            }
            for key in base.keys where current[key] == nil {
                merged[key] = nil
                removed.insert(key)
                touched = true
            }
            if touched { changedIn.append(space.name) }
        }
        guard !changedIn.isEmpty else { return }

        if merged != before || vault.records(for: account.id) == nil {
            vault.set(Array(merged.values), for: account.id)
        }
        for space in members {
            let store = stores[space.id]!
            await apply(merged, removing: removed, provider: account.provider, to: store)
            let after = keyed(records(in: await store.httpCookieStore.allCookies(), for: account.provider))
            baseline[space.id, default: [:]][account.id] = after
            let refused = merged.values.filter { !$0.isExpired && after[$0.key] != $0 }.map(\.name)
            if !refused.isEmpty {
                note("\(space.name): WebKit kept a different \(account.label) cookie for \(refused.joined(separator: ", "))")
            }
        }
        let others = members.map(\.name).filter { !changedIn.contains($0) }
        let change = Diff(from: before, to: merged)
        if !change.isEmpty {
            note("\(account.label) changed in \(changedIn.joined(separator: ", ")): \(change.summary)"
                 + (others.isEmpty ? "" : " → \(others.joined(separator: ", "))"))
        }
    }

    /// Writes `want` into the store and deletes the keys in `removing`. Cookies are overwritten in
    /// place, never deleted and re-added, so a live page never sees its session cookie missing.
    @discardableResult
    private func apply(_ want: [String: CookieRecord], removing: Set<String>, provider: Provider,
                       to store: WKWebsiteDataStore) async -> Int {
        var have: [String: (record: CookieRecord, cookie: HTTPCookie)] = [:]
        for cookie in await store.httpCookieStore.allCookies() where provider.tracks(cookie) {
            let record = CookieRecord(cookie)
            have[record.key] = (record, cookie)
        }
        var writes = 0
        for key in removing {
            if let existing = have[key] {
                await store.httpCookieStore.deleteCookie(existing.cookie)
                writes += 1
            }
        }
        for (key, record) in want where !record.isExpired && have[key]?.record != record {
            guard let cookie = record.cookie else {
                note("Could not rebuild cookie \(record.name) for \(record.domain)")
                continue
            }
            await store.httpCookieStore.setCookie(cookie)
            writes += 1
        }
        return writes
    }

    private func records(in cookies: [HTTPCookie], for provider: Provider) -> [CookieRecord] {
        cookies.filter(provider.tracks).map(CookieRecord.init).filter { !$0.isExpired }
    }

    private func keyed(_ records: [CookieRecord]) -> [String: CookieRecord] {
        Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func note(_ text: String) {
        log.append(LogLine(text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
        NSLog("iSmith sync: \(text)")
    }
}

private struct Diff {
    var added = 0, removed = 0, changed = 0

    init(from old: [String: CookieRecord], to new: [String: CookieRecord]) {
        for (key, value) in new {
            if let prior = old[key] { if prior != value { changed += 1 } } else { added += 1 }
        }
        removed = old.keys.filter { new[$0] == nil }.count
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
