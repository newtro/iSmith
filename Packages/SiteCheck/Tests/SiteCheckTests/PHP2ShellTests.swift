import Foundation
import XCTest
@testable import SiteCheck

/// Ported from php2shell-site-check's test/verdict.test.js.
private func evidence(_ headers: KeyValuePairs<String, String>, _ url: String = "https://example.com/") -> PHP2Shell.Evidence {
    PHP2Shell.merge(.init(), PHP2Shell.analyze(headers: headers.map { ($0.key, $0.value) }, url: URL(string: url)))
}

private func level(_ headers: KeyValuePairs<String, String>, _ url: String = "https://example.com/") -> PHP2Shell.Level {
    PHP2Shell.classify(evidence(headers, url)).level
}

final class PHP2ShellTests: XCTestCase {
    func testVersionsBelowEachFixAreVulnerable() {
        for v in ["8.5.11", "8.4.26", "8.3.35", "8.2.0"] {
            XCTAssertEqual(level(["X-Powered-By": "PHP/\(v)"]), .vulnerable, v)
        }
    }

    func testFixedReleasesAndLaterArePatched() {
        for v in ["8.5.12", "8.4.27", "8.3.40", "8.2.35", "8.6.0", "9.0.1"] {
            XCTAssertEqual(level(["X-Powered-By": "PHP/\(v)"]), .patched, v)
        }
    }

    func testEndOfLifeBranchesAreVulnerable() {
        for v in ["8.1.33", "7.4.33", "5.6.40"] {
            XCTAssertEqual(level(["X-Powered-By": "PHP/\(v)"]), .vulnerable, v)
        }
    }

    func testDistributionBuildsAreMaybe() {
        XCTAssertEqual(level(["X-Powered-By": "PHP/8.1.2-1ubuntu2.22"]), .maybe)
        XCTAssertEqual(level(["X-Powered-By": "PHP/8.2.29-1~deb12u1"]), .maybe)
        XCTAssertEqual(level(["X-Powered-By": "PHP/8.2.13", "Server": "Apache/2.4.57 (Red Hat Enterprise Linux)"]), .maybe)
        XCTAssertEqual(level(["X-Powered-By": "PHP/8.0.30", "Server": "Apache/2.4.37 (AlmaLinux) OpenSSL/1.1.1k"]), .maybe)
        XCTAssertEqual(level(["Server": "Apache/2.4.41 (Ubuntu) PHP/7.4.3"]), .maybe)
    }

    func testServerHeaderCarriesTheVersion() {
        XCTAssertEqual(level(["Server": "Apache/2.4.62 (Unix) PHP/8.3.20"]), .vulnerable)
    }

    func testPHPWithoutAVersionIsUnknown() {
        XCTAssertEqual(level(["Set-Cookie": "PHPSESSID=abc123; path=/"]), .unknown)
        XCTAssertEqual(level(["Set-Cookie": "a=1; path=/, PHPSESSID=abc123; path=/"]), .unknown)
        XCTAssertEqual(level(["X-Pingback": "https://example.com/xmlrpc.php"]), .unknown)
        XCTAssertEqual(level(["Link": #"<https://example.com/wp-json/>; rel="https://api.w.org/""#]), .unknown)
        XCTAssertEqual(level([:], "https://example.com/index.php"), .unknown)
        XCTAssertEqual(level(["X-Powered-By": "PHP/8.3"]), .unknown)
    }

    func testNoPHPSignalsIsNone() {
        XCTAssertEqual(level(["Server": "nginx", "X-Powered-By": "Express"]), .noPHP)
        XCTAssertEqual(level(["Set-Cookie": "session=abc"]), .noPHP)
        XCTAssertEqual(level([:], "https://example.com/php-guide"), .noPHP)
    }

    func testTokensContainingPHPAreIgnored() {
        XCTAssertEqual(level(["X-Powered-By": "PHPExpress-Clone"]), .noPHP)
        XCTAssertEqual(level(["Server": "phpmyfake"]), .noPHP)
    }

    func testUpstreamRepacksAndDockerImagesAreNotBackports() {
        XCTAssertEqual(level(["X-Powered-By": "PHP/8.3.20-1+ubuntu22.04.1+deb.sury.org+1"]), .vulnerable)
        XCTAssertEqual(level(["X-Powered-By": "PHP/8.3.20", "Server": "nginx/1.18.0 (Ubuntu)"]), .vulnerable)
        XCTAssertEqual(level(["X-Powered-By": "PHP/8.3.20", "Server": "Apache/2.4.62 (Debian)"]), .vulnerable)
        XCTAssertEqual(level(["X-Powered-By": "PHP/8.3.14-1+0~20241128.48+debian12~1.gbp3d6ba8"]), .vulnerable)
    }

    func testRHELBehindABareServerHeaderIsAKnownLimit() {
        let v = PHP2Shell.classify(evidence(["X-Powered-By": "PHP/8.2.13", "Server": "nginx/1.20.1"]))
        XCTAssertEqual(v.level, .vulnerable)
        XCTAssertTrue(v.reason.contains("unless its operating system vendor backported"))
    }

    func testMergeAddsSignalsAndTheWorstVersionWins() {
        var ev = evidence(["Set-Cookie": "PHPSESSID=1"])
        XCTAssertEqual(PHP2Shell.classify(ev).level, .unknown)
        ev = PHP2Shell.merge(ev, evidence(["X-Powered-By": "PHP/8.4.30"], "https://a.test/x"))
        XCTAssertEqual(PHP2Shell.classify(ev).level, .patched)
        ev = PHP2Shell.merge(ev, evidence(["X-Powered-By": "PHP/7.4.3"], "https://a.test/legacy/x.php"))
        XCTAssertEqual(PHP2Shell.classify(ev).level, .vulnerable)
        XCTAssertEqual(PHP2Shell.classify(ev).version, "7.4.3")
    }

    func testEvidenceIsCappedButTheWorstVersionSurvives() {
        var ev = evidence(["X-Powered-By": "PHP/7.4.3"])
        for i in 0..<50 {
            ev = PHP2Shell.merge(ev, PHP2Shell.analyze(headers: [("X-Powered-By", "PHP/8.5.\(20 + i)"), ("Server", "s\(i)")],
                                                       url: URL(string: "https://a.test/x")))
        }
        XCTAssertLessThanOrEqual(ev.versions.count, 10)
        XCTAssertLessThanOrEqual(ev.signals.count, 10)
        XCTAssertEqual(PHP2Shell.classify(ev).version, "7.4.3")
    }

    /// Foundation joins repeated headers with ", "; every version in them counts.
    func testRepeatedHeadersJoinedByFoundation() {
        XCTAssertEqual(level(["X-Powered-By": "PHP/8.4.30, PHP/7.4.3"]), .vulnerable)
        XCTAssertEqual(PHP2Shell.classify(evidence(["X-Powered-By": "PHP/8.4.30, PHP/7.4.3"])).version, "7.4.3")
    }

    func testReadsHTTPURLResponseHeaders() {
        let response = HTTPURLResponse(url: URL(string: "https://a.test/")!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["X-Powered-By": "PHP/8.4.1", "Content-Type": "text/html"])!
        XCTAssertEqual(PHP2Shell.classify(PHP2Shell.analyze(response)).level, .vulnerable)
    }
}
