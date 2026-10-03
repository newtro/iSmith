import Foundation
import SignInSync
import WebKit
import XCTest

/// One test's sign-in engine: config, vault and sync on files in a fresh temp folder, with the
/// spike's self-test layout of spaces on WebKit stores no other test uses. `tearDown()` deletes
/// the stores and the folder.
@MainActor
final class Fixture {
    let dir: URL
    let keyStore = InMemoryKeyStore()
    private(set) var vault: Vault!
    private(set) var config: Config!
    private(set) var sync: CookieSync!
    private(set) var manager: SpaceManager!
    /// Every store a test may have opened, so all of them are removed afterwards.
    private var storeIDs: Set<UUID> = []
    private let layout: (accounts: [AccountDef], spaces: [SpaceDef])

    var configURL: URL { dir.appendingPathComponent("config.json") }
    var vaultURL: URL { dir.appendingPathComponent("vault.json") }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignInSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        layout = Self.selfTestLayout()
        storeIDs = Set(layout.spaces.map(\.storeID))
        open()
    }

    /// Accounts and spaces with separate and local accounts, so isolation can be checked:
    /// - Contoso and its second space share a separate Microsoft account; Fabrikam has its own;
    /// - Contoso (second space) keeps Google and GitHub to itself; Personal keeps Microsoft;
    /// - Newtro Studios uses every shared sign-in.
    static func selfTestLayout() -> (accounts: [AccountDef], spaces: [SpaceDef]) {
        let accounts = [
            AccountDef(id: "ms-contoso", providerID: "microsoft", name: "Contoso"),
            AccountDef(id: "ms-fabrikam", providerID: "microsoft", name: "Fabrikam"),
        ]
        let local = SpaceDef.local
        let spaces = [
            SpaceDef(id: "contoso", name: "Contoso", color: 0, storeID: UUID(), bindings: ["microsoft": "ms-contoso"], home: ""),
            SpaceDef(id: "fabrikam", name: "Fabrikam", color: 1, storeID: UUID(), bindings: ["microsoft": "ms-fabrikam"], home: ""),
            SpaceDef(id: "contoso-b", name: "Contoso (second space)", color: 2, storeID: UUID(),
                     bindings: ["microsoft": "ms-contoso", "google": local, "github": local], home: ""),
            SpaceDef(id: "personal", name: "Personal", color: 3, storeID: UUID(), bindings: ["microsoft": local], home: ""),
            SpaceDef(id: "newtro", name: "Newtro Studios", color: 4, storeID: UUID(), bindings: [:], home: ""),
        ]
        return (accounts, spaces)
    }

    /// Opens the engine on the fixture's files, as a launch of the app would.
    private func open() {
        let vault = Vault(fileURL: vaultURL, keyStore: keyStore)
        let layout = layout
        let config = Config(fileURL: configURL, hasSession: { [vault] in vault.hasSession($0) }, starter: { layout })
        let sync = CookieSync(vault: vault, config: config)
        (self.vault, self.config, self.sync) = (vault, config, sync)
        manager = SpaceManager(config: config, vault: vault, sync: sync)
    }

    /// Quits and launches again: new Vault, Config and CookieSync instances on the same files.
    func relaunch() async {
        await sync.flush()
        await closeAll()
        open()
    }

    func space(_ id: String) -> SpaceDef {
        guard let def = config.space(id) else { fatalError("no space \(id)") }
        return def
    }

    func attach(_ id: String) async -> WKWebsiteDataStore {
        let def = space(id)
        storeIDs.insert(def.storeID)
        return await sync.attach(def)
    }

    /// The space's store without attaching it, to plant or remove cookies behind the sync's back.
    func store(_ id: String) -> WKWebsiteDataStore {
        let def = space(id)
        storeIDs.insert(def.storeID)
        return WKWebsiteDataStore(forIdentifier: def.storeID)
    }

    func track(_ def: SpaceDef) { storeIDs.insert(def.storeID) }

    private func closeAll() async {
        for id in sync.attached { await sync.detach(id) }
        storeIDs.formUnion(config.spaces.map(\.storeID))
        (vault, config, sync, manager) = (nil, nil, nil, nil)
    }

    /// Detaches everything and deletes the test's stores and files. WebKit refuses to remove a store
    /// while something still holds it, so removal is retried briefly while the last references go.
    func tearDown() async {
        await closeAll()
        for id in storeIDs {
            var removed = false
            for _ in 0..<40 {
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: id)
                    removed = true
                    break
                } catch {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            if !removed { XCTFail("WebKit store \(id) could not be removed") }
        }
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - Helpers shared by the sync tests

/// Lets the debounced scan (0.4 s) and its reconcile finish, the same wait the spike's self-test used.
func settle() async {
    try? await Task.sleep(nanoseconds: 3_000_000_000)
}

@MainActor
func find(_ store: WKWebsiteDataStore, _ name: String) async -> HTTPCookie? {
    await store.httpCookieStore.allCookies().first { $0.name == name }
}

@MainActor
func valueOf(_ store: WKWebsiteDataStore, _ name: String) async -> String? {
    await find(store, name)?.value
}

func cookie(_ name: String, _ value: String, _ domain: String, expires: Date?,
            secure: Bool = false, httpOnly: Bool = false) -> HTTPCookie {
    var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
    if let expires { props[.expires] = expires }
    if secure { props[.secure] = "TRUE" }
    if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    return HTTPCookie(properties: props)!
}

/// One of the spike's self-test checks: an assertion that also prints PASS/FAIL like the spike did,
/// so a run can be compared check by check.
func check(_ ok: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    print((ok ? "CHECK PASS  " : "CHECK FAIL  ") + what)
    XCTAssertTrue(ok, what, file: file, line: line)
}
