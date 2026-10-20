@testable import Codes
import CodesXPC
@testable import FakeRelayKit
import XCTest

/// The agent's engine against the fake relay over real sockets: pairing (and a key-swapping
/// relay), the stream with its Authorization header, delivery and acks, reconnects, the liveness
/// timeout, revocation and unpairing.
@MainActor
final class RelayEngineTests: XCTestCase {
    final class Sink: CodeSink {
        var delivered: [CodeMessage] = []
        var forgotten = 0
        func deliver(_ message: CodeMessage, settings: CodesSettings) async { delivered.append(message) }
        func pairingForgotten() { forgotten += 1 }
    }

    var relay: FakeRelayServer!
    var dir: URL!
    var secrets: InMemorySecretStore!
    var sink: Sink!
    var engine: CodesEngine!

    static var fast: RelayStream.Timing {
        var t = RelayStream.Timing()
        t.initialBackoff = 0.05
        t.maxBackoff = 0.3
        t.pingInterval = 0.4
        t.livenessTimeout = 2
        t.stableAfter = 30
        t.replacedBackoff = 1.5
        return t
    }

    override func setUp() async throws {
        relay = FakeRelayServer()
        try self.relay.start()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("codes-engine-\(UUID().uuidString)")
        secrets = InMemorySecretStore()
        sink = Sink()
        engine = makeEngine()
    }

    override func tearDown() async throws {
        self.engine.stop()
        self.relay.stopServer()
        try? FileManager.default.removeItem(at: dir)
    }

    func keychainPairing() -> KeychainPairing {
        CodesJSON.decode(KeychainPairing.self, from: secrets.values["pairing"] ?? Data())!
    }

    func makeEngine() -> CodesEngine {
        let e = CodesEngine(config: .init(dataDir: dir, relayURL: self.relay.baseURL, macName: "Test Mac", agentVersion: "1.0 (1)",
                                          secrets: self.secrets, streamTiming: Self.fast, pairPollInterval: 0.05,
                                          allowLocalHTTPRelay: true))
        e.sink = sink
        return e
    }

    func eventually(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @discardableResult
    func pair(name: String = "Galaxy S24") async throws -> FakePhone {
        let (uri, pairingID) = try await self.engine.startPairing()
        XCTAssertEqual(self.engine.pairingState().state, .waiting)
        XCTAssertTrue(uri.contains("u=http%3A%2F%2F127.0.0.1%3A\(self.relay.port)"))
        let phone = FakePhone(name: name)
        try await phone.pair(uri: uri)
        XCTAssertEqual(phone.pairingID, pairingID)
        let verifying = await eventually { self.engine.pairingState().state == .verify }
        XCTAssertTrue(verifying)
        let info = self.engine.pairingState()
        XCTAssertEqual(info.phoneName, name)
        XCTAssertEqual(info.fingerprint, groupedFingerprint(BoxCrypto.fingerprint(macPublicKey: phone.macPublicKey,
                                                                                 phonePublicKey: phone.keyPair.publicKey)))
        try await self.engine.confirmPairing()
        XCTAssertEqual(self.relay.pairing(pairingID)?.state, "active")
        let connected = await eventually { self.engine.connected }
        XCTAssertTrue(connected)
        return phone
    }

    func testPairingDeliveryAndAck() async throws {
        let phone = try await pair()
        XCTAssertTrue(self.engine.status().paired)
        XCTAssertEqual(self.engine.status().phoneName, "Galaxy S24")
        XCTAssertEqual(self.engine.pairingState().state, .active)
        // The Mac's key and token are in the secret store; the phone's key and name on disk.
        XCTAssertEqual(Array(self.secrets.values.keys), ["pairing"], "one Keychain item holds the pairing")
        let record = try String(contentsOf: dir.appendingPathComponent("pairing.json"), encoding: .utf8)
        XCTAssertTrue(record.contains("Galaxy S24"))
        XCTAssertFalse(record.contains(self.keychainPairing().macToken), "no token on disk")
        XCTAssertFalse(record.contains(Base64URL.encode(phone.keyPair.publicKey)), "the phone's key isn't taken from the file")

        let id = try await phone.send(code: "481516", domain: "chase.com", sender: "24273")
        let delivered = await eventually { self.sink.delivered.count == 1 }
        XCTAssertTrue(delivered)
        XCTAssertEqual(self.sink.delivered.first?.code, "481516")
        let acked = await eventually { self.relay.ackedIDs.contains(id) }
        XCTAssertTrue(acked, "acked over the stream after processing")
        XCTAssertEqual(self.engine.recentCodes(for: "www.chase.com").map(\.code), ["481516"])
        XCTAssertEqual(self.engine.recentCodes(for: "example.com"), [])
        XCTAssertNotNil(self.engine.status().lastMessageAt)
    }

    func testReplaysAndForgeriesAreAckedButNotDelivered() async throws {
        let phone = try await pair()
        let pairingID = phone.pairingID
        let env = phone.envelope(code: "111111")
        self.relay.enqueue(env, pairingID: pairingID)
        self.relay.enqueue(env, pairingID: pairingID) // the fallback queue delivering it again
        let stranger = FakePhone()
        let forged = stranger.envelope(code: "999999", to: phone.macPublicKey)
        self.relay.enqueue(forged, pairingID: pairingID)
        let stale = phone.envelope(code: "222222", ts: Date().addingTimeInterval(-11 * 60))
        self.relay.enqueue(stale, pairingID: pairingID)
        let allAcked = await eventually {
            self.relay.ackedIDs.filter { $0 == env["id"] as! String }.count == 2
                && self.relay.ackedIDs.contains(forged["id"] as! String) && self.relay.ackedIDs.contains(stale["id"] as! String)
        }
        XCTAssertTrue(allAcked)
        XCTAssertEqual(self.sink.delivered.map(\.code), ["111111"])
    }

    /// A relay that swaps the phone's key is caught by the proof: pairing fails and is deleted.
    func testKeySwappingRelayFailsPairing() async throws {
        let attacker = BoxKeyPair.generate()
        self.relay.swapPhoneKey = Base64URL.encode(attacker.publicKey)
        let (uri, _) = try await self.engine.startPairing()
        try await FakePhone().pair(uri: uri)
        let failed = await eventually { self.engine.pairingState().state == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(self.engine.pairingState().message, "Pairing failed: the phone's key didn't check out.")
        XCTAssertNil(self.engine.pairingState().fingerprint)
        XCTAssertEqual(self.relay.deleteCount, 1)
        XCTAssertFalse(self.engine.isPaired)
        do {
            try await self.engine.confirmPairing()
            XCTFail("nothing to confirm")
        } catch {}
        XCTAssertEqual(self.relay.confirmCount, 0)
        XCTAssertTrue(self.secrets.values.isEmpty)
    }

    func testCancelPairingDeletesItAtTheRelay() async throws {
        _ = try await self.engine.startPairing()
        await self.engine.cancelPairing()
        XCTAssertEqual(self.engine.pairingState().state, .idle)
        XCTAssertEqual(self.relay.deleteCount, 1)
        XCTAssertTrue(self.relay.allPairings.isEmpty)
    }

    func testReconnectsAfterTheStreamDropsAndGetsQueuedMessages() async throws {
        let phone = try await pair()
        self.relay.dropStreams()
        let disconnected = await eventually { !self.engine.connected || self.relay.streamConnections >= 2 }
        XCTAssertTrue(disconnected)
        // Sent while the Mac may be offline: queued at the relay, delivered on reconnect.
        let id = try await phone.send(code: "707070")
        let delivered = await eventually { self.sink.delivered.contains { $0.id == id } }
        XCTAssertTrue(delivered)
        XCTAssertGreaterThanOrEqual(self.relay.streamConnections, 2)
        let acked = await eventually { self.relay.ackedIDs.contains(id) }
        XCTAssertTrue(acked)
    }

    /// No pong (and no frame) for the liveness timeout: the client gives up on the socket and
    /// reconnects.
    func testSilentConnectionIsReplaced() async throws {
        try await pair()
        XCTAssertEqual(self.relay.streamConnections, 1)
        self.relay.answersPings = false
        let reconnected = await eventually(8) { self.relay.streamConnections >= 2 }
        XCTAssertTrue(reconnected)
    }

    func testRevokedFrameForgetsThePairing() async throws {
        let phone = try await pair()
        self.relay.revoke(phone.pairingID)
        let forgotten = await eventually { !self.engine.isPaired }
        XCTAssertTrue(forgotten)
        XCTAssertNotNil(self.engine.status().problem)
        XCTAssertTrue(self.secrets.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pairing.json").path))
    }

    func testUnpairRevokesAtTheRelayAndForgetsEverything() async throws {
        let phone = try await pair()
        _ = try await phone.send(code: "123123")
        _ = await eventually { self.sink.delivered.count == 1 }
        let warning = await self.engine.unpair()
        XCTAssertNil(warning)
        XCTAssertEqual(self.relay.deleteCount, 1)
        XCTAssertNil(self.relay.pairing(phone.pairingID))
        XCTAssertFalse(self.engine.isPaired)
        XCTAssertTrue(self.secrets.values.isEmpty)
        XCTAssertEqual(self.engine.recentCodeSummaries(), [])
        XCTAssertFalse(self.engine.connected)
    }

    func testRestartKeepsThePairingAndTheSeenSet() async throws {
        let phone = try await pair()
        let env = phone.envelope(code: "343434")
        self.relay.enqueue(env, pairingID: phone.pairingID)
        _ = await eventually { self.sink.delivered.count == 1 }
        self.engine.stop()

        engine = makeEngine()
        XCTAssertTrue(self.engine.isPaired)
        XCTAssertEqual(self.engine.status().phoneName, "Galaxy S24")
        self.engine.start()
        let connected = await eventually { self.engine.connected }
        XCTAssertTrue(connected)
        self.relay.enqueue(env, pairingID: phone.pairingID) // replayed after the restart
        let acked = await eventually { self.relay.ackedIDs.filter { $0 == env["id"] as! String }.count == 2 }
        XCTAssertTrue(acked)
        XCTAssertEqual(self.sink.delivered.count, 1, "the restarted agent still remembers the id")
    }

    func testSettingsPersistAndGateBrowserOffers() async throws {
        XCTAssertEqual(self.engine.settings, .defaults)
        XCTAssertFalse(self.engine.settings.copyToClipboard, "clipboard copy is off by default")
        let phone = try await pair()
        _ = try await phone.send(code: "565656")
        _ = await eventually { self.sink.delivered.count == 1 }
        XCTAssertEqual(self.engine.recentCodes(for: "anything.example").count, 1)
        try self.engine.setSettings(CodesSettings(notifications: false, copyToClipboard: true, offerInBrowser: false))
        XCTAssertEqual(self.engine.recentCodes(for: "anything.example"), [])
        XCTAssertEqual(self.engine.recentCodeSummaries().map(\.code), ["••••••"], "Settings still lists them, masked")
        self.engine.stop()
        engine = makeEngine()
        XCTAssertEqual(self.engine.settings, CodesSettings(notifications: false, copyToClipboard: true, offerInBrowser: false))
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("settings.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testAlreadyPairedRefusesANewPairing() async throws {
        try await pair()
        do {
            _ = try await self.engine.startPairing()
            XCTFail("expected alreadyPaired")
        } catch let error as CodesEngine.Failure {
            XCTAssertEqual(error, .alreadyPaired)
        }
    }

    /// Close 4409 (another stream for the pairing took over): the replaced stream waits out
    /// `replacedBackoff` instead of knocking the other one off straight away.
    func testReplacedStreamBacksOff() async throws {
        try await pair()
        let token = self.keychainPairing().macToken
        let other = RelayStream(url: RelayAPI(baseURL: self.relay.baseURL).streamURL, token: token, timing: Self.fast) { _ in }
        other.start()
        let replaced = await eventually { self.relay.streamConnections == 2 }
        XCTAssertTrue(replaced)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(self.relay.streamConnections, 2, "no immediate reconnect after 4409")
        other.stop()
        let back = await eventually { self.relay.streamConnections >= 3 && self.engine.connected }
        XCTAssertTrue(back, "it reconnects once the backoff has passed")
    }

    /// A 403 at the upgrade is a passing refusal, not a revocation: the pairing stays and the
    /// stream keeps trying with backoff.
    func testForbiddenUpgradeIsRetriedNotRevoked() async throws {
        let phone = try await pair()
        self.relay.refuseUpgrades = 403
        self.relay.dropStreams()
        let retried = await eventually { self.relay.refusedUpgrades >= 2 }
        XCTAssertTrue(retried)
        XCTAssertTrue(self.engine.isPaired)
        XCTAssertNil(self.engine.status().problem)
        self.relay.refuseUpgrades = nil
        let id = try await phone.send(code: "909090")
        let delivered = await eventually { self.sink.delivered.contains { $0.id == id } }
        XCTAssertTrue(delivered)
    }

    /// A message frame whose envelope doesn't decode is acked by id, so it doesn't come back.
    func testUndecodableEnvelopeIsAcked() async throws {
        let phone = try await pair()
        let id = UUID().uuidString.lowercased()
        self.relay.enqueue(["v": 1, "id": id, "nonce": 5], pairingID: phone.pairingID)
        let acked = await eventually { self.relay.ackedIDs.contains(id) }
        XCTAssertTrue(acked)
        XCTAssertTrue(self.sink.delivered.isEmpty)
    }

    func testCancelWhileStartingAbandonsThePairing() async throws {
        let starting = Task { try await self.engine.startPairing() }
        await Task.yield()
        await self.engine.cancelPairing()
        do {
            _ = try await starting.value
            // The relay may have answered before the cancel ran; then cancel it now.
            await self.engine.cancelPairing()
        } catch let error as CodesEngine.Failure {
            XCTAssertEqual(error, .cancelled)
        }
        let gone = await eventually { self.relay.allPairings.isEmpty }
        XCTAssertTrue(gone, "the relay forgot the abandoned pairing")
        XCTAssertEqual(self.engine.pairingState().state, .idle)
    }

    func testRevocationTellsTheSink() async throws {
        let phone = try await pair()
        self.relay.revoke(phone.pairingID)
        let told = await eventually { self.sink.forgotten == 1 }
        XCTAssertTrue(told)
    }

    // MARK: - Security fix round

    /// The file isn't trusted: a phone key or relay URL written into it is ignored (they come from
    /// the Keychain item), and a pairing id that doesn't match the Keychain disables the pairing.
    func testTamperedPairingFileIsNotTrusted() async throws {
        let phone = try await pair()
        engine.stop()
        let attacker = FakePhone(name: "Attacker")
        let url = dir.appendingPathComponent("pairing.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["phonePublicKey"] = Base64URL.encode(attacker.keyPair.publicKey)
        json["relayURL"] = "http://127.0.0.1:1"
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        engine = makeEngine()
        XCTAssertTrue(engine.isPaired)
        engine.start()
        let connected = await eventually { self.engine.connected }
        XCTAssertTrue(connected, "still the relay from the Keychain")
        let forged = attacker.envelope(code: "666666", to: phone.macPublicKey)
        relay.enqueue(forged, pairingID: phone.pairingID)
        let acked = await eventually { self.relay.ackedIDs.contains(forged["id"] as! String) }
        XCTAssertTrue(acked)
        XCTAssertTrue(sink.delivered.isEmpty, "a key in the file doesn't make a forgery acceptable")

        engine.stop()
        json["pairingId"] = UUID().uuidString.lowercased()
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        engine = makeEngine()
        XCTAssertFalse(engine.isPaired)
        XCTAssertNotNil(engine.status().problem)
        do {
            _ = try await engine.startPairing()
            XCTFail("a pairing file exists: unpair first")
        } catch let error as CodesEngine.Failure {
            XCTAssertEqual(error, .alreadyPaired)
        }
    }

    func testRelayMustBeHTTPS() async throws {
        try await pair()
        engine.stop()
        // The same Keychain item, read by an engine that doesn't allow a local http relay.
        let strict = CodesEngine(config: .init(dataDir: dir, relayURL: relay.baseURL, macName: "Test Mac", agentVersion: "1",
                                               secrets: secrets, allowLocalHTTPRelay: false))
        XCTAssertFalse(strict.isPaired)
        XCTAssertEqual(strict.status().problem, "The pairing's relay isn't an https address. Unpair, then pair again.")
        _ = await strict.unpair()
        do {
            _ = try await strict.startPairing()
            XCTFail("http relay")
        } catch let error as CodesEngine.Failure {
            XCTAssertEqual(error, .insecureRelay)
        }
        XCTAssertTrue(strict.relayAllowed(URL(string: "https://2fa.johnnycode.ai")!))
        XCTAssertFalse(strict.relayAllowed(URL(string: "http://2fa.johnnycode.ai")!))
        XCTAssertFalse(engine.relayAllowed(URL(string: "http://evil.example")!), "only loopback http, even in tests")
    }

    /// A lost or corrupt seen set fails closed: only messages sent after the agent loaded it.
    func testCorruptSeenSetFailsClosed() async throws {
        let phone = try await pair()
        let old = phone.envelope(code: "111111", ts: Date().addingTimeInterval(-60))
        relay.enqueue(old, pairingID: phone.pairingID)
        _ = await eventually { self.sink.delivered.count == 1 }
        engine.stop()
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("seen.json"))
        engine = makeEngine()
        engine.start()
        _ = await eventually { self.engine.connected }
        relay.enqueue(old, pairingID: phone.pairingID) // a replay the lost set can't recognize
        let acked = await eventually { self.relay.ackedIDs.filter { $0 == old["id"] as! String }.count == 2 }
        XCTAssertTrue(acked)
        XCTAssertEqual(sink.delivered.count, 1, "the replay is refused")
        try await Task.sleep(nanoseconds: 20_000_000)
        let id = try await phone.send(code: "222222")
        let fresh = await eventually { self.sink.delivered.contains { $0.id == id } }
        XCTAssertTrue(fresh, "a message sent after the load is accepted")
    }

    func testOffersNeedAPlainHostAndTheSetting() async throws {
        let phone = try await pair()
        _ = try await phone.send(code: "313131", domain: "chase.com")
        _ = await eventually { self.sink.delivered.count == 1 }
        XCTAssertEqual(engine.recentCodes(for: "login.chase.com").map(\.code), ["313131"])
        XCTAssertEqual(engine.recentCodes(for: "LOGIN.CHASE.COM.").map(\.code), ["313131"])
        for bad in ["", "evil.com/.chase.com", "evil.com#.chase.com", ".chase.com", "a..chase.com", "chase.com:443",
                    "evil com.chase.com", "[::1]"] {
            XCTAssertEqual(engine.recentCodes(for: bad), [], bad)
        }
        let id = try XCTUnwrap(engine.recentCodes(for: "chase.com").first?.id)
        engine.markUsed(id)
        XCTAssertEqual(engine.recentCodes(for: "chase.com"), [], "used codes aren't offered")
    }

    func testStreamRefusesABadToken() async throws {
        // A token the relay doesn't know: the upgrade is refused and the stream reports revoked.
        let revoked = expectation(description: "revoked")
        let api = RelayAPI(baseURL: self.relay.baseURL)
        let stream = RelayStream(url: api.streamURL, token: "nope", timing: Self.fast) { event in
            if case .revoked = event { revoked.fulfill() }
        }
        stream.start()
        await fulfillment(of: [revoked], timeout: 5)
        stream.stop()
    }

    func testBackoffGrowsWithJitterAndCaps() {
        var t = RelayStream.Timing()
        t.initialBackoff = 1
        t.maxBackoff = 60
        XCTAssertEqual(RelayStream.backoff(failures: 0, timing: t, random: 1), 1)
        XCTAssertEqual(RelayStream.backoff(failures: 3, timing: t, random: 1), 8)
        XCTAssertEqual(RelayStream.backoff(failures: 3, timing: t, random: 0.5), 4)
        XCTAssertEqual(RelayStream.backoff(failures: 30, timing: t, random: 1), 60)
        let jittered = (0..<50).map { _ in RelayStream.backoff(failures: 2, timing: t) }
        XCTAssertTrue(jittered.allSatisfy { (2...4).contains($0) })
        XCTAssertGreaterThan(Set(jittered).count, 1)
    }

    func testIdentityNames() {
        let release = CodesIdentity(appBundleID: "com.scottsmith.ismith")
        XCTAssertEqual(release.agentBundleID, "com.scottsmith.ismith.agent")
        XCTAssertEqual(release.machServiceName, "232A77467G.com.scottsmith.ismith.agent")
        XCTAssertEqual(release.launchAgentPlistName, "com.scottsmith.ismith.agent.plist")
        XCTAssertEqual(release.appRequirement,
                       #"anchor apple generic and certificate leaf[subject.OU] = "232A77467G" and identifier "com.scottsmith.ismith""#)
        let debug = CodesIdentity(agentBundleID: "com.scottsmith.ismith.debug.agent")
        XCTAssertEqual(debug?.appBundleID, "com.scottsmith.ismith.debug")
        XCTAssertEqual(debug?.machServiceName, "232A77467G.com.scottsmith.ismith.debug.agent")
        XCTAssertEqual(debug?.agentRequirement,
                       #"anchor apple generic and certificate leaf[subject.OU] = "232A77467G" and identifier "com.scottsmith.ismith.debug.agent""#)
        XCTAssertNil(CodesIdentity(agentBundleID: "com.scottsmith.ismith"))
    }
}
