import WebKit
import XCTest
@testable import iSmith

/// Unread counts from titles, and which pages are kept alive.
@MainActor
final class PageRulesTests: XCTestCase {
    func testUnreadCountsFromTitles() {
        XCTAssertEqual(UnreadBadge.count(in: "(7) Mail - Scott Smith - Outlook"), 7)
        XCTAssertEqual(UnreadBadge.count(in: "(3) Chat | Microsoft Teams"), 3)
        XCTAssertEqual(UnreadBadge.count(in: "  (12) Inbox"), 12)
        XCTAssertEqual(UnreadBadge.count(in: "(99+) Chat | Microsoft Teams"), 99)
        XCTAssertEqual(UnreadBadge.count(in: "(1)"), 1)
        XCTAssertEqual(UnreadBadge.count(in: "Inbox (12) - scott@gmail.com - Gmail"), 12)
        XCTAssertEqual(UnreadBadge.count(in: "Work (3) - scott@newtro.com - Gmail"), 3)
    }

    func testTitlesWithoutAnUnreadCount() {
        XCTAssertNil(UnreadBadge.count(in: "Mail - Scott Smith - Outlook"))
        XCTAssertNil(UnreadBadge.count(in: "Inbox - scott@gmail.com - Gmail"))
        XCTAssertNil(UnreadBadge.count(in: "Report (2) - Google Docs"), "only Gmail puts the count after the label")
        XCTAssertNil(UnreadBadge.count(in: "(0) Inbox"), "zero isn't a badge")
        XCTAssertNil(UnreadBadge.count(in: "(2024)Annual report"), "a number glued to the next word isn't a count")
        XCTAssertNil(UnreadBadge.count(in: "(beta) Release notes"))
        XCTAssertNil(UnreadBadge.count(in: "(123456) Big number"), "more than five digits isn't a count")
        XCTAssertNil(UnreadBadge.count(in: "(٣) Arabic digits"))
        XCTAssertNil(UnreadBadge.count(in: ""))
    }

    func testSpaceBadgeCountsAPageOpenTwiceOnce() {
        XCTAssertEqual(UnreadBadge.total(["(7) Mail - Outlook", "(7) Mail - Outlook", "(3) Chat | Microsoft Teams", "Docs"]), 10)
        XCTAssertEqual(UnreadBadge.total([]), 0)
    }

    func testKeepAliveHosts() {
        for url in ["https://outlook.office.com/mail/", "https://outlook.office365.com/owa/", "https://outlook.live.com/mail/0/",
                    "https://outlook.cloud.microsoft/mail/", "https://teams.microsoft.com/v2/", "https://teams.cloud.microsoft/",
                    "https://teams.live.com/", "https://mail.google.com/mail/u/0/#inbox", "https://MAIL.GOOGLE.COM./",
                    "https://eu.teams.microsoft.com/"] {
            XCTAssertTrue(KeepAlive.isAutomatic(URL(string: url)), url)
        }
        for url in ["https://www.google.com/", "https://calendar.google.com/", "https://login.microsoftonline.com/",
                    "https://outlook.office.com.evil.example/", "https://notoutlook.office.com/", "http://example.com/",
                    "data:text/html,outlook.office.com", "about:blank"] {
            XCTAssertFalse(KeepAlive.isAutomatic(URL(string: url)), url)
        }
        XCTAssertFalse(KeepAlive.isAutomatic(nil))
    }

    func testATabsOwnSettingWins() {
        let outlook = URL(string: "https://outlook.office.com/mail/")
        let news = URL(string: "https://news.ycombinator.com/")
        XCTAssertTrue(KeepAlive.isOn(setting: nil, url: outlook))
        XCTAssertFalse(KeepAlive.isOn(setting: false, url: outlook))
        XCTAssertFalse(KeepAlive.isOn(setting: nil, url: news))
        XCTAssertTrue(KeepAlive.isOn(setting: true, url: news))
        XCTAssertTrue(Tab(url: outlook).keepAlive)
        XCTAssertFalse(Tab(url: outlook, keepAlive: false).keepAlive)
    }

    func testKeepAliveSetsTheSchedulingPolicyOnItsOwnPreferences() {
        let on = BrowserState.preferences(keepAlive: true)
        let off = BrowserState.preferences(keepAlive: false)
        XCTAssertEqual(on.inactiveSchedulingPolicy, .none, "never throttled or suspended")
        XCTAssertEqual(off.inactiveSchedulingPolicy, .throttle)
        XCTAssertFalse(on === off, "each web view gets its own preferences")
        XCTAssertTrue(on.javaScriptCanOpenWindowsAutomatically)
        // The policy reaches a web view made with these preferences.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences = on
        let webView = WKWebView(frame: .zero, configuration: configuration)
        XCTAssertEqual(webView.configuration.preferences.inactiveSchedulingPolicy, .none)
    }
}
