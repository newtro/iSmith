import SignInSync
import WebKit
import XCTest

/// Cookie sharing between open spaces without real sign-ins: probe cookies are written on provider
/// domains in one space, and the tests check which other spaces receive them. Ported from the
/// spike's `--selftest` (18 checks).
@MainActor
final class SharingTests: XCTestCase {
    private var fx: Fixture!
    private let hour = Date().addingTimeInterval(3600)

    override func setUp() async throws {
        fx = try Fixture()
    }

    override func tearDown() async throws {
        await fx.tearDown()
        fx = nil
    }

    /// Opens Contoso, Fabrikam, Contoso (second space) and Personal.
    private func openSpaces() async -> (m: WKWebsiteDataStore, t: WKWebsiteDataStore, b: WKWebsiteDataStore, p: WKWebsiteDataStore) {
        let m = await fx.attach("contoso")
        let t = await fx.attach("fabrikam")
        let b = await fx.attach("contoso-b")
        let p = await fx.attach("personal")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return (m, t, b, p)
    }

    func testSignInCookiesReachOnlySpacesUsingTheAccount() async {
        let (m, t, b, p) = await openSpaces()
        await m.httpCookieStore.setCookie(cookie("SID", "v1", ".google.com", expires: hour))
        await m.httpCookieStore.setCookie(cookie("LSID", "s1", "accounts.google.com", expires: nil, secure: true, httpOnly: true))
        await m.httpCookieStore.setCookie(cookie("__Host-GAPS", "h1", "accounts.google.com", expires: hour, secure: true))
        await m.httpCookieStore.setCookie(cookie("ESTSAUTHPERSISTENT", "m1", "login.microsoftonline.com", expires: hour, secure: true, httpOnly: true))
        await m.httpCookieStore.setCookie(cookie("NID", "n1", ".google.com", expires: hour))
        await settle()
        check(await valueOf(t, "NID") == nil, "Google tracking cookie (NID) is not shared")

        check(await valueOf(t, "SID") == "v1", "Google cookie set in Contoso reaches Fabrikam")
        check(await valueOf(p, "SID") == "v1", "Google cookie set in Contoso reaches Personal")
        check(await valueOf(b, "SID") == nil, "Google cookie does not reach Contoso (second space), which has no Google account")
        check(await valueOf(t, "LSID") == "s1", "Google session cookie reaches Fabrikam")
        check(await find(t, "LSID")?.isHTTPOnly == true, "HttpOnly flag survives the copy")
        check(await find(t, "__Host-GAPS")?.domain == "accounts.google.com", "__Host- cookie stays host-only")
        check(await valueOf(b, "ESTSAUTHPERSISTENT") == "m1", "Contoso Microsoft cookie reaches Contoso (second space)")
        check(await valueOf(t, "ESTSAUTHPERSISTENT") == nil, "Contoso Microsoft cookie does not reach Fabrikam")
        check(await find(b, "ESTSAUTHPERSISTENT")?.domain == "login.microsoftonline.com", "Microsoft host-only cookie stays host-only")
    }

    func testChangesFlowBetweenSpaces() async {
        let (m, t, _, p) = await openSpaces()
        await m.httpCookieStore.setCookie(cookie("SID", "v1", ".google.com", expires: hour))
        await settle()

        await t.httpCookieStore.setCookie(cookie("SID", "v2", ".google.com", expires: hour))
        await settle()
        check(await valueOf(m, "SID") == "v2", "Change made in Fabrikam flows back to Contoso")
        check(await valueOf(p, "SID") == "v2", "Change made in Fabrikam reaches Personal")

        // Two spaces change different sign-in cookies at the same moment; neither change may be lost.
        async let a: Void = m.httpCookieStore.setCookie(cookie("HSID", "x1", ".google.com", expires: hour))
        async let c: Void = p.httpCookieStore.setCookie(cookie("SSID", "y1", ".google.com", expires: hour))
        _ = await (a, c)
        await settle()
        let (tH, tS) = (await valueOf(t, "HSID"), await valueOf(t, "SSID"))
        let (mS, pH) = (await valueOf(m, "SSID"), await valueOf(p, "HSID"))
        check(tH == "x1" && tS == "y1", "Simultaneous changes in two spaces both reach Fabrikam")
        check(mS == "y1" && pH == "x1", "Simultaneous changes cross over between the two spaces")
    }

    /// Two spaces change the same sign-in cookie before a sync: the newer change wins, per cookie,
    /// even when the space with the older change keeps changing other cookies afterwards (a busy
    /// page in Contoso used to make all of Contoso "newest" and undo Fabrikam's sign-in).
    func testNewestChangeWinsPerCookie() async {
        let (m, t, _, p) = await openSpaces()
        await m.httpCookieStore.setCookie(cookie("SID", "v0", ".google.com", expires: hour))
        await settle()

        // All of this happens within the 0.4 s debounce, so one reconcile sees every change.
        await m.httpCookieStore.setCookie(cookie("SID", "older", ".google.com", expires: hour))
        try? await Task.sleep(nanoseconds: 150_000_000)
        await t.httpCookieStore.setCookie(cookie("SID", "newer", ".google.com", expires: hour))
        try? await Task.sleep(nanoseconds: 100_000_000)
        await m.httpCookieStore.setCookie(cookie("HSID", "h1", ".google.com", expires: hour))
        await m.httpCookieStore.setCookie(cookie("NID", "busy", ".google.com", expires: hour))
        await settle()

        let sids = [await valueOf(m, "SID"), await valueOf(t, "SID"), await valueOf(p, "SID")]
        check(sids == ["newer", "newer", "newer"], "The newer SID (Fabrikam) wins everywhere: \(sids)")
        let hsids = [await valueOf(m, "HSID"), await valueOf(t, "HSID"), await valueOf(p, "HSID")]
        check(hsids == ["h1", "h1", "h1"], "Contoso' later change to another cookie still spreads: \(hsids)")
        let vault = fx.vault.records(for: fx.config.shared["google"]!)?.first { $0.name == "SID" }?.value
        check(vault == "newer", "The vault keeps the newer SID")
    }

    func testSignOutSpreadsAndLeavesTheVaultClean() async {
        let (m, t, b, p) = await openSpaces()
        await m.httpCookieStore.setCookie(cookie("SID", "v2", ".google.com", expires: hour))
        await m.httpCookieStore.setCookie(cookie("LSID", "s1", "accounts.google.com", expires: nil, secure: true, httpOnly: true))
        await m.httpCookieStore.setCookie(cookie("__Host-GAPS", "h1", "accounts.google.com", expires: hour, secure: true))
        await m.httpCookieStore.setCookie(cookie("HSID", "x1", ".google.com", expires: hour))
        await m.httpCookieStore.setCookie(cookie("SSID", "y1", ".google.com", expires: hour))
        await m.httpCookieStore.setCookie(cookie("ESTSAUTHPERSISTENT", "m1", "login.microsoftonline.com", expires: hour, secure: true, httpOnly: true))
        await settle()
        let (pSID, bMS) = (await valueOf(p, "SID"), await valueOf(b, "ESTSAUTHPERSISTENT"))
        XCTAssertEqual(pSID, "v2", "precondition: Personal is signed in to Google")
        XCTAssertEqual(bMS, "m1", "precondition: the second Contoso space is signed in")

        let probes: Set<String> = ["SID", "LSID", "__Host-GAPS", "HSID", "SSID"]
        for c in await p.httpCookieStore.allCookies() where probes.contains(c.name) {
            await p.httpCookieStore.deleteCookie(c)
        }
        await settle()
        check(await valueOf(m, "SID") == nil, "Sign-out (deleted cookie) in Personal spreads to Contoso")
        check(await valueOf(t, "LSID") == nil, "Sign-out in Personal spreads to Fabrikam")

        if let c = await find(b, "ESTSAUTHPERSISTENT") { await b.httpCookieStore.deleteCookie(c) }
        await settle()
        check(await valueOf(m, "ESTSAUTHPERSISTENT") == nil, "Microsoft sign-out in second space spreads to Contoso")

        // Read back from disk, decrypted with the same key, as the next launch would.
        let saved = Vault(fileURL: fx.vaultURL, keyStore: fx.keyStore)
        let leftovers = saved.entries.values.flatMap(\.cookies)
            .filter { $0.value != "" && ($0.name.contains("ismith_probe") || probes.contains($0.name) || $0.name == "ESTSAUTHPERSISTENT") }
        check(leftovers.isEmpty, "Vault on disk holds no probe cookies after cleanup")
    }
}
