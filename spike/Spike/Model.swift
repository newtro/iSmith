import SwiftUI

/// A sign-in service whose cookies belong to an account rather than a space: an identity
/// provider (Microsoft, Google) or any site you want one sign-in for across spaces.
struct ProviderDef: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Cookie domains owned by the provider: a cookie belongs to it when its domain equals one of
    /// these or is a subdomain of one.
    var domains: [String]
    /// When set, only these cookie names are shared. Google sets many fast-changing tracking
    /// cookies on google.com; only its sign-in set needs to follow the account.
    var names: [String]?
    /// Cookies that mean "signed in". When one appears in a space that has no account for this
    /// provider, the app offers to save the sign-in as an account. Empty means never offer.
    var sessionNames: [String]?
    var builtIn = false

    func owns(cookieDomain: String) -> Bool {
        var host = cookieDomain.lowercased()
        if host.hasPrefix(".") { host.removeFirst() }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func tracks(_ cookie: HTTPCookie) -> Bool {
        owns(cookieDomain: cookie.domain) && (names.map { $0.contains(cookie.name) } ?? true)
    }

    func tracks(record: CookieRecord) -> Bool {
        owns(cookieDomain: record.domain) && (names.map { $0.contains(record.name) } ?? true)
    }

    static let builtIns: [ProviderDef] = [
        ProviderDef(id: "microsoft", name: "Microsoft",
                    domains: ["login.microsoftonline.com", "login.microsoft.com", "login.windows.net"],
                    sessionNames: ["ESTSAUTH", "ESTSAUTHPERSISTENT"], builtIn: true),
        ProviderDef(id: "microsoft-personal", name: "Microsoft personal", domains: ["live.com"],
                    sessionNames: ["MSPAuth", "WLSSC"], builtIn: true),
        ProviderDef(id: "google", name: "Google", domains: ["google.com"], names: [
            "SID", "HSID", "SSID", "APISID", "SAPISID",
            "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID",
            "__Secure-1PSIDTS", "__Secure-3PSIDTS",
            "LSID", "__Host-1PLSID", "__Host-3PLSID", "__Host-GAPS", "ACCOUNT_CHOOSER",
        ], sessionNames: ["SID", "__Secure-1PSID"], builtIn: true),
        ProviderDef(id: "github", name: "GitHub", domains: ["github.com"],
                    names: ["user_session", "__Host-user_session_same_site", "logged_in", "dotcom_user"],
                    sessionNames: ["user_session"], builtIn: true),
    ]
}

/// One sign-in at one provider. Its provider cookies live in the vault and are shared by every
/// space bound to it.
struct AccountDef: Codable, Hashable, Identifiable {
    var id: String
    var providerID: String
    var name: String
}

/// A workspace with its own WebKit data store. By default it uses every provider's shared sign-in;
/// `bindings` holds only the exceptions.
struct SpaceDef: Codable, Hashable, Identifiable {
    /// Binding value meaning "this provider's sign-in stays in this space only".
    static let local = "local"

    var id: String
    var name: String
    var color: Int
    var storeID: UUID
    /// Provider id → a separate account id, or `SpaceDef.local`. Providers not listed use the
    /// provider's shared account.
    var bindings: [String: String]
    var home: String
    /// Providers whose sign-ins stay in this space only; the app won't offer to save them.
    var localProviders: [String] = []

    init(id: String, name: String, color: Int, storeID: UUID, bindings: [String: String], home: String,
         localProviders: [String] = []) {
        (self.id, self.name, self.color, self.storeID, self.bindings, self.home, self.localProviders) =
            (id, name, color, storeID, bindings, home, localProviders)
    }

    /// Fields added later decode with defaults, so an older config.json still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        storeID = try c.decode(UUID.self, forKey: .storeID)
        bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings) ?? [:]
        home = try c.decodeIfPresent(String.self, forKey: .home) ?? ""
        localProviders = try c.decodeIfPresent([String].self, forKey: .localProviders) ?? []
    }

    var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

enum Palette {
    static let names = ["Blue", "Green", "Purple", "Amber", "Crimson", "Teal", "Pink", "Slate"]
    private static let rgb: [(Double, Double, Double)] = [
        (0.15, 0.39, 0.92), (0.08, 0.54, 0.35), (0.49, 0.23, 0.93), (0.76, 0.42, 0.02),
        (0.75, 0.07, 0.24), (0.06, 0.46, 0.43), (0.86, 0.15, 0.55), (0.39, 0.45, 0.55),
    ]
    static func color(_ index: Int) -> Color {
        let c = rgb[((index % rgb.count) + rgb.count) % rgb.count]
        return Color(red: c.0, green: c.1, blue: c.2)
    }
}

enum AppPaths {
    /// `--selftest` uses its own folder and stores so real sign-ins are untouched.
    static let isSelfTest = CommandLine.arguments.contains("--selftest")

    static let dir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isSelfTest ? "iSmithSpike-selftest" : "iSmithSpike", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }()
}

/// Providers, accounts and spaces, saved to config.json. Everything is editable in the app.
@MainActor
final class Config: ObservableObject {
    struct File: Codable {
        var version: Int?
        var providers: [ProviderDef]
        var accounts: [AccountDef]
        var spaces: [SpaceDef]
        var shared: [String: String]?
    }

    @Published private(set) var providers: [ProviderDef] = []
    @Published private(set) var accounts: [AccountDef] = []
    @Published private(set) var spaces: [SpaceDef] = []
    /// Provider id → the account every space uses unless it overrides it. One sign-in session can
    /// hold several accounts (Google's and Microsoft's own account pickers), so this is normally
    /// all anyone needs.
    @Published private(set) var shared: [String: String] = [:]
    private let fileURL: URL
    /// False when config.json exists but couldn't be read or backed up: nothing is written over it.
    private var canSave = true

    init(fileURL: URL = AppPaths.dir.appendingPathComponent("config.json")) {
        self.fileURL = fileURL
        var needsMigration = false
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let file = try JSONDecoder().decode(File.self, from: data)
                providers = file.providers
                accounts = file.accounts
                spaces = file.spaces
                shared = file.shared ?? [:]
                needsMigration = (file.version ?? 1) < 2
            } catch {
                // Never overwrite a config that didn't load: keep a copy to recover from.
                let backup = fileURL.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                canSave = (try? FileManager.default.copyItem(at: fileURL, to: backup)) != nil
                NSLog("iSmith: config.json could not be read (\(error)); saved a copy at \(backup.path)")
                (accounts, spaces) = Self.starter()
            }
        } else {
            (accounts, spaces) = Self.starter()
        }
        // Built-in provider definitions always come from the app, so fixes reach existing configs.
        providers = ProviderDef.builtIns + providers.filter { !$0.builtIn }
        if needsMigration { migrateToShared() }
        for provider in providers { ensureShared(provider.id) }
        save()
    }

    /// Version 1 gave each space its own account per provider. Version 2 shares one sign-in per
    /// provider across all spaces: the account most spaces used becomes the shared one (keeping its
    /// saved session), and every space goes back to the default.
    private func migrateToShared() {
        for provider in providers {
            let used = spaces.compactMap { $0.bindings[provider.id] }.filter { $0 != SpaceDef.local }
            let counts = Dictionary(grouping: used, by: { $0 }).mapValues(\.count)
            guard let top = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key,
                  let i = accounts.firstIndex(where: { $0.id == top }) else { continue }
            shared[provider.id] = top
            accounts[i].name = "All my accounts"
        }
        for i in spaces.indices { spaces[i].bindings = [:] }
        NSLog("iSmith: config moved to shared sign-ins")
    }

    private func ensureShared(_ providerID: String) {
        if let id = shared[providerID], account(id) != nil { return }
        let account = AccountDef(id: "shared-" + providerID, providerID: providerID, name: "All my accounts")
        if self.account(account.id) == nil { accounts.append(account) }
        shared[providerID] = account.id
    }

    func isShared(_ accountID: String) -> Bool { shared.values.contains(accountID) }

    /// The account a space uses for a provider, or nil if the provider's sign-in stays local.
    func accountID(in space: SpaceDef, for providerID: String) -> String? {
        switch space.bindings[providerID] {
        case nil: return shared[providerID]
        case SpaceDef.local: return nil
        case let id?: return account(id) == nil ? shared[providerID] : id
        }
    }

    func provider(_ id: String) -> ProviderDef? { providers.first { $0.id == id } }
    func account(_ id: String) -> AccountDef? { accounts.first { $0.id == id } }
    func space(_ id: String) -> SpaceDef? { spaces.first { $0.id == id } }
    func accounts(for providerID: String) -> [AccountDef] { accounts.filter { $0.providerID == providerID } }

    /// The space's accounts in provider order.
    func bound(_ space: SpaceDef) -> [(provider: ProviderDef, account: AccountDef)] {
        providers.compactMap { p in accountID(in: space, for: p.id).flatMap(account).map { (p, $0) } }
    }

    func spaces(using accountID: String) -> [SpaceDef] {
        guard let account = account(accountID) else { return [] }
        return spaces.filter { self.accountID(in: $0, for: account.providerID) == accountID }
    }

    func label(_ account: AccountDef) -> String {
        "\(provider(account.providerID)?.name ?? account.providerID): \(account.name)"
    }

    func upsert(_ space: SpaceDef) {
        if let i = spaces.firstIndex(where: { $0.id == space.id }) { spaces[i] = space } else { spaces.append(space) }
        save()
    }

    func removeSpace(_ id: String) {
        spaces.removeAll { $0.id == id }
        save()
    }

    @discardableResult
    func addAccount(providerID: String, name: String) -> AccountDef {
        let account = AccountDef(id: "acct-" + UUID().uuidString.prefix(8).lowercased(), providerID: providerID, name: name)
        accounts.append(account)
        save()
        return account
    }

    func renameAccount(_ id: String, to name: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        accounts[i].name = name
        save()
    }

    func removeAccount(_ id: String) {
        guard spaces(using: id).isEmpty, !isShared(id) else { return }
        accounts.removeAll { $0.id == id }
        save()
    }

    /// Adds a provider, or returns why it can't be added. Two providers may not claim the same
    /// cookies, or two accounts in one space would overwrite each other's sign-in.
    @discardableResult
    func addProvider(name: String, domains: [String], sessionNames: [String]) -> String? {
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
    func removeProvider(_ id: String) -> [String] {
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
            try encoder.encode(File(version: 2, providers: providers, accounts: accounts, spaces: spaces, shared: shared))
                .write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("iSmith config save failed: \(error)")
        }
    }

    /// First-run setup: one space; every provider shared. The self-test instead gets a layout with
    /// separate and local accounts so isolation can be checked.
    private static func starter() -> ([AccountDef], [SpaceDef]) {
        guard AppPaths.isSelfTest else {
            return ([], [SpaceDef(id: "personal", name: "Personal", color: 3, storeID: UUID(), bindings: [:],
                                  home: "https://mail.google.com/")])
        }
        let accounts = [
            AccountDef(id: "ms-contoso", providerID: "microsoft", name: "Contoso"),
            AccountDef(id: "ms-fabrikam", providerID: "microsoft", name: "Fabrikam"),
        ]
        func store(_ n: Int) -> UUID { UUID(uuidString: "6F1C2A40-0000-4000-9000-00000000000\(n)")! }
        let local = SpaceDef.local
        let spaces = [
            SpaceDef(id: "contoso", name: "Contoso", color: 0, storeID: store(1), bindings: ["microsoft": "ms-contoso"], home: ""),
            SpaceDef(id: "fabrikam", name: "Fabrikam", color: 1, storeID: store(2), bindings: ["microsoft": "ms-fabrikam"], home: ""),
            SpaceDef(id: "contoso-b", name: "Contoso (second space)", color: 2, storeID: store(3),
                     bindings: ["microsoft": "ms-contoso", "google": local, "github": local], home: ""),
            SpaceDef(id: "personal", name: "Personal", color: 3, storeID: store(4), bindings: ["microsoft": local], home: ""),
            SpaceDef(id: "newtro", name: "Newtro Studios", color: 4, storeID: store(5), bindings: [:], home: ""),
        ]
        return (accounts, spaces)
    }
}

struct QuickLink: Identifiable {
    let name: String
    let url: URL
    var id: String { name }

    static let all: [QuickLink] = [
        ("Outlook", "https://outlook.office.com/mail/"),
        ("Azure DevOps", "https://dev.azure.com/contoso-dev"),
        ("Azure portal", "https://portal.azure.com"),
        ("My Microsoft account", "https://myaccount.microsoft.com"),
        ("Gmail", "https://mail.google.com/"),
        ("Google account", "https://myaccount.google.com"),
        ("GitHub", "https://github.com"),
        ("Etsy shop", "https://www.etsy.com/your/shops/me/dashboard"),
    ].map { QuickLink(name: $0.0, url: URL(string: $0.1)!) }
}
