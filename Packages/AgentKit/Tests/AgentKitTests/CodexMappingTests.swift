import Foundation
import XCTest
@testable import AgentKit

final class CodexMappingTests: XCTestCase {
    func testLocateExecutableSearchOrder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("locate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let home = root.appendingPathComponent("home"), localBin = home.appendingPathComponent(".local/bin")
        for dir in [first, second, localBin] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        func makeCodex(in dir: URL, executable: Bool = true) throws {
            let url = dir.appendingPathComponent("codex")
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
        // Not executable in the first PATH entry: skipped.
        try makeCodex(in: first, executable: false)
        try makeCodex(in: second)
        try makeCodex(in: localBin)
        let env = ["PATH": "\(first.path):\(second.path)"]

        XCTAssertEqual(CodexAppServerBackend.locateExecutable(environment: env, home: home)?.path,
                       second.appendingPathComponent("codex").path)

        // Not on PATH: ~/.local/bin comes next.
        try fm.removeItem(at: second.appendingPathComponent("codex"))
        XCTAssertEqual(CodexAppServerBackend.locateExecutable(environment: env, home: home)?.path,
                       localBin.appendingPathComponent("codex").path)

        // A directory named codex isn't a program.
        try fm.removeItem(at: localBin.appendingPathComponent("codex"))
        try fm.createDirectory(at: localBin.appendingPathComponent("codex"), withIntermediateDirectories: true)
        let fallback = CodexAppServerBackend.locateExecutable(environment: env, home: home)
        let wellKnown = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].first { fm.isExecutableFile(atPath: $0) }
        XCTAssertEqual(fallback?.path, wellKnown)
    }

    func testChildEnvironmentExtendsPath() {
        let env = CodexAppServerBackend.childEnvironment(["PATH": "/usr/bin:/custom", "HOME": "/Users/x"])
        XCTAssertEqual(env["PATH"], "/usr/bin:/custom:/Users/x/.local/bin:/opt/homebrew/bin:/usr/local/bin:/bin")
        XCTAssertEqual(CodexAppServerBackend.childEnvironment(["HOME": "/h"])["PATH"],
                       "/h/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }

    func testModeMapping() {
        typealias B = CodexAppServerBackend
        XCTAssertEqual(AgentMode.allCases.map(B.sandboxMode(for:)),
                       ["read-only", "workspace-write", "workspace-write", "danger-full-access"])
        XCTAssertEqual(AgentMode.allCases.map(B.approvalPolicy(for:)), ["untrusted", "untrusted", "on-request", "never"])
        XCTAssertEqual(B.sandboxPolicy(for: .readOnly, cwd: "/w"), ["type": "readOnly"])
        let workspace: JSONValue = ["type": "workspaceWrite", "writableRoots": ["/w"], "networkAccess": false]
        XCTAssertEqual(B.sandboxPolicy(for: .ask, cwd: "/w"), workspace)
        XCTAssertEqual(B.sandboxPolicy(for: .confirmSubmits, cwd: "/w"), workspace)
        XCTAssertEqual(B.sandboxPolicy(for: .yolo, cwd: "/w"), ["type": "dangerFullAccess"])
    }

    func testCodexConfig() {
        let base: [String: JSONValue] = [
            "features.computer_use": false, "features.browser_use": false, "features.browser_use_external": false,
            "features.in_app_browser": false, "features.memories": false, "notify": [],
            "suppress_unstable_features_warning": true,
        ]
        var ask = base
        ask["features.apps"] = false
        ask["features.plugins"] = false
        ask["web_search"] = "disabled"
        var readOnly = ask
        readOnly["features.shell_tool"] = false
        readOnly["features.unified_exec"] = false
        XCTAssertEqual(CodexAppServerBackend.codexConfig(for: .readOnly), .object(readOnly))
        XCTAssertEqual(CodexAppServerBackend.codexConfig(for: .ask), .object(ask))
        XCTAssertEqual(CodexAppServerBackend.codexConfig(for: .confirmSubmits), .object(ask))
        XCTAssertEqual(CodexAppServerBackend.codexConfig(for: .yolo), .object(base))
    }

    func testThreadConfigMergesExtraKeys() {
        let merged = CodexAppServerBackend.threadConfig(for: .ask, extra: ["mcp_servers.x.enabled": false, "features.browser_use": true])
        XCTAssertEqual(merged["mcp_servers.x.enabled"], false)
        XCTAssertEqual(merged["features.browser_use"], false)
        XCTAssertEqual(CodexAppServerBackend.threadConfig(for: .yolo, extra: [:]), CodexAppServerBackend.codexConfig(for: .yolo))
    }

    func testTurnStartParams() {
        let params = CodexAppServerBackend.turnStartParams(
            threadID: "t1", text: "hi", settings: AgentTurnSettings(cwd: "/w", model: "m1", mode: .yolo))
        XCTAssertEqual(params, ["threadId": "t1", "input": [["type": "text", "text": "hi"]], "cwd": "/w", "model": "m1",
                                "approvalPolicy": "never", "sandboxPolicy": ["type": "dangerFullAccess"]])
        let noModel = CodexAppServerBackend.turnStartParams(threadID: "t1", text: "hi", settings: AgentTurnSettings(cwd: "/w", mode: .ask))
        XCTAssertNil(noModel["model"])
    }

    func testItemMapping() {
        typealias B = CodexAppServerBackend
        XCTAssertEqual(B.item(from: ["type": "userMessage", "id": "u", "content": [["type": "text", "text": "a"], ["type": "image", "url": "x"], ["type": "text", "text": "b"]]]),
                       AgentItem(id: "u", kind: .userMessage(text: "a\nb")))
        XCTAssertEqual(B.item(from: ["type": "dynamicToolCall", "id": "d", "tool": "t", "arguments": ["a": 1], "status": "failed", "success": false]),
                       AgentItem(id: "d", kind: .toolCall(tool: "t", arguments: ["a": 1], status: .failed, success: false)))
        XCTAssertEqual(B.item(from: ["type": "commandExecution", "id": "c", "command": "ls", "cwd": "/", "status": "declined"]),
                       AgentItem(id: "c", kind: .command(command: "ls", cwd: "/", status: .declined, exitCode: nil, output: nil)))
        XCTAssertEqual(B.item(from: ["type": "imageView", "id": "i", "path": "/a.png"]), AgentItem(id: "i", kind: .other(type: "imageView")))
        XCTAssertNil(B.item(from: ["type": "agentMessage", "text": "no id"]))
        XCTAssertEqual(B.turnStatus("interrupted"), .interrupted)
        XCTAssertEqual(B.turnStatus("failed"), .failed)
    }

    func testPermissionsSummaryAndResponses() {
        typealias B = CodexAppServerBackend
        let requested: JSONValue = [
            "network": ["enabled": true],
            "fileSystem": ["write": ["/a"], "entries": [["access": "read", "path": ["type": "path", "path": "/b"]],
                                                        ["access": "write", "path": ["type": "special", "value": ["kind": "tmpdir"]]]]],
        ]
        XCTAssertEqual(B.permissionsSummary(requested), "Network access; write: /a, tmpdir; read: /b")
        XCTAssertEqual(B.permissionsSummary([:]), "Extra sandbox permissions")
        XCTAssertEqual(B.permissionsResponse(.accept, requested: requested), ["permissions": requested, "scope": "turn"])
        XCTAssertEqual(B.permissionsResponse(.acceptForSession, requested: requested), ["permissions": requested, "scope": "session"])
        XCTAssertEqual(B.permissionsResponse(.cancel, requested: requested), ["permissions": [:]])
        XCTAssertEqual(B.toolCallResponse(AgentToolResult(success: false, content: [.text("t"), .image(dataURL: "data:image/png;base64,AA")])),
                       ["success": false, "contentItems": [["type": "inputText", "text": "t"],
                                                           ["type": "inputImage", "imageUrl": "data:image/png;base64,AA"]]])
    }
}
