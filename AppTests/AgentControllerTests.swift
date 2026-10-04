import AgentKit
import BrowserData
import XCTest
@testable import iSmith

/// The panel's engine against a scripted backend: chats are started, named and saved per space,
/// survive a relaunch and resume with their history; tool calls reach the browser tools; events
/// stream into the chat; approvals and Stop.
@MainActor
final class AgentControllerTests: XCTestCase {
    private var wired: WiredBrowser!

    override func setUp() async throws {
        wired = try WiredBrowser()
    }

    override func tearDown() async throws {
        await wired.tearDown()
    }

    private func controller(_ backend: ScriptedBackend) -> AgentController {
        let controller = AgentController(browser: wired.browser)
        controller.makeBackend = { handler in
            backend.handler = handler
            return backend
        }
        return controller
    }

    func testChatsAreSavedNamedAndResumed() async throws {
        let backend = ScriptedBackend()
        let agent = controller(backend)
        let session = agent.session("fixture")
        agent.setMode(.ask, in: "fixture")
        agent.send("Find the price on this page\nand add it to the cart", in: "fixture")
        let started = await eventually { backend.turns.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(backend.started.count, 1)
        let options = try XCTUnwrap(backend.started.first)
        XCTAssertEqual(options.mode, .ask)
        XCTAssertTrue(options.developerInstructions.contains("Fixture"), "names the space")
        XCTAssertTrue(options.tools.contains { $0.name == "page_snapshot" })
        XCTAssertEqual(backend.names.first?.1, "Find the price on this page")
        let saved = try XCTUnwrap(wired.browser.data?.agent.threads(space: "fixture"))
        XCTAssertEqual(saved.map(\.name), ["Find the price on this page"])
        XCTAssertEqual(session.threadID, saved.first?.id)
        XCTAssertEqual(backend.turns.first?.settings.mode, .ask)

        // Streamed reply and steps.
        let thread = try XCTUnwrap(session.threadID)
        backend.emit(.turnStarted(threadID: thread, turnID: "t1"))
        backend.emit(.itemStarted(threadID: thread, turnID: "t1", item: AgentItem(id: "c1", kind: .toolCall(tool: "page_snapshot", arguments: [:], status: .inProgress, success: nil))))
        backend.emit(.itemCompleted(threadID: thread, turnID: "t1", item: AgentItem(id: "c1", kind: .toolCall(tool: "page_snapshot", arguments: [:], status: .completed, success: true))))
        backend.emit(.messageDelta(threadID: thread, turnID: "t1", itemID: "m1", delta: "The price is "))
        backend.emit(.messageDelta(threadID: thread, turnID: "t1", itemID: "m1", delta: "$42."))
        let streamed = await eventually { session.entries.contains { $0.kind == .agent("The price is $42.") } }
        XCTAssertTrue(streamed)
        XCTAssertTrue(session.entries.contains { $0.kind == .steps([AgentStep(id: "c1", title: "Read the page", status: .completed)]) })
        XCTAssertTrue(session.running)
        backend.emit(.turnCompleted(threadID: thread, turnID: "t1", status: .completed, error: nil))
        let finished = await eventually { !session.running }
        XCTAssertTrue(finished)

        // A relaunch: a new controller lists the chat and resumes it with its history.
        let backend2 = ScriptedBackend()
        backend2.resumeTurns = [AgentTurnRecord(id: "t1", status: .completed, items: [
            AgentItem(id: "u1", kind: .userMessage(text: "Find the price")),
            AgentItem(id: "c1", kind: .toolCall(tool: "click", arguments: ["element": 5], status: .completed, success: true)),
            AgentItem(id: "m1", kind: .agentMessage(text: "Added it.")),
        ])]
        let relaunched = controller(backend2)
        let session2 = relaunched.session("fixture")
        XCTAssertEqual(session2.threads.map(\.id), [thread])
        XCTAssertEqual(session2.mode, .ask, "the space's mode is saved")
        relaunched.openThread(thread, in: "fixture")
        let resumed = await eventually { session2.entries.count == 3 }
        XCTAssertTrue(resumed)
        XCTAssertEqual(backend2.resumed, [thread])
        XCTAssertEqual(session2.entries.first?.kind, .user("Find the price"))
        XCTAssertEqual(session2.entries.last?.kind, .agent("Added it."))
        // Continuing it doesn't start a new thread.
        relaunched.send("Thanks", in: "fixture")
        let continued = await eventually { backend2.turns.count == 1 }
        XCTAssertTrue(continued)
        XCTAssertTrue(backend2.started.isEmpty)
        XCTAssertEqual(backend2.turns.first?.threadID, thread)
    }

    func testToolCallsReachTheBrowserToolsAndApprovalsWait() async throws {
        let backend = ScriptedBackend()
        let agent = controller(backend)
        let session = agent.session("fixture")
        agent.send("List my tabs", in: "fixture")
        let started = await eventually { backend.turns.count == 1 }
        XCTAssertTrue(started)
        let thread = try XCTUnwrap(session.threadID)
        _ = wired.browser.openTab(in: wired.window, space: "fixture", url: nil, title: "Blank tab")
        let result = await backend.callTool(AgentToolCall(threadID: thread, turnID: "t1", callID: "x", tool: "list_tabs", arguments: [:]))
        XCTAssertTrue(result.success)
        guard case let .text(listing)? = result.content.first else { return XCTFail() }
        XCTAssertTrue(listing.contains("Blank tab") || listing.contains("New tab"), listing)
        // A tool call from a thread no space knows is refused.
        let stray = await backend.callTool(AgentToolCall(threadID: "unknown", turnID: "t", callID: "y", tool: "list_tabs", arguments: [:]))
        XCTAssertFalse(stray.success)

        // A command approval shows a card and waits for the user.
        backend.emit(.turnStarted(threadID: thread, turnID: "t1"))
        let request = AgentApprovalRequest(id: "7", threadID: thread, turnID: "t1", itemID: "i", kind: .command(command: "ls", cwd: "/tmp", reason: nil))
        let decision = Task { await backend.approve(request) }
        let shown = await eventually { session.cards.count == 1 }
        XCTAssertTrue(shown)
        session.cards.first?.answer(.allowForSession)
        let answered = await decision.value
        XCTAssertEqual(answered, .acceptForSession)
        XCTAssertTrue(session.cards.isEmpty)

        // Read-only declines commands without asking.
        agent.setMode(.readOnly, in: "fixture")
        let declined = await backend.approve(request)
        XCTAssertEqual(declined, .decline)
        // A stricter mode stops the running turn (Codex's sandbox for it was set at its start).
        let stoppedForMode = await eventually { backend.interrupted.count == 1 }
        XCTAssertTrue(stoppedForMode)
        backend.emit(.turnStarted(threadID: thread, turnID: "t1"))

        // A request the backend withdraws takes its card away.
        agent.setMode(.ask, in: "fixture")
        let withdrawn = Task { await backend.approve(AgentApprovalRequest(id: "9", threadID: thread, turnID: "t1", itemID: "k", kind: .command(command: "rm x", cwd: nil, reason: nil))) }
        let shownWithdrawn = await eventually { session.cards.count == 1 }
        XCTAssertTrue(shownWithdrawn)
        backend.emit(.requestResolved(requestID: "9"))
        let gone = await withdrawn.value
        XCTAssertEqual(gone, .cancel)
        XCTAssertTrue(session.cards.isEmpty)

        // Stop answers waiting cards and interrupts the turn.
        agent.setMode(.yolo, in: "fixture")
        let waiting = Task { await backend.approve(AgentApprovalRequest(id: "8", threadID: thread, turnID: "t1", itemID: "j", kind: .fileChange(reason: nil, grantRoot: nil))) }
        let shownAgain = await eventually { session.cards.count == 1 }
        XCTAssertTrue(shownAgain)
        agent.stop(in: "fixture")
        let stopped = await waiting.value
        XCTAssertEqual(stopped, .cancel)
        let interrupted = await eventually { backend.interrupted.count == 2 }
        XCTAssertTrue(interrupted)
    }

    /// Codex's own MCP servers are off in panel threads unless the mode is YOLO, and the ones that
    /// drive the screen or another browser are off even then.
    func testCodexMCPServersAreSwitchedOff() {
        let config = """
            model = "x"
            [mcp_servers.node_repl]
            command = "node"
            [mcp_servers.node_repl.env]
            A = "1"
            [mcp_servers.applescript_execute]
            [mcp_servers.aws-mcp]
            [mcp_servers."computer-use"]
            [projects."/Users/x"]
            """
        XCTAssertEqual(AgentController.mcpServerNames(in: config), ["node_repl", "applescript_execute", "aws-mcp", "computer-use"])
        let yolo = AgentController.mcpOverrides(mode: .yolo, configText: config)
        XCTAssertEqual(Set(yolo.keys), ["mcp_servers.applescript_execute.enabled", "mcp_servers.computer-use.enabled"])
        let ask = AgentController.mcpOverrides(mode: .ask, configText: config)
        XCTAssertEqual(ask.count, 4)
        XCTAssertTrue(ask.values.allSatisfy { $0 == .bool(false) })
        XCTAssertTrue(AgentController.mcpOverrides(mode: .readOnly, configText: nil).isEmpty)
    }

    func testMissingCodexIsReported() async throws {
        let agent = AgentController(browser: wired.browser)
        agent.makeBackend = { _ in nil }
        let ok = await agent.prepare()
        XCTAssertFalse(ok)
        XCTAssertEqual(agent.status, .notInstalled)
    }
}

/// A backend that records what the controller asks and lets the test play the backend's side.
final class ScriptedBackend: AgentBackend, @unchecked Sendable {
    let displayName = "Scripted"
    var handler: AgentBackendHandler?
    var started: [AgentThreadOptions] = []
    var resumed: [String] = []
    var names: [(String, String)] = []
    var turns: [(threadID: String, text: String, settings: AgentTurnSettings)] = []
    var interrupted: [String] = []
    var resumeTurns: [AgentTurnRecord] = []
    private var count = 0

    func start() async throws {}
    func shutdown() async {}
    func models() async throws -> [AgentModel] { [AgentModel(id: "m", displayName: "Model M", isDefault: true)] }

    func startThread(_ options: AgentThreadOptions) async throws -> AgentThreadInfo {
        started.append(options)
        count += 1
        return AgentThreadInfo(id: "thread-\(count)-\(UUID().uuidString.prefix(4))", model: "m")
    }

    func resumeThread(id: String, options: AgentThreadOptions) async throws -> AgentThreadInfo {
        resumed.append(id)
        return AgentThreadInfo(id: id, model: "m", turns: resumeTurns)
    }

    func setThreadName(id: String, name: String) async throws { names.append((id, name)) }

    func startTurn(threadID: String, text: String, settings: AgentTurnSettings) async throws -> String {
        turns.append((threadID, text, settings))
        return "t\(turns.count)"
    }

    func interruptTurn(threadID: String, turnID: String) async throws { interrupted.append(turnID) }

    func emit(_ event: AgentEvent) { handler?.event(event) }
    func callTool(_ call: AgentToolCall) async -> AgentToolResult { await handler!.toolCall(call) }
    func approve(_ request: AgentApprovalRequest) async -> AgentApprovalDecision { await handler!.approval(request) }
}
