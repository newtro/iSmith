import Foundation
import WebKit

/// Space and account changes that touch config, the vault and the sync together. The app asks the
/// user first (switching accounts, deleting a space, removing a signed-in account) and then calls
/// these; nothing here shows UI.
@MainActor
public final class SpaceManager {
    public let config: Config
    public let vault: Vault
    public let sync: CookieSync

    public init(config: Config, vault: Vault, sync: CookieSync) {
        self.config = config
        self.vault = vault
        self.sync = sync
    }

    // MARK: - Spaces

    @discardableResult
    public func createSpace(name: String, color: Int, home: String, choices: [String: AccountChoice],
                            newNames: [String: String]) -> SpaceDef {
        let def = SpaceDef(id: "space-" + UUID().uuidString.prefix(8).lowercased(), name: name, color: color,
                           storeID: UUID(), bindings: resolve(choices, newNames, spaceName: name), home: home)
        config.upsert(def)
        return def
    }

    /// The providers whose account the space would change to with these choices. Any change means
    /// switching accounts, which clears the space's browsing data; the app confirms that first.
    public func changedProviders(in spaceID: String, choices: [String: AccountChoice]) -> [String] {
        guard let old = config.space(spaceID) else { return [] }
        return config.providers.map(\.id).filter { provider in
            let before = config.accountID(in: old, for: provider)
            switch choices[provider] ?? .shared {
            case .shared: return before != config.shared[provider]
            case .local: return before != nil
            case .existing(let id): return before != id
            case .new: return true
            }
        }
    }

    /// Saves edits. Without account changes they are saved at once and `committed` is called
    /// before returning nil. If any account changed, `willSwitch` runs first (the app parks its
    /// tabs on a blank page, so a live app such as Outlook refreshing a token can't write the old
    /// account back after the wipe), then the returned task saves every account the space used,
    /// commits the edit, clears the space's browsing data and loads every bound account's sign-in.
    @discardableResult
    public func updateSpace(_ id: String, name: String, color: Int, home: String,
                            choices: [String: AccountChoice], newNames: [String: String],
                            willSwitch: () -> Void = {},
                            committed: @escaping @MainActor (SpaceDef) -> Void = { _ in }) -> Task<Void, Never>? {
        guard let old = config.space(id) else { return nil }
        let changed = changedProviders(in: id, choices: choices)
        var def = old
        def.name = name
        def.color = color
        def.home = home
        guard !changed.isEmpty else {
            config.upsert(def)
            committed(def)
            return nil
        }
        def.bindings = resolve(choices, newNames, spaceName: name)
        // Every account the space used is saved before the wipe, not only the changed ones, so a
        // cookie refreshed seconds earlier isn't lost.
        let oldAccounts = Array(Set(config.bound(old).map(\.account.id)))
        willSwitch()
        return Task { [config, sync] in
            await sync.switchAccounts(spaceID: id, oldAccounts: oldAccounts) {
                guard config.space(id) != nil else { return } // deleted meanwhile
                config.upsert(def)
                committed(def)
            }
        }
    }

    /// Removes the space from config at once; the returned task detaches it from the sync and
    /// deletes its browsing data. The app closes the space's tabs first, so the store isn't in use.
    @discardableResult
    public func deleteSpace(_ id: String) -> Task<Void, Never> {
        let storeID = config.space(id)?.storeID
        config.removeSpace(id)
        return Task { [sync] in
            await sync.detach(id)
            guard let storeID else { return }
            do { try await WKWebsiteDataStore.remove(forIdentifier: storeID) } catch { NSLog("iSmith: store removal failed: \(error)") }
        }
    }

    /// Turns editor choices into the space's exceptions; anything left on .shared isn't stored.
    private func resolve(_ choices: [String: AccountChoice], _ newNames: [String: String], spaceName: String) -> [String: String] {
        var bindings: [String: String] = [:]
        for (providerID, choice) in choices {
            switch choice {
            case .shared: break
            case .local: bindings[providerID] = SpaceDef.local
            case .existing(let id): if id != config.shared[providerID] { bindings[providerID] = id }
            case .new:
                let name = newNames[providerID].flatMap { $0.isEmpty ? nil : $0 } ?? spaceName
                bindings[providerID] = config.addAccount(providerID: providerID, name: name).id
            }
        }
        return bindings
    }

    // MARK: - Accounts

    /// Removes a separate account no space uses, with its saved sign-in.
    public func removeAccount(_ id: String) {
        guard config.spaces(using: id).isEmpty, !config.isShared(id) else { return }
        config.removeAccount(id)
        vault.remove(id)
    }

    public func removeProvider(_ id: String) {
        for accountID in config.removeProvider(id) { vault.remove(accountID) }
    }

    public func signOutEverywhere(_ id: String) async {
        await sync.signOutEverywhere(id)
    }
}
