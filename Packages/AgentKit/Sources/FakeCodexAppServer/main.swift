import Foundation

// A stand-in for `codex app-server` used by AgentKit's tests: newline-delimited JSON-RPC on
// stdin/stdout, no network, no model. It answers the client requests AgentKit sends and plays a
// short script for each turn, chosen by the turn's text:
//
//   tool       sends an item/tool/call, then echoes the reply in an agent message
//   approvals  command, file-change and permissions approvals in turn; echoes the replies
//   misc       currentTime/read and an unsupported request; echoes the replies
//   stream     reasoning and message deltas, several item types, error/warning notices
//   big        a 5 MB message delta, then a tool call whose reply size is echoed
//   crash      exits mid-turn the first time (marker file in FAKE_CODEX_STATE), echoes after that
//   stall      starts the turn and goes silent
//   subagent   announces a child thread, then asks approvals on it and on an unknown thread
//   abandon    sends a tool call and completes the turn without waiting for the answer
//   wait       starts the turn and waits for turn/interrupt
//   anything else: echo the text back
//
// thread/name/set with the name "hang" is never answered; "clear" reports a null name.
//
// Environment: FAKE_CODEX_LOG (append every received message as a JSON line, long strings
// shortened), FAKE_CODEX_STATE (a folder for markers), FAKE_CODEX_SCENARIO ("crashLoop": exit on
// any turn/start or thread/resume; "exitAtStart": exit before reading anything; "ignoreSigterm":
// SIGTERM does nothing, so only SIGKILL stops it).

let env = ProcessInfo.processInfo.environment
let scenario = env["FAKE_CODEX_SCENARIO"] ?? "default"
let logPath = env["FAKE_CODEX_LOG"]
let statePath = env["FAKE_CODEX_STATE"]

if scenario == "ignoreSigterm" { signal(SIGTERM, SIG_IGN) }

if scenario == "exitAtStart" {
    FileHandle.standardError.write(Data("fake codex: refusing to start\n".utf8))
    exit(2)
}

typealias Object = [String: Any]

func send(_ message: Object) {
    guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func shorten(_ value: Any) -> Any {
    switch value {
    case let s as String: return s.count > 500 ? "<\(s.utf8.count) bytes>" : s
    case let a as [Any]: return a.map(shorten)
    case let o as [String: Any]: return o.mapValues(shorten)
    default: return value
    }
}

func log(_ message: Object) {
    guard let logPath else { return }
    let entry: Object = ["pid": Int(getpid()), "msg": shorten(message)]
    guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
    data.append(0x0A)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

func notify(_ method: String, _ params: Object) {
    // The real app server leaves out "jsonrpc"; so do we.
    send(["method": method, "params": params])
}

var nextServerRequest = 0
var awaiting: [String: (Object) -> Void] = [:]

func idText(_ id: Any?) -> String {
    switch id {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    default: return "?"
    }
}

/// Sends a server request and runs `then` with the whole response message.
func serverRequest(_ method: String, _ params: Object, stringID: Bool = false, then: @escaping (Object) -> Void) {
    nextServerRequest += 1
    let id: Any = stringID ? "srv-\(nextServerRequest)" : nextServerRequest
    awaiting[idText(id)] = then
    send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
}

func reply(_ id: Any, _ result: Any) { send(["id": id, "result": result]) }

func jsonText(_ value: Any?) -> String {
    guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

var threadCounter = 0
var turnCounter = 0
var itemCounter = 0
/// Running turn per thread, for interrupt.
var runningTurns: [String: String] = [:]

func newItemID() -> String { itemCounter += 1; return "item-\(itemCounter)" }

func completeTurn(_ threadID: String, _ turnID: String, status: String = "completed", error: String? = nil) {
    runningTurns[threadID] = nil
    var turn: Object = ["id": turnID, "status": status, "items": [Any]()]
    if let error { turn["error"] = ["message": error] }
    notify("turn/completed", ["threadId": threadID, "turn": turn])
}

func agentMessage(_ threadID: String, _ turnID: String, _ text: String, deltas: [String]? = nil) {
    let itemID = newItemID()
    notify("item/started", ["threadId": threadID, "turnId": turnID, "item": ["type": "agentMessage", "id": itemID, "text": ""]])
    for delta in deltas ?? [text] {
        notify("item/agentMessage/delta", ["threadId": threadID, "turnId": turnID, "itemId": itemID, "delta": delta])
    }
    notify("item/completed", ["threadId": threadID, "turnId": turnID, "item": ["type": "agentMessage", "id": itemID, "text": text]])
}

func describeToolReply(_ response: Object) -> String {
    guard let result = response["result"] as? Object else { return "error: \(jsonText(response["error"]))" }
    let success = (result["success"] as? Bool) ?? false
    let parts = ((result["contentItems"] as? [Object]) ?? []).map { item -> String in
        switch item["type"] as? String {
        case "inputText": return "text:\((item["text"] as? String) ?? "")"
        case "inputImage":
            let url = (item["imageUrl"] as? String) ?? ""
            return "image:\(url.hasPrefix("data:image/") ? "data" : "other"):\(url.utf8.count)"
        default: return "unknown"
        }
    }
    return "success=\(success) " + parts.joined(separator: " | ")
}

func savedTurns() -> [Object] {
    [[
        "id": "turn-old-1", "status": "completed",
        "items": [
            ["type": "userMessage", "id": "u1", "content": [["type": "text", "text": "Hello"], ["type": "image", "url": "x"]]],
            ["type": "reasoning", "id": "r1", "summary": ["Thinking about it"], "content": [String]()],
            ["type": "dynamicToolCall", "id": "d1", "tool": "browser_snapshot", "arguments": ["tab": 1], "status": "completed", "success": true],
            ["type": "commandExecution", "id": "c1", "command": "ls", "cwd": "/tmp", "status": "completed", "exitCode": 0,
             "aggregatedOutput": "a\nb", "commandActions": [Any]()],
            ["type": "fileChange", "id": "f1", "changes": [["path": "/tmp/a.txt", "kind": ["type": "add"], "diff": ""]], "status": "declined"],
            ["type": "mcpToolCall", "id": "m1", "server": "docs", "tool": "search", "status": "failed", "arguments": [String: Any]()],
            ["type": "webSearch", "id": "w1", "query": "swift pipes"],
            ["type": "contextCompaction", "id": "cc1"],
            ["type": "agentMessage", "id": "a1", "text": "Hi there"],
        ] as [Any],
    ], [
        "id": "turn-old-2", "status": "failed", "items": [Any](), "error": ["message": "model overloaded"],
    ]]
}

func runTurn(threadID: String, turnID: String, text: String) {
    runningTurns[threadID] = turnID
    notify("turn/started", ["threadId": threadID, "turn": ["id": turnID, "status": "inProgress", "items": [Any]()]])
    notify("item/started", ["threadId": threadID, "turnId": turnID,
                            "item": ["type": "userMessage", "id": newItemID(), "content": [["type": "text", "text": text]]]])
    let command = text.split(separator: " ").first.map(String.init) ?? ""
    switch command {
    case "tool":
        serverRequest("item/tool/call", ["threadId": threadID, "turnId": turnID, "callId": "call-1",
                                         "tool": "browser_snapshot", "arguments": ["selector": "#main", "full": true]]) { response in
            agentMessage(threadID, turnID, describeToolReply(response))
            completeTurn(threadID, turnID)
        }
    case "big":
        let big = String(repeating: "x", count: 5_000_000)
        agentMessage(threadID, turnID, "big", deltas: [big])
        serverRequest("item/tool/call", ["threadId": threadID, "turnId": turnID, "callId": "call-big",
                                         "tool": "browser_screenshot", "arguments": [String: Any]()]) { response in
            agentMessage(threadID, turnID, describeToolReply(response))
            completeTurn(threadID, turnID)
        }
    case "approvals":
        var replies: [String] = []
        serverRequest("item/commandExecution/requestApproval",
                      ["threadId": threadID, "turnId": turnID, "itemId": "cmd-1", "command": "rm -rf build", "cwd": "/tmp/space",
                       "reason": "clean up", "startedAtMs": 1], stringID: true) { r1 in
            replies.append(jsonText(r1["result"] ?? r1["error"]))
            serverRequest("item/fileChange/requestApproval",
                          ["threadId": threadID, "turnId": turnID, "itemId": "fc-1", "reason": "edit notes",
                           "grantRoot": "/tmp/space", "startedAtMs": 2]) { r2 in
                replies.append(jsonText(r2["result"] ?? r2["error"]))
                serverRequest("item/permissions/requestApproval",
                              ["threadId": threadID, "turnId": turnID, "itemId": "perm-1", "cwd": "/tmp/space", "reason": "needs network",
                               "startedAtMs": 3,
                               "permissions": ["network": ["enabled": true],
                                               "fileSystem": ["write": ["/tmp/out"]]]], stringID: true) { r3 in
                    replies.append(jsonText(r3["result"] ?? r3["error"]))
                    agentMessage(threadID, turnID, replies.joined(separator: "\n"))
                    completeTurn(threadID, turnID)
                }
            }
        }
    case "misc":
        serverRequest("currentTime/read", ["threadId": threadID]) { r1 in
            serverRequest("item/tool/requestUserInput", ["threadId": threadID, "turnId": turnID, "itemId": "q", "questions": [Any]()]) { r2 in
                agentMessage(threadID, turnID, jsonText(r1) + "\n" + jsonText(r2))
                completeTurn(threadID, turnID)
            }
        }
    case "stream":
        let reasoningID = newItemID()
        notify("item/started", ["threadId": threadID, "turnId": turnID, "item": ["type": "reasoning", "id": reasoningID, "summary": [String](), "content": [String]()]])
        notify("item/reasoning/summaryTextDelta", ["threadId": threadID, "turnId": turnID, "itemId": reasoningID, "delta": "Plan", "summaryIndex": 0])
        notify("item/completed", ["threadId": threadID, "turnId": turnID, "item": ["type": "reasoning", "id": reasoningID, "summary": ["Plan"], "content": [String]()]])
        notify("error", ["threadId": threadID, "turnId": turnID, "willRetry": true, "error": ["message": "Reconnecting… 1/5"]])
        notify("warning", ["threadId": threadID, "message": "Heads up"])
        notify("configWarning", ["summary": "Odd config", "details": "line 3"])
        notify("deprecationNotice", ["summary": "Old thing"])
        notify("warning", ["message": "  "])
        notify("thread/tokenUsage/updated", ["threadId": threadID, "turnId": turnID])
        notify("item/completed", ["threadId": threadID, "turnId": turnID,
                                  "item": ["type": "commandExecution", "id": "cmd-9", "command": "echo hi", "cwd": "/tmp", "status": "completed",
                                           "exitCode": 0, "aggregatedOutput": "hi\n", "commandActions": [Any]()]])
        agentMessage(threadID, turnID, "Hello", deltas: ["Hel", "lo"])
        completeTurn(threadID, turnID)
    case "crash":
        let marker = statePath.map { ($0 as NSString).appendingPathComponent("crashed") }
        if let marker, !FileManager.default.fileExists(atPath: marker) {
            FileManager.default.createFile(atPath: marker, contents: Data())
            // No trailing newline: the last stderr line must still be reported.
            FileHandle.standardError.write(Data("fake codex: simulated crash".utf8))
            exit(3)
        }
        agentMessage(threadID, turnID, "echo: \(text)")
        completeTurn(threadID, turnID)
    case "subagent":
        let child = "child-of-\(threadID)"
        notify("thread/started", ["thread": ["id": child, "parentThreadId": threadID, "turns": [Any]()]])
        serverRequest("item/commandExecution/requestApproval",
                      ["threadId": child, "turnId": turnID, "itemId": "sub-cmd", "command": "make", "startedAtMs": 1]) { r1 in
            serverRequest("item/commandExecution/requestApproval",
                          ["threadId": "stranger", "turnId": turnID, "itemId": "x-cmd", "command": "curl evil", "startedAtMs": 2]) { r2 in
                agentMessage(threadID, turnID, jsonText(r1["result"]) + "\n" + jsonText(r2["result"]))
                completeTurn(threadID, turnID)
            }
        }
    case "abandon":
        serverRequest("item/tool/call", ["threadId": threadID, "turnId": turnID, "callId": "call-x",
                                         "tool": "browser_click", "arguments": [String: Any]()]) { _ in }
        completeTurn(threadID, turnID)
    case "stall", "wait":
        break
    default:
        agentMessage(threadID, turnID, "echo: \(text)")
        completeTurn(threadID, turnID)
    }
}

func handleRequest(id: Any, method: String, params: Object) {
    switch method {
    case "initialize":
        reply(id, ["userAgent": "fake-codex/0.0", "codexHome": "/tmp/fake", "platformFamily": "unix", "platformOs": "macos"])
    case "model/list":
        if (params["cursor"] as? String) == "page2" {
            reply(id, ["data": [["id": "fake-mini", "model": "fake-mini", "displayName": "Fake Mini", "description": "Small",
                                 "isDefault": false, "hidden": false]],
                       "nextCursor": NSNull()])
        } else {
            reply(id, ["data": [["id": "fake-pro", "model": "fake-pro", "displayName": "Fake Pro", "description": "Big",
                                 "isDefault": true, "hidden": false],
                                ["id": "fake-secret", "model": "fake-secret", "displayName": "Secret", "description": "",
                                 "isDefault": false, "hidden": true]],
                       "nextCursor": "page2"])
        }
    case "thread/start":
        threadCounter += 1
        let threadID = "thread-\(getpid())-\(threadCounter)"
        reply(id, ["thread": ["id": threadID, "name": NSNull(), "turns": [Any]()], "model": (params["model"] as? String) ?? "fake-pro"])
    case "thread/resume":
        if scenario == "crashLoop" { exit(4) }
        let threadID = (params["threadId"] as? String) ?? "?"
        reply(id, ["thread": ["id": threadID, "name": "Saved name", "turns": savedTurns()], "model": (params["model"] as? String) ?? "fake-pro"])
    case "thread/unsubscribe":
        reply(id, ["status": "unsubscribed"])
    case "thread/name/set":
        // "hang" never gets an answer, for testing calls that are pending at shutdown.
        if (params["name"] as? String) == "hang" { return }
        reply(id, [String: Any]())
        let name: Any = (params["name"] as? String).flatMap { $0 == "clear" ? nil : $0 } ?? NSNull()
        notify("thread/name/updated", ["threadId": (params["threadId"] as? String) ?? "?", "threadName": name])
    case "turn/start":
        if scenario == "crashLoop" { exit(5) }
        turnCounter += 1
        let turnID = "turn-\(getpid())-\(turnCounter)"
        let threadID = (params["threadId"] as? String) ?? "?"
        let text = ((params["input"] as? [Object])?.first?["text"] as? String) ?? ""
        reply(id, ["turn": ["id": turnID, "status": "inProgress", "items": [Any]()]])
        runTurn(threadID: threadID, turnID: turnID, text: text)
    case "turn/interrupt":
        let threadID = (params["threadId"] as? String) ?? "?"
        let turnID = (params["turnId"] as? String) ?? "?"
        reply(id, [String: Any]())
        for pending in awaiting.keys.sorted() {
            let requestID: Any = Int(pending).map { $0 as Any } ?? pending
            notify("serverRequest/resolved", ["threadId": threadID, "requestId": requestID])
        }
        awaiting = [:]
        completeTurn(threadID, turnID, status: "interrupted")
    default:
        send(["id": id, "error": ["code": -32601, "message": "fake: unknown method \(method)"]])
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let message = (try? JSONSerialization.jsonObject(with: data)) as? Object else { continue }
    log(message)
    if let method = message["method"] as? String {
        if let id = message["id"] {
            handleRequest(id: id, method: method, params: (message["params"] as? Object) ?? [:])
        }
        // Notifications (initialized) need no answer.
    } else if let id = message["id"], let then = awaiting.removeValue(forKey: idText(id)) {
        then(message)
    }
}
