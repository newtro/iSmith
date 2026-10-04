@testable import BrowserData
import XCTest

/// The agent panel's threads, settings and activity log.
final class AgentStoreTests: XCTestCase {
    private var db: BrowserDatabase!

    override func setUpWithError() throws {
        db = try BrowserDatabase.inMemory()
    }

    func testThreadsPerSpaceNewestFirst() throws {
        let agent = db.agent
        let t0 = Date(timeIntervalSince1970: 1_000)
        try agent.saveThread(AgentThreadRecord(id: "a", space: "contoso", backend: "codex", name: "Find the invoice",
                                               createdAt: t0, updatedAt: t0))
        try agent.saveThread(AgentThreadRecord(id: "b", space: "contoso", backend: "codex", name: "Assign WI",
                                               createdAt: t0.addingTimeInterval(10), updatedAt: t0.addingTimeInterval(10), model: "m1"))
        try agent.saveThread(AgentThreadRecord(id: "c", space: "fabrikam", backend: "codex", name: "Other",
                                               createdAt: t0, updatedAt: t0))
        XCTAssertEqual(try agent.threads(space: "contoso").map(\.id), ["b", "a"])
        XCTAssertEqual(try agent.threads(space: "fabrikam").map(\.id), ["c"])
        try agent.touchThread(id: "a", at: t0.addingTimeInterval(20))
        XCTAssertEqual(try agent.threads(space: "contoso").map(\.id), ["a", "b"])
        try agent.renameThread(id: "a", name: "Invoice")
        XCTAssertEqual(try agent.thread(id: "a")?.name, "Invoice")
        XCTAssertEqual(try agent.thread(id: "b")?.model, "m1")
        // Saving again keeps the space and creation date.
        try agent.saveThread(AgentThreadRecord(id: "a", space: "fabrikam", backend: "codex", name: "Invoice 2",
                                               createdAt: t0.addingTimeInterval(99), updatedAt: t0.addingTimeInterval(30)))
        let a = try XCTUnwrap(agent.thread(id: "a"))
        XCTAssertEqual(a.space, "contoso")
        XCTAssertEqual(a.createdAt, t0)
        XCTAssertEqual(a.name, "Invoice 2")
        try agent.removeThread(id: "b")
        XCTAssertEqual(try agent.threads(space: "contoso").map(\.id), ["a"])
    }

    func testSettings() throws {
        XCTAssertNil(try db.agent.settings(space: "contoso"))
        try db.agent.saveSettings(AgentSpaceSettings(space: "contoso", mode: "ask", workingFolder: "/tmp/x", model: nil))
        XCTAssertEqual(try db.agent.settings(space: "contoso"), AgentSpaceSettings(space: "contoso", mode: "ask", workingFolder: "/tmp/x"))
        try db.agent.saveSettings(AgentSpaceSettings(space: "contoso", mode: "yolo", workingFolder: nil, model: "m2"))
        XCTAssertEqual(try db.agent.settings(space: "contoso")?.mode, "yolo")
        XCTAssertNil(try db.agent.settings(space: "contoso")?.workingFolder)
    }

    func testActivityLogAndPrune() throws {
        let agent = db.agent
        let t0 = Date(timeIntervalSince1970: 5_000)
        for (i, tool) in ["page_snapshot", "click", "type"].enumerated() {
            try agent.log(AgentActivity(space: "contoso", threadID: "a", at: t0.addingTimeInterval(Double(i)), tool: tool,
                                        tabTitle: "Shop", tabURL: "https://shop.test/", target: "button “Add”", outcome: .done))
        }
        try agent.log(AgentActivity(space: "fabrikam", threadID: nil, at: t0, tool: "click", tabTitle: nil, tabURL: nil,
                                    target: "x", outcome: .blocked))
        XCTAssertEqual(try agent.activity(space: "contoso").map(\.tool), ["type", "click", "page_snapshot"])
        XCTAssertEqual(try agent.activity(space: "fabrikam").first?.outcome, .blocked)
        try agent.pruneActivity(olderThan: t0.addingTimeInterval(1.5))
        XCTAssertEqual(try agent.activity(space: "contoso").map(\.tool), ["type"])
        try agent.clearActivity(space: "contoso")
        XCTAssertTrue(try agent.activity(space: "contoso").isEmpty)
    }

    func testRemoveSpaceRemovesAgentRecords() throws {
        try db.agent.saveThread(AgentThreadRecord(id: "a", space: "contoso", backend: "codex", name: "x"))
        try db.agent.saveSettings(AgentSpaceSettings(space: "contoso", mode: "ask"))
        try db.agent.log(AgentActivity(space: "contoso", threadID: "a", tool: "click", tabTitle: nil, tabURL: nil, target: "x", outcome: .done))
        try db.agent.saveThread(AgentThreadRecord(id: "b", space: "fabrikam", backend: "codex", name: "y"))
        try db.removeSpace("contoso")
        XCTAssertTrue(try db.agent.threads(space: "contoso").isEmpty)
        XCTAssertNil(try db.agent.settings(space: "contoso"))
        XCTAssertTrue(try db.agent.activity(space: "contoso").isEmpty)
        XCTAssertEqual(try db.agent.threads(space: "fabrikam").count, 1)
    }

    /// A database made by v1 (no agent tables) gains them.
    func testMigratesAV1File() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AgentStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("browser.sqlite")
        do {
            let first = try BrowserDatabase(fileURL: url)
            try first.history.recordVisit(space: "contoso", url: URL(string: "https://a.test/")!, title: "A", typed: false)
        }
        let reopened = try BrowserDatabase(fileURL: url)
        try reopened.agent.saveThread(AgentThreadRecord(id: "a", space: "contoso", backend: "codex", name: "x"))
        XCTAssertEqual(try reopened.agent.threads(space: "contoso").count, 1)
        XCTAssertNil(reopened.movedAside)
    }
}
