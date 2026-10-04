import Foundation

// The panel's view of an agent backend. Codex's app server is the first (`CodexAppServerBackend`);
// Claude Code, agy, opencode or an API key plug in behind the same protocol later. Nothing here
// knows about browsers: iSmith hands its browser tools in as `AgentToolSpec`s and answers their
// calls through `AgentBackendHandler`.

/// A space's permission mode (AGENT_PANEL.md). The backend maps it to its own sandbox and
/// approval settings; the app enforces it for browser tools.
public enum AgentMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case readOnly
    case ask
    case confirmSubmits
    case yolo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .readOnly: return "Read-only"
        case .ask: return "Ask"
        case .confirmSubmits: return "Confirm submits"
        case .yolo: return "YOLO"
        }
    }

    /// Unknown names (from a newer version) read as the safest mode.
    public init(from decoder: Decoder) throws {
        self = AgentMode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .readOnly
    }
}

/// A tool the app defines for the agent (a Codex dynamic tool).
public struct AgentToolSpec: Equatable, Sendable {
    public var name: String
    public var description: String
    /// A JSON Schema object for the arguments.
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        (self.name, self.description, self.inputSchema) = (name, description, inputSchema)
    }
}

/// How a thread is started or resumed.
public struct AgentThreadOptions: Equatable, Sendable {
    /// The working folder for shell commands and file edits (the space's folder).
    public var cwd: String
    /// nil: the backend's default model.
    public var model: String?
    public var mode: AgentMode
    /// Added to the backend's own instructions (what iSmith is, how to use its tools).
    public var developerInstructions: String
    /// Only used when a thread starts; a resumed thread keeps the tools it was started with.
    public var tools: [AgentToolSpec]
    /// Extra backend config sent when the thread starts or resumes (Codex: merged into `config`,
    /// e.g. `"mcp_servers.<name>.enabled": false`). The backend's own keys win on a clash, so this
    /// can't turn back on what the backend turns off.
    public var extraConfig: [String: JSONValue]

    public init(cwd: String, model: String? = nil, mode: AgentMode, developerInstructions: String, tools: [AgentToolSpec],
                extraConfig: [String: JSONValue] = [:]) {
        (self.cwd, self.model, self.mode, self.developerInstructions, self.tools) = (cwd, model, mode, developerInstructions, tools)
        self.extraConfig = extraConfig
    }
}

/// Per-turn settings: the mode can change between turns.
public struct AgentTurnSettings: Equatable, Sendable {
    public var cwd: String
    public var model: String?
    public var mode: AgentMode

    public init(cwd: String, model: String? = nil, mode: AgentMode) {
        (self.cwd, self.model, self.mode) = (cwd, model, mode)
    }
}

/// A model the backend offers (`model/list`).
public struct AgentModel: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var description: String
    public var isDefault: Bool

    public init(id: String, displayName: String, description: String = "", isDefault: Bool = false) {
        (self.id, self.displayName, self.description, self.isDefault) = (id, displayName, description, isDefault)
    }
}

/// One thing in a thread: a message, a tool call, a command, a file change.
public struct AgentItem: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable {
        case inProgress, completed, failed, declined
    }

    public enum Kind: Equatable, Sendable {
        case userMessage(text: String)
        case agentMessage(text: String)
        /// Reasoning summary lines, if the backend shares them.
        case reasoning(summary: [String])
        /// One of the app's tools (a Codex dynamic tool call).
        case toolCall(tool: String, arguments: JSONValue, status: Status, success: Bool?)
        case command(command: String, cwd: String?, status: Status, exitCode: Int?, output: String?)
        case fileChange(paths: [String], status: Status)
        /// A tool from one of the backend's own servers (MCP).
        case mcpToolCall(server: String, tool: String, status: Status)
        case webSearch(query: String)
        /// Anything else, by the backend's own type name.
        case other(type: String)
    }

    public var id: String
    public var kind: Kind

    public init(id: String, kind: Kind) {
        (self.id, self.kind) = (id, kind)
    }
}

public enum AgentTurnStatus: String, Equatable, Sendable {
    case inProgress, completed, interrupted, failed
}

/// A finished (or running) turn as the backend has it, for showing a resumed thread.
public struct AgentTurnRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var status: AgentTurnStatus
    public var items: [AgentItem]
    public var error: String?

    public init(id: String, status: AgentTurnStatus, items: [AgentItem], error: String? = nil) {
        (self.id, self.status, self.items, self.error) = (id, status, items, error)
    }
}

/// A thread after `startThread` or `resumeThread`.
public struct AgentThreadInfo: Equatable, Sendable {
    public var id: String
    /// The model the thread runs on now.
    public var model: String?
    public var name: String?
    /// Earlier turns (filled in by `resumeThread`; empty for a new thread).
    public var turns: [AgentTurnRecord]

    public init(id: String, model: String?, name: String? = nil, turns: [AgentTurnRecord] = []) {
        (self.id, self.model, self.name, self.turns) = (id, model, name, turns)
    }
}

/// The agent asks to use one of the app's tools.
public struct AgentToolCall: Equatable, Sendable {
    public var threadID: String
    public var turnID: String
    public var callID: String
    public var tool: String
    public var arguments: JSONValue
    /// The backend's id for this request (Codex: the JSON-RPC id, as text). It is the id that
    /// `AgentEvent.requestResolved` carries when the backend withdraws the call, so the app can
    /// dismiss the matching card. Defaults to `callID`.
    public var requestID: String

    public init(threadID: String, turnID: String, callID: String, tool: String, arguments: JSONValue, requestID: String? = nil) {
        (self.threadID, self.turnID, self.callID, self.tool, self.arguments) = (threadID, turnID, callID, tool, arguments)
        self.requestID = requestID ?? callID
    }
}

/// What a tool call returns to the agent.
public struct AgentToolResult: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case text(String)
        /// A `data:image/png;base64,…` URL.
        case image(dataURL: String)
    }

    public var success: Bool
    public var content: [Content]

    public init(success: Bool, content: [Content]) {
        (self.success, self.content) = (success, content)
    }

    public static func text(_ text: String, success: Bool = true) -> AgentToolResult {
        AgentToolResult(success: success, content: [.text(text)])
    }
}

/// The backend asks the user to approve a command, a file change or extra permissions.
public struct AgentApprovalRequest: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case command(command: String?, cwd: String?, reason: String?)
        case fileChange(reason: String?, grantRoot: String?)
        /// Extra sandbox permissions (file system or network); `summary` describes them.
        case permissions(reason: String?, summary: String)
    }

    /// Unique for this request (the JSON-RPC request id, as text).
    public var id: String
    public var threadID: String
    public var turnID: String
    public var itemID: String
    public var kind: Kind

    public init(id: String, threadID: String, turnID: String, itemID: String, kind: Kind) {
        (self.id, self.threadID, self.turnID, self.itemID, self.kind) = (id, threadID, turnID, itemID, kind)
    }
}

public enum AgentApprovalDecision: String, Equatable, Sendable {
    /// Allow this one.
    case accept
    /// Allow this and the same kind of request for the rest of the session.
    case acceptForSession
    /// Refuse; the agent carries on.
    case decline
    /// Refuse and stop the turn.
    case cancel
}

/// The backend process's state, for the panel.
public enum AgentBackendStatus: Equatable, Sendable {
    case stopped
    case starting
    case ready
    /// The process died or stopped responding and is starting again; threads are resumed.
    case restarting(reason: String)
    /// It couldn't start (or keeps dying); `reason` says why.
    case failed(reason: String)
    /// The backend's program isn't installed.
    case notInstalled
}

/// What the backend reports while it runs.
public enum AgentEvent: Equatable, Sendable {
    case status(AgentBackendStatus)
    case turnStarted(threadID: String, turnID: String)
    case turnCompleted(threadID: String, turnID: String, status: AgentTurnStatus, error: String?)
    case itemStarted(threadID: String, turnID: String, item: AgentItem)
    case itemCompleted(threadID: String, turnID: String, item: AgentItem)
    /// Streamed text of an agent message.
    case messageDelta(threadID: String, turnID: String, itemID: String, delta: String)
    /// Streamed reasoning summary text.
    case reasoningDelta(threadID: String, turnID: String, itemID: String, delta: String)
    /// A problem the backend reported (a failed model request, a retry).
    case error(threadID: String?, turnID: String?, message: String, willRetry: Bool)
    /// A notice worth showing (a warning, a deprecation).
    case notice(threadID: String?, message: String)
    case threadNameChanged(threadID: String, name: String)
    /// A request the app was answering (a tool call or an approval) was settled or withdrawn by
    /// the backend (the turn was interrupted, the process restarted): any card for it goes away.
    case requestResolved(requestID: String)
}

/// How the app answers the backend. Every closure may be called from any thread.
///
/// `toolCall` and `approval` run in their own task, which is cancelled when the backend withdraws
/// the request (it was resolved, its turn ended, or the process stopped); a handler should check
/// `Task.isCancelled` before doing anything with side effects. Its answer is then dropped.
public struct AgentBackendHandler: Sendable {
    public var toolCall: @Sendable (AgentToolCall) async -> AgentToolResult
    public var approval: @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision
    public var event: @Sendable (AgentEvent) -> Void

    public init(toolCall: @escaping @Sendable (AgentToolCall) async -> AgentToolResult,
                approval: @escaping @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision,
                event: @escaping @Sendable (AgentEvent) -> Void) {
        (self.toolCall, self.approval, self.event) = (toolCall, approval, event)
    }
}

public enum AgentBackendError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The backend's program wasn't found.
    case notInstalled(String)
    /// The process couldn't start or exited.
    case processExited(String)
    /// The backend answered a request with an error.
    case requestFailed(method: String, message: String)
    /// The backend's answer wasn't what the protocol says.
    case badResponse(method: String, detail: String)
    /// `start()` hasn't been called, or `shutdown()` has.
    case notRunning

    public var description: String {
        switch self {
        case let .notInstalled(what): return what
        case let .processExited(why): return why
        case let .requestFailed(method, message): return "\(method) failed: \(message)"
        case let .badResponse(method, detail): return "Unexpected answer to \(method): \(detail)"
        case .notRunning: return "The agent isn't running."
        }
    }
}

/// An agent backend: one long-lived process (or connection) that runs many threads.
///
/// No caps: turns, time and tokens are unlimited. Failure is detected by liveness (the process
/// exits, or a turn goes a long time with no events while nothing waits on the app); the backend
/// then restarts and resumes its threads, and reports the running turn as failed.
public protocol AgentBackend: AnyObject, Sendable {
    /// "Codex".
    var displayName: String { get }

    /// Starts the process and handshakes. Calling it again while running does nothing.
    func start() async throws
    /// Stops the process. Pending calls fail with `notRunning`.
    func shutdown() async

    func models() async throws -> [AgentModel]
    func startThread(_ options: AgentThreadOptions) async throws -> AgentThreadInfo
    /// Loads a saved thread (with its earlier turns) so new turns can run on it.
    func resumeThread(id: String, options: AgentThreadOptions) async throws -> AgentThreadInfo
    func setThreadName(id: String, name: String) async throws
    /// Starts a turn with the user's text; returns the turn id. Events follow through the handler.
    func startTurn(threadID: String, text: String, settings: AgentTurnSettings) async throws -> String
    func interruptTurn(threadID: String, turnID: String) async throws
}
