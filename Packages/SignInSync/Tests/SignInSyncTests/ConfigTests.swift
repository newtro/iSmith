import Foundation
import SignInSync
import WebKit
import XCTest

/// Shared-by-default sign-ins: new spaces need no setup, overrides still isolate, custom providers
/// share too, and an older per-space config migrates without losing a sign-in. Ported from the
/// spike's `--phase=config` (28 checks).
@MainActor
final class ConfigTests: XCTestCase {
    private var fx: Fixture!
    private let hour = Date().addingTimeInterval(3600)
    private var config: Config { fx.config }

    override func setUp() async throws {
        fx = try Fixture()
    }

    override func tearDown() async throws {
        await fx.tearDown()
        fx = nil
    }

    /// The spike's starting point: Contoso signed in to Google; Newtro Studios to the shared
    /// Microsoft session; Fabrikam to its separate Microsoft account.
    private func signInBasics() async -> (m: WKWebsiteDataStore, t: WKWebsiteDataStore, s: WKWebsiteDataStore) {
        let m = await fx.attach("contoso")
        let t = await fx.attach("fabrikam")
        let s = await fx.attach("newtro")
        await m.httpCookieStore.setCookie(cookie("SID", "c1", ".google.com", expires: hour))
        await s.httpCookieStore.setCookie(cookie("ESTSAUTHPERSISTENT", "s1", "login.microsoftonline.com", expires: hour, secure: true))
        await t.httpCookieStore.setCookie(cookie("ESTSAUTHPERSISTENT", "t1", "login.microsoftonline.com", expires: hour, secure: true))
        await settle()
        return (m, t, s)
    }

    private func createSpace(_ name: String, choices: [String: AccountChoice] = [:], newNames: [String: String] = [:]) -> SpaceDef {
        let def = fx.manager.createSpace(name: name, color: 5, home: "", choices: choices, newNames: newNames)
        fx.track(def)
        return def
    }

    /// Edits a space's account choices the way the space editor does, and waits for the switch.
    private func update(_ spaceID: String, _ change: (inout [String: AccountChoice]) -> Void) async {
        let def = fx.space(spaceID)
        var choices = AccountChoice.current(in: def)
        change(&choices)
        await fx.manager.updateSpace(spaceID, name: def.name, color: def.color, home: def.home,
                                     choices: choices, newNames: [:])?.value
    }

    func testNewSpaceIsSignedInEverywhere() async {
        let (_, t, _) = await signInBasics()
        // The complaint: a new space should already be signed in to everything.
        let fresh = createSpace("Fresh")
        let f = await fx.sync.attach(fresh)
        check(fresh.bindings.isEmpty, "New space needs no account setup")
        check(await valueOf(f, "SID") == "c1", "New space is signed in to Google from another space's sign-in")
        check(await valueOf(f, "ESTSAUTHPERSISTENT") == "s1", "New space is signed in to the shared Microsoft session")
        check(await valueOf(t, "ESTSAUTHPERSISTENT") == "t1", "A space with a separate Microsoft account keeps its own")
    }

    func testSeparateAccountStaysSeparate() async {
        let (m, _, _) = await signInBasics()
        let f = await fx.sync.attach(createSpace("Fresh"))
        let sep = createSpace("Separate", choices: ["google": .new], newNames: ["google": "Second Google"])
        let n = await fx.sync.attach(sep)
        check(await valueOf(n, "SID") == nil, "Space with a new separate Google account starts signed out")
        await n.httpCookieStore.setCookie(cookie("SID", "n1", ".google.com", expires: hour))
        await settle()
        let (mSID2, fSID2) = (await valueOf(m, "SID"), await valueOf(f, "SID"))
        check(mSID2 == "c1" && fSID2 == "c1", "Separate account doesn't leak into shared spaces")
    }

    func testSwitchingBetweenSeparateAndSharedAccounts() async {
        let (_, t, _) = await signInBasics()
        await update("fabrikam") { $0["microsoft"] = .shared }
        await settle()
        check(await valueOf(t, "ESTSAUTHPERSISTENT") == "s1", "Switching to Shared loads the shared Microsoft session")
        check(fx.vault.records(for: "ms-fabrikam")?.first { $0.name == "ESTSAUTHPERSISTENT" }?.value == "t1",
              "The separate account keeps its session for later")
        await update("fabrikam") { $0["microsoft"] = .existing("ms-fabrikam") }
        await settle()
        check(await valueOf(t, "ESTSAUTHPERSISTENT") == "t1", "Switching back loads the separate account again")
    }

    func testNotSharedKeepsSignInsInTheSpace() async {
        let (m, t, _) = await signInBasics()
        // Not shared: the space signs out of the shared Google and keeps its own changes local.
        await update("fabrikam") { $0["google"] = .local }
        await settle()
        check(await valueOf(t, "SID") == nil, "Not shared signs the space out of the shared Google")
        await t.httpCookieStore.setCookie(cookie("SID", "z9", ".google.com", expires: hour))
        await settle()
        check(await valueOf(m, "SID") == "c1", "A not-shared space's sign-in stays in that space")
        await update("fabrikam") { $0["google"] = .shared }
        await settle()
        check(await valueOf(t, "SID") == "c1", "Back on Shared, the space is signed in again")
    }

    func testCustomProvidersAreSharedByDefault() async {
        let (m, _, _) = await signInBasics()
        let f = await fx.sync.attach(createSpace("Fresh"))
        check(config.addProvider(name: "Okta", domains: ["https://contoso.okta.com/app"], sessionNames: []) == nil,
              "Provider from a pasted URL is added")
        let okta = config.providers.last!
        check(okta.domains == ["contoso.okta.com"] && config.shared[okta.id] != nil, "Custom provider gets a shared sign-in")
        await m.httpCookieStore.setCookie(cookie("sid", "o1", "contoso.okta.com", expires: hour, secure: true))
        await settle()
        check(await valueOf(f, "sid") == "o1", "Custom provider sign-in reaches other spaces")
        check(config.addProvider(name: "Workspace", domains: ["mail.google.com"], sessionNames: []) != nil,
              "Provider overlapping Google is refused")
    }

    func testNewestSessionChangeWins() async {
        let (_, _, s) = await signInBasics()
        let f = await fx.sync.attach(createSpace("Fresh"))
        // Two spaces change the same Microsoft session cookie: the newest change wins everywhere.
        await f.httpCookieStore.setCookie(cookie("ESTSAUTH", "older", "login.microsoftonline.com", expires: nil, secure: true))
        try? await Task.sleep(nanoseconds: 150_000_000)
        await s.httpCookieStore.setCookie(cookie("ESTSAUTH", "newer", "login.microsoftonline.com", expires: nil, secure: true))
        await settle()
        let (fE, sE) = (await valueOf(f, "ESTSAUTH"), await valueOf(s, "ESTSAUTH"))
        check(fE == "newer" && sE == "newer", "Newest Microsoft session change wins in every space")
        await f.httpCookieStore.setCookie(cookie("esctx", "only-f", "login.microsoftonline.com", expires: nil, secure: true))
        await settle()
        check(await valueOf(s, "esctx") == nil, "Per-sign-in Microsoft cookies stay in their space")
    }

    func testMigratedSpaceKeepsItsOwnSignIn() async {
        let (m, _, _) = await signInBasics()
        // A migrated space that holds its own GitHub sign-in keeps it on first open.
        await m.httpCookieStore.setCookie(cookie("user_session", "g1", "github.com", expires: hour, secure: true))
        await settle()
        await fx.store("personal").httpCookieStore
            .setCookie(cookie("user_session", "own1", "github.com", expires: hour, secure: true))
        config.markPendingAdoption("personal", providers: ["github"])
        let p = await fx.attach("personal")
        await settle()
        let kept = config.space("personal")?.bindings["github"]
        check(kept != nil && kept != config.shared["github"], "Space's own GitHub sign-in becomes a separate account")
        check(await valueOf(p, "user_session") == "own1", "Its own sign-in is not replaced")
        check(await valueOf(m, "user_session") == "g1", "The shared GitHub sign-in is untouched")
    }

    func testOwnSignInBecomesSharedWhenTheSharedOneIsSignedOut() async {
        let (m, _, _) = await signInBasics()
        // The shared GitHub entry holds only a signed-out cookie: a migrated space's own sign-in
        // becomes the shared one instead of being deleted.
        await m.httpCookieStore.setCookie(cookie("logged_in", "no", ".github.com", expires: hour))
        await settle()
        XCTAssertEqual(fx.vault.records(for: "shared-github")?.map(\.name), ["logged_in"],
                       "precondition: the shared GitHub sign-in is signed out")
        await fx.sync.detach("newtro")
        await fx.store("newtro").httpCookieStore
            .setCookie(cookie("user_session", "mine", "github.com", expires: hour, secure: true))
        config.markPendingAdoption("newtro", providers: ["github"])
        let nAgain = await fx.attach("newtro")
        await settle()
        check(await valueOf(nAgain, "user_session") == "mine", "Own sign-in survives when the shared one is signed out")
        check(await valueOf(m, "user_session") == "mine", "That sign-in becomes the shared one for other spaces")
    }

    func testSpaceOrderIsSavedAcrossRelaunch() {
        let before = config.spaces.map(\.id)
        XCTAssertGreaterThanOrEqual(before.count, 3, "precondition: the fixture has three spaces")
        config.moveSpace(before[0], to: 2)
        var expected = before
        expected.insert(expected.remove(at: 0), at: 2)
        check(config.spaces.map(\.id) == expected, "Moving a space puts it at the new position")
        config.moveSpace(before[1], to: -5)
        config.moveSpace("no-such-space", to: 0)
        expected.insert(expected.remove(at: expected.firstIndex(of: before[1])!), at: 0)
        check(config.spaces.map(\.id) == expected, "Indexes are clamped and unknown spaces ignored")
        let reopened = Config(fileURL: config.fileURL, hasSession: { _ in false })
        check(reopened.spaces.map(\.id) == expected, "The order is the same after a relaunch")
    }

    func testOlderPerSpaceConfigMigrates() {
        // An older per-space config moves to shared sign-ins, keeping the most-used sessions.
        let old = fx.dir.appendingPathComponent("migrate-test.json")
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
        XCTAssertNoThrow(try v1.data(using: .utf8)!.write(to: old))
        let migrated = Config(fileURL: old, hasSession: { ["ms-contoso", "ms-fabrikam", "google-personal"].contains($0) })
        check(migrated.space("b")?.bindings == ["microsoft": "ms-fabrikam"], "Migration keeps a second signed-in account as separate")
        check(migrated.space("d")?.bindings.isEmpty == true, "Migration moves an account with no session to the shared one")
        check(migrated.pendingAdoption["a"] == ["microsoft-personal", "github"],
              "Providers a space already shared aren't re-checked on first open")
        check(migrated.pendingAdoption["d"]?.contains("google") == true, "A no-session account's cookies are checked on first open")
        check(migrated.shared["microsoft"] == "ms-contoso" && migrated.shared["google"] == "google-personal",
              "Migration keeps the most-used sessions as the shared ones")
    }
}
