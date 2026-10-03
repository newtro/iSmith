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
///
/// When two spaces change the same cookie before a sync, the newer change wins, per cookie. Each
/// store's change notifications are diffed against what the sync last saw there (`seen`), and
/// every tracked cookie the page changed gets its own time (`changedAt`). Values the sync wrote
/// itself update `seen` without a time, so they never count as a page's change.
@MainActor
public final class CookieSync: ObservableObject {
    public struct LogLine: Identifiable {
        public let id = UUID()
        public let time = Date()
        public let text: String
    }

    @Published public private(set) var log: [LogLine] = []
    @Published public private(set) var attached: Set<String> = []

    public let vault: Vault
    public let config: Config
    private var stores: [String: WKWebsiteDataStore] = [:]
    private var observers: [String: StoreObserver] = [:]
    private var attachTasks: [String: Task<WKWebsiteDataStore, Never>] = [:]
    private var pendingScan: [String: Task<Void, Never>] = [:]
    private var scanSince: [String: Date] = [:]
    /// Space id → cookie key → the tracked cookie as the sync last saw it in that store, its own
    /// writes included. A later read that differs is a change the page made.
    private var seen: [String: [String: CookieRecord]] = [:]
    /// Space id → cookie key → when the page in that space last changed (or deleted) the cookie.
    /// When spaces disagree about a cookie, the newest change wins.
    private var changedAt: [String: [String: Date]] = [:]
    /// The first change notification from each store since the sync last read it. A change found
    /// by a read is dated by it (or by the read itself, if its notification hasn't arrived yet).
    /// Reads follow notifications at once, at most ten times a second per store, so a change is
    /// dated within about 0.1 s even when the page keeps setting other cookies.
    private var notifiedAt: [String: Date] = [:]
    /// When each store's last diff started, to space them out.
    private var diffedAt: [String: Date] = [:]
    /// Spaces with a diff waiting to run.
    private var diffPending: Set<String> = []
    static let diffSpacing: TimeInterval = 0.1
    /// Work queued or running, so tests can wait for the sync to go quiet.
    private var running = 0
    /// Space id → provider id → the provider cookies that space had right after its last sync.
    private var baseline: [String: [String: [String: CookieRecord]]] = [:]
    private var tail: Task<Void, Never>?

    /// Lets the browser refresh a space's state when sync changes its bindings.
    public var bindingChanged: ((SpaceDef) -> Void)?

    public init(vault: Vault, config: Config) {
        self.vault = vault
        self.config = config
    }

    /// Opens the space's store and seeds it from the vault. Every caller waits for seeding to
    /// finish, so no page loads signed out.
    public func attach(_ space: SpaceDef) async -> WKWebsiteDataStore {
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

    /// Changes which accounts a space uses. Runs on the queue so no scan sees a half-applied change:
    /// the old accounts' latest cookies are saved under the old binding first, then `commit`
    /// updates the config, then the space's browsing data is cleared and every bound account's
    /// sign-in is loaded. Clearing everything (not just the provider's cookies) is what makes the
    /// sites themselves (Outlook, Gmail, Etsy) switch accounts too.
    public func switchAccounts(spaceID: String, oldAccounts: [String], commit: @escaping @MainActor () -> Void) async {
        await enqueue {
            for accountID in oldAccounts { await self.reconcile(accountID) }
            commit()
            guard self.config.space(spaceID) != nil else { return }
            await self.resetStore(spaceID)
        }
        scheduleScan(spaceID)
    }

    /// Signs the account out in every space: clears its cookies from the vault and all stores.
    public func signOutEverywhere(_ accountID: String) async {
        await enqueue {
            guard let account = self.config.account(accountID), let provider = self.config.provider(account.providerID) else { return }
            self.vault.set([], for: accountID)
            for space in self.config.spaces(using: accountID) {
                guard let store = self.stores[space.id] else { continue } // closed spaces are cleared when opened
                let local = self.keyed(self.records(in: await store.httpCookieStore.allCookies(), for: provider))
                let written = await self.apply([:], removing: Set(local.keys), provider: provider, to: store, current: local)
                self.baseline[space.id, default: [:]][provider.id] = [:]
                await self.noteWritten(written, in: space.id, store: store)
            }
            self.note("\(self.config.label(account)): signed out everywhere")
        }
    }

    /// Detaches a space before it is deleted. Its tabs must already be closed.
    public func detach(_ spaceID: String) async {
        await enqueue {
            if let store = self.stores[spaceID], let observer = self.observers[spaceID] {
                store.httpCookieStore.remove(observer)
            }
            self.pendingScan[spaceID]?.cancel()
            self.pendingScan[spaceID] = nil
            self.scanSince[spaceID] = nil
            self.stores[spaceID] = nil
            self.observers[spaceID] = nil
            self.baseline[spaceID] = nil
            self.forgetChanges(spaceID)
            self.attached.remove(spaceID)
        }
    }

    /// Merges every open space's latest changes into the vault. Called before quitting.
    public func flush() async {
        await enqueue {
            for account in self.config.accounts { await self.reconcile(account.id) }
        }
    }

    public func rescanAll() {
        for id in stores.keys { scheduleScan(id) }
    }

    // MARK: - Queue

    private func enqueue<T>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        running += 1
        let task = Task { @MainActor in
            _ = await previous?.value
            let result = await work()
            self.running -= 1
            return result
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// Whether nothing is queued, running or waiting to run. Tests poll it; WebKit's
    /// notifications for the sync's own writes can still arrive afterwards.
    var isIdle: Bool { running == 0 && pendingScan.isEmpty && diffPending.isEmpty }

    /// A store reported a change: its tracked cookies are diffed against `seen` (at once, or
    /// `diffSpacing` after the last diff; changes meanwhile are read together), and a scan is
    /// scheduled.
    private func storeChanged(_ spaceID: String) {
        if notifiedAt[spaceID] == nil { notifiedAt[spaceID] = Date() }
        scheduleDiff(spaceID)
        scheduleScan(spaceID)
    }

    private func scheduleDiff(_ spaceID: String) {
        guard !diffPending.contains(spaceID) else { return }
        diffPending.insert(spaceID)
        let wait = max(0, (diffedAt[spaceID] ?? .distantPast).addingTimeInterval(Self.diffSpacing).timeIntervalSinceNow)
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self else { return }
            await self.enqueue {
                self.diffPending.remove(spaceID)
                guard let store = self.stores[spaceID] else { return }
                self.diffedAt[spaceID] = Date()
                let notified = self.takeNotified(spaceID)
                self.observe(spaceID, await store.httpCookieStore.allCookies(), notified: notified)
            }
        }
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
                for (_, account) in self.config.bound(space) { await self.reconcile(account.id) }
            }
        }
    }

    // MARK: - Work (only ever runs on the queue)

    private func performAttach(_ spaceID: String) async -> WKWebsiteDataStore {
        // A space deleted while its first open was queued gets a throwaway store, never attached.
        guard let space = config.space(spaceID) else { return .nonPersistent() }
        let store = WKWebsiteDataStore(forIdentifier: space.storeID)
        var nowShared: Set<String> = []
        if let providers = config.pendingAdoption[space.id] { nowShared = await keepOwnSignIns(space, store, providers: providers) }
        for (provider, account) in config.bound(config.space(spaceID) ?? space) {
            await seed(store, spaceName: space.name, provider: provider, account: account, adoptIfNew: true)
                .map { baseline[space.id, default: [:]][provider.id] = $0 }
        }
        // A session that just became the shared one is pushed to open spaces by the next reconcile.
        for providerID in nowShared { baseline[space.id, default: [:]][providerID] = [:] }
        // What the space holds now is the sync's doing (seeding), not a change by a page.
        forgetChanges(spaceID)
        seen[spaceID] = tracked(await store.httpCookieStore.allCookies())
        let observer = StoreObserver { [weak self] in self?.storeChanged(spaceID) }
        observers[space.id] = observer
        store.httpCookieStore.add(observer)
        stores[space.id] = store
        attached.insert(space.id)
        return store
    }

    /// First open after migration: a sign-in this space holds that differs from the shared one
    /// becomes a separate account for this space instead of being replaced.
    /// Returns the providers whose shared sign-in this space's session became.
    private func keepOwnSignIns(_ space: SpaceDef, _ store: WKWebsiteDataStore, providers: [String]) async -> Set<String> {
        let cookies = await store.httpCookieStore.allCookies()
        var nowShared: Set<String> = []
        var def = space
        for provider in config.providers where def.bindings[provider.id] == nil && providers.contains(provider.id) {
            let local = records(in: cookies, for: provider)
            let mine = provider.session(local)
            guard !mine.isEmpty, let sharedID = config.shared[provider.id] else { continue }
            let theirs = provider.session(vault.records(for: sharedID) ?? [])
            if theirs.isEmpty {
                // The shared sign-in has no session (e.g. only a signed-out "logged_in=no"): this
                // space's session becomes the shared one rather than being deleted by seeding.
                vault.set(local, for: sharedID)
                nowShared.insert(provider.id)
                note("\(space.name): its \(provider.name) sign-in is now the shared one")
                continue
            }
            guard theirs != mine else { continue }
            let account = config.addAccount(providerID: provider.id, name: space.name)
            vault.set(local, for: account.id)
            def.bindings[provider.id] = account.id
            note("\(space.name): kept its own \(provider.name) sign-in as \(config.label(account))")
        }
        if def != space { config.upsert(def) }
        config.finishAdoption(space.id)
        bindingChanged?(def)
        return nowShared
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
            let want = keyed(saved.filter(provider.tracks(record:)))
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

    /// Clears all of a space's browsing data and loads each bound account's sign-in from the vault.
    private func resetStore(_ spaceID: String) async {
        guard let space = config.space(spaceID) else { return }
        // A closed space's store is opened just to reset it; it is seeded again when opened.
        let store = stores[spaceID] ?? WKWebsiteDataStore(forIdentifier: space.storeID)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        baseline[spaceID] = [:]
        for (provider, account) in config.bound(space) {
            let next = await seed(store, spaceName: space.name, provider: provider, account: account, adoptIfNew: false)
            if stores[spaceID] != nil { baseline[spaceID, default: [:]][provider.id] = next }
        }
        if stores[spaceID] != nil {
            // The wipe and the new accounts' cookies are the sync's own writes.
            forgetChanges(spaceID)
            seen[spaceID] = tracked(await store.httpCookieStore.allCookies())
        }
        note("\(space.name): switched accounts; browsing data cleared")
    }

    private func reconcile(_ accountID: String) async {
        guard let account = config.account(accountID), let provider = config.provider(account.providerID) else { return }
        let members = config.spaces(using: accountID).filter { stores[$0.id] != nil }
        guard !members.isEmpty else { return }
        let label = config.label(account)
        let before = keyed((vault.records(for: account.id) ?? []).filter(provider.tracks(record:)))
        var merged = before
        var removed = Set<String>()
        var changedIn: [String] = []
        var currents: [String: [String: CookieRecord]] = [:]
        // Cookie key → the newest change any space made to it since its last sync (nil: deleted).
        var newest: [String: (at: Date, record: CookieRecord?)] = [:]

        for space in members {
            let notified = takeNotified(space.id)
            let all = await stores[space.id]!.httpCookieStore.allCookies()
            observe(space.id, all, notified: notified)
            let current = keyed(records(in: all, for: provider))
            currents[space.id] = current
            let base = baseline[space.id]?[provider.id] ?? [:]
            let times = changedAt[space.id] ?? [:]
            var touched = false
            // A change with no time (an adopted sign-in, a cookie that expired) loses to any
            // change a page made.
            func offer(_ key: String, _ record: CookieRecord?, at: Date) {
                touched = true
                if let other = newest[key], other.at >= at { return }
                newest[key] = (at, record)
            }
            for (key, record) in current where base[key] != record { offer(key, record, at: times[key] ?? .distantPast) }
            for (key, record) in base where current[key] == nil {
                offer(key, nil, at: record.isExpired ? .distantPast : times[key] ?? .distantPast)
            }
            if touched { changedIn.append(space.name) }
        }
        guard !changedIn.isEmpty else { return }
        for (key, change) in newest {
            if let record = change.record {
                merged[key] = record
                removed.remove(key)
            } else {
                merged[key] = nil
                removed.insert(key)
            }
        }

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
            noteWritten(written, in: space.id, after: after)
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

    // MARK: - Per-cookie change times

    /// The store's first change notification since its last read, cleared as a read starts (so a
    /// notification arriving during the read counts for the next one).
    private func takeNotified(_ spaceID: String) -> Date? {
        defer { notifiedAt[spaceID] = nil }
        return notifiedAt[spaceID]
    }

    /// Diffs a store's tracked cookies against what the sync last saw there. Each cookie the page
    /// changed or deleted gets `notified` (the first notification since the last read), or now
    /// if no notification has arrived for it yet. A cookie that merely expired isn't a change.
    private func observe(_ spaceID: String, _ cookies: [HTTPCookie], notified: Date?) {
        let at = notified ?? Date()
        let current = tracked(cookies)
        let old = seen[spaceID] ?? [:]
        var times = changedAt[spaceID] ?? [:]
        for (key, record) in current where old[key] != record { times[key] = at }
        for (key, record) in old where current[key] == nil && !record.isExpired { times[key] = at }
        changedAt[spaceID] = times
        seen[spaceID] = current
    }

    /// The sync wrote these keys: their new values are its own, not a page's change.
    private func noteWritten(_ keys: Set<String>, in spaceID: String, after: [String: CookieRecord]) {
        guard !keys.isEmpty, seen[spaceID] != nil else { return }
        for key in keys { seen[spaceID]?[key] = after[key] }
    }

    private func noteWritten(_ keys: Set<String>, in spaceID: String, store: WKWebsiteDataStore) async {
        guard !keys.isEmpty else { return }
        noteWritten(keys, in: spaceID, after: tracked(await store.httpCookieStore.allCookies()))
    }

    private func forgetChanges(_ spaceID: String) {
        seen[spaceID] = nil
        changedAt[spaceID] = nil
        notifiedAt[spaceID] = nil
        diffedAt[spaceID] = nil
    }

    /// Every unexpired cookie any provider tracks, by key (providers never share a domain).
    private func tracked(_ cookies: [HTTPCookie]) -> [String: CookieRecord] {
        var out: [String: CookieRecord] = [:]
        for cookie in cookies where config.providers.contains(where: { $0.tracks(cookie) }) {
            let record = CookieRecord(cookie)
            if !record.isExpired, out[record.key] == nil { out[record.key] = record }
        }
        return out
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
