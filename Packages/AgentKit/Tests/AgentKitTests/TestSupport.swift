import Foundation
import XCTest
@testable import AgentKit

/// Collects backend events and lets a test wait for a condition on them.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var all: [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var statuses: [AgentBackendStatus] {
        all.compactMap { if case let .status(s) = $0 { return s } else { return nil } }
    }

    /// Polls until `condition` holds, failing the test after `timeout` seconds.
    @discardableResult
    func wait(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
              _ what: String, until condition: ([AgentEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(all) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(what). Events: \(all.map(Self.brief))", file: file, line: line)
        return false
    }

    func turnCompleted(_ turnID: String) -> (status: AgentTurnStatus, error: String?)? {
        for event in all {
            if case let .turnCompleted(_, id, status, error) = event, id == turnID { return (status, error) }
        }
        return nil
    }

    func completedAgentMessages(turnID: String) -> [String] {
        all.compactMap { event in
            if case let .itemCompleted(_, t, item) = event, t == turnID, case let .agentMessage(text) = item.kind { return text }
            return nil
        }
    }

    /// Events without huge payloads, for failure messages.
    static func brief(_ event: AgentEvent) -> String {
        let text = String(describing: event)
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}

/// Thread-safe list of whatever a handler saw.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

/// A backend wired to the fake app server, with a temp folder for its log and state.
final class FakeHarness {
    let directory: URL
    let logURL: URL
    let recorder = EventRecorder()
    let backend: CodexAppServerBackend

    static var fakeServerURL: URL {
        Bundle(for: EventRecorder.self).bundleURL.deletingLastPathComponent().appendingPathComponent("FakeCodexAppServer")
    }

    init(scenario: String = "default",
         stallTimeout: TimeInterval = 600,
         restartLimit: (count: Int, window: TimeInterval) = (3, 300),
         toolCall: @escaping @Sendable (AgentToolCall) async -> AgentToolResult = { _ in .text("ok") },
         approval: @escaping @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision = { _ in .decline }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("fake.log")
        var env = ProcessInfo.processInfo.environment
        env["FAKE_CODEX_SCENARIO"] = scenario
        env["FAKE_CODEX_LOG"] = logURL.path
        env["FAKE_CODEX_STATE"] = directory.path
        let recorder = recorder
        backend = CodexAppServerBackend(
            executable: Self.fakeServerURL, arguments: [], environment: env, clientName: "iSmithTests", clientVersion: "9.9",
            handler: AgentBackendHandler(toolCall: toolCall, approval: approval, event: { recorder.append($0) }),
            stallTimeout: stallTimeout, restartLimit: restartLimit)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Every message the fake received: (pid, message).
    func received() -> [(pid: Int, message: JSONValue)] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let entry = JSONValue.parse(String(line)), let pid = entry["pid"]?.intValue, let msg = entry["msg"] else { return nil }
            return (pid, msg)
        }
    }

    func received(method: String) -> [(pid: Int, message: JSONValue)] {
        received().filter { $0.message["method"]?.stringValue == method }
    }

    static let threadOptions = AgentThreadOptions(
        cwd: "/tmp/space", mode: .ask, developerInstructions: "You are iSmith's agent.",
        tools: [AgentToolSpec(name: "browser_snapshot", description: "Reads the page.",
                              inputSchema: ["type": "object", "properties": ["selector": ["type": "string"]]])])

    static func settings(_ mode: AgentMode = .ask) -> AgentTurnSettings {
        AgentTurnSettings(cwd: "/tmp/space", mode: mode)
    }
}
