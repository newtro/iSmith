@testable import Passwords
import XCTest

/// Origin parsing and the matching rules, as tables.
final class OriginTests: XCTestCase {
    func testNormalization() {
        let table: [(String, String?)] = [
            ("https://Example.COM/path?q=1#x", "https://example.com"),
            ("https://example.com:443/", "https://example.com"),
            ("http://example.com:80", "http://example.com"),
            ("https://example.com:8443", "https://example.com:8443"),
            ("https://user:pw@example.com/", "https://example.com"),
            ("https://example.com./", "https://example.com"),
            ("http://localhost:3000", "http://localhost:3000"),
            ("http://127.0.0.1:8080/x", "http://127.0.0.1:8080"),
            ("http://[::1]:8080/", "http://[::1]:8080"),
            ("https://xn--bcher-kva.de/", "https://xn--bcher-kva.de"),
            ("https://bücher.de/", "https://xn--bcher-kva.de"),
            ("ftp://example.com", nil),
            ("file:///etc/passwd", nil),
            ("data:text/html,hi", nil),
            ("about:blank", nil),
            ("javascript:alert(1)", nil),
            ("https://", nil),
            ("https://exa mple.com", nil),
        ]
        for (input, expected) in table {
            XCTAssertEqual(Origin(string: input)?.serialized, expected, input)
        }
        XCTAssertEqual(Origin(scheme: "HTTPS", host: "Example.com", port: 0)?.serialized, "https://example.com")
        XCTAssertEqual(Origin(scheme: "https", host: "example.com", port: 443), Origin(string: "https://example.com"))
        XCTAssertNil(Origin(scheme: "", host: "", port: 0), "an opaque origin as WebKit reports it")
        XCTAssertNil(Origin(scheme: "https", host: "example.com", port: 70000))
    }

    func testPunycode() {
        XCTAssertEqual(Punycode.asciiHost("bücher.de"), "xn--bcher-kva.de")
        XCTAssertEqual(Punycode.asciiHost("münchen.de"), "xn--mnchen-3ya.de")
        XCTAssertEqual(Punycode.asciiHost("公司.cn"), "xn--55qx5d.cn")
        XCTAssertEqual(Punycode.asciiHost("例え.テスト"), "xn--r8jz45g.xn--zckzah")
        XCTAssertEqual(Punycode.asciiHost("EXAMPLE.com"), "example.com")
    }

    func testRegistrableDomains() {
        let psl = PublicSuffixList.shared
        XCTAssertFalse(psl.isEmpty, "the list ships with the package")
        let table: [(String, String?)] = [
            ("example.com", "example.com"),
            ("www.example.com", "example.com"),
            ("a.b.c.example.com", "example.com"),
            ("example.co.uk", "example.co.uk"),
            ("login.example.co.uk", "example.co.uk"),
            ("co.uk", nil),
            ("com", nil),
            ("alice.github.io", "alice.github.io"),
            ("github.io", nil),
            ("myapp.vercel.app", "myapp.vercel.app"),
            ("login.microsoftonline.com", "microsoftonline.com"),
            ("accounts.google.com", "google.com"),
            ("contoso.azurewebsites.net", "contoso.azurewebsites.net"),
            ("contoso.sharepoint.com", "sharepoint.com"),  // not a listed suffix
            ("foo.bar.ck", "foo.bar.ck"),        // *.ck: bar.ck is a public suffix
            ("bar.ck", nil),
            ("www.ck", "www.ck"),                // !www.ck: an exception
            ("a.www.ck", "www.ck"),
            ("xn--55qx5d.cn", nil),              // 公司.cn is a listed suffix
            ("shop.xn--55qx5d.cn", "shop.xn--55qx5d.cn"),
            ("example.unknowntld", "example.unknowntld"),
        ]
        for (host, expected) in table {
            XCTAssertEqual(psl.registrableDomain(of: host), expected, host)
        }
    }

    func testMatchingRules() {
        func m(_ saved: String, _ page: String) -> MatchKind? {
            Origin.match(saved: Origin(string: saved)!, page: Origin(string: page)!)
        }
        let table: [(saved: String, page: String, expected: MatchKind?, why: String)] = [
            ("https://example.com", "https://example.com", .exact, "same origin"),
            ("https://example.com", "https://example.com:443", .exact, "default port spelled out"),
            ("https://example.com", "https://www.example.com", .sameSite, "subdomain of the saved host"),
            ("https://login.example.com", "https://www.example.com", .sameSite, "sibling subdomains"),
            ("https://www.example.com", "https://example.com", .sameSite, "parent of the saved host"),
            ("https://example.com", "http://example.com", nil, "never https to http"),
            ("http://example.com", "https://example.com", nil, "never http to https either"),
            ("https://example.com", "https://example.com:8443", nil, "another port"),
            ("https://example.com:8443", "https://www.example.com:8443", .sameSite, "same non-default port"),
            ("https://example.com:8443", "https://www.example.com", nil, "port differs across subdomains"),
            ("https://example.com", "https://example.org", nil, "another site"),
            ("https://example.com", "https://example.com.evil.net", nil, "lookalike prefix"),
            ("https://example.com", "https://evilexample.com", nil, "lookalike suffix"),
            ("https://alice.github.io", "https://bob.github.io", nil, "different owners under a public suffix"),
            ("https://alice.github.io", "https://alice.github.io", .exact, "same host under a public suffix"),
            ("https://github.io", "https://alice.github.io", nil, "a public suffix host matches only itself"),
            ("https://a.example.co.uk", "https://b.example.co.uk", .sameSite, "multi-label suffix"),
            ("https://example.co.uk", "https://other.co.uk", nil, "different sites under co.uk"),
            ("http://localhost:3000", "http://localhost:3000", .exact, "localhost exact"),
            ("http://localhost:3000", "http://localhost:8080", nil, "localhost on another port"),
            ("http://127.0.0.1:8080", "http://localhost:8080", nil, "an IP and a name are different"),
            ("http://10.0.0.1", "http://10.0.0.2", nil, "IP addresses match exactly only"),
            ("http://1.2.3.4", "http://5.2.3.4", nil, "IPs don't share a 'site'"),
            ("http://intranet", "http://www.intranet", nil, "single-label hosts match exactly only"),
            ("http://[::1]:8080", "http://[::1]:8080", .exact, "IPv6 exact"),
            ("https://login.microsoftonline.com", "https://login.live.com", nil, "Microsoft's two sign-in sites stay apart"),
            ("https://contoso.azurewebsites.net", "https://fabrikam.azurewebsites.net", nil, "apps under a private suffix"),
            ("http://login.example.com", "http://www.example.com", nil, "no same-site matching over http"),
            ("http://example.com", "http://example.com", .exact, "http still matches exactly"),
            ("https://contoso-dev.okta.com", "https://evil-tenant.okta.com", nil, "Okta tenants stay apart"),
            ("https://contoso.sharepoint.com", "https://fabrikam.sharepoint.com", nil, "SharePoint tenants stay apart"),
            ("https://acme.atlassian.net", "https://evil.atlassian.net", nil, "Atlassian sites stay apart"),
            ("https://acme.my.salesforce.com", "https://evil.my.salesforce.com", nil, "Salesforce orgs stay apart"),
            ("https://acme.zendesk.com", "https://acme.zendesk.com", .exact, "a tenant still matches itself"),
        ]
        for row in table {
            XCTAssertEqual(m(row.saved, row.page), row.expected, "\(row.saved) on \(row.page): \(row.why)")
        }
    }

    func testNoListMeansExactOnly() {
        let empty = PublicSuffixList(text: "")
        let a = Origin(string: "https://www.example.com")!, b = Origin(string: "https://login.example.com")!
        XCTAssertNil(Origin.match(saved: a, page: b, using: empty))
        XCTAssertEqual(Origin.match(saved: a, page: a, using: empty), .exact)
    }
}
