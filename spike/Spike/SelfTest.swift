import AppKit
import WebKit

/// Exercises cookie sharing without real sign-ins: writes probe cookies on provider domains in one
/// space and checks which other spaces receive them. Run with `--selftest`; exits 0 on success.
@MainActor
struct SelfTest {
    let browser: BrowserState
    private var sync: CookieSync { browser.sync }

    func run() async {
        if CommandLine.arguments.contains("--phase=write") { return await writePhase() }
        if CommandLine.arguments.contains("--phase=read") { return await readPhase() }
        if CommandLine.arguments.contains("--phase=config") { return await configPhase() }
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "PASS  " : "FAIL  ") + what)
            if !ok { failures.append(what) }
        }

        await wipeTestStores()
        let byID = Dictionary(uniqueKeysWithValues: browser.config.spaces.map { ($0.id, $0) })
        let m = await sync.attach(byID["contoso"]!)
        let t = await sync.attach(byID["fabrikam"]!)
        let b = await sync.attach(byID["contoso-b"]!)
        let p = await sync.attach(byID["personal"]!)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let hour = Date().addingTimeInterval(3600)
        let gPersistent = cookie("SID", "v1", ".google.com", expires: hour)
        let gSession = cookie("LSID", "s1", "accounts.google.com", expires: nil, secure: true, httpOnly: true)
        let msHost = cookie("ESTSAUTHPERSISTENT", "m1", "login.microsoftonline.com", expires: hour, secure: true, httpOnly: true)
        let gHostPrefix = cookie("__Host-GAPS", "h1", "accounts.google.com", expires: hour, secure: true)

        await m.httpCookieStore.setCookie(gPersistent)
        await m.httpCookieStore.setCookie(gSession)
        await m.httpCookieStore.setCookie(gHostPrefix)
        await m.httpCookieStore.setCookie(msHost)
        await m.httpCookieStore.setCookie(cookie("NID", "n1", ".google.com", expires: hour))
        await settle()
        check(await value(t, "NID") == nil, "Google tracking cookie (NID) is not shared")

        check(await value(t, "SID") == "v1", "Google cookie set in Contoso reaches Fabrikam")
        check(await value(p, "SID") == "v1", "Google cookie set in Contoso reaches Personal")
        check(await value(b, "SID") == nil, "Google cookie does not reach Contoso (second space), which has no Google account")
        check(await value(t, "LSID") == "s1", "Google session cookie reaches Fabrikam")
        check(await find(t, "LSID")?.isHTTPOnly == true, "HttpOnly flag survives the copy")
        check(await find(t, "__Host-GAPS")?.domain == "accounts.google.com", "__Host- cookie stays host-only")
        check(await value(b, "ESTSAUTHPERSISTENT") == "m1", "Contoso Microsoft cookie reaches Contoso (second space)")
        check(await value(t, "ESTSAUTHPERSISTENT") == nil, "Contoso Microsoft cookie does not reach Fabrikam")
        check(await find(b, "ESTSAUTHPERSISTENT")?.domain == "login.microsoftonline.com", "Microsoft host-only cookie stays host-only")

        await t.httpCookieStore.setCookie(cookie("SID", "v2", ".google.com", expires: hour))
        await settle()
        check(await value(m, "SID") == "v2", "Change made in Fabrikam flows back to Contoso")
        check(await value(p, "SID") == "v2", "Change made in Fabrikam reaches Personal")

        // Two spaces change different sign-in cookies at the same moment; neither change may be lost.
        async let a: Void = m.httpCookieStore.setCookie(cookie("HSID", "x1", ".google.com", expires: hour))
        async let c: Void = p.httpCookieStore.setCookie(cookie("SSID", "y1", ".google.com", expires: hour))
        _ = await (a, c)
        await settle()
        let (tH, tS) = (await value(t, "HSID"), await value(t, "SSID"))
        let (mS, pH) = (await value(m, "SSID"), await value(p, "HSID"))
        check(tH == "x1" && tS == "y1", "Simultaneous changes in two spaces both reach Fabrikam")
        check(mS == "y1" && pH == "x1", "Simultaneous changes cross over between the two spaces")

        let probes: Set<String> = ["SID", "LSID", "__Host-GAPS", "HSID", "SSID"]
        for c in await p.httpCookieStore.allCookies() where probes.contains(c.name) {
            await p.httpCookieStore.deleteCookie(c)
        }
        await settle()
        check(await value(m, "SID") == nil, "Sign-out (deleted cookie) in Personal spreads to Contoso")
        check(await value(t, "LSID") == nil, "Sign-out in Personal spreads to Fabrikam")

        if let c = await find(b, "ESTSAUTHPERSISTENT") { await b.httpCookieStore.deleteCookie(c) }
        await settle()
        check(await value(m, "ESTSAUTHPERSISTENT") == nil, "Microsoft sign-out in second space spreads to Contoso")

        let saved = Vault()
        let leftovers = saved.entries.values.flatMap(\.cookies).filter { $0.value != "" && ($0.name.contains("ismith_probe") || probes.contains($0.name)) }
        check(leftovers.isEmpty, "Vault on disk holds no probe cookies after cleanup")

        print(failures.isEmpty ? "SELFTEST OK" : "SELFTEST FAILED: \(failures.count)")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// Relaunch test, part 1: sign-in cookies (one session-only) appear in Contoso, then the app quits.
    private func writePhase() async {
        let m = await sync.attach(browser.config.space("contoso")!)
        await m.httpCookieStore.setCookie(cookie("LSID", "s1", "accounts.google.com", expires: nil, secure: true))
        await m.httpCookieStore.setCookie(cookie("ESTSAUTH", "m1", "login.microsoftonline.com",
                                                 expires: Date().addingTimeInterval(3600), secure: true))
        await settle()
        print("WRITE PHASE DONE")
        exit(0)
    }

    /// Relaunch test, part 2: in a new process, spaces that were never opened before are seeded from
    /// the vault, including the session cookie WebKit itself would have dropped.
    private func readPhase() async {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "PASS  " : "FAIL  ") + what)
            if !ok { failures.append(what) }
        }
        let t = await sync.attach(browser.config.space("fabrikam")!)
        let b = await sync.attach(browser.config.space("contoso-b")!)
        check(await value(t, "LSID") == "s1", "After relaunch, Google session cookie is in Fabrikam")
        check(await value(b, "ESTSAUTH") == "m1", "After relaunch, Contoso Microsoft cookie is in the second Contoso space")
        check(await value(t, "ESTSAUTH") == nil, "After relaunch, Contoso Microsoft cookie is still not in Fabrikam")
        for c in await t.httpCookieStore.allCookies() where c.name.hasPrefix("ismith_relaunch") || c.name == "LSID" { await t.httpCookieStore.deleteCookie(c) }
        for c in await b.httpCookieStore.allCookies() where c.name.hasPrefix("ismith_relaunch") || c.name == "ESTSAUTH" { await b.httpCookieStore.deleteCookie(c) }
        await settle()
        print(failures.isEmpty ? "RELAUNCH OK" : "RELAUNCH FAILED: \(failures.count)")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// Shared-by-default sign-ins: new spaces need no setup, overrides still isolate, and an older
    /// per-space config migrates.
    private func configPhase() async {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "PASS  " : "FAIL  ") + what)
            if !ok { failures.append(what) }
        }
        let config = browser.config
        await wipeTestStores()
        let hour = Date().addingTimeInterval(3600)
        let m = await sync.attach(config.space("contoso")!)
        let t = await sync.attach(config.space("fabrikam")!)
        let s = await sync.attach(config.space("newtro")!)
        await m.httpCookieStore.setCookie(cookie("SID", "c1", ".google.com", expires: hour))
        await s.httpCookieStore.setCookie(cookie("ESTSAUTHPERSISTENT", "s1", "login.microsoftonline.com", expires: hour, secure: true))
        await t.httpCookieStore.setCookie(cookie("ESTSAUTHPERSISTENT", "t1", "login.microsoftonline.com", expires: hour, secure: true))
        await settle()

        // The complaint: a new space should already be signed in to everything.
        browser.createSpace(name: "Fresh", color: 5, home: "", choices: [:], newNames: [:])
        let fresh = config.spaces.first { $0.name == "Fresh" }!
        let f = await sync.attach(fresh)
        check(fresh.bindings.isEmpty, "New space needs no account setup")
        check(await value(f, "SID") == "c1", "New space is signed in to Google from another space's sign-in")
        check(await value(f, "ESTSAUTHPERSISTENT") == "s1", "New space is signed in to the shared Microsoft session")
        check(await value(t, "ESTSAUTHPERSISTENT") == "t1", "A space with a separate Microsoft account keeps its own")

        // A separate account stays separate.
        browser.createSpace(name: "Separate", color: 6, home: "", choices: ["google": .new], newNames: ["google": "Second Google"])
        let sep = config.spaces.first { $0.name == "Separate" }!
        let n = await sync.attach(sep)
        check(await value(n, "SID") == nil, "Space with a new separate Google account starts signed out")
        await n.httpCookieStore.setCookie(cookie("SID", "n1", ".google.com", expires: hour))
        await settle()
        let (mSID2, fSID2) = (await value(m, "SID"), await value(f, "SID"))
        check(mSID2 == "c1" && fSID2 == "c1", "Separate account doesn't leak into shared spaces")

        // Moving a space between its separate account and the shared one.
        update("fabrikam") { $0["microsoft"] = .shared }
        await settle()
        check(await value(t, "ESTSAUTHPERSISTENT") == "s1", "Switching to Shared loads the shared Microsoft session")
        check(browser.vault.records(for: "ms-fabrikam")?.first { $0.name == "ESTSAUTHPERSISTENT" }?.value == "t1", "The separate account keeps its session for later")
        update("fabrikam") { $0["microsoft"] = .existing("ms-fabrikam") }
        await settle()
        check(await value(t, "ESTSAUTHPERSISTENT") == "t1", "Switching back loads the separate account again")

        // Not shared: the space signs out of the shared Google and keeps its own changes local.
        update("fabrikam") { $0["google"] = .local }
        await settle()
        check(await value(t, "SID") == nil, "Not shared signs the space out of the shared Google")
        await t.httpCookieStore.setCookie(cookie("SID", "z9", ".google.com", expires: hour))
        await settle()
        check(await value(m, "SID") == "c1", "A not-shared space's sign-in stays in that space")
        update("fabrikam") { $0["google"] = .shared }
        await settle()
        check(await value(t, "SID") == "c1", "Back on Shared, the space is signed in again")

        // Custom providers are shared by default too.
        check(config.addProvider(name: "Okta", domains: ["https://contoso.okta.com/app"], sessionNames: []) == nil, "Provider from a pasted URL is added")
        let okta = config.providers.last!
        check(okta.domains == ["contoso.okta.com"] && config.shared[okta.id] != nil, "Custom provider gets a shared sign-in")
        await m.httpCookieStore.setCookie(cookie("sid", "o1", "contoso.okta.com", expires: hour, secure: true))
        await settle()
        check(await value(f, "sid") == "o1", "Custom provider sign-in reaches other spaces")
        check(config.addProvider(name: "Workspace", domains: ["mail.google.com"], sessionNames: []) != nil, "Provider overlapping Google is refused")

        // Two spaces change the same Microsoft session cookie: the newest change wins everywhere.
        await f.httpCookieStore.setCookie(cookie("ESTSAUTH", "older", "login.microsoftonline.com", expires: nil, secure: true))
        try? await Task.sleep(nanoseconds: 150_000_000)
        await s.httpCookieStore.setCookie(cookie("ESTSAUTH", "newer", "login.microsoftonline.com", expires: nil, secure: true))
        await settle()
        let (fE, sE) = (await value(f, "ESTSAUTH"), await value(s, "ESTSAUTH"))
        check(fE == "newer" && sE == "newer", "Newest Microsoft session change wins in every space")
        await f.httpCookieStore.setCookie(cookie("esctx", "only-f", "login.microsoftonline.com", expires: nil, secure: true))
        await settle()
        check(await value(s, "esctx") == nil, "Per-sign-in Microsoft cookies stay in their space")

        // A migrated space that holds its own GitHub sign-in keeps it on first open.
        await m.httpCookieStore.setCookie(cookie("user_session", "g1", "github.com", expires: hour, secure: true))
        await settle()
        let personal = config.space("personal")!
        await WKWebsiteDataStore(forIdentifier: personal.storeID).httpCookieStore
            .setCookie(cookie("user_session", "own1", "github.com", expires: hour, secure: true))
        config.markPendingAdoption("personal", providers: ["github"])
        let p = await sync.attach(personal)
        await settle()
        let kept = config.space("personal")?.bindings["github"]
        check(kept != nil && kept != config.shared["github"], "Space's own GitHub sign-in becomes a separate account")
        check(await value(p, "user_session") == "own1", "Its own sign-in is not replaced")
        check(await value(m, "user_session") == "g1", "The shared GitHub sign-in is untouched")

        // The shared GitHub entry holds only a signed-out cookie: a migrated space's own sign-in
        // becomes the shared one instead of being deleted.
        if let c = await find(m, "user_session") { await m.httpCookieStore.deleteCookie(c) }
        await m.httpCookieStore.setCookie(cookie("logged_in", "no", ".github.com", expires: hour))
        await settle()
        let newtro = config.space("newtro")!
        await sync.detach("newtro")
        let nStore = WKWebsiteDataStore(forIdentifier: newtro.storeID)
        await nStore.httpCookieStore.setCookie(cookie("user_session", "mine", "github.com", expires: hour, secure: true))
        config.markPendingAdoption("newtro", providers: ["github"])
        let nAgain = await sync.attach(newtro)
        await settle()
        check(await value(nAgain, "user_session") == "mine", "Own sign-in survives when the shared one is signed out")
        check(await value(m, "user_session") == "mine", "That sign-in becomes the shared one for other spaces")

        // An older per-space config moves to shared sign-ins, keeping the most-used sessions.
        let old = AppPaths.dir.appendingPathComponent("migrate-test.json")
        let v1 = """
        {"providers":[],"accounts":[{"id":"ms-contoso","providerID":"microsoft","name":"Contoso"},
         {"id":"ms-fabrikam","providerID":"microsoft","name":"Fabrikam"},
         {"id":"google-personal","providerID":"google","name":"personal"},
         {"id":"google-newtro","providerID":"google","name":"Newtro Studios"}],
         "spaces":[
          {"id":"a","name":"A","color":0,"storeID":"6F1C2A40-0000-4000-9000-0000000000A1","bindings":{"microsoft":"ms-contoso","google":"google-personal"},"home":""},
          {"id":"b","name":"B","color":1,"storeID":"6F1C2A40-0000-4000-9000-0000000000A2","bindings":{"microsoft":"ms-fabrikam","google":"google-personal"},"home":""},
          {"id":"c","name":"C","color":2,"storeID":"6F1C2A40-0000-4000-9000-0000000000A3","bindings":{"microsoft":"ms-contoso"},"home":""},
          {"id":"d","name":"D","color":3,"storeID":"6F1C2A40-0000-4000-9000-0000000000A4","bindings":{"google":"google-newtro"},"home":""}]}
        """
        try? v1.data(using: .utf8)!.write(to: old)
        let migrated = Config(fileURL: old, hasSession: { ["ms-contoso", "ms-fabrikam", "google-personal"].contains($0) })
        check(migrated.space("b")?.bindings == ["microsoft": "ms-fabrikam"], "Migration keeps a second signed-in account as separate")
        check(migrated.space("d")?.bindings.isEmpty == true, "Migration moves an account with no session to the shared one")
        check(migrated.pendingAdoption["a"] == ["microsoft-personal", "github"],
              "Providers a space already shared aren't re-checked on first open")
        check(migrated.pendingAdoption["d"]?.contains("google") == true, "A no-session account's cookies are checked on first open")
        check(migrated.shared["microsoft"] == "ms-contoso" && migrated.shared["google"] == "google-personal",
              "Migration keeps the most-used sessions as the shared ones")
        try? FileManager.default.removeItem(at: old)

        for def in config.spaces where ["Fresh", "Separate"].contains(def.name) {
            browser.spaces.first { $0.id == def.id }.map { state in state.tabs.forEach { browser.close($0, in: state) } }
            await sync.detach(def.id)
            try? await WKWebsiteDataStore.remove(forIdentifier: def.storeID)
        }
        print(failures.isEmpty ? "CONFIG OK" : "CONFIG FAILED: \(failures.count)")
        exit(failures.isEmpty ? 0 : 1)
    }

    private func update(_ spaceID: String, _ change: (inout [String: AccountChoice]) -> Void) {
        let def = browser.config.space(spaceID)!
        var choices = def.bindings.mapValues { $0 == SpaceDef.local ? AccountChoice.local : .existing($0) }
        change(&choices)
        browser.updateSpace(spaceID, name: def.name, color: def.color, home: def.home, choices: choices, newNames: [:], confirm: false)
    }

    /// Test stores are reused between runs (WebKit keeps them by identifier), so each suite starts
    /// by clearing them. Only the self-test's own stores are touched.
    private func wipeTestStores() async {
        precondition(AppPaths.isSelfTest)
        for def in browser.config.spaces {
            await WKWebsiteDataStore(forIdentifier: def.storeID)
                .removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }

    private func find(_ store: WKWebsiteDataStore, _ name: String) async -> HTTPCookie? {
        await store.httpCookieStore.allCookies().first { $0.name == name }
    }

    private func value(_ store: WKWebsiteDataStore, _ name: String) async -> String? {
        await find(store, name)?.value
    }

    private func cookie(_ name: String, _ value: String, _ domain: String, expires: Date?,
                        secure: Bool = false, httpOnly: Bool = false) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
        if let expires { props[.expires] = expires }
        if secure { props[.secure] = "TRUE" }
        if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: props)!
    }
}
