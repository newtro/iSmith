import SignInSync
import WebKit
import XCTest

/// Session-only cookies survive a relaunch, the case only the vault can cover: WebKit drops them
/// when the app quits. Ported from the spike's `--phase=write` and `--phase=read` (3 checks), with
/// one more: the space that had the cookie gets it back too.
///
/// The spike ran two processes. Here the relaunch is new Vault, Config and CookieSync instances on
/// the same files. WebKit keeps session cookies for the life of the process, so the test deletes
/// the cookie from the target stores itself and checks they really lack it before reopening.
@MainActor
final class RelaunchTests: XCTestCase {
    private var fx: Fixture!

    override func setUp() async throws {
        fx = try Fixture()
    }

    override func tearDown() async throws {
        await fx.tearDown()
        fx = nil
    }

    func testSessionCookiesAreRestoredFromTheVault() async {
        // First launch: sign-in cookies, one of them session-only, appear in Contoso; then quit.
        let m = await fx.attach("contoso")
        await m.httpCookieStore.setCookie(cookie("LSID", "s1", "accounts.google.com", expires: nil, secure: true))
        await m.httpCookieStore.setCookie(cookie("ESTSAUTH", "m1", "login.microsoftonline.com",
                                                 expires: Date().addingTimeInterval(3600), secure: true))
        await settle()
        await fx.relaunch()

        // What WebKit does at quit: the session cookie is gone from every store.
        for id in ["contoso", "fabrikam", "contoso-b"] {
            let store = fx.store(id)
            for c in await store.httpCookieStore.allCookies() where c.name == "LSID" || c.name == "ESTSAUTH" {
                await store.httpCookieStore.deleteCookie(c)
            }
            let left = await store.httpCookieStore.allCookies().map(\.name)
            XCTAssertFalse(left.contains("LSID"), "precondition: \(id) has no LSID before reopening")
            XCTAssertFalse(left.contains("ESTSAUTH"), "precondition: \(id) has no ESTSAUTH before reopening")
        }

        // Second launch: spaces that were never opened before are seeded from the vault.
        let t = await fx.attach("fabrikam")
        let b = await fx.attach("contoso-b")
        check(await valueOf(t, "LSID") == "s1", "After relaunch, Google session cookie is in Fabrikam")
        check(await valueOf(b, "ESTSAUTH") == "m1", "After relaunch, Contoso Microsoft cookie is in the second Contoso space")
        check(await valueOf(t, "ESTSAUTH") == nil, "After relaunch, Contoso Microsoft cookie is still not in Fabrikam")
        let m2 = await fx.attach("contoso")
        check(await valueOf(m2, "LSID") == "s1", "After relaunch, Contoso gets back the session cookie WebKit dropped")
    }
}
