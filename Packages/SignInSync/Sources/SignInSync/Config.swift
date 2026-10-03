import Combine
import Foundation

/// Providers, accounts and spaces, saved to config.json. Everything is editable in the app.
@MainActor
public final class Config: ObservableObject {
    struct File: Codable {
        var version: Int?
        var providers: [ProviderDef]
        var accounts: [AccountDef]
        var spaces: [SpaceDef]
        var shared: [String: String]?
        var pendingAdoption: [String: [String]]?
    }

    /// The accounts and spaces a first run starts with.
    public typealias Starter = () -> (accounts: [AccountDef], spaces: [SpaceDef])

    @Published public private(set) var providers: [ProviderDef] = []
    @Published public private(set) var accounts: [AccountDef] = []
    @Published public private(set) var spaces: [SpaceDef] = []
    /// Provider id → the account every space uses unless it overrides it. One sign-in session can
    /// hold several accounts (Google's and Microsoft's own account pickers), so this is normally
    /// all anyone needs.
    @Published public private(set) var shared: [String: String] = [:]
    /// Space id → providers whose cookies, in version 1, belonged to the space alone (unbound, or
    /// bound to an account with no session). On the space's first open, a session it holds for one
    /// of these is kept as a separate account, never deleted. Providers the space already shared
    /// in version 1 aren't checked: their cookies are the same account, just possibly newer.
    @Published public private(set) var pendingAdoption: [String: [String]] = [:]
    public let fileURL: URL
    private let hasSession: (String) -> Bool
    /// False when config.json exists but couldn't be read or backed up: nothing is written over it.
    private var canSave = true

    /// `hasSession` tells whether the vault holds a signed-in session for an account id.
    /// `starter` sets up a first run; by default one Personal space with every provider shared.
    public init(fileURL: URL, hasSession: @escaping (String) -> Bool, starter: Starter? = nil) {
        self.fileURL = fileURL
        self.hasSession = hasSession
        let starter = starter ?? Self.defaultStarter
        var needsMigration = false
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let file = try JSONDecoder().decode(File.self, from: data)
                providers = file.providers
                accounts = file.accounts
                spaces = file.spaces
                shared = file.shared ?? [:]
                pendingAdoption = file.pendingAdoption ?? [:]
                needsMigration = (file.version ?? 1) < 2
            } catch {
                // Never overwrite a config that didn't load: keep a copy to recover from.
                do {
                    let backup = try SecureFile.backUp(fileURL, reason: "unreadable")
                    NSLog("iSmith: config.json could not be read (\(error)); saved a copy at \(backup.path)")
                } catch {
                    canSave = false
                    NSLog("iSmith: config.json could not be read or backed up (\(error)); it won't be changed")
                }
                (accounts, spaces) = starter()
            }
        } else {
            (accounts, spaces) = starter()
        }
        // Built-in provider definitions always come from the app, so fixes reach existing configs.
        providers = ProviderDef.builtIns + providers.filter { !$0.builtIn }
        if needsMigration { migrateToShared() }
        for provider in providers { ensureShared(provider.id) }
        save()
    }

    /// First-run setup: one space; every provider shared.
    public static func defaultStarter() -> (accounts: [AccountDef], spaces: [SpaceDef]) {
        ([], [SpaceDef(id: "personal", name: "Personal", color: 3, storeID: UUID(), bindings: [:],
                       home: "https://mail.google.com/")])
    }

    /// Version 1 gave each space its own account per provider. Version 2 shares one sign-in per
    /// provider. Nothing signed in is lost:
    /// - the most-used account that has a session becomes the shared one;
    /// - any other account with a session stays bound to its spaces as a separate account;
    /// - accounts with no session, and providers a space didn't bind, move to the shared one;
    ///   on first open, a session such a space holds on its own is kept (see `pendingAdoption`).
    private func migrateToShared() {
        for space in spaces {
            pendingAdoption[space.id] = providers.map(\.id).filter { p in
                guard let bound = space.bindings[p], bound != SpaceDef.local else { return true }
                return !hasSession(bound)
            }
        }
        for provider in providers {
            let used = spaces.compactMap { $0.bindings[provider.id] }.filter { account($0) != nil }
            let signedIn = used.filter(hasSession)
            let pool = signedIn.isEmpty ? used : signedIn
            let counts = Dictionary(grouping: pool, by: { $0 }).mapValues(\.count)
            let order = accounts.map(\.id)
            guard let top = counts.max(by: { a, b in
                a.value != b.value ? a.value < b.value
                    : (order.firstIndex(of: a.key) ?? 0) > (order.firstIndex(of: b.key) ?? 0)
            })?.key, let i = accounts.firstIndex(where: { $0.id == top }) else { continue }
            shared[provider.id] = top
            accounts[i].name = "All my accounts"
            for s in spaces.indices {
                guard let bound = spaces[s].bindings[provider.id] else { continue }
                if bound == top || bound == SpaceDef.local || !hasSession(bound) { spaces[s].bindings[provider.id] = nil }
            }
        }
        for s in spaces.indices {
            spaces[s].bindings = spaces[s].bindings.filter { $0.value != SpaceDef.local }
        }
        NSLog("iSmith: config moved to shared sign-ins")
    }

    public func finishAdoption(_ spaceID: String) {
        guard pendingAdoption.removeValue(forKey: spaceID) != nil else { return }
        save()
    }

    /// Test hook: treat a space's providers as freshly migrated.
    public func markPendingAdoption(_ spaceID: String, providers: [String]) {
        pendingAdoption[spaceID] = providers
        save()
    }

    private func ensureShared(_ providerID: String) {
        if let id = shared[providerID], account(id) != nil { return }
        let account = AccountDef(id: "shared-" + providerID, providerID: providerID, name: "All my accounts")
        if self.account(account.id) == nil { accounts.append(account) }
        shared[providerID] = account.id
    }

    public func isShared(_ accountID: String) -> Bool { shared.values.contains(accountID) }

    /// The account a space uses for a provider, or nil if the provider's sign-in stays local.
    public func accountID(in space: SpaceDef, for providerID: String) -> String? {
        switch space.bindings[providerID] {
        case nil: return shared[providerID]
        case SpaceDef.local: return nil
        case let id?: return account(id) == nil ? shared[providerID] : id
        }
    }

    public func provider(_ id: String) -> ProviderDef? { providers.first { $0.id == id } }
    public func account(_ id: String) -> AccountDef? { accounts.first { $0.id == id } }
    public func space(_ id: String) -> SpaceDef? { spaces.first { $0.id == id } }
    public func accounts(for providerID: String) -> [AccountDef] { accounts.filter { $0.providerID == providerID } }

    /// The space's accounts in provider order.
    public func bound(_ space: SpaceDef) -> [(provider: ProviderDef, account: AccountDef)] {
        providers.compactMap { p in accountID(in: space, for: p.id).flatMap(account).map { (p, $0) } }
    }

    public func spaces(using accountID: String) -> [SpaceDef] {
        guard let account = account(accountID) else { return [] }
        return spaces.filter { self.accountID(in: $0, for: account.providerID) == accountID }
    }

    public func label(_ account: AccountDef) -> String {
        "\(provider(account.providerID)?.name ?? account.providerID): \(account.name)"
    }

    public func upsert(_ space: SpaceDef) {
        if let i = spaces.firstIndex(where: { $0.id == space.id }) { spaces[i] = space } else { spaces.append(space) }
        save()
    }

    public func removeSpace(_ id: String) {
        spaces.removeAll { $0.id == id }
        save()
    }

    /// Moves a space to a new position in the rail; `index` is where it ends up, clamped to the
    /// list. The order is saved, so it's the same after a relaunch.
    public func moveSpace(_ id: String, to index: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(index, spaces.count - 1))
        guard from != to else { return }
        let space = spaces.remove(at: from)
        spaces.insert(space, at: to)
        save()
    }

    @discardableResult
    public func addAccount(providerID: String, name: String) -> AccountDef {
        let account = AccountDef(id: "acct-" + UUID().uuidString.prefix(8).lowercased(), providerID: providerID, name: name)
        accounts.append(account)
        save()
        return account
    }

    public func renameAccount(_ id: String, to name: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        accounts[i].name = name
        save()
    }

    public func removeAccount(_ id: String) {
        guard spaces(using: id).isEmpty, !isShared(id) else { return }
        accounts.removeAll { $0.id == id }
        save()
    }

    /// Adds a provider, or returns why it can't be added. Two providers may not claim the same
    /// cookies, or two accounts in one space would overwrite each other's sign-in.
    @discardableResult
    public func addProvider(name: String, domains: [String], sessionNames: [String]) -> String? {
        let domains = domains.map { d -> String in
            var d = d.lowercased()
            if let host = URL(string: d.contains("://") ? d : "https://" + d)?.host { d = host }
            while d.hasPrefix(".") || d.hasPrefix("*") { d.removeFirst() }
            return d
        }.filter { $0.contains(".") }
        guard !domains.isEmpty else { return "Enter at least one domain, like okta.com." }
        for d in domains {
            for p in providers {
                if let clash = p.domains.first(where: { $0 == d || $0.hasSuffix("." + d) || d.hasSuffix("." + $0) }) {
                    return "\(d) overlaps \(p.name) (\(clash))."
                }
            }
        }
        let id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        providers.append(ProviderDef(id: id, name: name, domains: domains,
                                     sessionNames: sessionNames.isEmpty ? nil : sessionNames))
        ensureShared(id)
        save()
        return nil
    }

    /// Removes a custom provider that has no separate accounts. Returns the removed account ids.
    @discardableResult
    public func removeProvider(_ id: String) -> [String] {
        guard provider(id)?.builtIn == false, accounts(for: id).allSatisfy({ isShared($0.id) }) else { return [] }
        let removed = accounts(for: id).map(\.id)
        providers.removeAll { $0.id == id }
        accounts.removeAll { $0.providerID == id }
        shared[id] = nil
        for i in spaces.indices { spaces[i].bindings[id] = nil }
        save()
        return removed
    }

    private func save() {
        guard canSave else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(File(version: 2, providers: providers, accounts: accounts, spaces: spaces,
                                               shared: shared, pendingAdoption: pendingAdoption.isEmpty ? nil : pendingAdoption))
            try SecureFile.prepareDirectory(fileURL.deletingLastPathComponent())
            try SecureFile.write(data, to: fileURL)
        } catch {
            NSLog("iSmith config save failed: \(error)")
        }
    }
}
