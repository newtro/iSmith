import Foundation

// How AgentKit's types map onto the Codex app-server protocol (codex-cli 0.160, experimental API):
// request params we send, and the results and notifications we read back. Kept apart from the
// process and liveness logic so the mapping can be unit-tested on its own.

extension CodexAppServerBackend {
    // MARK: Mode mapping

    /// The `sandbox` value for `thread/start` and `thread/resume`.
    public static func sandboxMode(for mode: AgentMode) -> String {
        switch mode {
        case .readOnly: return "read-only"
        case .ask, .confirmSubmits: return "workspace-write"
        case .yolo: return "danger-full-access"
        }
    }

    /// The `sandboxPolicy` object for `turn/start`. Workspace-write may write only the space's
    /// folder and has no network (a command that needs either asks for permission).
    public static func sandboxPolicy(for mode: AgentMode, cwd: String) -> JSONValue {
        switch mode {
        case .readOnly: return ["type": "readOnly"]
        case .ask, .confirmSubmits:
            return ["type": "workspaceWrite", "writableRoots": .array([.string(cwd)]), "networkAccess": false]
        case .yolo: return ["type": "dangerFullAccess"]
        }
    }

    /// The `approvalPolicy` value. Read-only and Ask use "untrusted": anything beyond Codex's
    /// known-safe reads asks (and in Read-only the backend itself declines). Confirm submits lets
    /// the model run sandboxed commands and ask when it needs more.
    public static func approvalPolicy(for mode: AgentMode) -> String {
        switch mode {
        case .readOnly, .ask: return "untrusted"
        case .confirmSubmits: return "on-request"
        case .yolo: return "never"
        }
    }

    /// Config overrides for `thread/start` and `thread/resume` (dotted keys are accepted).
    ///
    /// Codex's own computer-use and browser features are off: in iSmith the browser is driven
    /// through the app's tools, under the space's mode. Notifications go to the panel, not to a
    /// `notify` program, and the unstable-features warning is silenced because we turn
    /// experimental features off on purpose. Read-only also drops the shell tool; every mode but
    /// YOLO drops connected apps and plugins, which would act outside the space's rules.
    public static func codexConfig(for mode: AgentMode) -> JSONValue {
        var config: [String: JSONValue] = [
            "features.computer_use": false,
            "features.browser_use": false,
            "features.browser_use_external": false,
            "features.in_app_browser": false,
            // Page text must not carry over into the user's other Codex sessions.
            "features.memories": false,
            "notify": .array([]),
            "suppress_unstable_features_warning": true,
        ]
        if mode == .readOnly {
            config["features.shell_tool"] = false
            config["features.unified_exec"] = false
        }
        if mode != .yolo {
            config["features.apps"] = false
            config["features.plugins"] = false
            // A search query is a way out for what the agent read; outside YOLO it's off.
            config["web_search"] = "disabled"
        }
        return .object(config)
    }

    /// `codexConfig(for:)` plus the thread's `extraConfig`; our keys win on a clash.
    public static func threadConfig(for mode: AgentMode, extra: [String: JSONValue]) -> JSONValue {
        guard case let .object(own) = codexConfig(for: mode) else { return codexConfig(for: mode) }
        var extra = extra
        // A nested `"features": {...}` table must not sneak back what the dotted keys turn off.
        if case var .object(features)? = extra["features"] {
            for key in own.keys where key.hasPrefix("features.") { features[String(key.dropFirst("features.".count))] = nil }
            extra["features"] = .object(features)
        }
        return .object(extra.merging(own) { _, ours in ours })
    }

    // MARK: Request params

    static func initializeParams(clientName: String, clientVersion: String) -> JSONValue {
        ["clientInfo": ["name": .string(clientName), "version": .string(clientVersion)],
         "capabilities": ["experimentalApi": true]]
    }

    static func threadStartParams(_ options: AgentThreadOptions, serviceName: String) -> JSONValue {
        var params = commonThreadParams(options)
        params["dynamicTools"] = .array(options.tools.map { tool in
            ["type": "function", "name": .string(tool.name), "description": .string(tool.description),
             "inputSchema": tool.inputSchema]
        })
        params["serviceName"] = .string(serviceName)
        return .object(params)
    }

    /// No `dynamicTools`: a thread keeps the tools it was started with, even in a new process.
    static func threadResumeParams(threadID: String, options: AgentThreadOptions) -> JSONValue {
        var params = commonThreadParams(options)
        params["threadId"] = .string(threadID)
        return .object(params)
    }

    private static func commonThreadParams(_ options: AgentThreadOptions) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "cwd": .string(options.cwd),
            "sandbox": .string(sandboxMode(for: options.mode)),
            "approvalPolicy": .string(approvalPolicy(for: options.mode)),
            "developerInstructions": .string(options.developerInstructions),
            "config": threadConfig(for: options.mode, extra: options.extraConfig),
        ]
        if let model = options.model { params["model"] = .string(model) }
        return params
    }

    static func turnStartParams(threadID: String, text: String, settings: AgentTurnSettings) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": [["type": "text", "text": .string(text)]],
            "cwd": .string(settings.cwd),
            "approvalPolicy": .string(approvalPolicy(for: settings.mode)),
            "sandboxPolicy": sandboxPolicy(for: settings.mode, cwd: settings.cwd),
        ]
        if let model = settings.model { params["model"] = .string(model) }
        return .object(params)
    }

    // MARK: Results

    /// `thread/start` and `thread/resume` results: `{"thread": {...}, "model": ...}`.
    static func threadInfo(from result: JSONValue, method: String) throws -> AgentThreadInfo {
        guard let thread = result["thread"], let id = thread["id"]?.stringValue else {
            throw AgentBackendError.badResponse(method: method, detail: "no thread id")
        }
        let turns = (thread["turns"]?.arrayValue ?? []).compactMap(turnRecord(from:))
        return AgentThreadInfo(id: id, model: result["model"]?.stringValue, name: thread["name"]?.stringValue, turns: turns)
    }

    static func turnRecord(from turn: JSONValue) -> AgentTurnRecord? {
        guard let id = turn["id"]?.stringValue else { return nil }
        let items = (turn["items"]?.arrayValue ?? []).compactMap(item(from:))
        return AgentTurnRecord(id: id, status: turnStatus(turn["status"]), items: items,
                               error: turn["error"]?["message"]?.stringValue)
    }

    static func turnStatus(_ value: JSONValue?) -> AgentTurnStatus {
        value?.stringValue.flatMap(AgentTurnStatus.init(rawValue:)) ?? .completed
    }

    /// A `model/list` page: visible models, plus the cursor for the next page if there is one.
    static func modelPage(from result: JSONValue) -> (models: [AgentModel], nextCursor: String?) {
        let models: [AgentModel] = (result["data"]?.arrayValue ?? []).compactMap { entry in
            guard entry["hidden"]?.boolValue != true,
                  let id = entry["id"]?.stringValue ?? entry["model"]?.stringValue else { return nil }
            return AgentModel(id: id, displayName: entry["displayName"]?.stringValue ?? id,
                              description: entry["description"]?.stringValue ?? "",
                              isDefault: entry["isDefault"]?.boolValue ?? false)
        }
        let cursor = result["nextCursor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return (models, cursor)
    }

    /// A `ThreadItem` → `AgentItem`; nil if it has no id.
    static func item(from item: JSONValue) -> AgentItem? {
        guard let id = item["id"]?.stringValue else { return nil }
        let type = item["type"]?.stringValue ?? "unknown"
        func status() -> AgentItem.Status {
            item["status"]?.stringValue.flatMap(AgentItem.Status.init(rawValue:)) ?? .inProgress
        }
        let kind: AgentItem.Kind
        switch type {
        case "userMessage":
            let parts = (item["content"]?.arrayValue ?? []).compactMap { part -> String? in
                part["type"]?.stringValue == "text" ? part["text"]?.stringValue : nil
            }
            kind = .userMessage(text: parts.joined(separator: "\n"))
        case "agentMessage":
            kind = .agentMessage(text: item["text"]?.stringValue ?? "")
        case "reasoning":
            kind = .reasoning(summary: (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue))
        case "dynamicToolCall":
            kind = .toolCall(tool: item["tool"]?.stringValue ?? "", arguments: item["arguments"] ?? .null,
                             status: status(), success: item["success"]?.boolValue)
        case "commandExecution":
            kind = .command(command: item["command"]?.stringValue ?? "", cwd: item["cwd"]?.stringValue, status: status(),
                            exitCode: item["exitCode"]?.intValue, output: item["aggregatedOutput"]?.stringValue)
        case "fileChange":
            kind = .fileChange(paths: (item["changes"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue },
                               status: status())
        case "mcpToolCall":
            kind = .mcpToolCall(server: item["server"]?.stringValue ?? "", tool: item["tool"]?.stringValue ?? "",
                                status: status())
        case "webSearch":
            kind = .webSearch(query: item["query"]?.stringValue ?? "")
        default:
            kind = .other(type: type)
        }
        return AgentItem(id: id, kind: kind)
    }

    // MARK: Server requests

    /// The reply to an `item/tool/call` request.
    static func toolCallResponse(_ result: AgentToolResult) -> JSONValue {
        let items: [JSONValue] = result.content.map { content in
            switch content {
            case let .text(text): return ["type": "inputText", "text": .string(text)]
            case let .image(url): return ["type": "inputImage", "imageUrl": .string(url)]
            }
        }
        return ["success": .bool(result.success), "contentItems": .array(items)]
    }

    /// The reply to a command or file-change approval request.
    static func decisionResponse(_ decision: AgentApprovalDecision) -> JSONValue {
        ["decision": .string(decision.rawValue)]
    }

    /// The reply to `item/permissions/requestApproval`: the requested profile when granted (for
    /// this turn, or the session), an empty grant otherwise.
    static func permissionsResponse(_ decision: AgentApprovalDecision, requested: JSONValue) -> JSONValue {
        switch decision {
        case .accept: return ["permissions": requested, "scope": "turn"]
        case .acceptForSession: return ["permissions": requested, "scope": "session"]
        case .decline, .cancel: return ["permissions": .object([:])]
        }
    }

    /// A short description of a requested permission profile for the approval card, e.g.
    /// "Network access; write: /Users/me/project; read: /etc/hosts".
    static func permissionsSummary(_ permissions: JSONValue) -> String {
        var parts: [String] = []
        if permissions["network"]?["enabled"]?.boolValue == true { parts.append("Network access") }
        if let fs = permissions["fileSystem"] {
            var byAccess: [String: [String]] = [:]
            for path in fs["write"]?.arrayValue ?? [] { if let p = path.stringValue { byAccess["write", default: []].append(p) } }
            for path in fs["read"]?.arrayValue ?? [] { if let p = path.stringValue { byAccess["read", default: []].append(p) } }
            for entry in fs["entries"]?.arrayValue ?? [] {
                guard let access = entry["access"]?.stringValue, let path = entry["path"] else { continue }
                let text: String?
                switch path["type"]?.stringValue {
                case "path": text = path["path"]?.stringValue
                case "glob_pattern": text = path["pattern"]?.stringValue
                case "special":
                    let kind = path["value"]?["kind"]?.stringValue ?? "special"
                    text = path["value"]?["path"]?.stringValue ?? kind.replacingOccurrences(of: "_", with: " ")
                default: text = path.stringValue
                }
                if let text { byAccess[access, default: []].append(text) }
            }
            for access in ["write", "read", "deny"] {
                if let paths = byAccess[access], !paths.isEmpty {
                    parts.append("\(access): \(paths.joined(separator: ", "))")
                }
            }
        }
        return parts.isEmpty ? "Extra sandbox permissions" : parts.joined(separator: "; ")
    }

    /// Text of a `warning`, `configWarning`, `deprecationNotice` or similar notification.
    static func noticeText(_ params: JSONValue) -> String? {
        let text = params["message"]?.stringValue ?? params["summary"]?.stringValue ?? params["details"]?.stringValue
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
