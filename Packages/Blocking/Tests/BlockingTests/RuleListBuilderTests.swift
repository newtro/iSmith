@testable import Blocking
import ContentBlockerConverter
import Foundation
import WebKit
import XCTest

/// Conversion of Adblock Plus lists to WebKit JSON, and the split into lists under a limit.
final class RuleListBuilderTests: XCTestCase {
    private func rules(_ json: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    private func actions(_ rules: [[String: Any]], _ type: String) -> [[String: Any]] {
        rules.filter { ($0["action"] as? [String: Any])?["type"] as? String == type }
    }

    private func urlFilter(_ rule: [String: Any]) -> String {
        (rule["trigger"] as? [String: Any])?["url-filter"] as? String ?? ""
    }

    func testConvertsFixtureList() throws {
        let lists = try RuleListBuilder.build(sources: [("fixture", Fixtures.fixtureText)])
        XCTAssertEqual(lists.map(\.name), ["fixture-1"])
        let list = lists[0]
        let rules = try rules(list.json)
        XCTAssertEqual(rules.count, list.ruleCount)

        let blocks = actions(rules, "block")
        XCTAssertTrue(blocks.contains { urlFilter($0).contains("adbanner") }, "the /ads/adbanner.js rule")
        XCTAssertTrue(blocks.contains { urlFilter($0).contains("tracker\\.example") }, "the ||tracker.example^ rule")
        let thirdParty = try XCTUnwrap(blocks.first { urlFilter($0).contains("ads\\.example") })
        XCTAssertEqual((thirdParty["trigger"] as? [String: Any])?["load-type"] as? [String], ["third-party"])

        let exceptions = actions(rules, "ignore-previous-rules")
        XCTAssertTrue(exceptions.contains { urlFilter($0).contains("allowed\\.js") }, "the @@ exception")

        let hiding = actions(rules, "css-display-none")
        XCTAssertTrue(hiding.contains { ($0["action"] as? [String: Any])?["selector"] as? String == ".ad-banner" })
        XCTAssertTrue(hiding.contains { ($0["action"] as? [String: Any])?["selector"] as? String == ".sponsored-box" })
        // The #@# exception keeps .ad-banner visible on example.org.
        let generic = try XCTUnwrap(hiding.first { ($0["action"] as? [String: Any])?["selector"] as? String == ".ad-banner" })
        let trigger = generic["trigger"] as? [String: Any] ?? [:]
        let unless = (trigger["unless-domain"] as? [String] ?? []) + (trigger["unless-top-url"] as? [String] ?? [])
            + (trigger["unless-frame-url"] as? [String] ?? [])
        XCTAssertTrue(unless.contains { $0.contains("example.org") || $0.contains("example\\.org") }, "\(trigger)")

        // CSS injection (#$#) is advanced AdGuard syntax WebKit can't express; it's left out.
        XCTAssertFalse(list.json.contains("background"))
        XCTAssertEqual(list.skippedLines, 1, "the rule with an unknown option")
    }

    func testSkipsCommentsBlankLinesAndHeaders() {
        let text = "\u{FEFF}[Adblock Plus 2.0]\r\n! comment\r\n\r\n  ||a.example^  \n[not a header\n"
        XCTAssertEqual(RuleListBuilder.rules(in: text), ["||a.example^", "[not a header"])
    }

    func testClassifiesLinesThatAffectOtherLines() {
        XCTAssertTrue(RuleListBuilder.isGlobal("@@||a.example^"))
        XCTAssertTrue(RuleListBuilder.isGlobal("example.org#@#.ad"))
        XCTAssertTrue(RuleListBuilder.isGlobal("||a.example^$script,badfilter"))
        XCTAssertTrue(RuleListBuilder.isGlobal("||a.example^$badfilter"))
        XCTAssertFalse(RuleListBuilder.isGlobal("||a.example^$script"))
        XCTAssertFalse(RuleListBuilder.isGlobal("##.ad"))
    }

    /// 200 blocking lines across two sources with a limit of 50 rules per list: each list stays
    /// under the limit, every blocking line lands in exactly one list (as its two rules, see
    /// `subresourceTypes`), and every list carries every exception, including the other source's.
    func testSplitsIntoListsUnderTheLimitWithExceptionsInEach() throws {
        let alpha = (0..<120).map { "||alpha\($0).example^" } + ["@@||alpha0.example/ok.js"]
        let beta = (0..<80).map { "||beta\($0).example^" } + ["@@||alpha1.example/ok.js", "@@||beta0.example/ok.js"]
        let lists = try RuleListBuilder.build(sources: [("alpha", alpha.joined(separator: "\n")), ("beta", beta.joined(separator: "\n"))],
                                              safariVersion: .autodetect(), maxRulesPerList: 50)
        XCTAssertGreaterThan(lists.count, 4)
        XCTAssertTrue(lists.contains { $0.name == "alpha-3" })
        XCTAssertTrue(lists.contains { $0.name == "beta-2" })

        var blocked: [String] = []
        for list in lists {
            let rules = try rules(list.json)
            XCTAssertLessThanOrEqual(rules.count, 50, list.name)
            XCTAssertEqual(rules.count, list.ruleCount)
            XCTAssertEqual(actions(rules, "ignore-previous-rules").count, 3, "\(list.name) has all three exceptions")
            // Exceptions come after the blocking rules, so they apply to them.
            let lastBlock = rules.lastIndex { ($0["action"] as? [String: Any])?["type"] as? String == "block" } ?? -1
            let firstException = rules.firstIndex { ($0["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" } ?? .max
            XCTAssertLessThan(lastBlock, firstException, list.name)
            blocked += actions(rules, "block").map(urlFilter)
        }
        XCTAssertEqual(blocked.count, 400)
        XCTAssertEqual(Set(blocked).count, 200)
    }

    func testSplitListsCompileInWebKit() async throws {
        let lines = (0..<300).map { "||split\($0).example^" } + ["@@||split0.example/ok.js"]
        let lists = try RuleListBuilder.build(sources: [("split", lines.joined(separator: "\n"))],
                                              safariVersion: .autodetect(), maxRulesPerList: 100)
        XCTAssertGreaterThan(lists.count, 6, "300 lines make 600 rules")
        XCTAssertTrue(lists.allSatisfy { $0.ruleCount <= 100 })
        let dir = try TempDir()
        let store = try await WebKitRuleListStore(directory: dir.url)
        for list in lists {
            let compiled = try await store.compile(identifier: list.name, json: list.json)
            let identifier = await compiled.identifier
            XCTAssertEqual(identifier, list.name)
        }
    }

    func testExceptionsOverTheLimitThrow() {
        let lines = (0..<20).map { "@@||ok\($0).example^" } + ["||ad.example^"]
        XCTAssertThrowsError(try RuleListBuilder.build(sources: [("x", lines.joined(separator: "\n"))],
                                                       safariVersion: .autodetect(), maxRulesPerList: 10)) { error in
            guard case RuleListBuilder.BuildError.exceptionsExceedLimit = error else { return XCTFail("\(error)") }
        }
    }

    func testEmptySourceStillMakesACompilableList() throws {
        let lists = try RuleListBuilder.build(sources: [("empty", "[Adblock Plus 2.0]\n! nothing\n")])
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(lists[0].ruleCount, 0)
        XCTAssertEqual(try rules(lists[0].json).count, 1, "WebKit needs one rule; the converter adds a no-op")
    }

    /// A cosmetic exception and a `$badfilter` in one source act on the other source's rules.
    func testCosmeticExceptionsAndBadfilterWorkAcrossSources() throws {
        let alpha = "##.cross-ad\n||cross.example^\n||kept.example^\n"
        let beta = "example.org#@#.cross-ad\n||cross.example^$badfilter\n||beta.example^\n"
        let lists = try RuleListBuilder.build(sources: [("alpha", alpha), ("beta", beta)])
        let alphaRules = try rules(try XCTUnwrap(lists.first { $0.name == "alpha-1" }).json)
        let blocked = actions(alphaRules, "block").map(urlFilter)
        XCTAssertFalse(blocked.contains { $0.contains("cross") }, "badfilter from beta: \(blocked)")
        XCTAssertTrue(blocked.contains { $0.contains("kept") })
        let hiding = try XCTUnwrap(actions(alphaRules, "css-display-none").first {
            ($0["action"] as? [String: Any])?["selector"] as? String == ".cross-ad"
        })
        let trigger = hiding["trigger"] as? [String: Any] ?? [:]
        let unless = (trigger["unless-domain"] as? [String] ?? []) + (trigger["unless-top-url"] as? [String] ?? [])
            + (trigger["unless-frame-url"] as? [String] ?? [])
        XCTAssertTrue(unless.contains { $0.contains("example.org") || $0.contains("example\\.org") }, "\(trigger)")
    }
}
