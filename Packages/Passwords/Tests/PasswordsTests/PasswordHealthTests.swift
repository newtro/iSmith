import AppKit
@testable import Passwords
import SignInSync
import XCTest

/// Weak and reused password detection, the generator, and the pasteboard helper.
final class PasswordHealthTests: XCTestCase {
    func testWeakPasswords() {
        let weak = [
            "", "abc", "short1!", "password", "Password1!", "P@ssw0rd123", "12345678", "qwertyuiop",
            "abcdefgh", "aaaaaaaaaaaa", "abababababab", "Football2024", "letmein!!", "scottsmith99",
            "Example2024!",
        ]
        for password in weak {
            XCTAssertEqual(PasswordStrength.evaluate(password, username: "scottsmith@example.com", host: "www.example.com"),
                           .weak, password)
        }
        let notWeak = ["xKfr4w-Pmdq7z-hTbn2c", "correct horse battery staple", "Tr0ub4dor&3-xyzzy", "q8#Lm2!vZ0pW"]
        for password in notWeak {
            XCTAssertGreaterThan(PasswordStrength.evaluate(password, username: "scottsmith", host: "example.com"),
                                 .weak, password)
        }
        XCTAssertEqual(PasswordStrength.evaluate("xKfr4w-Pmdq7z-hTbn2c"), .strong)
    }

    func testReuseAcrossSitesNotWithinOne() {
        let a = Origin(string: "https://a.com")!, wwwA = Origin(string: "https://www.a.com")!
        let b = Origin(string: "https://b.com")!, c = Origin(string: "https://c.com")!
        let shared = "Shared-Password-9x"
        let logins = [
            Login(origin: a, username: "1", password: shared),
            Login(origin: wwwA, username: "2", password: shared),   // same site: not reuse by itself
            Login(origin: b, username: "3", password: shared),
            Login(origin: c, username: "4", password: "Unique-Password-7q"),
            Login(origin: c, username: "5", password: "Only-On-C-site-4z"),
            Login(origin: a, username: "6", password: "Only-On-C-site-4z".uppercased()),
            Login(origin: b, username: "7", password: "password"),
        ]
        let report = SecurityReport(logins: logins)
        XCTAssertEqual(report.reused.count, 1)
        XCTAssertEqual(Set(report.reused[0]), Set([logins[0].id, logins[1].id, logins[2].id]))
        XCTAssertTrue(report.isReused(logins[1].id))
        XCTAssertFalse(report.isReused(logins[3].id))
        XCTAssertEqual(report.weak, [logins[6].id])

        let sameSiteOnly = SecurityReport(logins: [logins[0], logins[1]])
        XCTAssertTrue(sameSiteOnly.reused.isEmpty, "one password on two hosts of one site isn't reuse")
    }

    func testStoreSecurityReport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Health-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PasswordStore(fileURL: dir.appendingPathComponent("p.sqlite"), keyStore: InMemoryKeyStore())
        let weak = try store.add(origin: Origin(string: "https://a.com")!, username: "u", password: "123456")
        let r1 = try store.add(origin: Origin(string: "https://b.com")!, username: "u", password: "Reused-Twice-88z")
        let r2 = try store.add(origin: Origin(string: "https://c.com")!, username: "u", password: "Reused-Twice-88z")
        let report = try store.securityReport()
        XCTAssertEqual(report.weak, [weak.id])
        XCTAssertEqual(report.reused.map { Set($0) }, [Set([r1.id, r2.id])])
    }

    func testDefaultGeneratedPasswords() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let p = PasswordGenerator.generate()
            XCTAssertEqual(p.count, 20)
            let groups = p.split(separator: "-")
            XCTAssertEqual(groups.count, 3, p)
            XCTAssertTrue(groups.allSatisfy { $0.count == 6 }, p)
            XCTAssertTrue(p.contains { $0.isUppercase }, p)
            XCTAssertTrue(p.contains { $0.isLowercase }, p)
            XCTAssertTrue(p.contains { $0.isNumber }, p)
            XCTAssertFalse(p.contains { "lIoO01".contains($0) }, "no look-alikes: \(p)")
            XCTAssertEqual(PasswordStrength.evaluate(p), .strong, p)
            seen.insert(p)
        }
        XCTAssertEqual(seen.count, 200, "no repeats")
    }

    func testGeneratorFollowsPageRules() {
        let short = PasswordRequirements(maxLength: 12)
        for _ in 0..<50 {
            let p = PasswordGenerator.generate(short)
            XCTAssertEqual(p.count, 12)
        }
        let rules = PasswordRequirements(rules: "required: upper; required: digit; required: [!#]; allowed: lower; max-consecutive: 2; minlength: 10; maxlength: 16;")
        for _ in 0..<100 {
            let p = PasswordGenerator.generate(rules)
            XCTAssertEqual(p.count, 16, p)
            XCTAssertTrue(p.contains { $0.isUppercase }, p)
            XCTAssertTrue(p.contains { $0.isNumber }, p)
            XCTAssertTrue(p.contains { "!#".contains($0) }, p)
            XCTAssertFalse(p.contains("-"), "hyphens aren't allowed by these rules: \(p)")
            let chars = Array(p)
            for i in 2..<chars.count {
                XCTAssertFalse(chars[i] == chars[i - 1] && chars[i] == chars[i - 2], "max-consecutive 2: \(p)")
            }
        }
        let long = PasswordGenerator.generate(PasswordRequirements(minLength: 32))
        XCTAssertEqual(long.count, 32)
        // Page-supplied numbers can't stall the app or force a silly length.
        let start = Date()
        let huge = PasswordGenerator.generate(PasswordRequirements(minLength: 2_000_000_000, rules: "minlength: 2000000000; max-consecutive: 1;"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(huge.count, PasswordGenerator.lengthLimits.upperBound)
        XCTAssertEqual(PasswordGenerator.generate(PasswordRequirements(maxLength: 2)).count, PasswordGenerator.lengthLimits.lowerBound)
        // Bracketed literals never bring control characters, spaces or quotes.
        for _ in 0..<50 {
            let p = PasswordGenerator.generate(PasswordRequirements(rules: "allowed: [\u{01}\u{7F} \"'`ab]; required: [\u{01}x];"))
            XCTAssertTrue(p.allSatisfy { "abx".contains($0) }, p.debugDescription)
        }
        let fixture = PasswordRequirements(maxLength: 24, rules: "required: upper; required: digit; minlength: 12; maxlength: 24;")
        let p = PasswordGenerator.generate(fixture)
        XCTAssertTrue((12...24).contains(p.count), p)
    }

    @MainActor
    func testPasteboardIsConcealedAndCleared() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ismith-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        SecretPasteboard.copy("copied-secret", clearAfter: 0.3, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied-secret")
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertNil(pasteboard.string(forType: .string), "cleared after the delay")

        // Something copied in between is left alone.
        SecretPasteboard.copy("copied-secret", clearAfter: 0.3, pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("user's own text", forType: .string)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(pasteboard.string(forType: .string), "user's own text")
    }
}
