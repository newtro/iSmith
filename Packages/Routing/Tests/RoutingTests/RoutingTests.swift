import Foundation
import XCTest
@testable import Routing

private func url(_ s: String) -> URL { URL(string: s)! }
private func pattern(_ s: String) -> URLPattern { try! URLPattern(parsing: s) }

final class URLPatternTests: XCTestCase {
    /// Which addresses each kind of pattern matches.
    func testMatchingTable() {
        let table: [(String, String, Bool)] = [
            // Host only: any path, any case, www. ignored, either scheme.
            ("dev.azure.com", "https://dev.azure.com/contoso-dev/Storefront/_boards", true),
            ("dev.azure.com", "http://DEV.Azure.com", true),
            ("github.com", "https://www.github.com/newtro", true),
            ("www.github.com", "https://github.com/", true),
            ("dev.azure.com", "https://azure.com/", false),
            ("dev.azure.com", "https://x.dev.azure.com/", false),
            ("dev.azure.com", "https://dev.azure.com.evil.com/", false),
            // Host and path prefix, on segment boundaries, without case.
            ("dev.azure.com/contoso-dev", "https://dev.azure.com/contoso-dev", true),
            ("dev.azure.com/contoso-dev", "https://dev.azure.com/contoso-dev/", true),
            ("dev.azure.com/contoso-dev", "https://dev.azure.com/Contoso-Dev/Storefront/_workitems/edit/12?x=1#y", true),
            ("dev.azure.com/contoso-dev", "https://dev.azure.com/contoso-dev2/x", false),
            ("dev.azure.com/contoso-dev", "https://dev.azure.com/other/contoso-dev", false),
            ("dev.azure.com/contoso-dev/*", "https://dev.azure.com/contoso-dev/a", true),
            ("https://dev.azure.com/contoso-dev/", "https://dev.azure.com/contoso-dev/a", true),
            ("example.com/a/b", "https://example.com/a/b/c", true),
            ("example.com/a/b", "https://example.com/a/c", false),
            ("example.com/with%20space", "https://example.com/with%20space/x", true),
            // Wildcard subdomains: the domain itself and every subdomain.
            ("*.fabrikam.com", "https://fabrikam.com/", true),
            ("*.fabrikam.com", "https://files.fabrikam.com/a", true),
            ("*.fabrikam.com", "https://a.b.fabrikam.com/", true),
            ("*.fabrikam.com", "https://notfabrikam.com/", false),
            ("*.sharepoint.com/sites/ops", "https://fabrikam.sharepoint.com/sites/ops/Shared", true),
            ("*.sharepoint.com/sites/ops", "https://fabrikam.sharepoint.com/sites/dev", false),
            // Ports.
            ("localhost:3000", "http://localhost:3000/x", true),
            ("localhost:3000", "http://localhost:3001/x", false),
            ("localhost", "http://localhost:3001/x", true),
            ("example.com:443", "https://example.com/", true),
            // Only web addresses.
            ("example.com", "ftp://example.com/", false),
            ("example.com", "file:///example.com", false),
        ]
        for (p, u, expected) in table {
            XCTAssertEqual(pattern(p).matches(url(u)), expected, "\(p) vs \(u)")
        }
    }

    func testParsingNormalizesAndRejects() throws {
        XCTAssertEqual(pattern("HTTPS://WWW.Dev.Azure.com/Contoso-Dev/*").description, "dev.azure.com/contoso-dev")
        XCTAssertEqual(pattern("*.Fabrikam.com/").description, "*.fabrikam.com")
        XCTAssertEqual(pattern("  localhost:3000/app?x=1#top ").description, "localhost:3000/app")
        XCTAssertEqual(pattern("example.com.").description, "example.com")
        XCTAssertThrowsError(try URLPattern(parsing: "   ")) { XCTAssertEqual($0 as? URLPattern.ParseError, .empty) }
        XCTAssertThrowsError(try URLPattern(parsing: "dev.*.com")) { XCTAssertEqual($0 as? URLPattern.ParseError, .misplacedWildcard) }
        XCTAssertThrowsError(try URLPattern(parsing: "example.com/foo*")) { XCTAssertEqual($0 as? URLPattern.ParseError, .misplacedWildcard) }
        XCTAssertThrowsError(try URLPattern(parsing: "*")) { XCTAssertEqual($0 as? URLPattern.ParseError, .misplacedWildcard) }
        XCTAssertThrowsError(try URLPattern(parsing: "exa mple.com")) { XCTAssertEqual($0 as? URLPattern.ParseError, .badHost) }
        XCTAssertThrowsError(try URLPattern(parsing: "example.com:http")) { XCTAssertEqual($0 as? URLPattern.ParseError, .badPort) }
        XCTAssertThrowsError(try URLPattern(parsing: "/just/a/path")) { XCTAssertEqual($0 as? URLPattern.ParseError, .badHost) }
    }

    func testCodableAsText() throws {
        let rule = RoutingRule(pattern: pattern("*.fabrikam.com/sites"), space: "fabrikam")
        let json = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
        XCTAssertTrue(json.contains("\"*.fabrikam.com\\/sites\""), json)
        XCTAssertEqual(try JSONDecoder().decode(RoutingRule.self, from: Data(json.utf8)), rule)
    }
}

final class RouterTests: XCTestCase {
    let spaces = ["personal", "contoso", "fabrikam", "newtro"]

    private func state() -> RoutingState {
        var s = RoutingState()
        s.rules = [
            RoutingRule(pattern: pattern("dev.azure.com/contoso-dev"), space: "contoso"),
            RoutingRule(pattern: pattern("*.sharepoint.com/sites/fabrikam"), space: "fabrikam"),
            RoutingRule(pattern: pattern("fabrikam.sharepoint.com"), space: "fabrikam"),
            RoutingRule(pattern: pattern("dev.azure.com"), space: "personal"),
            RoutingRule(pattern: pattern("etsy.com/your/shops/newtro"), space: "newtro"),
        ]
        return s
    }

    func testFirstMatchingRuleWins() {
        let s = state()
        XCTAssertEqual(s.route(url("https://dev.azure.com/contoso-dev/Storefront/_boards"), spaces: spaces)?.space, "contoso")
        XCTAssertEqual(s.route(url("https://dev.azure.com/other"), spaces: spaces)?.space, "personal", "the broader rule below")
        XCTAssertEqual(s.route(url("https://fabrikam.sharepoint.com/:w:/r/x"), spaces: spaces)?.space, "fabrikam")
        XCTAssertEqual(s.route(url("https://www.etsy.com/your/shops/newtro/dashboard"), spaces: spaces)?.space, "newtro")
        XCTAssertEqual(s.route(url("https://dev.azure.com/contoso-dev"), spaces: spaces)?.reason, .rule(s.rules[0].id))
    }

    func testNoRuleGoesToTheDefaultSpace() {
        var s = state()
        XCTAssertEqual(s.route(url("https://example.com"), spaces: spaces), Route(space: "personal", reason: .defaultSpace),
                       "no Default space set: the first space")
        s.defaultSpace = "newtro"
        XCTAssertEqual(s.route(url("https://example.com"), spaces: spaces)?.space, "newtro")
        XCTAssertEqual(s.route(url("https://example.com"), spaces: ["contoso", "fabrikam"])?.space, "contoso",
                       "a deleted Default space falls back to the first space")
        XCTAssertNil(s.route(url("https://example.com"), spaces: []))
    }

    func testRulesForDeletedSpacesAreSkipped() {
        let s = state()
        XCTAssertEqual(s.route(url("https://dev.azure.com/contoso-dev"), spaces: ["personal", "fabrikam"])?.space, "personal",
                       "the Contoso rule is skipped, the next match applies")
    }

    func testSharedAddressHostsUseTheLastUsedSpace() {
        var s = state()
        let outlook = url("https://outlook.office.com/mail/inbox/id/AAQk")
        XCTAssertEqual(s.route(outlook, spaces: spaces)?.reason, .defaultSpace, "never used: the Default space")
        XCTAssertTrue(s.noteUse(url("https://outlook.office.com/mail/"), space: "fabrikam"))
        XCTAssertFalse(s.noteUse(url("https://outlook.office.com/calendar"), space: "fabrikam"), "unchanged")
        XCTAssertEqual(s.route(outlook, spaces: spaces), Route(space: "fabrikam", reason: .lastUsed))
        s.noteUse(url("https://outlook.office.com/"), space: "contoso")
        XCTAssertEqual(s.route(outlook, spaces: spaces)?.space, "contoso", "the latest use wins")
        // Each shared host is tracked on its own.
        s.noteUse(url("https://teams.microsoft.com/l/message/1"), space: "fabrikam")
        s.noteUse(url("https://mail.google.com/mail/u/0/"), space: "newtro")
        s.noteUse(url("https://www.office.com/"), space: "fabrikam")
        XCTAssertEqual(s.route(url("https://teams.microsoft.com/l/meetup-join/x"), spaces: spaces)?.space, "fabrikam")
        XCTAssertEqual(s.route(url("https://mail.google.com/mail/u/0/#inbox/1"), spaces: spaces)?.space, "newtro")
        XCTAssertEqual(s.route(url("https://office.com/launch/word"), spaces: spaces)?.space, "fabrikam")
        XCTAssertEqual(s.route(outlook, spaces: spaces)?.space, "contoso")
        // Other hosts aren't tracked.
        XCTAssertFalse(s.noteUse(url("https://github.com/"), space: "fabrikam"))
        XCTAssertEqual(s.route(url("https://github.com/"), spaces: spaces)?.reason, .defaultSpace)
        // A rule beats last-used; a deleted space is skipped.
        s.rules.insert(RoutingRule(pattern: pattern("outlook.office.com"), space: "personal"), at: 0)
        XCTAssertEqual(s.route(outlook, spaces: spaces)?.space, "personal")
        s.rules.removeFirst()
        XCTAssertEqual(s.route(outlook, spaces: ["personal", "fabrikam"])?.reason, .defaultSpace)
    }

    func testSharedAddressHostList() {
        for u in ["https://outlook.office.com/mail", "https://outlook.office365.com/owa", "https://teams.microsoft.com/",
                  "https://www.office.com/", "https://m365.cloud.microsoft/", "https://mail.google.com/"] {
            XCTAssertNotNil(SharedAddressHosts.key(for: url(u)), u)
        }
        for u in ["https://dev.azure.com/", "https://google.com/", "https://microsoft.com/", "https://docs.google.com/"] {
            XCTAssertNil(SharedAddressHosts.key(for: url(u)), u)
        }
    }

    func testRemovingASpace() {
        var s = state()
        s.defaultSpace = "fabrikam"
        s.noteUse(url("https://outlook.office.com/"), space: "fabrikam")
        _ = s.recordMove(link: UUID(), url: url("https://example.com/a"), to: "fabrikam", spaces: spaces)
        s.removeSpace("fabrikam")
        XCTAssertFalse(s.rules.contains { $0.space == "fabrikam" })
        XCTAssertNil(s.defaultSpace)
        XCTAssertTrue(s.lastUsed.isEmpty)
        XCTAssertTrue(s.moves.isEmpty)
    }
}

final class LearningTests: XCTestCase {
    let spaces = ["personal", "contoso", "fabrikam"]

    func testTwoMovesOfTheSameKindOfLinkOfferARule() {
        var s = RoutingState()
        XCTAssertNil(s.recordMove(link: UUID(), url: url("https://dev.azure.com/contoso-dev/Storefront/_workitems/edit/1"),
                                  to: "contoso", spaces: spaces), "once isn't enough")
        let suggestion = s.recordMove(link: UUID(), url: url("https://dev.azure.com/Contoso-Dev/Storefront/_git/repo"),
                                      to: "contoso", spaces: spaces)
        XCTAssertEqual(suggestion, RuleSuggestion(pattern: pattern("dev.azure.com/contoso-dev"), space: "contoso"))
        let rule = s.accept(suggestion!)
        XCTAssertEqual(s.rules, [rule])
        XCTAssertTrue(s.moves.isEmpty, "the moves behind an accepted rule are forgotten")
        XCTAssertEqual(s.route(url("https://dev.azure.com/contoso-dev/x"), spaces: spaces)?.space, "contoso")
        XCTAssertNil(s.recordMove(link: UUID(), url: url("https://dev.azure.com/contoso-dev/a"), to: "contoso", spaces: spaces))
        XCTAssertNil(s.recordMove(link: UUID(), url: url("https://dev.azure.com/contoso-dev/b"), to: "contoso", spaces: spaces),
                     "the rule already does it")
    }

    func testTheSameLinkMovedAgainCountsOnce() {
        var s = RoutingState()
        let link = UUID()
        let u = url("https://dev.azure.com/contoso-dev/a")
        XCTAssertNil(s.recordMove(link: link, url: u, to: "fabrikam", spaces: spaces))
        XCTAssertNil(s.recordMove(link: link, url: u, to: "contoso", spaces: spaces))
        XCTAssertNil(s.recordMove(link: link, url: u, to: "contoso", spaces: spaces))
        XCTAssertEqual(s.moves.count, 1, "only where the link ended up")
    }

    func testDifferentPathsOnOneHostOfferTheHost() {
        var s = RoutingState()
        XCTAssertNil(s.recordMove(link: UUID(), url: url("https://fabrikam.sharepoint.com/sites/ops/x"), to: "fabrikam", spaces: spaces))
        XCTAssertEqual(s.recordMove(link: UUID(), url: url("https://fabrikam.sharepoint.com/:w:/r/doc"), to: "fabrikam", spaces: spaces),
                       RuleSuggestion(pattern: pattern("fabrikam.sharepoint.com"), space: "fabrikam"))
        // A host whose links went to two spaces isn't offered as a whole.
        var t = RoutingState()
        _ = t.recordMove(link: UUID(), url: url("https://github.com/newtro/a"), to: "personal", spaces: spaces)
        _ = t.recordMove(link: UUID(), url: url("https://github.com/contoso-dev/b"), to: "contoso", spaces: spaces)
        XCTAssertNil(t.recordMove(link: UUID(), url: url("https://github.com/scott/c"), to: "personal", spaces: spaces))
        XCTAssertEqual(t.recordMove(link: UUID(), url: url("https://github.com/contoso-dev/d"), to: "contoso", spaces: spaces),
                       RuleSuggestion(pattern: pattern("github.com/contoso-dev"), space: "contoso"))
    }

    func testRootLinksOfferTheHost() {
        var s = RoutingState()
        _ = s.recordMove(link: UUID(), url: url("https://www.etsy.com/"), to: "fabrikam", spaces: spaces)
        XCTAssertEqual(s.recordMove(link: UUID(), url: url("https://etsy.com"), to: "fabrikam", spaces: spaces),
                       RuleSuggestion(pattern: pattern("etsy.com"), space: "fabrikam"))
    }

    func testSharedAddressHostsAreNotLearned() {
        var s = RoutingState()
        for _ in 0..<3 {
            XCTAssertNil(s.recordMove(link: UUID(), url: url("https://outlook.office.com/mail/x"), to: "fabrikam", spaces: spaces))
        }
        XCTAssertTrue(s.moves.isEmpty)
    }

    func testNotNowAndNever() {
        var s = RoutingState()
        let a = url("https://dev.azure.com/contoso-dev/1")
        _ = s.recordMove(link: UUID(), url: a, to: "contoso", spaces: spaces)
        let first = s.recordMove(link: UUID(), url: a, to: "contoso", spaces: spaces)!
        s.postpone(first)
        XCTAssertNil(s.recordMove(link: UUID(), url: a, to: "contoso", spaces: spaces), "Not now: two more moves needed")
        XCTAssertEqual(s.recordMove(link: UUID(), url: a, to: "contoso", spaces: spaces), first)
        s.never(first)
        XCTAssertEqual(s.neverSuggest, [first.pattern])
        for _ in 0..<3 { XCTAssertNil(s.recordMove(link: UUID(), url: a, to: "contoso", spaces: spaces), "Never") }
        XCTAssertTrue(s.rules.isEmpty)
    }

    func testAcceptedRuleGoesAheadOfABroaderRule() {
        var s = RoutingState()
        let broad = RoutingRule(pattern: pattern("dev.azure.com"), space: "personal")
        let other = RoutingRule(pattern: pattern("github.com"), space: "personal")
        s.rules = [other, broad]
        let a = url("https://dev.azure.com/contoso-dev/1")
        _ = s.recordMove(link: UUID(), url: a, to: "contoso", spaces: spaces)
        let suggestion = s.recordMove(link: UUID(), url: a, to: "contoso", spaces: spaces)!
        let rule = s.accept(suggestion)
        XCTAssertEqual(s.rules.map(\.id), [other.id, rule.id, broad.id])
        XCTAssertEqual(s.route(a, spaces: spaces)?.space, "contoso")
    }

    func testMovesAreCapped() {
        var s = RoutingState()
        for i in 0..<(RoutingState.maxMoves + 10) {
            _ = s.recordMove(link: UUID(), url: url("https://h\(i).example.com/"), to: "fabrikam", spaces: spaces)
        }
        XCTAssertEqual(s.moves.count, RoutingState.maxMoves)
        XCTAssertEqual(s.moves.first?.host, "h10.example.com")
    }
}

@MainActor
final class RoutingStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appendingPathComponent("routing.json") }

    func testEverythingSurvivesARelaunch() throws {
        let store = RoutingStore(fileURL: file)
        let a = RoutingRule(pattern: pattern("dev.azure.com/contoso-dev"), space: "contoso")
        let b = RoutingRule(pattern: pattern("*.fabrikam.com"), space: "fabrikam")
        let c = RoutingRule(pattern: pattern("etsy.com"), space: "newtro")
        store.addRule(a)
        store.addRule(b)
        store.addRule(c, at: 0)
        store.moveRule(c.id, to: 2)
        var edited = b
        edited.space = "personal"
        store.updateRule(edited)
        store.setDefaultSpace("contoso")
        store.noteUse(url("https://outlook.office.com/mail/"), space: "fabrikam")
        _ = store.recordMove(link: UUID(), url: url("https://github.com/x"), to: "personal", spaces: ["personal"])
        store.never(RuleSuggestion(pattern: pattern("example.com"), space: "personal"))
        store.setDefaultBrowserOffered()

        let reopened = RoutingStore(fileURL: file)
        XCTAssertEqual(reopened.state, store.state)
        XCTAssertEqual(reopened.state.rules.map(\.id), [a.id, edited.id, c.id])
        XCTAssertEqual(reopened.state.rules[1].space, "personal")
        XCTAssertEqual(reopened.state.defaultSpace, "contoso")
        XCTAssertEqual(reopened.state.lastUsed, ["outlook.office.com": "fabrikam"])
        XCTAssertEqual(reopened.state.moves.count, 1)
        XCTAssertEqual(reopened.state.neverSuggest, [pattern("example.com")])
        XCTAssertTrue(reopened.state.defaultBrowserOffered)

        reopened.removeRule(a.id)
        reopened.allowSuggestions(pattern("example.com"))
        reopened.forgetLastUsed(host: "outlook.office.com")
        let third = RoutingStore(fileURL: file)
        XCTAssertEqual(third.state.rules.map(\.id), [edited.id, c.id])
        XCTAssertTrue(third.state.neverSuggest.isEmpty)
        XCTAssertTrue(third.state.lastUsed.isEmpty)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600, "routing.json is owner-only")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testTheFileIsReadable() throws {
        let store = RoutingStore(fileURL: file)
        store.addRule(RoutingRule(pattern: pattern("https://dev.azure.com/contoso-dev/*"), space: "contoso"))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"dev.azure.com\\/contoso-dev\""), text)
    }

    func testUnreadableFileIsKeptAside() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: file)
        let store = RoutingStore(fileURL: file)
        XCTAssertEqual(store.state, RoutingState())
        XCTAssertNotNil(store.movedAside)
        XCTAssertEqual(try String(contentsOf: store.movedAside!, encoding: .utf8), "{ not json")
        store.setDefaultSpace("x")
        XCTAssertEqual(RoutingStore(fileURL: file).state.defaultSpace, "x")
    }

    func testABadRuleIsDroppedNotTheFile() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"version": 1, "defaultSpace": "contoso",
         "rules": [{"id": "\(UUID().uuidString)", "pattern": "dev.*.com", "space": "a"},
                   {"id": "\(UUID().uuidString)", "pattern": "github.com", "space": "b"}]}
        """
        try Data(json.utf8).write(to: file)
        let store = RoutingStore(fileURL: file)
        XCTAssertNil(store.movedAside)
        XCTAssertEqual(store.state.defaultSpace, "contoso")
        XCTAssertEqual(store.state.rules.map(\.pattern.description), ["github.com"])
    }

    func testLastUsedWritesOnlyOnChange() throws {
        let store = RoutingStore(fileURL: file)
        store.noteUse(url("https://outlook.office.com/"), space: "a")
        let first = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
        store.noteUse(url("https://outlook.office.com/mail"), space: "a")
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertNotNil(first)
        XCTAssertEqual(after, Date(timeIntervalSince1970: 0), "same space again: not rewritten")
    }
}
