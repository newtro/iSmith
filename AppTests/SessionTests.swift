import SignInSync
import XCTest
@testable import iSmith

/// session.json: windows → spaces → groups → tabs survive a save and a load, bad files are kept
/// aside, and deleted spaces drop out.
@MainActor
final class SessionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("iSmithSessionTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Contoso: Outlook, then a "Storefront" group of two (collapsed), then a kept-alive tab.
    private func sampleSpace() -> SpaceTabs {
        let tabs = SpaceTabs(spaceID: "contoso")
        let outlook = Tab(url: URL(string: "https://outlook.office.com/mail/"), title: "(7) Mail - Outlook")
        let board = Tab(url: URL(string: "https://dev.azure.com/contoso-dev"), title: "Boards")
        let repo = Tab(url: URL(string: "https://dev.azure.com/contoso-dev/_git"), title: "Repos")
        let news = Tab(url: URL(string: "https://news.ycombinator.com"), title: "Hacker News", keepAlive: true)
        for tab in [outlook, board, repo, news] { tabs.add(tab) { $0.insert(tab.id) } }
        tabs.update {
            let g = $0.createGroup(with: [board.id, repo.id], name: "Storefront", color: .cyan)!
            $0.select(board.id)
            $0.setCollapsed(g, true)
        }
        return tabs
    }

    func testSpaceTabsRoundTripThroughTheFile() throws {
        let original = sampleSpace()
        let window = WindowState(activeSpaceID: "contoso")
        window.setTabs(original)
        let file = SessionFile(windows: [window.record(spaceOrder: ["contoso", "fabrikam"])])
        let store = SessionStore(fileURL: dir.appendingPathComponent("session.json"))
        store.save(file)
        var reader = SessionStore(fileURL: store.fileURL)
        let loaded = try XCTUnwrap(reader.load())
        XCTAssertEqual(loaded, file)

        let restored = SpaceTabs.restore(try XCTUnwrap(loaded.windows.first?.spaces.first))
        XCTAssertEqual(restored.layout, original.layout, "order, groups, collapse and selection come back")
        XCTAssertEqual(restored.ordered.map(\.title), original.ordered.map(\.title))
        XCTAssertEqual(restored.ordered.map(\.url), original.ordered.map(\.url))
        XCTAssertEqual(restored.ordered.map(\.keepAliveSetting), [nil, nil, nil, true])
        XCTAssertTrue(restored.ordered.allSatisfy { $0.webView == nil }, "restored tabs load only when shown")
        XCTAssertEqual(restored.ordered.first?.keepAlive, true, "Outlook is kept alive automatically")
        XCTAssertEqual(restored.layout.groups.first?.collapsed, true)
        XCTAssertNotEqual(restored.layout.selected, restored.layout.tabs(in: restored.layout.groups[0].id).first,
                          "collapsing moved the selection out of the group")

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600, "session.json is owner-only")
    }

    func testEmptySpacesAreNotSaved() {
        let window = WindowState(activeSpaceID: "personal")
        _ = window.tabs(for: "personal")
        window.setTabs(sampleSpace())
        let record = window.record(spaceOrder: ["personal", "contoso"])
        XCTAssertEqual(record.spaces.map(\.space), ["contoso"])
        XCTAssertEqual(record.activeSpace, "personal")
    }

    func testUnreadableFileIsKeptAsideAndNotOverwritten() throws {
        let url = dir.appendingPathComponent("session.json")
        try SecureFile.prepareDirectory(dir)
        try Data("{ not json".utf8).write(to: url)
        var store = SessionStore(fileURL: url)
        XCTAssertNil(store.load())
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("unreadable") }
        XCTAssertEqual(backups.count, 1, "a copy of the bad file is kept")
        XCTAssertTrue(store.canSave, "with the copy kept, saving can go ahead")
    }

    func testOlderOrPartialRecordsDecodeWithDefaults() throws {
        let json = """
        {"windows":[{"activeSpace":"a","spaces":[{"space":"a","tabs":[{"url":"https://example.com","group":"6F1C2A40-0000-4000-9000-0000000000D1"}],
          "groups":[{"id":"6F1C2A40-0000-4000-9000-0000000000D1","color":"chartreuse"}]}]}]}
        """
        let file = try JSONDecoder().decode(SessionFile.self, from: Data(json.utf8))
        let space = try XCTUnwrap(file.windows.first?.spaces.first)
        XCTAssertEqual(space.tabs.first?.title, "")
        XCTAssertEqual(space.groups.first?.color, .grey, "an unknown color reads as grey")
        XCTAssertEqual(space.groups.first?.collapsed, false)
        XCTAssertEqual(space.layout.tabs(in: space.groups[0].id).count, 1)
    }

    func testPruningDropsDeletedSpacesAndEmptyWindows() {
        let tab = TabRecord(id: UUID(), url: nil, title: "x", group: nil, keepAlive: nil)
        let file = SessionFile(windows: [
            WindowRecord(id: UUID(), frame: nil, activeSpace: "gone", spaces: [
                SpaceRecord(space: "gone", selected: nil, groups: [], tabs: [tab]),
                SpaceRecord(space: "kept", selected: nil, groups: [], tabs: [tab]),
            ]),
            WindowRecord(id: UUID(), frame: nil, activeSpace: "gone", spaces: [
                SpaceRecord(space: "gone", selected: nil, groups: [], tabs: [tab]),
            ]),
        ])
        let pruned = SessionStore.pruned(file, spaces: ["kept"])
        XCTAssertEqual(pruned.windows.count, 1, "a window left with nothing is dropped")
        XCTAssertEqual(pruned.windows[0].spaces.map(\.space), ["kept"])
        XCTAssertEqual(pruned.windows[0].activeSpace, "kept", "the active space falls back to one that's left")
    }

    func testRailOrderIsSavedThroughTheBrowser() {
        let paths = AppPaths(dataDir: dir, spikeDir: nil)
        let browser = BrowserState(paths: paths, keyStore: InMemoryKeyStore(), passwordsKeyStore: InMemoryKeyStore())
        let a = browser.manager.createSpace(name: "Alpha", color: 0, home: "", choices: [:], newNames: [:])
        let b = browser.manager.createSpace(name: "Beta", color: 1, home: "", choices: [:], newNames: [:])
        // The browser lists spaces it was started with; restart it to pick up the two new ones.
        let restarted = BrowserState(paths: paths, keyStore: InMemoryKeyStore(), passwordsKeyStore: InMemoryKeyStore())
        XCTAssertEqual(restarted.spaces.map(\.def.name), ["Personal", "Alpha", "Beta"])
        restarted.moveSpace(b.id, to: 0)
        XCTAssertEqual(restarted.spaces.map(\.id), [b.id, "personal", a.id])
        let again = BrowserState(paths: paths, keyStore: InMemoryKeyStore(), passwordsKeyStore: InMemoryKeyStore())
        XCTAssertEqual(again.spaces.map(\.id), [b.id, "personal", a.id], "the rail order is the same after a relaunch")
    }
}
