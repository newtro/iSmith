import CryptoKit
import SignInSync
import XCTest
@testable import iSmith

/// App-level checks, run inside the signed app (TEST_HOST), so the Keychain sees the app's own
/// signature. The sign-in engine itself is tested by the SignInSync package (`swift test`).
@MainActor
final class AppTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("iSmithAppTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testKeychainWorksInTheSignedApp() throws {
        // A throwaway item, so the real vault key is never touched.
        let store = KeychainKeyStore(service: "com.scottsmith.ismith.tests.\(UUID().uuidString)")
        defer { try? store.deleteKey() }
        XCTAssertNil(try store.loadKey())
        let key = SymmetricKey(size: .bits256)
        try store.saveKey(key)
        XCTAssertEqual(try store.loadKey()?.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
    }

    func testFirstLaunchImportsTheSpike() throws {
        let spike = dir.appendingPathComponent("iSmithSpike", isDirectory: true)
        try FileManager.default.createDirectory(at: spike, withIntermediateDirectories: true)
        try Data("""
            {"version":2,"providers":[],"accounts":[],"shared":{},
             "spaces":[{"id":"contoso","name":"Contoso","color":0,"storeID":"6F1C2A40-0000-4000-9000-0000000000D1","bindings":{},"home":""},
                       {"id":"fabrikam","name":"Fabrikam","color":1,"storeID":"6F1C2A40-0000-4000-9000-0000000000D2","bindings":{},"home":""}]}
            """.utf8).write(to: spike.appendingPathComponent("config.json"))
        let sid = HTTPCookie(properties: [.name: "SID", .value: "v1", .domain: ".google.com", .path: "/",
                                          .expires: Date().addingTimeInterval(3600)])!
        try JSONEncoder().encode(["shared-google": Vault.Entry(cookies: [CookieRecord(sid)], updated: Date())])
            .write(to: spike.appendingPathComponent("vault.json"))

        let paths = AppPaths(dataDir: dir.appendingPathComponent("iSmith", isDirectory: true), spikeDir: spike)
        let browser = BrowserState(paths: paths, keyStore: InMemoryKeyStore())
        XCTAssertEqual(browser.spaces.map(\.def.name), ["Contoso", "Fabrikam"])
        XCTAssertEqual(browser.vault.records(for: "shared-google")?.first?.value, "v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configURL.path))
    }

    func testFreshDataFolderStartsWithOneSpace() {
        let paths = AppPaths(dataDir: dir, spikeDir: nil)
        let browser = BrowserState(paths: paths, keyStore: InMemoryKeyStore())
        XCTAssertEqual(browser.spaces.map(\.def.name), ["Personal"])
        XCTAssertEqual(browser.spaces.first?.def.home, "https://mail.google.com/")
        XCTAssertTrue(browser.windows.isEmpty, "windows open only when the app starts them")
    }

    func testAddressInput() {
        XCTAssertEqual(AddressInput.url(for: "https://dev.azure.com/contoso-dev")?.absoluteString, "https://dev.azure.com/contoso-dev")
        XCTAssertEqual(AddressInput.url(for: " github.com ")?.absoluteString, "https://github.com")
        XCTAssertEqual(AddressInput.url(for: "etsy shop stats")?.absoluteString, "https://www.google.com/search?q=etsy%20shop%20stats")
        XCTAssertNil(AddressInput.url(for: "   "))
    }

    func testUserAgentIsSafari() {
        XCTAssertTrue(BrowserState.userAgent.hasSuffix("Safari/605.1.15"))
        XCTAssertTrue(BrowserState.userAgent.contains("Version/"))
    }
}
