import SignInSync
import WebKit
import XCTest

/// Space and account removal through SpaceManager, which the spike only exercised by hand.
@MainActor
final class SpaceManagerTests: XCTestCase {
    private var fx: Fixture!

    override func setUp() async throws {
        fx = try Fixture()
    }

    override func tearDown() async throws {
        await fx.tearDown()
        fx = nil
    }

    func testDeletingASpaceDeletesItsBrowsingData() async {
        let def = fx.manager.createSpace(name: "Short-lived", color: 2, home: "", choices: [:], newNames: [:])
        fx.track(def)
        await plant(in: def)
        let before = await WKWebsiteDataStore.allDataStoreIdentifiers
        XCTAssertTrue(before.contains(def.storeID), "precondition: the space has a store on disk")
        await fx.manager.deleteSpace(def.id).value
        XCTAssertNil(fx.config.space(def.id))
        XCTAssertFalse(fx.sync.attached.contains(def.id))
        let left = await WKWebsiteDataStore.allDataStoreIdentifiers
        XCTAssertFalse(left.contains(def.storeID), "the space's WebKit store is gone")
    }

    /// Opens the space and gives it a site cookie, holding the store only for this call.
    private func plant(in def: SpaceDef) async {
        let store = await fx.sync.attach(def)
        await store.httpCookieStore.setCookie(cookie("session", "x", "www.etsy.com", expires: Date().addingTimeInterval(3600)))
    }

    func testRemovingAccountsAndProviders() {
        let sep = fx.config.addAccount(providerID: "google", name: "Second Google")
        fx.vault.set([CookieRecord(cookie("SID", "g2", ".google.com", expires: nil))], for: sep.id)
        fx.manager.removeAccount("ms-fabrikam")
        XCTAssertNotNil(fx.config.account("ms-fabrikam"), "an account a space uses stays")
        fx.manager.removeAccount("shared-google")
        XCTAssertNotNil(fx.config.account("shared-google"), "a shared account stays")
        fx.manager.removeAccount(sep.id)
        XCTAssertNil(fx.config.account(sep.id))
        XCTAssertNil(fx.vault.records(for: sep.id), "its saved sign-in is deleted")

        XCTAssertNil(fx.config.addProvider(name: "Okta", domains: ["okta.com"], sessionNames: []))
        let okta = fx.config.providers.last!
        let shared = fx.config.shared[okta.id]!
        fx.vault.set([CookieRecord(cookie("sid", "o1", "okta.com", expires: nil))], for: shared)
        fx.manager.removeProvider(okta.id)
        XCTAssertNil(fx.config.provider(okta.id))
        XCTAssertNil(fx.vault.records(for: shared), "the provider's shared sign-in is deleted")
        fx.manager.removeProvider("google")
        XCTAssertNotNil(fx.config.provider("google"), "built-in providers stay")
    }
}
