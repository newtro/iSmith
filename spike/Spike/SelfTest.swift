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
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "PASS  " : "FAIL  ") + what)
            if !ok { failures.append(what) }
        }

        let byID = Dictionary(uniqueKeysWithValues: Seed.spaces.map { ($0.id, $0) })
        let m = await sync.attach(byID["contoso"]!)
        let t = await sync.attach(byID["fabrikam"]!)
        let b = await sync.attach(byID["contoso-b"]!)
        let p = await sync.attach(byID["personal"]!)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let hour = Date().addingTimeInterval(3600)
        let gPersistent = cookie("ismith_probe_g", "v1", ".google.com", expires: hour)
        let gSession = cookie("ismith_probe_gs", "s1", "accounts.google.com", expires: nil, secure: true, httpOnly: true)
        let msHost = cookie("ismith_probe_ms", "m1", "login.microsoftonline.com", expires: hour, secure: true, httpOnly: true)
        let gHostPrefix = cookie("__Host-ismith_probe", "h1", "accounts.google.com", expires: hour, secure: true)

        await m.httpCookieStore.setCookie(gPersistent)
        await m.httpCookieStore.setCookie(gSession)
        await m.httpCookieStore.setCookie(gHostPrefix)
        await m.httpCookieStore.setCookie(msHost)
        await settle()

        check(await value(t, "ismith_probe_g") == "v1", "Google cookie set in Contoso reaches Fabrikam")
        check(await value(p, "ismith_probe_g") == "v1", "Google cookie set in Contoso reaches Personal")
        check(await value(b, "ismith_probe_g") == nil, "Google cookie does not reach Contoso (second space), which has no Google account")
        check(await value(t, "ismith_probe_gs") == "s1", "Google session cookie reaches Fabrikam")
        check(await find(t, "ismith_probe_gs")?.isHTTPOnly == true, "HttpOnly flag survives the copy")
        check(await find(t, "__Host-ismith_probe")?.domain == "accounts.google.com", "__Host- cookie stays host-only")
        check(await value(b, "ismith_probe_ms") == "m1", "Contoso Microsoft cookie reaches Contoso (second space)")
        check(await value(t, "ismith_probe_ms") == nil, "Contoso Microsoft cookie does not reach Fabrikam")
        check(await find(b, "ismith_probe_ms")?.domain == "login.microsoftonline.com", "Microsoft host-only cookie stays host-only")

        await t.httpCookieStore.setCookie(cookie("ismith_probe_g", "v2", ".google.com", expires: hour))
        await settle()
        check(await value(m, "ismith_probe_g") == "v2", "Change made in Fabrikam flows back to Contoso")
        check(await value(p, "ismith_probe_g") == "v2", "Change made in Fabrikam reaches Personal")

        for c in await p.httpCookieStore.allCookies() where c.name.hasPrefix("ismith_probe_g") || c.name == "__Host-ismith_probe" {
            await p.httpCookieStore.deleteCookie(c)
        }
        await settle()
        check(await value(m, "ismith_probe_g") == nil, "Sign-out (deleted cookie) in Personal spreads to Contoso")
        check(await value(t, "ismith_probe_gs") == nil, "Sign-out in Personal spreads to Fabrikam")

        if let c = await find(b, "ismith_probe_ms") { await b.httpCookieStore.deleteCookie(c) }
        await settle()
        check(await value(m, "ismith_probe_ms") == nil, "Microsoft sign-out in second space spreads to Contoso")

        let saved = Vault()
        let leftovers = saved.entries.values.flatMap(\.cookies).filter { $0.name.contains("ismith_probe") }
        check(leftovers.isEmpty, "Vault on disk holds no probe cookies after cleanup")

        print(failures.isEmpty ? "SELFTEST OK" : "SELFTEST FAILED: \(failures.count)")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// Relaunch test, part 1: sign-in cookies (one session-only) appear in Contoso, then the app quits.
    private func writePhase() async {
        let m = await sync.attach(Seed.spaces.first { $0.id == "contoso" }!)
        await m.httpCookieStore.setCookie(cookie("ismith_relaunch_gs", "s1", "accounts.google.com", expires: nil, secure: true))
        await m.httpCookieStore.setCookie(cookie("ismith_relaunch_ms", "m1", "login.microsoftonline.com",
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
        let t = await sync.attach(Seed.spaces.first { $0.id == "fabrikam" }!)
        let b = await sync.attach(Seed.spaces.first { $0.id == "contoso-b" }!)
        check(await value(t, "ismith_relaunch_gs") == "s1", "After relaunch, Google session cookie is in Fabrikam")
        check(await value(b, "ismith_relaunch_ms") == "m1", "After relaunch, Contoso Microsoft cookie is in the second Contoso space")
        check(await value(t, "ismith_relaunch_ms") == nil, "After relaunch, Contoso Microsoft cookie is still not in Fabrikam")
        for c in await t.httpCookieStore.allCookies() where c.name.hasPrefix("ismith_relaunch") { await t.httpCookieStore.deleteCookie(c) }
        for c in await b.httpCookieStore.allCookies() where c.name.hasPrefix("ismith_relaunch") { await b.httpCookieStore.deleteCookie(c) }
        await settle()
        print(failures.isEmpty ? "RELAUNCH OK" : "RELAUNCH FAILED: \(failures.count)")
        exit(failures.isEmpty ? 0 : 1)
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
