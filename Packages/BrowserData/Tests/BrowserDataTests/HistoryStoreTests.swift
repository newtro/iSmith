@testable import BrowserData
import GRDB
import XCTest

/// History: recording and aggregation, titles, spaces, the history page's search, address bar
/// suggestions and inline completion, deleting, and speed at 50k pages.
final class HistoryStoreTests: XCTestCase {
    private var db: BrowserDatabase!
    private var history: HistoryStore { db.history }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        db = try BrowserDatabase.inMemory()
    }

    private func u(_ s: String) -> URL { URL(string: s)! }

    private func page(_ url: String, space: String) throws -> HistorySuggestion? {
        try history.suggestions(for: url, space: space, limit: 50).first { $0.url == url && $0.space == space }
    }

    // MARK: Recording

    func testRecordAggregatesFragmentsAndDedupesWithinOneSecond() throws {
        try history.recordVisit(space: "home", url: u("https://example.com/a#top"), title: "A", at: t0)
        try history.recordVisit(space: "home", url: u("https://example.com/a"), title: nil, at: t0.addingTimeInterval(0.5))
        try history.recordVisit(space: "home", url: u("https://example.com/a#later"), title: nil, at: t0.addingTimeInterval(5))
        try history.recordVisit(space: "home", url: u("about:blank"), title: "blank", at: t0)
        try history.recordVisit(space: "home", url: u("file:///tmp/x.html"), title: "file", at: t0)

        let all = try history.visits(space: nil, matching: "", limit: 100)
        XCTAssertEqual(all.map(\.url), ["https://example.com/a", "https://example.com/a"], "two visits, fragment dropped, non-http ignored")
        XCTAssertEqual(all.first?.visitedAt, t0.addingTimeInterval(5))
        let s = try XCTUnwrap(try page("https://example.com/a", space: "home"))
        XCTAssertEqual(s.visitCount, 2)
        XCTAssertEqual(s.typedCount, 0)
        XCTAssertEqual(s.lastVisit, t0.addingTimeInterval(5))
        XCTAssertEqual(s.title, "A")
    }

    func testTypedVisitWithinWindowUpgradesTheVisit() throws {
        try history.recordVisit(space: "home", url: u("https://example.com/"), title: nil, at: t0)
        try history.recordVisit(space: "home", url: u("https://example.com/"), title: nil, typed: true, at: t0.addingTimeInterval(0.3))
        let s = try XCTUnwrap(try page("https://example.com/", space: "home"))
        XCTAssertEqual(s.visitCount, 1)
        XCTAssertEqual(s.typedCount, 1)
    }

    func testTitlesArriveLaterAndNilKeepsTheTitle() throws {
        try history.recordVisit(space: "home", url: u("https://example.com/"), title: nil, at: t0)
        XCTAssertNil(try page("https://example.com/", space: "home")?.title)
        try history.updateTitle(space: "home", url: u("https://example.com/#x"), title: "Example Domain")
        XCTAssertEqual(try page("https://example.com/", space: "home")?.title, "Example Domain")
        try history.recordVisit(space: "home", url: u("https://example.com/"), title: "  ", at: t0.addingTimeInterval(10))
        XCTAssertEqual(try page("https://example.com/", space: "home")?.title, "Example Domain")
        try history.recordVisit(space: "home", url: u("https://example.com/"), title: "New", at: t0.addingTimeInterval(20))
        XCTAssertEqual(try page("https://example.com/", space: "home")?.title, "New")
        // Titles are searchable.
        XCTAssertEqual(try history.visits(space: "home", matching: "new", limit: 10).count, 3)
        // Updating a page that isn't in this space's history does nothing.
        try history.updateTitle(space: "work", url: u("https://example.com/"), title: "Other")
        XCTAssertEqual(try history.visits(space: "work", matching: "", limit: 10), [])
    }

    func testSpacesAreSeparate() throws {
        try history.recordVisit(space: "home", url: u("https://example.com/"), title: "Ex", at: t0)
        try history.recordVisit(space: "work", url: u("https://example.com/"), title: "Ex", at: t0.addingTimeInterval(0.2))
        try history.recordVisit(space: "work", url: u("https://dev.azure.com/"), title: "DevOps", at: t0.addingTimeInterval(10))
        XCTAssertEqual(try history.visits(space: "home", matching: "", limit: 10).count, 1, "not deduped across spaces")
        XCTAssertEqual(try history.visits(space: "work", matching: "", limit: 10).map(\.url),
                       ["https://dev.azure.com/", "https://example.com/"])
        XCTAssertEqual(try history.visits(space: nil, matching: "", limit: 10).count, 3)
        XCTAssertEqual(Set(try history.visits(space: nil, matching: "", limit: 10).map(\.space)), ["home", "work"])
    }

    func testVisitsSearchNeedsEveryWordAndPagesWithBefore() throws {
        try history.recordVisit(space: "s", url: u("https://github.com/scott/iSmith"), title: "iSmith browser", at: t0)
        try history.recordVisit(space: "s", url: u("https://github.com/apple/swift"), title: "Swift language", at: t0.addingTimeInterval(10))
        try history.recordVisit(space: "s", url: u("https://news.example.org/swift"), title: "Swift news", at: t0.addingTimeInterval(20))

        XCTAssertEqual(try history.visits(space: "s", matching: "GITHUB swift", limit: 10).map(\.url),
                       ["https://github.com/apple/swift"])
        XCTAssertEqual(try history.visits(space: "s", matching: "  swift  ", limit: 10).map(\.url),
                       ["https://news.example.org/swift", "https://github.com/apple/swift"])
        XCTAssertEqual(try history.visits(space: "s", matching: "browser ismith", limit: 10).count, 1)
        XCTAssertEqual(try history.visits(space: "s", matching: "github nothing", limit: 10), [])
        XCTAssertEqual(try history.visits(space: "s", matching: "", before: t0.addingTimeInterval(20), limit: 1).map(\.url),
                       ["https://github.com/apple/swift"])
        XCTAssertEqual(try history.visits(space: "s", matching: "", limit: 2).count, 2)
    }

    // MARK: Suggestions

    func testSuggestionsPutCurrentSpaceFirstAndDedupe() throws {
        for i in 0..<10 {
            try history.recordVisit(space: "work", url: u("https://example.com/popular"), title: "Popular", at: t0.addingTimeInterval(Double(i) * 10))
        }
        try history.recordVisit(space: "home", url: u("https://example.com/rare"), title: "Rare", at: t0)
        try history.recordVisit(space: "home", url: u("https://example.com/popular"), title: "Popular", at: t0)

        let s = try history.suggestions(for: "example", space: "home", limit: 10)
        XCTAssertEqual(s.map(\.space), ["home", "home"], "the shared page appears once, from the current space")
        XCTAssertEqual(Set(s.map(\.url)), ["https://example.com/rare", "https://example.com/popular"])
        let fromWork = try history.suggestions(for: "example", space: "work", limit: 10)
        XCTAssertEqual(fromWork.map(\.url), ["https://example.com/popular", "https://example.com/rare"])
        XCTAssertEqual(fromWork.map(\.space), ["work", "home"])
        XCTAssertEqual(try history.suggestions(for: "example", space: "home", limit: 1).count, 1)
        XCTAssertEqual(try history.suggestions(for: "   ", space: "home", limit: 10), [])
    }

    func testSuggestionsBoostTypedAndPrefixMatches() throws {
        let now = Date()
        // Visited three times vs typed once: typed ×3 plus the visit itself wins.
        for i in 0..<3 {
            try history.recordVisit(space: "s", url: u("https://a.example.com/often"), title: "Often", at: now.addingTimeInterval(Double(-100 - i * 10)))
        }
        try history.recordVisit(space: "s", url: u("https://b.example.com/typed"), title: "Typed", typed: true, at: now.addingTimeInterval(-100))
        XCTAssertEqual(try history.suggestions(for: "example", space: "s", limit: 10).map(\.url),
                       ["https://b.example.com/typed", "https://a.example.com/often"])

        // A host-prefix match beats a page that only mentions the text in its path or title.
        for i in 0..<3 {
            try history.recordVisit(space: "s", url: u("https://search.example.net/q=gitlab"), title: "gitlab results", at: now.addingTimeInterval(Double(-50 - i * 10)))
        }
        try history.recordVisit(space: "s", url: u("https://www.gitlab.com/"), title: "GitLab", at: now.addingTimeInterval(-50))
        let s = try history.suggestions(for: "gitlab", space: "s", limit: 10)
        XCTAssertEqual(s.map(\.url), ["https://www.gitlab.com/", "https://search.example.net/q=gitlab"])
        XCTAssertEqual(s.map(\.isPrefixMatch), [true, false], "www. is ignored for the prefix")
        XCTAssertEqual(try history.suggestions(for: "https://gitl", space: "s", limit: 1).first?.isPrefixMatch, true)

        // Recency: an old page with more visits loses to a recent one.
        for i in 0..<4 {
            try history.recordVisit(space: "s", url: u("https://old.example.org/"), title: "zeta", at: now.addingTimeInterval(-400 * 86_400 - Double(i * 10)))
        }
        try history.recordVisit(space: "s", url: u("https://new.example.org/"), title: "zeta", at: now.addingTimeInterval(-60))
        XCTAssertEqual(try history.suggestions(for: "zeta", space: "s", limit: 10).map(\.url),
                       ["https://new.example.org/", "https://old.example.org/"])
    }

    // MARK: Inline completion

    func testInlineCompletion() throws {
        try history.recordVisit(space: "s", url: u("https://github.com/scott/repo"), title: nil, at: t0)
        try history.recordVisit(space: "s", url: u("https://github.com/scott/repo"), title: nil, at: t0.addingTimeInterval(10))
        try history.recordVisit(space: "s", url: u("https://github.com/scott"), title: nil, at: t0.addingTimeInterval(20))
        try history.recordVisit(space: "s", url: u("https://www.gitlab.com/"), title: nil, at: t0)
        try history.recordVisit(space: "s", url: u("https://dev.azure.com/contoso-dev/Storefront"), title: nil, typed: true, at: t0)
        try history.recordVisit(space: "other", url: u("https://zeplin.io/projects"), title: nil, at: t0)
        try history.recordVisit(space: "other", url: u("https://github.community/"), title: nil, typed: true, at: t0)

        // Host completion: github.com has the most visits among "git" hosts in this space.
        XCTAssertEqual(try history.inlineCompletion(for: "git", space: "s"), "github.com/")
        XCTAssertEqual(try history.inlineCompletion(for: "GIT", space: "s"), "github.com/", "case-insensitive")
        XCTAssertEqual(try history.inlineCompletion(for: "gitl", space: "s"), "gitlab.com/", "www. stripped")
        XCTAssertEqual(try history.inlineCompletion(for: "github.com", space: "s"), "github.com/")
        // Path completion after a slash: the most visited page.
        XCTAssertEqual(try history.inlineCompletion(for: "github.com/sc", space: "s"), "github.com/scott/repo")
        XCTAssertEqual(try history.inlineCompletion(for: "github.com/scott/r", space: "s"), "github.com/scott/repo")
        XCTAssertEqual(try history.inlineCompletion(for: "dev.azure.com/contoso-dev/s", space: "s"),
                       "dev.azure.com/contoso-dev/Storefront")
        // Scheme and www. typed by the user stay at the front.
        XCTAssertEqual(try history.inlineCompletion(for: "https://gi", space: "s"), "https://github.com/")
        XCTAssertEqual(try history.inlineCompletion(for: "www.gitl", space: "s"), "www.gitlab.com/")
        XCTAssertEqual(try history.inlineCompletion(for: "https://www.dev", space: "s"), "https://www.dev.azure.com/")
        // No completion for text with spaces, empty text, or nothing to add.
        XCTAssertNil(try history.inlineCompletion(for: "git hub", space: "s"))
        XCTAssertNil(try history.inlineCompletion(for: "", space: "s"))
        XCTAssertNil(try history.inlineCompletion(for: "https://", space: "s"))
        XCTAssertNil(try history.inlineCompletion(for: "github.com/scott/repo", space: "s"))
        XCTAssertNil(try history.inlineCompletion(for: "nothing", space: "s"))
        // Other spaces are a fallback only.
        XCTAssertEqual(try history.inlineCompletion(for: "zep", space: "s"), "zeplin.io/")
        XCTAssertEqual(try history.inlineCompletion(for: "github.c", space: "s"), "github.com/",
                       "this space's github.com beats the other space's typed github.community")
        XCTAssertEqual(try history.inlineCompletion(for: "github.c", space: "other"), "github.community/")
    }

    func testInlineCompletionPrefersTypedHosts() throws {
        for i in 0..<5 {
            try history.recordVisit(space: "s", url: u("https://docs.example.com/\(i)"), title: nil, at: t0.addingTimeInterval(Double(i * 10)))
        }
        try history.recordVisit(space: "s", url: u("https://dev.example.com/"), title: nil, typed: true, at: t0)
        XCTAssertEqual(try history.inlineCompletion(for: "d", space: "s"), "dev.example.com/")
        XCTAssertEqual(try history.inlineCompletion(for: "do", space: "s"), "docs.example.com/")
        XCTAssertEqual(try history.inlineCompletion(for: "localhost", space: "s"), nil)
        try history.recordVisit(space: "s", url: u("https://localhost:8443/app"), title: nil, at: t0)
        XCTAssertEqual(try history.inlineCompletion(for: "localh", space: "s"), "localhost:8443/")
    }

    // MARK: Deleting

    func testDeletingVisitsKeepsCountsRight() throws {
        try history.recordVisit(space: "s", url: u("https://a.com/"), title: "A", typed: true, at: t0)
        try history.recordVisit(space: "s", url: u("https://a.com/"), title: "A", at: t0.addingTimeInterval(10))
        try history.recordVisit(space: "s", url: u("https://a.com/"), title: "A", at: t0.addingTimeInterval(20))
        try history.recordVisit(space: "s", url: u("https://b.com/"), title: "B", at: t0.addingTimeInterval(30))

        let visits = try history.visits(space: "s", matching: "a.com", limit: 10)
        XCTAssertEqual(visits.count, 3)
        // Delete the newest and the typed (oldest) visit.
        try history.delete(visitIDs: [visits[0].visitID, visits[2].visitID])
        let a = try XCTUnwrap(try page("https://a.com/", space: "s"))
        XCTAssertEqual(a.visitCount, 1)
        XCTAssertEqual(a.typedCount, 0)
        XCTAssertEqual(a.lastVisit, t0.addingTimeInterval(10))

        try history.delete(visitIDs: [visits[1].visitID])
        XCTAssertNil(try page("https://a.com/", space: "s"), "a page with no visits left is gone")
        XCTAssertNil(try history.inlineCompletion(for: "a.c", space: "s"))

        try history.deleteURL(space: "s", url: u("https://b.com/#frag"))
        XCTAssertEqual(try history.visits(space: nil, matching: "", limit: 10), [])
    }

    func testPruneAndClear() throws {
        for (i, space) in ["s", "s", "t"].enumerated() {
            try history.recordVisit(space: space, url: u("https://a.com/"), title: nil, at: t0.addingTimeInterval(Double(i * 100)))
            try history.recordVisit(space: space, url: u("https://old.com/"), title: nil, at: t0.addingTimeInterval(Double(i * 100) - 50_000))
        }
        try history.prune(olderThan: t0.addingTimeInterval(-1))
        XCTAssertEqual(try history.visits(space: nil, matching: "old", limit: 10), [])
        XCTAssertNil(try history.inlineCompletion(for: "old", space: "s"), "pruned pages are gone")
        XCTAssertEqual(try page("https://a.com/", space: "s")?.visitCount, 2)

        try history.clear(space: "s", since: t0.addingTimeInterval(50))
        XCTAssertEqual(try page("https://a.com/", space: "s")?.visitCount, 1)
        XCTAssertEqual(try page("https://a.com/", space: "s")?.lastVisit, t0)
        XCTAssertEqual(try history.visits(space: "t", matching: "", limit: 10).count, 1, "other space untouched")

        try history.clear(space: "s", since: nil)
        XCTAssertEqual(try history.visits(space: "s", matching: "", limit: 10), [])
        XCTAssertEqual(try history.visits(space: "t", matching: "", limit: 10).count, 1)

        try history.recordVisit(space: "s", url: u("https://a.com/"), title: nil, at: t0)
        try history.clear(space: nil, since: t0.addingTimeInterval(150))
        XCTAssertEqual(try history.visits(space: nil, matching: "", limit: 10).map(\.space), ["s"])
        try history.clear(space: nil, since: nil)
        XCTAssertEqual(try history.visits(space: nil, matching: "", limit: 10), [])
    }

    func testDidChangeIsPostedOnMain() throws {
        let posted = expectation(forNotification: HistoryStore.didChange, object: history) { note in
            XCTAssertTrue(Thread.isMainThread)
            return (note.userInfo?[BrowserDatabase.spacesKey] as? [String]) == ["s"]
        }
        try history.recordVisit(space: "s", url: u("https://a.com/"), title: nil)
        wait(for: [posted], timeout: 2)
    }

    // MARK: Speed

    /// 50k pages across two spaces: suggestions and inline completion stay well inside a keystroke.
    func testSuggestionSpeedWith50kPages() throws {
        let now = Date().timeIntervalSince1970
        try db.writer.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO history_url (space, url, host, bare, title, search, visitCount, typedCount, lastVisit)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let hosts = ["github.com", "gitlab.com", "dev.azure.com", "news.ycombinator.com", "example.org",
                         "docs.swift.org", "developer.apple.com", "stackoverflow.com", "www.google.com", "teams.microsoft.com"]
            for i in 0..<50_000 {
                let host = i < 9_000 ? "site\(i % 3000).example.net" : hosts[i % hosts.count]
                let url = URL(string: "https://\(host)/path/\(i)/item-\(i * 7 % 1000)?q=\(i)")!
                let page = PageAddress(url)!
                let title = "Page \(i) about topic \(i % 97)"
                try statement.execute(arguments: [i % 2 == 0 ? "s" : "t", page.url, page.host, page.bare, title,
                                                  page.search(title: title), 1 + i % 13, i % 5 == 0 ? 1 : 0,
                                                  now - Double(i % 1000) * 3600])
            }
        }
        _ = try history.suggestions(for: "warm", space: "s", limit: 8)

        func time(_ body: () throws -> Void) rethrows -> Double {
            let start = Date()
            try body()
            return Date().timeIntervalSince(start) * 1000
        }
        var worst = 0.0
        for text in ["g", "git", "github.com/pa", "topic 42", "dev azure", "zzz-nothing", "https://www.goo"] {
            var s: [HistorySuggestion] = []
            worst = max(worst, try time { s = try history.suggestions(for: text, space: "s", limit: 8) })
            worst = max(worst, try time { _ = try history.inlineCompletion(for: text, space: "s") })
            if text == "git" { XCTAssertEqual(s.count, 8) }
        }
        XCTAssertEqual(try history.inlineCompletion(for: "git", space: "s"), "github.com/")
        print("BrowserData: slowest suggestion/completion over 50k pages: \(String(format: "%.1f", worst)) ms")
        XCTAssertLessThan(worst, 100)
    }
}
