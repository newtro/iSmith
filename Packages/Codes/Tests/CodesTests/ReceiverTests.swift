import Codes
import CodesXPC
import FakeRelayKit
import XCTest

/// PROTOCOL.md §3's receiver rules, with envelopes sealed by a fake phone.
final class ReceiverTests: XCTestCase {
    let mac = BoxKeyPair.generate()
    var phone: FakePhone!
    var dir: URL!
    let now = Date(timeIntervalSince1970: 1_760_900_000)

    override func setUpWithError() throws {
        phone = FakePhone()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("codes-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func envelope(_ e: [String: Any]) -> Envelope {
        Envelope(v: e["v"] as! Int, id: e["id"] as! String, nonce: e["nonce"] as! String, ct: e["ct"] as! String)
    }

    func receiver(seenFile: URL? = nil, pairing: String = "p1") -> Receiver {
        Receiver(phonePublicKey: phone.keyPair.publicKey, macSecretKey: mac.secretKey,
                 seen: SeenStore(fileURL: seenFile, pairingID: pairing))
    }

    func make(code: String = "123456", id: String = UUID().uuidString.lowercased(), innerID: String? = nil,
              ctr: Int64? = nil, ts: Date? = nil) -> Envelope {
        envelope(phone.envelope(code: code, id: id, innerID: innerID, ctr: ctr, ts: ts ?? now, to: mac.publicKey))
    }

    func testAcceptsAFreshMessage() {
        let r = receiver()
        guard case let .accepted(m) = r.receive(make(code: "654321", ctr: 7), now: now) else { return XCTFail() }
        XCTAssertEqual(m.code, "654321")
        XCTAssertEqual(m.ctr, 7)
    }

    func testReplayOfTheSameIDIsDropped() {
        let r = receiver()
        let e = make(ctr: 1)
        XCTAssertNotEqual(r.receive(e, now: now), .dropped(.replay))
        XCTAssertEqual(r.receive(e, now: now.addingTimeInterval(1)), .dropped(.replay))
    }

    func testSameCounterWithANewIDIsDropped() {
        let r = receiver()
        guard case .accepted = r.receive(make(ctr: 5), now: now) else { return XCTFail() }
        XCTAssertEqual(r.receive(make(ctr: 5), now: now), .dropped(.replay))
    }

    func testCountersMayArriveOutOfOrder() {
        let r = receiver()
        guard case .accepted = r.receive(make(ctr: 9), now: now) else { return XCTFail() }
        guard case .accepted = r.receive(make(ctr: 8), now: now) else { return XCTFail("a lower counter after a higher one is fine") }
    }

    func testStaleTimestampIsDropped() {
        let r = receiver()
        XCTAssertEqual(r.receive(make(ts: now.addingTimeInterval(-10 * 60 - 1)), now: now), .dropped(.stale))
        guard case .accepted = r.receive(make(ts: now.addingTimeInterval(-10 * 60 + 5)), now: now) else { return XCTFail() }
    }

    func testFutureTimestampIsDropped() {
        let r = receiver()
        XCTAssertEqual(r.receive(make(ts: now.addingTimeInterval(2 * 60 + 1)), now: now), .dropped(.future))
        guard case .accepted = r.receive(make(ts: now.addingTimeInterval(2 * 60 - 5)), now: now) else { return XCTFail() }
    }

    func testInnerIDMismatchIsDropped() {
        let r = receiver()
        XCTAssertEqual(r.receive(make(id: UUID().uuidString.lowercased(), innerID: UUID().uuidString.lowercased()), now: now),
                       .dropped(.idMismatch))
    }

    func testOtherSendersKeyAndBadPlaintextAreDropped() {
        let r = receiver()
        let stranger = FakePhone()
        let e = envelope(stranger.envelope(to: mac.publicKey))
        XCTAssertEqual(r.receive(e, now: Date()), .dropped(.boxDidNotOpen))

        let nonce = BoxCrypto.randomBytes(24)
        let ct = BoxCrypto.seal(Data(#"{"v":2}"#.utf8), nonce: nonce, recipientPublicKey: mac.publicKey, senderSecretKey: phone.keyPair.secretKey)!
        XCTAssertEqual(r.receive(Envelope(id: UUID().uuidString.lowercased(), nonce: Base64URL.encode(nonce), ct: Base64URL.encode(ct)), now: now),
                       .dropped(.badPlaintext))
        XCTAssertEqual(r.receive(Envelope(id: "x", nonce: "short", ct: "AAAA"), now: now), .dropped(.malformedEnvelope))
        XCTAssertEqual(r.receive(make(code: "12"), now: now), .dropped(.badPlaintext))
        XCTAssertEqual(r.receive(make(code: "12 34 56"), now: now), .dropped(.badPlaintext))
    }

    /// The WebOTP domain is normalized (case, one trailing dot); one that still isn't a plain
    /// multi-label ASCII host keeps the code but fails closed: it's never offered on any page.
    func testOddDomainsFailClosed() {
        for (domain, kept) in [("chase.com", "chase.com"), ("CHASE.COM", "chase.com"), ("chase.com.", "chase.com"),
                               ("localhost", nil), ("bücher.de", nil), ("a..com", nil), ("-x.com", nil),
                               ("my_bank.com", nil), ("chase.com..", nil)] as [(String, String?)] {
            let r = receiver()
            let e = envelope(phone.envelope(code: "123456", domain: domain, ts: now, to: mac.publicKey))
            guard case let .accepted(m) = r.receive(e, now: now) else { return XCTFail(domain) }
            XCTAssertEqual(m.domain, kept, domain)
            XCTAssertEqual(m.bindingUnusable, kept == nil, domain)
            XCTAssertEqual(m.code, "123456")
            let recent = RecentCodes()
            recent.add(m, receivedAt: now)
            XCTAssertEqual(recent.offers(for: "evil.example", now: now), [], "\(domain) isn't offered elsewhere")
            XCTAssertEqual(recent.offers(for: "chase.com", now: now).isEmpty, kept == nil, domain)
            XCTAssertEqual(recent.all(now: now).count, 1, "kept for the notification")
        }
    }

    func testMissingSeenFileWhilePairedFailsClosed() {
        let file = dir.appendingPathComponent("seen.json")
        let r = Receiver(phonePublicKey: phone.keyPair.publicKey, macSecretKey: mac.secretKey,
                         seen: SeenStore(fileURL: file, pairingID: "p1", expectFile: true, now: now))
        XCTAssertEqual(r.receive(make(ts: now.addingTimeInterval(-1)), now: now), .dropped(.seenSetLost))
        guard case .accepted = r.receive(make(ts: now.addingTimeInterval(1)), now: now.addingTimeInterval(2)) else { return XCTFail() }
    }

    /// The seen set survives a restart (it's on disk, owner-only) and belongs to one pairing.
    func testSeenSetPersistsOwnerOnlyAndPerPairing() throws {
        let file = dir.appendingPathComponent("seen.json")
        let e = make(ctr: 3)
        guard case .accepted = receiver(seenFile: file).receive(e, now: now) else { return XCTFail() }
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let dirPerms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700)

        XCTAssertEqual(receiver(seenFile: file).receive(e, now: now.addingTimeInterval(60)), .dropped(.replay))
        XCTAssertEqual(receiver(seenFile: file).receive(make(ctr: 3), now: now.addingTimeInterval(60)), .dropped(.replay))
        // Kept past 15 minutes (the ts window refuses it by then anyway).
        let later = receiver(seenFile: file).seen
        XCTAssertTrue(later.contains(id: e.id, ctr: 3))
        // A new pairing starts its counter over.
        guard case .accepted = receiver(seenFile: file, pairing: "p2").receive(make(ctr: 3), now: now) else { return XCTFail() }
    }

    func testSeenEntriesOutliveFifteenMinutes() {
        let seen = SeenStore(fileURL: nil, pairingID: "p")
        seen.insert(id: "a", ctr: 1, now: now)
        seen.insert(id: "b", ctr: 2, now: now.addingTimeInterval(16 * 60))
        XCTAssertTrue(seen.contains(id: "a", ctr: 99))
        seen.insert(id: "c", ctr: 3, now: now.addingTimeInterval(21 * 60))
        XCTAssertFalse(seen.contains(id: "a", ctr: 99), "pruned after 20 minutes")
    }
}

/// What may be offered on a page (PROTOCOL.md §5) and the 10-minute lifetime.
final class RecentCodesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_760_900_000)

    func message(_ code: String, domain: String?) -> CodeMessage {
        CodeMessage(id: UUID().uuidString.lowercased(), ctr: 1, ts: 0, sender: "Chase", code: code, domain: domain, body: "")
    }

    func testDomainBoundCodesOnlyOnTheDomainAndSubdomains() {
        let recent = RecentCodes()
        recent.add(message("111111", domain: "chase.com"), receivedAt: t0)
        XCTAssertEqual(recent.offers(for: "chase.com", now: t0).map(\.code), ["111111"])
        XCTAssertEqual(recent.offers(for: "secure.chase.com", now: t0).map(\.code), ["111111"])
        XCTAssertEqual(recent.offers(for: "CHASE.COM.", now: t0).map(\.code), ["111111"])
        XCTAssertEqual(recent.offers(for: "evilchase.com", now: t0), [])
        XCTAssertEqual(recent.offers(for: "chase.com.evil.net", now: t0), [])
        XCTAssertEqual(recent.offers(for: "com", now: t0), [])
        // Bound codes aren't limited to 2 minutes; they last the 10.
        XCTAssertEqual(recent.offers(for: "chase.com", now: t0.addingTimeInterval(9 * 60)).count, 1)
        XCTAssertEqual(recent.offers(for: "chase.com", now: t0.addingTimeInterval(10 * 60 + 1)).count, 0)
    }

    func testUnboundCodesAnywhereForTwoMinutes() {
        let recent = RecentCodes()
        recent.add(message("222222", domain: nil), receivedAt: t0)
        XCTAssertEqual(recent.offers(for: "example.org", now: t0.addingTimeInterval(119)).map(\.code), ["222222"])
        XCTAssertEqual(recent.offers(for: "example.org", now: t0.addingTimeInterval(121)), [])
        // Still listed (Settings) until 10 minutes.
        XCTAssertEqual(recent.all(now: t0.addingTimeInterval(300)).count, 1)
        XCTAssertEqual(recent.all(now: t0.addingTimeInterval(601)).count, 0)
    }

    func testMarkUsedAndNewestFirst() {
        let recent = RecentCodes()
        let a = message("333333", domain: nil), b = message("444444", domain: nil)
        recent.add(a, receivedAt: t0)
        recent.add(b, receivedAt: t0.addingTimeInterval(1))
        XCTAssertEqual(recent.offers(for: "x.com", now: t0.addingTimeInterval(2)).map(\.code), ["444444", "333333"])
        recent.markUsed(b.id)
        XCTAssertEqual(recent.offers(for: "x.com", now: t0.addingTimeInterval(2)).map(\.code), ["333333"])
        XCTAssertEqual(recent.code(id: b.id, now: t0.addingTimeInterval(2))?.code, "444444")
    }
}
