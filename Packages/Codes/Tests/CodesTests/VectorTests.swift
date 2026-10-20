import Codes
import CodesXPC
import XCTest

/// `protocol/crypto_vectors.json`, reproduced byte for byte.
final class VectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct Key: Decodable { let seed: String; let publicKey: String; let secretKey: String }
        struct PairingV: Decodable {
            let pairingId, pairingSecret, macPublicKey, phonePublicKey, proof, fingerprint: String
            let swappedPhonePublicKey, proofForSwappedKey, fingerprintForSwappedKey: String
        }
        struct Message: Decodable { let plaintext: String; let envelope: Envelope }
        struct MustFail: Decodable { let why: String; let envelope: Envelope }
        let keys: [String: Key]
        let pairing: PairingV
        let messages: [Message]
        let mustFail: [MustFail]
    }

    static func load() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "crypto_vectors", withExtension: "json", subdirectory: "Resources"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    var v: Vectors!

    override func setUpWithError() throws { v = try Self.load() }

    func b(_ s: String) -> Data { Base64URL.decode(s)! }

    static func hex(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    func testKeysFromSeeds() throws {
        for (label, key) in v.keys {
            let pair = try XCTUnwrap(BoxKeyPair.fromSeed(Self.hex(key.seed)), label)
            XCTAssertEqual(Base64URL.encode(pair.publicKey), key.publicKey, label)
            XCTAssertEqual(Base64URL.encode(pair.secretKey), key.secretKey, label)
            // The public key rebuilt from the secret one (how the agent reloads its Keychain item).
            XCTAssertEqual(BoxKeyPair(secretKey: b(key.secretKey))?.publicKey, b(key.publicKey), label)
        }
    }

    func testProofAndFingerprint() {
        let p = v.pairing
        let proof = BoxCrypto.pairingProof(secret: b(p.pairingSecret), pairingID: p.pairingId,
                                           macPublicKey: b(p.macPublicKey), phonePublicKey: b(p.phonePublicKey))
        XCTAssertEqual(Base64URL.encode(proof), p.proof)
        XCTAssertEqual(BoxCrypto.fingerprint(macPublicKey: b(p.macPublicKey), phonePublicKey: b(p.phonePublicKey)), p.fingerprint)
        XCTAssertEqual(groupedFingerprint(p.fingerprint), "472 001")

        let swapped = BoxCrypto.pairingProof(secret: b(p.pairingSecret), pairingID: p.pairingId,
                                             macPublicKey: b(p.macPublicKey), phonePublicKey: b(p.swappedPhonePublicKey))
        XCTAssertEqual(Base64URL.encode(swapped), p.proofForSwappedKey)
        XCTAssertNotEqual(swapped, proof)
        XCTAssertEqual(BoxCrypto.fingerprint(macPublicKey: b(p.macPublicKey), phonePublicKey: b(p.swappedPhonePublicKey)),
                       p.fingerprintForSwappedKey)
        // The phone's proof doesn't vouch for a key the relay swapped in.
        XCTAssertFalse(BoxCrypto.proofMatches(proof, secret: b(p.pairingSecret), pairingID: p.pairingId,
                                              macPublicKey: b(p.macPublicKey), phonePublicKey: b(p.swappedPhonePublicKey)))
        XCTAssertTrue(BoxCrypto.proofMatches(proof, secret: b(p.pairingSecret), pairingID: p.pairingId,
                                             macPublicKey: b(p.macPublicKey), phonePublicKey: b(p.phonePublicKey)))
    }

    /// The Mac's check of what the relay passed on: the real key verifies with the vector's
    /// fingerprint; the attacker's key with the phone's proof is rejected.
    func testPairingSessionCheck() throws {
        let p = v.pairing
        let mac = try XCTUnwrap(BoxKeyPair(secretKey: b(v.keys["mac"]!.secretKey)))
        let reply = PairStartReply(pairingId: p.pairingId, registrationToken: Base64URL.encode(Data(repeating: 1, count: 32)),
                                   macToken: Base64URL.encode(Data(repeating: 2, count: 32)), expiresAt: 0)
        let session = PairingSession(relayURL: URL(string: "https://2fa.johnnycode.ai")!, reply: reply,
                                     macName: "Scott's MacBook Pro", keyPair: mac, secret: b(p.pairingSecret))
        let good = PairStatusReply(state: "pending", phonePublicKey: p.phonePublicKey, phoneName: "Galaxy S24", proof: p.proof)
        XCTAssertEqual(session.check(good), .verified(phonePublicKey: b(p.phonePublicKey), phoneName: "Galaxy S24",
                                                      fingerprint: p.fingerprint))
        let swapped = PairStatusReply(state: "pending", phonePublicKey: p.swappedPhonePublicKey, phoneName: "Galaxy S24", proof: p.proof)
        XCTAssertEqual(session.check(swapped), .rejected)
        XCTAssertEqual(session.check(PairStatusReply(state: "pending", phonePublicKey: p.phonePublicKey, phoneName: nil, proof: nil)), .rejected)

        XCTAssertEqual(session.qrURI,
                       "2fasync://pair?v=1&u=https%3A%2F%2F2fa.johnnycode.ai&p=\(p.pairingId)"
                       + "&t=\(reply.registrationToken)&k=\(p.macPublicKey)&s=\(p.pairingSecret)&n=Scott%27s%20MacBook%20Pro")
        // Foundation refuses "2fasync" as a scheme (it starts with a digit), so read the query alone.
        XCTAssertNil(URLComponents(string: session.qrURI))
        let items = URLComponents(string: "x://pair?" + session.qrURI.dropFirst("2fasync://pair?".count))!.queryItems!
        XCTAssertEqual(items.first { $0.name == "u" }?.value, "https://2fa.johnnycode.ai")
        XCTAssertEqual(items.first { $0.name == "n" }?.value, "Scott's MacBook Pro")
    }

    func testMessagesOpenAndSealByteForByte() throws {
        let macSecret = b(v.keys["mac"]!.secretKey)
        let phone = v.keys["phone"]!
        for m in v.messages {
            let opened = try XCTUnwrap(BoxCrypto.open(ciphertext: b(m.envelope.ct), nonce: b(m.envelope.nonce),
                                                      senderPublicKey: b(phone.publicKey), recipientSecretKey: macSecret))
            XCTAssertEqual(opened, Data(m.plaintext.utf8))
            // Sealing the plaintext with the vector's nonce gives the vector's ciphertext.
            let sealed = BoxCrypto.seal(Data(m.plaintext.utf8), nonce: b(m.envelope.nonce),
                                        recipientPublicKey: b(v.keys["mac"]!.publicKey), senderSecretKey: b(phone.secretKey))
            XCTAssertEqual(sealed.map(Base64URL.encode), m.envelope.ct)

            // And the receiver accepts it when it's fresh.
            let message = try JSONDecoder().decode(CodeMessage.self, from: opened)
            let receiver = Receiver(phonePublicKey: b(phone.publicKey), macSecretKey: macSecret,
                                    seen: SeenStore(fileURL: nil, pairingID: "p"))
            let now = Date(timeIntervalSince1970: TimeInterval(message.ts) / 1000 + 5)
            XCTAssertEqual(receiver.receive(m.envelope, now: now), .accepted(message))
        }
        let first = try JSONDecoder().decode(CodeMessage.self, from: Data(v.messages[0].plaintext.utf8))
        XCTAssertEqual(first.domain, "chase.com")
        let second = try JSONDecoder().decode(CodeMessage.self, from: Data(v.messages[1].plaintext.utf8))
        XCTAssertNil(second.domain)
        XCTAssertEqual(second.code, "G-482913")
        XCTAssertTrue(second.body.contains("Ünïcödé ✓"))
    }

    func testMustFailVectorsAreDropped() {
        let macSecret = b(v.keys["mac"]!.secretKey)
        let phonePub = b(v.keys["phone"]!.publicKey)
        XCTAssertEqual(v.mustFail.count, 2)
        for f in v.mustFail {
            XCTAssertNil(BoxCrypto.open(ciphertext: b(f.envelope.ct), nonce: b(f.envelope.nonce),
                                        senderPublicKey: phonePub, recipientSecretKey: macSecret), f.why)
            let receiver = Receiver(phonePublicKey: phonePub, macSecretKey: macSecret, seen: SeenStore(fileURL: nil, pairingID: "p"))
            XCTAssertEqual(receiver.receive(f.envelope, now: Date(timeIntervalSince1970: 1_760_900_000)), .dropped(.boxDidNotOpen), f.why)
        }
    }

    func testBase64URL() {
        XCTAssertEqual(Base64URL.encode(Data([0xfb, 0xff])), "-_8")
        XCTAssertEqual(Base64URL.decode("-_8"), Data([0xfb, 0xff]))
        XCTAssertNil(Base64URL.decode("+/8="))
        XCTAssertNil(Base64URL.decode("a"))
    }
}
