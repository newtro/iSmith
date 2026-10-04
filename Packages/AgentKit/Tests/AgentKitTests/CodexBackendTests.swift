import Foundation
import XCTest
@testable import AgentKit

/// End-to-end tests against the fake app server (`FakeCodexAppServer`), never the real Codex.
final class CodexBackendTests: XCTestCase {
    override func setUp() async throws {
        let path = FakeHarness.fakeServerURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            XCTFail("FakeCodexAppServer not built at \(path)")
            throw XCTSkip("no fake server")
        }
    }

    func testHandshakeAndThreadStartParams() async throws {
        let h = try FakeHarness()
        try await h.backend.start()
        try await h.backend.start() // Again: nothing happens.
        let info = try await h.backend.startThread(FakeHarness.threadOptions)
        await h.backend.shutdown()

        XCTAssertTrue(info.id.hasPrefix("thread-"))
        XCTAssertEqual(info.model, "fake-pro")
        XCTAssertNil(info.name)
        XCTAssertEqual(h.recorder.statuses, [.starting, .ready, .stopped])

        let messages = h.received()
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages.first?.message["method"], "initialize")
        XCTAssertEqual(messages.first?.message["params"],
                       ["clientInfo": ["name": "iSmithTests", "version": "9.9"], "capabilities": ["experimentalApi": true]])
        XCTAssertEqual(messages[1].message["method"], "initialized")
        XCTAssertNil(messages[1].message["id"])

        let params = try XCTUnwrap(h.received(method: "thread/start").first?.message["params"])
        XCTAssertEqual(params["cwd"], "/tmp/space")
        XCTAssertEqual(params["sandbox"], "workspace-write")
        XCTAssertEqual(params["approvalPolicy"], "untrusted")
        XCTAssertEqual(params["developerInstructions"], "You are iSmith's agent.")
        XCTAssertEqual(params["serviceName"], "iSmithTests")
        XCTAssertNil(params["model"])
        XCTAssertEqual(params["dynamicTools"], [["type": "function", "name": "browser_snapshot", "description": "Reads the page.",
                                                 "inputSchema": ["type": "object", "properties": ["selector": ["type": "string"]]]]])
        XCTAssertEqual(params["config"], CodexAppServerBackend.codexConfig(for: .ask))
        for key in ["features.computer_use", "features.browser_use", "features.browser_use_external", "features.in_app_browser"] {
            XCTAssertEqual(params["config"]?[key], false, key)
        }
    }

    func testToolRoundTripWithImage() async throws {
        let calls = Box<AgentToolCall>()
        let h = try FakeHarness(toolCall: { call in
            calls.append(call)
            return AgentToolResult(success: true, content: [.text("hello"), .image(dataURL: "data:image/png;base64,iVBORw0K")])
        })
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "tool", settings: FakeHarness.settings())
        await h.recorder.wait("turn completed") { _ in h.recorder.turnCompleted(turn) != nil }
        await h.backend.shutdown()

        XCTAssertEqual(calls.all, [AgentToolCall(threadID: thread.id, turnID: turn, callID: "call-1", tool: "browser_snapshot",
                                                 arguments: ["selector": "#main", "full": true], requestID: "1")])
        XCTAssertEqual(h.recorder.completedAgentMessages(turnID: turn), ["success=true text:hello | image:data:30"])
        XCTAssertEqual(h.recorder.turnCompleted(turn)?.status, .completed)
        XCTAssertTrue(h.recorder.all.contains(.turnStarted(threadID: thread.id, turnID: turn)))

        let turnParams = try XCTUnwrap(h.received(method: "turn/start").first?.message["params"])
        XCTAssertEqual(turnParams["input"], [["type": "text", "text": "tool"]])
        XCTAssertEqual(turnParams["sandboxPolicy"], CodexAppServerBackend.sandboxPolicy(for: .ask, cwd: "/tmp/space"))
        XCTAssertEqual(turnParams["approvalPolicy"], "untrusted")
    }

    func testApprovalRoundTrip() async throws {
        let requests = Box<AgentApprovalRequest>()
        let h = try FakeHarness(approval: { request in
            requests.append(request)
            switch request.kind {
            case .command: return .accept
            case .fileChange: return .decline
            case .permissions: return .acceptForSession
            }
        })
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "approvals", settings: FakeHarness.settings())
        await h.recorder.wait("turn completed") { _ in h.recorder.turnCompleted(turn) != nil }
        await h.backend.shutdown()

        XCTAssertEqual(requests.all, [
            AgentApprovalRequest(id: "srv-1", threadID: thread.id, turnID: turn, itemID: "cmd-1",
                                 kind: .command(command: "rm -rf build", cwd: "/tmp/space", reason: "clean up")),
            AgentApprovalRequest(id: "2", threadID: thread.id, turnID: turn, itemID: "fc-1",
                                 kind: .fileChange(reason: "edit notes", grantRoot: "/tmp/space")),
            AgentApprovalRequest(id: "srv-3", threadID: thread.id, turnID: turn, itemID: "perm-1",
                                 kind: .permissions(reason: "needs network", summary: "Network access; write: /tmp/out")),
        ])
        XCTAssertEqual(h.recorder.completedAgentMessages(turnID: turn), [[
            #"{"decision":"accept"}"#,
            #"{"decision":"decline"}"#,
            #"{"permissions":{"fileSystem":{"write":["\/tmp\/out"]},"network":{"enabled":true}},"scope":"session"}"#,
        ].joined(separator: "\n")])
    }

    func testReadOnlyAutoDeclinesWithoutAskingTheApp() async throws {
        let asked = Box<AgentApprovalRequest>()
        let h = try FakeHarness(approval: { request in
            asked.append(request)
            return .accept
        })
        try await h.backend.start()
        var options = FakeHarness.threadOptions
        options.mode = .ask
        let thread = try await h.backend.startThread(options)
        // The turn's mode is what counts.
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "approvals", settings: FakeHarness.settings(.readOnly))
        await h.recorder.wait("turn completed") { _ in h.recorder.turnCompleted(turn) != nil }
        await h.backend.shutdown()

        XCTAssertEqual(asked.all, [])
        XCTAssertEqual(h.recorder.completedAgentMessages(turnID: turn),
                       [#"{"decision":"decline"}"# + "\n" + #"{"decision":"decline"}"# + "\n" + #"{"permissions":{}}"#])
        let turnParams = try XCTUnwrap(h.received(method: "turn/start").first?.message["params"])
        XCTAssertEqual(turnParams["sandboxPolicy"], ["type": "readOnly"])
        XCTAssertEqual(turnParams["approvalPolicy"], "untrusted")
    }

    func testOtherServerRequests() async throws {
        let h = try FakeHarness()
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "misc", settings: FakeHarness.settings())
        await h.recorder.wait("turn completed") { _ in h.recorder.turnCompleted(turn) != nil }
        await h.backend.shutdown()

        let text = try XCTUnwrap(h.recorder.completedAgentMessages(turnID: turn).first)
        let lines = text.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        XCTAssertEqual(lines.count, 2)
        let now = Date().timeIntervalSince1970
        let time = try XCTUnwrap(lines.first?["result"]?["currentTimeAt"]?.doubleValue)
        XCTAssertLessThan(abs(time - now), 30)
        XCTAssertEqual(lines.last?["error"]?["code"], -32601)
    }

    func testStreamingDeltasAndNotices() async throws {
        let h = try FakeHarness()
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let t = thread.id
        let turn = try await h.backend.startTurn(threadID: t, text: "stream", settings: FakeHarness.settings())
        await h.recorder.wait("turn completed") { _ in h.recorder.turnCompleted(turn) != nil }
        await h.backend.shutdown()

        let events = h.recorder.all
        XCTAssertTrue(events.contains(.reasoningDelta(threadID: t, turnID: turn, itemID: "item-2", delta: "Plan")))
        XCTAssertTrue(events.contains(.itemCompleted(threadID: t, turnID: turn, item: AgentItem(id: "item-2", kind: .reasoning(summary: ["Plan"])))))
        XCTAssertTrue(events.contains(.error(threadID: t, turnID: turn, message: "Reconnecting… 1/5", willRetry: true)))
        let notices = events.compactMap { if case let .notice(_, m) = $0 { return m } else { return nil } }
        XCTAssertEqual(notices, ["Heads up", "Odd config", "Old thing"])
        XCTAssertTrue(events.contains(.itemCompleted(threadID: t, turnID: turn, item: AgentItem(
            id: "cmd-9", kind: .command(command: "echo hi", cwd: "/tmp", status: .completed, exitCode: 0, output: "hi\n")))))
        let deltas = events.compactMap { if case let .messageDelta(_, _, _, d) = $0 { return d } else { return nil } }
        XCTAssertEqual(deltas, ["Hel", "lo"])
        XCTAssertEqual(h.recorder.completedAgentMessages(turnID: turn), ["Hello"])
        XCTAssertTrue(events.contains(.itemStarted(threadID: t, turnID: turn, item: AgentItem(id: "item-1", kind: .userMessage(text: "stream")))))
        // Order: the turn starts before its items and completes after them.
        let startIndex = try XCTUnwrap(events.firstIndex(of: .turnStarted(threadID: t, turnID: turn)))
        let endIndex = try XCTUnwrap(events.firstIndex { if case .turnCompleted = $0 { return true } else { return false } })
        XCTAssertLessThan(startIndex, endIndex)
        XCTAssertEqual(events.lastIndex { if case .messageDelta = $0 { return true } else { return false } }.map { $0 < endIndex }, true)
    }

    func testResumeMapsTurnsAndRenames() async throws {
        let h = try FakeHarness()
        try await h.backend.start()
        var options = FakeHarness.threadOptions
        options.model = "fake-mini"
        options.mode = .yolo
        let info = try await h.backend.resumeThread(id: "saved-1", options: options)
        try await h.backend.setThreadName(id: "saved-1", name: "Trip planning")
        await h.recorder.wait("name change") { $0.contains(.threadNameChanged(threadID: "saved-1", name: "Trip planning")) }
        await h.backend.shutdown()

        XCTAssertEqual(info.id, "saved-1")
        XCTAssertEqual(info.model, "fake-mini")
        XCTAssertEqual(info.name, "Saved name")
        XCTAssertEqual(info.turns.count, 2)
        XCTAssertEqual(info.turns[0].status, .completed)
        XCTAssertEqual(info.turns[0].items, [
            AgentItem(id: "u1", kind: .userMessage(text: "Hello")),
            AgentItem(id: "r1", kind: .reasoning(summary: ["Thinking about it"])),
            AgentItem(id: "d1", kind: .toolCall(tool: "browser_snapshot", arguments: ["tab": 1], status: .completed, success: true)),
            AgentItem(id: "c1", kind: .command(command: "ls", cwd: "/tmp", status: .completed, exitCode: 0, output: "a\nb")),
            AgentItem(id: "f1", kind: .fileChange(paths: ["/tmp/a.txt"], status: .declined)),
            AgentItem(id: "m1", kind: .mcpToolCall(server: "docs", tool: "search", status: .failed)),
            AgentItem(id: "w1", kind: .webSearch(query: "swift pipes")),
            AgentItem(id: "cc1", kind: .other(type: "contextCompaction")),
            AgentItem(id: "a1", kind: .agentMessage(text: "Hi there")),
        ])
        XCTAssertEqual(info.turns[1], AgentTurnRecord(id: "turn-old-2", status: .failed, items: [], error: "model overloaded"))

        let params = try XCTUnwrap(h.received(method: "thread/resume").first?.message["params"])
        XCTAssertEqual(params["threadId"], "saved-1")
        XCTAssertEqual(params["model"], "fake-mini")
        XCTAssertEqual(params["sandbox"], "danger-full-access")
        XCTAssertEqual(params["approvalPolicy"], "never")
        XCTAssertEqual(params["config"], CodexAppServerBackend.codexConfig(for: .yolo))
        XCTAssertNil(params["dynamicTools"])
        XCTAssertEqual(h.received(method: "thread/name/set").first?.message["params"], ["threadId": "saved-1", "name": "Trip planning"])
    }

    func testModelListPagingSkipsHidden() async throws {
        let h = try FakeHarness()
        try await h.backend.start()
        let models = try await h.backend.models()
        await h.backend.shutdown()
        XCTAssertEqual(models, [AgentModel(id: "fake-pro", displayName: "Fake Pro", description: "Big", isDefault: true),
                                AgentModel(id: "fake-mini", displayName: "Fake Mini", description: "Small", isDefault: false)])
        XCTAssertEqual(h.received(method: "model/list").map { $0.message["params"] },
                       [["includeHidden": false], ["includeHidden": false, "cursor": "page2"]])
    }

    func testInterrupt() async throws {
        let h = try FakeHarness()
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "wait", settings: FakeHarness.settings())
        await h.recorder.wait("turn started") { $0.contains(.turnStarted(threadID: thread.id, turnID: turn)) }
        try await h.backend.interruptTurn(threadID: thread.id, turnID: turn)
        await h.recorder.wait("turn interrupted") { _ in h.recorder.turnCompleted(turn)?.status == .interrupted }
        await h.backend.shutdown()
        XCTAssertEqual(h.received(method: "turn/interrupt").first?.message["params"], ["threadId": .string(thread.id), "turnId": .string(turn)])
    }

    func testInterruptWithPendingToolCallResolvesItAndDropsTheLateReply() async throws {
        let release = AsyncGate()
        let calls = Box<AgentToolCall>()
        let cancelled = Box<Bool>()
        let h = try FakeHarness(toolCall: { call in
            calls.append(call)
            await release.wait()
            cancelled.append(Task.isCancelled)
            return .text("late")
        })
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "tool", settings: FakeHarness.settings())
        await h.recorder.wait("tool call") { _ in !calls.all.isEmpty }
        try await h.backend.interruptTurn(threadID: thread.id, turnID: turn)
        await h.recorder.wait("request resolved") { $0.contains(.requestResolved(requestID: "1")) }
        await h.recorder.wait("turn interrupted") { _ in h.recorder.turnCompleted(turn)?.status == .interrupted }
        await release.open()
        await h.recorder.wait("handler finished") { _ in !cancelled.all.isEmpty }
        XCTAssertEqual(cancelled.all, [true], "the withdrawn call's task is cancelled")
        XCTAssertEqual(calls.all.first?.requestID, "1")
        try await Task.sleep(nanoseconds: 200_000_000)
        await h.backend.shutdown()
        // The fake never got an answer to its tool call.
        XCTAssertFalse(h.received().contains { $0.message["method"] == nil && $0.message["id"] == 1 })
    }

    func testCrashMidTurnRestartsAndResumes() async throws {
        let h = try FakeHarness()
        try await h.backend.start()
        var options = FakeHarness.threadOptions
        options.mode = .ask
        let thread = try await h.backend.startThread(options)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "crash", settings: FakeHarness.settings(.confirmSubmits))
        await h.recorder.wait("ready again") { _ in h.recorder.statuses.filter { $0 == .ready }.count == 2 }

        let completed = try XCTUnwrap(h.recorder.turnCompleted(turn))
        XCTAssertEqual(completed.status, .failed)
        XCTAssertTrue(completed.error?.hasPrefix("Codex stopped: Codex exited with status 3.") == true, completed.error ?? "")
        XCTAssertTrue(completed.error?.contains("simulated crash") == true, completed.error ?? "")
        let statuses = h.recorder.statuses
        XCTAssertEqual(statuses.count, 4)
        if case .restarting = statuses[2] {} else { XCTFail("expected restarting, got \(statuses)") }

        let pids = Set(h.received().map(\.pid))
        XCTAssertEqual(pids.count, 2)
        let resume = try XCTUnwrap(h.received(method: "thread/resume").first)
        XCTAssertEqual(resume.message["params"]?["threadId"], .string(thread.id))
        XCTAssertEqual(resume.message["params"]?["sandbox"], "workspace-write")
        XCTAssertNil(resume.message["params"]?["dynamicTools"])
        let secondInit = h.received(method: "initialize").map(\.pid)
        XCTAssertEqual(secondInit.count, 2)
        XCTAssertEqual(secondInit.last, resume.pid)

        // The thread works on the new process.
        let next = try await h.backend.startTurn(threadID: thread.id, text: "again", settings: FakeHarness.settings())
        await h.recorder.wait("second turn") { _ in h.recorder.turnCompleted(next)?.status == .completed }
        XCTAssertEqual(h.recorder.completedAgentMessages(turnID: next), ["echo: again"])
        await h.backend.shutdown()
    }

    func testRestartLimitGivesUp() async throws {
        let h = try FakeHarness(scenario: "crashLoop", restartLimit: (2, 60))
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        do {
            _ = try await h.backend.startTurn(threadID: thread.id, text: "x", settings: FakeHarness.settings())
            XCTFail("turn/start should fail when the process dies")
        } catch let AgentBackendError.processExited(reason) {
            XCTAssertTrue(reason.contains("status 5"), reason)
        }
        await h.recorder.wait("failed") { _ in h.recorder.statuses.contains { if case .failed = $0 { return true } else { return false } } }
        let statuses = h.recorder.statuses
        XCTAssertEqual(statuses.filter { if case .restarting = $0 { return true } else { return false } }.count, 2)
        guard case let .failed(reason)? = statuses.last else { return XCTFail("\(statuses)") }
        XCTAssertTrue(reason.contains("keeps stopping"), reason)
        do {
            _ = try await h.backend.models()
            XCTFail("calls fail once it gave up")
        } catch AgentBackendError.processExited {}

        // start() tries again (and resumes the thread it knew, which crashes this fake again).
        await h.backend.shutdown()
    }

    func testStartFailsWhenProcessExits() async throws {
        let h = try FakeHarness(scenario: "exitAtStart")
        do {
            try await h.backend.start()
            XCTFail("start should fail")
        } catch let AgentBackendError.processExited(reason) {
            XCTAssertTrue(reason.contains("refusing to start"), reason)
        }
        guard case .failed? = h.recorder.statuses.last else { return XCTFail("\(h.recorder.statuses)") }
        do { _ = try await h.backend.models(); XCTFail() } catch AgentBackendError.processExited {}
    }

    func testMissingExecutableFailsToStart() async throws {
        let recorder = EventRecorder()
        let backend = CodexAppServerBackend(
            executable: URL(fileURLWithPath: "/nonexistent/codex"), clientVersion: "1",
            handler: AgentBackendHandler(toolCall: { _ in .text("") }, approval: { _ in .decline }, event: { recorder.append($0) }))
        do { try await backend.start(); XCTFail() } catch AgentBackendError.processExited {}
        XCTAssertEqual(recorder.statuses.first, .starting)
        guard case .failed? = recorder.statuses.last else { return XCTFail("\(recorder.statuses)") }
        // Before start, calls say it isn't running.
        let idle = CodexAppServerBackend(clientVersion: "1", handler: AgentBackendHandler(
            toolCall: { _ in .text("") }, approval: { _ in .decline }, event: { _ in }))
        do { _ = try await idle.models(); XCTFail() } catch AgentBackendError.notRunning {}
    }

    func testStallRestartsCodex() async throws {
        let h = try FakeHarness(stallTimeout: 0.6)
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "stall", settings: FakeHarness.settings())
        await h.recorder.wait("stall restart") { _ in h.recorder.statuses.filter { $0 == .ready }.count == 2 }
        let completed = try XCTUnwrap(h.recorder.turnCompleted(turn))
        XCTAssertEqual(completed.status, .failed)
        XCTAssertTrue(completed.error?.contains("stopped responding") == true, completed.error ?? "")
        XCTAssertEqual(h.received(method: "thread/resume").count, 1)
        await h.backend.shutdown()
    }

    func testPendingToolCallIsNotAStall() async throws {
        let h = try FakeHarness(stallTimeout: 0.4, toolCall: { _ in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return .text("slow but fine")
        })
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "tool", settings: FakeHarness.settings())
        await h.recorder.wait("turn completed") { _ in h.recorder.turnCompleted(turn) != nil }
        XCTAssertEqual(h.recorder.turnCompleted(turn)?.status, .completed)
        XCTAssertEqual(h.recorder.completedAgentMessages(turnID: turn), ["success=true text:slow but fine"])
        // Idle with no turn running isn't a stall either.
        try await Task.sleep(nanoseconds: 800_000_000)
        await h.backend.shutdown()
        XCTAssertEqual(h.recorder.statuses, [.starting, .ready, .stopped])
    }

    func testLargeLinesBothWays() async throws {
        let image = "data:image/png;base64," + String(repeating: "A", count: 6_000_000)
        let h = try FakeHarness(toolCall: { _ in AgentToolResult(success: true, content: [.image(dataURL: image)]) })
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "big", settings: FakeHarness.settings())
        await h.recorder.wait(timeout: 20, "turn completed") { _ in h.recorder.turnCompleted(turn) != nil }
        await h.backend.shutdown()
        let deltas = h.recorder.all.compactMap { if case let .messageDelta(_, _, _, d) = $0 { return d } else { return nil } }
        XCTAssertEqual(deltas.first?.count, 5_000_000)
        XCTAssertEqual(h.recorder.completedAgentMessages(turnID: turn).last, "success=true image:data:\(image.utf8.count)")
    }

    func testShutdownFailsPendingCalls() async throws {
        let h = try FakeHarness()
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let backend = h.backend
        let pending = Task { try await backend.setThreadName(id: thread.id, name: "hang") }
        try await Task.sleep(nanoseconds: 300_000_000)
        await h.backend.shutdown()
        do {
            try await pending.value
            XCTFail("pending call should fail")
        } catch {
            XCTAssertEqual(error as? AgentBackendError, .notRunning)
        }
        do { _ = try await h.backend.models(); XCTFail() } catch AgentBackendError.notRunning {}
        XCTAssertEqual(h.recorder.statuses.last, .stopped)

        // It can start again afterwards.
        try await h.backend.start()
        let models = try await h.backend.models()
        XCTAssertEqual(models.count, 2)
        await h.backend.shutdown()
    }
}

extension CodexBackendTests {
    func testExtraConfigReachesStartAndResumeButCannotOverrideOurKeys() async throws {
        let h = try FakeHarness()
        try await h.backend.start()
        var options = FakeHarness.threadOptions
        options.extraConfig = [
            "mcp_servers.computer-use.enabled": false,
            "features.computer_use": true,
            "features.in_app_browser": true,
            "suppress_unstable_features_warning": false,
            "features": ["browser_use": true, "web_search": true],
        ]
        let thread = try await h.backend.startThread(options)
        // A crash makes recovery resume the thread with the same config.
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "crash", settings: FakeHarness.settings())
        await h.recorder.wait("ready again") { _ in h.recorder.statuses.filter { $0 == .ready }.count == 2 }
        _ = try await h.backend.resumeThread(id: thread.id, options: options)
        await h.backend.shutdown()
        XCTAssertEqual(h.recorder.turnCompleted(turn)?.status, .failed)

        let configs = (h.received(method: "thread/start") + h.received(method: "thread/resume")).compactMap { $0.message["params"]?["config"] }
        XCTAssertEqual(configs.count, 3)
        // Resuming a thread the process has loaded unloads it first, so the new config applies.
        XCTAssertEqual(h.received(method: "thread/unsubscribe").count, 1)
        for config in configs {
            XCTAssertEqual(config["mcp_servers.computer-use.enabled"], false)
            XCTAssertEqual(config["features.computer_use"], false)
            XCTAssertEqual(config["features.in_app_browser"], false)
            XCTAssertEqual(config["features.browser_use"], false)
            XCTAssertEqual(config["suppress_unstable_features_warning"], true)
            XCTAssertEqual(config["features"], ["web_search": true])
        }
    }

    func testSubagentThreadsFollowTheParentModeAndUnknownThreadsAreDeclined() async throws {
        let asked = Box<AgentApprovalRequest>()
        let h = try FakeHarness(approval: { request in
            asked.append(request)
            return .accept
        })
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "subagent", settings: FakeHarness.settings(.ask))
        await h.recorder.wait("turn completed") { _ in h.recorder.turnCompleted(turn) != nil }
        let readOnlyTurn = try await h.backend.startTurn(threadID: thread.id, text: "subagent", settings: FakeHarness.settings(.readOnly))
        await h.recorder.wait("turn completed") { _ in h.recorder.turnCompleted(readOnlyTurn) != nil }
        await h.backend.shutdown()

        XCTAssertEqual(asked.all.map(\.threadID), ["child-of-\(thread.id)"], "only the child (in Ask) reaches the user")
        XCTAssertEqual(h.recorder.completedAgentMessages(turnID: turn), [#"{"decision":"accept"}"# + "\n" + #"{"decision":"decline"}"#])
        XCTAssertEqual(h.recorder.completedAgentMessages(turnID: readOnlyTurn), [#"{"decision":"decline"}"# + "\n" + #"{"decision":"decline"}"#])
    }

    func testTurnEndingWithdrawsItsPendingRequests() async throws {
        let cancelled = Box<Bool>()
        let h = try FakeHarness(toolCall: { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            cancelled.append(Task.isCancelled)
            return .text("too late")
        })
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "abandon", settings: FakeHarness.settings())
        await h.recorder.wait("resolved") { $0.contains(.requestResolved(requestID: "1")) }
        await h.recorder.wait("handler cancelled") { _ in cancelled.all == [true] }
        XCTAssertEqual(h.recorder.turnCompleted(turn)?.status, .completed)
        await h.backend.shutdown()
        XCTAssertFalse(h.received().contains { $0.message["method"] == nil && $0.message["id"] == 1 })
    }

    func testHungCallOutsideATurnRestartsCodex() async throws {
        let h = try FakeHarness(stallTimeout: 0.5)
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        do {
            try await h.backend.setThreadName(id: thread.id, name: "hang")
            XCTFail("the hung call should fail")
        } catch let AgentBackendError.processExited(reason) {
            XCTAssertTrue(reason.contains("stopped responding"), reason)
        }
        await h.recorder.wait("ready again") { _ in h.recorder.statuses.filter { $0 == .ready }.count == 2 }
        await h.backend.shutdown()
    }

    func testStallStopEscalatesToKillWhenSigtermIsIgnored() async throws {
        let h = try FakeHarness(scenario: "ignoreSigterm", stallTimeout: 0.4)
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        let turn = try await h.backend.startTurn(threadID: thread.id, text: "stall", settings: FakeHarness.settings())
        await h.recorder.wait(timeout: 10, "restart") { _ in h.recorder.statuses.filter { $0 == .ready }.count == 2 }
        XCTAssertEqual(h.recorder.turnCompleted(turn)?.status, .failed)
        XCTAssertTrue(h.recorder.turnCompleted(turn)?.error?.contains("stopped responding") == true)
        await h.backend.shutdown()
    }

    func testClearedNameAndCancelledCall() async throws {
        let h = try FakeHarness()
        try await h.backend.start()
        let thread = try await h.backend.startThread(FakeHarness.threadOptions)
        try await h.backend.setThreadName(id: thread.id, name: "clear")
        await h.recorder.wait("cleared name") { $0.contains(.threadNameChanged(threadID: thread.id, name: "")) }

        let backend = h.backend
        let call = Task { try await backend.setThreadName(id: thread.id, name: "hang") }
        try await Task.sleep(nanoseconds: 200_000_000)
        call.cancel()
        do { try await call.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        // The connection still works.
        let models = try await h.backend.models()
        XCTAssertEqual(models.count, 2)
        await h.backend.shutdown()
    }
}

/// Lets a test hold a handler until it says go.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
