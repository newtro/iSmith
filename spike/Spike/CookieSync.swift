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
    /// Space id → providers someone signed in to in that space that it has no account for.
    @Published private(set) var detected: [String: Set<String>] = [:]

    /// How a space's account for a provider changed.
    enum Rebind {
        /// The space no longer uses an account for the provider; its cookies stay in the space.
        case unbind
        /// The space now uses the account; its current cookies are cleared and replaced by the
        /// account's (or left empty for a new account, ready to sign in).
        case replace
        /// The space's current sign-in becomes the account's (from "Save this sign-in").
        case adopt
    }

    let vault: Vault
    let config: Config
    private var stores: [String: WKWebsiteDataStore] = [:]
    private var observers: [String: StoreObserver] = [:]
    private var attachTasks: [String: Task<WKWebsiteDataStore, Never>] = [:]
    private var pendingScan: [String: Task<Void, Never>] = [:]
    private var scanSince: [String: Date] = [:]
    /// Space id → provider id → the provider cookies that space had right after its last sync.
    private var baseline: [String: [String: [String: CookieRecord]]] = [:]
    private var tail: Task<Void, Never>?

    init(vault: Vault, config: Config) {
        self.vault = vault
        self.config = config
    }

    /// Opens the space's store and seeds it from the vault. Every caller waits for seeding to
    /// finish, so no page loads signed out.
    func attach(_ space: SpaceDef) async -> WKWebsiteDataStore {
        if let store = stores[space.id] { return store }
        if let task = attachTasks[space.id] { return await task.value }
        let task = Task { await self.enqueue { await self.performAttach(space.id) } }
        attachTasks[space.id] = task
        let store = await task.value
        attachTasks[space.id] = nil
        // Shares newly adopted sign-ins with open spaces and checks for unsaved sign-ins.
        scheduleScan(space.id)
        return store
    }

    /// Applies a change to which account a space uses for a provider. Call after updating Config.
    func rebind(spaceID: String, providerID: String, _ change: Rebind) async {
        await enqueue { await self.performRebind(spaceID: spaceID, providerID: providerID, change) }
        scheduleScan(spaceID)
    }

    /// Signs the account out in every space: clears its cookies from the vault and all stores.
    func signOutEverywhere(_ accountID: String) async {
        await enqueue {
            guard let account = self.config.account(accountID), let provider = self.config.provider(account.providerID) else { return }
            self.vault.set([], for: accountID)
            for space in self.config.spaces(using: accountID) {
                guard let store = self.stores[space.id] else { continue } // closed spaces are cleared when opened
                let local = self.keyed(self.records(in: await store.httpCookieStore.allCookies(), for: provider))
                await self.apply([:], removing: Set(local.keys), provider: provider, to: store, current: local)
                self.baseline[space.id, default: [:]][provider.id] = [:]
            }
            self.note("\(self.config.label(account)): signed out everywhere")
        }
    }

    /// Detaches a space before it is deleted. Its tabs must already be closed.
    func detach(_ spaceID: String) async {
        await enqueue {
            if let store = self.stores[spaceID], let observer = self.observers[spaceID] {
                store.httpCookieStore.remove(observer)
            }
            self.pendingScan[spaceID]?.cancel()
            self.stores[spaceID] = nil
            self.observers[spaceID] = nil
            self.baseline[spaceID] = nil
            self.attached.remove(spaceID)
            self.detected[spaceID] = nil
        }
    }

    /// Hides the "save this sign-in" offer for a provider in a space.
    func dismissDetected(spaceID: String, providerID: String) {
        detected[spaceID]?.remove(providerID)
    }

    /// Merges every open space's latest changes into the vault. Called before quitting.
    func flush() async {
        await enqueue {
            for account in self.config.accounts { await self.reconcile(account.id) }
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

    /// Debounces bursts of changes, but never postpones a scan by more than two seconds, so a page
    /// that sets cookies constantly can't starve it.
    private func scheduleScan(_ spaceID: String) {
        if let since = scanSince[spaceID], Date().timeIntervalSince(since) > 2, pendingScan[spaceID] != nil { return }
        if scanSince[spaceID] == nil { scanSince[spaceID] = Date() }
        pendingScan[spaceID]?.cancel()
        pendingScan[spaceID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.pendingScan[spaceID] = nil
            self?.scanSince[spaceID] = nil
            guard let self else { return }
            await self.enqueue {
                guard let space = self.config.space(spaceID) else { return }
                for accountID in space.bindings.values { await self.reconcile(accountID) }
                await self.detect(spaceID)
            }
        }
    }

    // MARK: - Work (only ever runs on the queue)

    private func performAttach(_ spaceID: String) async -> WKWebsiteDataStore {
        let space = config.space(spaceID)!
        let store = WKWebsiteDataStore(forIdentifier: space.storeID)
        for (provider, account) in config.bound(space) {
            await seed(store, spaceName: space.name, provider: provider, account: account, adoptIfNew: true)
                .map { baseline[space.id, default: [:]][provider.id] = $0 }
        }
        let observer = StoreObserver { [weak self] in self?.scheduleScan(spaceID) }
        observers[space.id] = observer
        store.httpCookieStore.add(observer)
        stores[space.id] = store
        attached.insert(space.id)
        return store
    }

    /// Makes the store's cookies for the provider match the account's vault entry, and returns the
    /// space's new baseline. For an account the vault hasn't seen: with `adoptIfNew`, the store's
    /// current sign-in becomes the account's; otherwise the store is cleared, ready to sign in.
    private func seed(_ store: WKWebsiteDataStore, spaceName: String, provider: ProviderDef, account: AccountDef,
                      adoptIfNew: Bool) async -> [String: CookieRecord]? {
        let local = keyed(records(in: await store.httpCookieStore.allCookies(), for: provider))
        if let saved = vault.records(for: account.id) {
            // The vault is the source of truth: leftover cookies it doesn't have (an older
            // session, another account, or a sign-out elsewhere) are removed.
            let want = keyed(saved)
            let written = await apply(want, removing: Set(local.keys).subtracting(want.keys), provider: provider,
                                      to: store, current: local)
            note("\(spaceName): loaded \(config.label(account)) (\(saved.count) cookies, \(written.count) written)")
            return keyed(records(in: await store.httpCookieStore.allCookies(), for: provider))
        }
        if adoptIfNew && !local.isEmpty {
            // First sighting: adopt now, so a space opened next seeds from it. The empty baseline
            // makes the next reconcile share it with spaces that are already open.
            vault.set(Array(local.values), for: account.id)
            note("\(spaceName): saved existing sign-in as \(config.label(account))")
            return [:]
        }
        if !local.isEmpty {
            await apply([:], removing: Set(local.keys), provider: provider, to: store, current: local)
            note("\(spaceName): cleared \(provider.name) cookies, ready to sign in as \(config.label(account))")
        }
        return [:]
    }

    private func performRebind(spaceID: String, providerID: String, _ change: Rebind) async {
        guard let space = config.space(spaceID), let provider = config.provider(providerID) else { return }
        detected[spaceID]?.remove(providerID)
        let isOpen = stores[spaceID] != nil
        if case .unbind = change {
            baseline[spaceID]?[providerID] = nil
            note("\(space.name): \(provider.name) sign-ins now stay in this space")
            return
        }
        guard let account = space.bindings[providerID].flatMap(config.account) else { return }
        // A closed space's store is opened just to update its cookies; it is seeded again when opened.
        let store = stores[spaceID] ?? WKWebsiteDataStore(forIdentifier: space.storeID)
        switch change {
        case .adopt:
            let local = keyed(records(in: await store.httpCookieStore.allCookies(), for: provider))
            if vault.records(for: account.id) == nil { vault.set(Array(local.values), for: account.id) }
            // An empty baseline makes the next reconcile merge this sign-in and share it.
            if isOpen { baseline[spaceID, default: [:]][providerID] = [:] }
            note("\(space.name): saved this \(provider.name) sign-in as \(config.label(account))")
        case .replace:
            let next = await seed(store, spaceName: space.name, provider: provider, account: account, adoptIfNew: false)
            if isOpen { baseline[spaceID, default: [:]][providerID] = next }
        case .unbind:
            break
        }
    }

    private func detect(_ spaceID: String) async {
        guard let space = config.space(spaceID), let store = stores[spaceID] else { return }
        let cookies = await store.httpCookieStore.allCookies()
        let found = Set(config.providers.filter { p in
            space.bindings[p.id] == nil && !space.localProviders.contains(p.id) && cookies.contains(where: p.indicatesSignIn)
        }.map(\.id))
        if detected[spaceID] ?? [] != found { detected[spaceID] = found }
    }

    private func reconcile(_ accountID: String) async {
        guard let account = config.account(accountID), let provider = config.provider(account.providerID) else { return }
        let members = config.spaces(using: accountID).filter { stores[$0.id] != nil && $0.bindings[provider.id] == accountID }
        guard !members.isEmpty else { return }
        let label = config.label(account)
        let before = keyed(vault.records(for: account.id) ?? [])
        var merged = before
        var removed = Set<String>()
        var changedIn: [String] = []
        var currents: [String: [String: CookieRecord]] = [:]

        for space in members {
            let current = keyed(records(in: await stores[space.id]!.httpCookieStore.allCookies(), for: provider))
            currents[space.id] = current
            let base = baseline[space.id]?[provider.id] ?? [:]
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
            guard let store = stores[space.id] else { continue }
            let current = currents[space.id] ?? [:]
            let written = await apply(merged, removing: removed, provider: provider, to: store, current: current)
            let after = keyed(records(in: await store.httpCookieStore.allCookies(), for: provider))
            // Only keys we wrote take the re-read value. Anything else the page changed meanwhile
            // stays different from the baseline, so the next scan picks it up as a delta.
            var next = current
            for key in written { next[key] = after[key] }
            baseline[space.id, default: [:]][provider.id] = next
            let refused = written.compactMap { merged[$0] }.filter { !$0.isExpired && after[$0.key] != $0 }.map(\.name)
            if !refused.isEmpty {
                note("\(space.name): WebKit kept a different \(label) cookie for \(refused.joined(separator: ", "))")
            }
        }
        let others = members.map(\.name).filter { !changedIn.contains($0) }
        let change = Diff(from: before, to: merged)
        if !change.isEmpty {
            note("\(label) changed in \(changedIn.joined(separator: ", ")): \(change.summary)"
                 + (others.isEmpty ? "" : " → \(others.joined(separator: ", "))"))
        }
    }

    /// Writes `want` into the store and deletes the keys in `removing`, and returns the keys it
    /// touched. `current` is what the store held when it was last read; a key the page has changed
    /// since then is left alone (the page's newer value wins and is picked up by the next scan).
    /// Cookies are overwritten in place, never deleted and re-added, so a live page never sees its
    /// session cookie missing.
    @discardableResult
    private func apply(_ want: [String: CookieRecord], removing: Set<String>, provider: ProviderDef,
                       to store: WKWebsiteDataStore, current: [String: CookieRecord]) async -> Set<String> {
        var have: [String: (record: CookieRecord, cookie: HTTPCookie)] = [:]
        for cookie in await store.httpCookieStore.allCookies() where provider.tracks(cookie) {
            let record = CookieRecord(cookie)
            if !record.isExpired { have[record.key] = (record, cookie) }
        }
        var written = Set<String>()
        for key in removing where have[key]?.record == current[key] {
            if let existing = have[key] {
                await store.httpCookieStore.deleteCookie(existing.cookie)
                written.insert(key)
            }
        }
        for (key, record) in want where !record.isExpired && !removing.contains(key)
            && have[key]?.record != record && have[key]?.record == current[key] {
            guard let cookie = record.cookie else {
                note("Could not rebuild cookie \(record.name) for \(record.domain)")
                continue
            }
            await store.httpCookieStore.setCookie(cookie)
            written.insert(key)
        }
        return written
    }

    private func records(in cookies: [HTTPCookie], for provider: ProviderDef) -> [CookieRecord] {
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
