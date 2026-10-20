import CodesXPC
import CoreImage
import ServiceManagement
import XCTest
@testable import iSmith

/// iSmith Agent's wiring in the built Debug app: the embedded agent and its launchd plist carry
/// the Debug names, the QR code decodes back to the URI, and (opt-in) the whole path through
/// launchd, XPC and a local fake relay.
@MainActor
final class CodesWiringTests: XCTestCase {
    func testDebugBuildUsesTheDebugAgentNames() throws {
        let identity = CodesClient.identity
        XCTAssertEqual(identity.appBundleID, "com.scottsmith.ismith.debug")
        XCTAssertEqual(identity.agentBundleID, "com.scottsmith.ismith.debug.agent")
        XCTAssertEqual(identity.machServiceName, "232A77467G.com.scottsmith.ismith.debug.agent")

        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let plistURL = contents.appendingPathComponent("Library/LaunchAgents/\(identity.launchAgentPlistName)")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, identity.agentBundleID)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], [identity.appBundleID])
        XCTAssertEqual((plist["MachServices"] as? [String: Bool])?[identity.machServiceName], true)
        let program = try XCTUnwrap(plist["BundleProgram"] as? String)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent(program).path))

        let agent = try XCTUnwrap(Bundle(url: contents.appendingPathComponent("Library/LoginItems/iSmith Agent.app")))
        XCTAssertEqual(agent.bundleIdentifier, identity.agentBundleID)
        XCTAssertEqual(agent.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
        let info = agent.infoDictionary ?? [:]
        XCTAssertEqual("\(info["CFBundleShortVersionString"] ?? "") (\(info["CFBundleVersion"] ?? ""))", CodesClient.appVersion,
                       "the app and its agent ship with one version")
    }

    func testQRCodeDecodesToTheURI() throws {
        let uri = "twofasync://pair?v=1&u=https%3A%2F%2F2fa.johnnycode.ai&p=3b241101-e2bb-4255-8caf-4136c566a962"
            + "&t=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE&k=PP-onxJH-U3_xeHL4KsrZsvYwBEnNbgj_J2V99kPTVw"
            + "&s=ed-iFKx6u8JMsXxwlg16tavkxruP0p8EX4sFBM5Glb0&n=Scott%27s%20MacBook%20Pro"
        let image = try XCTUnwrap(CodesController.qrImage(uri))
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let found = detector.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(found, [uri])
    }

    /// The real path end to end: SMAppService registers the Debug agent, launchd starts it, XPC
    /// (with both code-signing requirements) reaches it, it pairs with the fake relay's phone,
    /// receives a code over the WebSocket and offers it under the WebOTP binding, restarts on
    /// `quit` (the Sparkle rule), then unpairs. Opt-in, because it registers a launch agent:
    /// run `swift run FakeRelay 8787` in Packages/Codes,
    /// `defaults write com.scottsmith.ismith.debug.agent CodesRelayURL http://127.0.0.1:8787`, then
    /// `TEST_RUNNER_ISMITH_CODES_E2E_RELAY=http://127.0.0.1:8787 xcodebuild test … -only-testing:iSmithTests/CodesWiringTests`.
    /// Against the real relay run locally, point CodesRelayURL and ISMITH_CODES_E2E_RELAY at it
    /// and ISMITH_CODES_E2E_PHONE at a FakeRelay, whose phone hooks pair through the URI's relay.
    /// It unregisters the agent when done.
    func testEndToEndThroughLaunchdAndXPC() async throws {
        guard let relayString = ProcessInfo.processInfo.environment["ISMITH_CODES_E2E_RELAY"],
              let relay = URL(string: relayString) else {
            throw XCTSkip("set ISMITH_CODES_E2E_RELAY to a running FakeRelay")
        }
        let identity = CodesClient.identity
        let service = SMAppService.agent(plistName: identity.launchAgentPlistName)
        let client = CodesClient.shared
        // Leave things as they were found: a registration that was there stays, and a Debug agent
        // that's already paired (someone's real dev pairing) isn't touched at all.
        let wasRegistered = service.status == .enabled
        if wasRegistered, let status = try? await client.status(), status.paired {
            throw XCTSkip("the Debug agent is paired; unpair it in iSmith Dev first")
        }
        do {
            try service.register()
        } catch {
            XCTAssertNotEqual(service.status, .requiresApproval, "approve iSmith Dev in Login Items, then run again")
            if service.status != .enabled { throw error }
        }
        // The fake phone's hooks: the FakeRelay itself, or a FakeRelay run next to the real relay.
        let phone = ProcessInfo.processInfo.environment["ISMITH_CODES_E2E_PHONE"].flatMap(URL.init(string:)) ?? relay
        do {
            try await runEndToEnd(relay: relay, phone: phone, client: client, service: service)
        } catch {
            await cleanUp(client: client, service: service, unregister: !wasRegistered)
            throw error
        }
        await cleanUp(client: client, service: service, unregister: !wasRegistered)
    }

    private func cleanUp(client: CodesClient, service: SMAppService, unregister: Bool) async {
        try? await client.cancelPairing()
        _ = try? await client.unpair()
        try? await client.setSettings(.defaults)
        client.reset()
        guard unregister else { return }
        try? await service.unregister()
        XCTAssertNotEqual(service.status, .enabled, "the Debug agent is unregistered afterwards")
    }

    private func runEndToEnd(relay: URL, phone: URL, client: CodesClient, service: SMAppService) async throws {
        XCTAssertEqual(service.status, .enabled)

        let up = await eventually(timeout: 30) { (try? await client.status()) != nil }
        XCTAssertTrue(up, "launchd started the agent and XPC reached it")
        var status = try await client.status()
        XCTAssertEqual(status.agentVersion, CodesClient.appVersion)
        XCTAssertFalse(status.paired)

        let (uri, pairingID) = try await client.startPairing()
        XCTAssertTrue(uri.contains("\(relay.host ?? "")%3A\(relay.port ?? 0)"), "the Debug agent was pointed at the fake relay")
        try await post(phone.appendingPathComponent("test/phone/pair"), ["uri": uri, "phoneName": "E2E Phone"])
        let verifying = await eventually(timeout: 15) { (try? await client.pairingState())?.state == .verify }
        XCTAssertTrue(verifying)
        let info = try await client.pairingState()
        XCTAssertEqual(info.phoneName, "E2E Phone")
        XCTAssertEqual(info.fingerprint?.count, 7)
        try await client.confirmPairing()
        let connected = await eventually(timeout: 15) { (try? await client.status())?.connected == true }
        XCTAssertTrue(connected)
        status = try await client.status()
        XCTAssertTrue(status.paired)
        XCTAssertFalse(pairingID.isEmpty)

        // Notifications and the clipboard stay off for the test run.
        try await client.setSettings(CodesSettings(notifications: false, copyToClipboard: false, offerInBrowser: true))
        let sentAt = Date()
        try await post(phone.appendingPathComponent("test/phone/send"), ["code": "424242", "domain": "example.com", "sender": "E2E"])
        let arrived = await eventually(timeout: 10) {
            (try? await client.recentCodes(for: "login.example.com"))?.contains { $0.code == "424242" } == true
        }
        XCTAssertTrue(arrived)
        XCTAssertLessThan(Date().timeIntervalSince(sentAt), 2.5, "a code reaches the Mac within 2 s")
        let elsewhere = try await client.recentCodes(for: "example.com.evil.net")
        XCTAssertEqual(elsewhere, [])
        let offers = try await client.recentCodes(for: "example.com")
        let offer = try XCTUnwrap(offers.first)
        try await client.markUsed(offer.id)
        let afterUse = try await client.recentCodes(for: "example.com")
        XCTAssertEqual(afterUse, [])

        // The Sparkle rule: `quit` exits the agent; launchd's KeepAlive starts it again, and the
        // new process still has the pairing (its Keychain items and pairing file).
        let oldPID = try await client.status().processID
        try await client.quit()
        let back = await eventually(timeout: 60) {
            guard let s = try? await client.status() else { return false }
            return s.processID != oldPID && s.paired
        }
        XCTAssertTrue(back, "KeepAlive restarted the agent and it kept the pairing")
        let reconnected = await eventually(timeout: 15) { (try? await client.status())?.connected == true }
        XCTAssertTrue(reconnected)

        let warning = try await client.unpair()
        XCTAssertNil(warning)
        let unpaired = try await client.status()
        XCTAssertFalse(unpaired.paired)
    }

    private func post(_ url: URL, _ body: [String: String]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 202)
    }
}
