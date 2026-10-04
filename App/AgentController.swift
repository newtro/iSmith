import AgentKit
import AppKit
import BrowserData
import Combine
import Foundation

/// Where a window shows the agent panel (the toolbar's dock control; per window, saved with the
/// session).
enum AgentDock: String, Codable, CaseIterable {
    case right, bottom, hidden

    static let defaultsKey = "agentDock"

    /// The last choice, for new windows. The panel starts on the right.
    static var preferred: AgentDock {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AgentDock.init(rawValue:)) ?? .right }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    init(from decoder: Decoder) throws {
        self = AgentDock(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .right
    }
}

/// One line in a chat: what the user said, what the agent said, a run of steps (tool calls,
/// commands, edits), or a problem.
struct AgentEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case agent(String)
        case steps([AgentStep])
        case problem(String)
        case notice(String)
    }

    let id: String
    var kind: Kind
}

struct AgentStep: Identifiable, Equatable {
    let id: String
    var title: String
    var status: AgentItem.Status
}

/// A question waiting in the panel: approve a browser action or a command, or sign in.
@MainActor
final class AgentCard: ObservableObject, Identifiable {
    enum Kind {
        case browser(BrowserApprovalRequest)
        case backend(AgentApprovalRequest)
        case handOff(HandOffRequest)
    }

    enum Answer {
        case allow, allowForSession, deny, proceed, stop
    }

    let id: String
    let kind: Kind
    let threadID: String
    /// The backend request it answers (directly, or through a tool call), if any.
    let requestID: String?
    private var resolver: ((Answer) -> Void)?

    init(id: String, kind: Kind, threadID: String, requestID: String? = nil, resolve: @escaping (Answer) -> Void) {
        (self.id, self.kind, self.threadID, self.requestID, resolver) = (id, kind, threadID, requestID, resolve)
    }

    func answer(_ answer: Answer) {
        let r = resolver
        resolver = nil
        r?(answer)
    }

    var isOpen: Bool { resolver != nil }
}

/// One space's agent: its settings, its chat threads, the chat on screen and the questions
/// waiting for the user. Every window showing the space shares it.
@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let spaceID: String
    nonisolated var id: String { spaceID }
    @Published var mode: AgentMode
    /// nil: the backend's default model.
    @Published var model: String?
    @Published var workingFolder: String
    @Published private(set) var threads: [AgentThreadRecord] = []
    @Published var threadID: String?
    @Published var entries: [AgentEntry] = []
    @Published var turnID: String?
    /// The model the chat on screen runs on (as the backend reports it).
    @Published var activeModel: String?
    /// Sending or loading (before a turn starts).
    @Published var busy = false
    @Published var cards: [AgentCard] = []
    @Published var draft = ""
    @Published private(set) var activity: [AgentActivity] = []
    /// The chat's text streamed so far, by item.
    var streaming: [String: String] = [:]
    var loadingThread = false
    private weak var store: AgentStore?
    private var observer: NSObjectProtocol?

    init(spaceID: String, store: AgentStore?, defaultMode: AgentMode, defaultFolder: String) {
        self.spaceID = spaceID
        self.store = store
        let saved = try? store?.settings(space: spaceID)
        mode = saved?.mode.flatMap(AgentMode.init(rawValue:)) ?? defaultMode
        model = saved?.model
        workingFolder = saved?.workingFolder ?? defaultFolder
        reload()
        observer = NotificationCenter.default.addObserver(forName: AgentStore.didChange, object: nil, queue: .main) { [weak self] note in
            let spaces = note.userInfo?[BrowserDatabase.spacesKey] as? [String]
            MainActor.assumeIsolated {
                guard let self, spaces == nil || spaces?.contains(self.spaceID) == true else { return }
                self.reload()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var running: Bool { turnID != nil || busy }
    var currentThread: AgentThreadRecord? { threads.first { $0.id == threadID } }

    func reload() {
        threads = (try? store?.threads(space: spaceID)) ?? []
        activity = (try? store?.activity(space: spaceID, limit: 300)) ?? []
    }

    func saveSettings() {
        try? store?.saveSettings(AgentSpaceSettings(space: spaceID, mode: mode.rawValue, workingFolder: workingFolder, model: model))
    }
}

/// The agent panel's engine: one backend process (Codex's app server) for the app, a session per
/// space, and the bridge between the backend's tool calls and approvals and the browser tools
/// and the panel's cards.
@MainActor
final class AgentController: ObservableObject, AgentToolHost {
    private weak var browser: BrowserState?
    let tools: AgentBrowserTools
    @Published private(set) var status: AgentBackendStatus = .stopped
    @Published private(set) var models: [AgentModel] = []
    /// What the backend said when it last failed to start or answer, for the panel.
    @Published private(set) var problem: String?
    private var backend: AgentBackend?
    private var starting: Task<Bool, Never>?
    private var sessions: [String: AgentSession] = [:]
    /// Thread id → space, for routing the backend's events and calls.
    private var threadSpace: [String: String] = [:]
    /// Threads loaded into the running backend process.
    private var loaded: Set<String> = []
    /// Makes the backend; tests put a fake here.
    var makeBackend: (AgentBackendHandler) -> AgentBackend? = { handler in
        CodexAppServerBackend(clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1",
                              handler: handler)
    }

    /// The mode a space starts in (Settings ▸ Agents). YOLO, as Scott chose.
    static let defaultModeKey = "agentDefaultMode"
    static var defaultMode: AgentMode {
        get { UserDefaults.standard.string(forKey: defaultModeKey).flatMap(AgentMode.init(rawValue:)) ?? .yolo }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultModeKey) }
    }

    init(browser: BrowserState) {
        self.browser = browser
        tools = AgentBrowserTools(browser: browser)
        tools.host = self
    }

    func session(_ spaceID: String) -> AgentSession {
        if let s = sessions[spaceID] { return s }
        let s = AgentSession(spaceID: spaceID, store: browser?.data?.agent, defaultMode: Self.defaultMode,
                             defaultFolder: defaultFolder(for: spaceID).path)
        sessions[spaceID] = s
        return s
    }

    var backendName: String { backend?.displayName ?? "Codex" }

    // MARK: - Backend

    /// Starts the backend if it isn't running and loads its models. Returns false if it can't run.
    @discardableResult
    func prepare() async -> Bool {
        if case .ready = status, backend != nil { return true }
        if let starting { return await starting.value }
        let task = Task { () -> Bool in
            defer { self.starting = nil }
            if backend == nil {
                let handler = AgentBackendHandler(
                    toolCall: { [weak self] call in
                        guard let self else { return .text("The browser is closing.", success: false) }
                        return await self.handleToolCall(call)
                    },
                    approval: { [weak self] request in
                        guard let self else { return .decline }
                        return await self.handleApproval(request)
                    },
                    event: { [weak self] event in
                        Task { @MainActor in self?.handle(event) }
                    })
                backend = makeBackend(handler)
            }
            guard let backend else {
                status = .notInstalled
                return false
            }
            do {
                try await backend.start()
                status = .ready
                problem = nil
                if models.isEmpty { models = (try? await backend.models()) ?? [] }
                return true
            } catch let error as AgentBackendError {
                if case .notInstalled = error { status = .notInstalled } else { status = .failed(reason: error.description) }
                problem = error.description
                return false
            } catch {
                status = .failed(reason: error.localizedDescription)
                problem = error.localizedDescription
                return false
            }
        }
        starting = task
        return await task.value
    }

    /// "Check Again" after installing Codex, or "Try Again" after a failure.
    func retry() {
        backend = nil
        loaded = []
        status = .stopped
        Task { await prepare() }
    }

    func shutdown() async {
        await backend?.shutdown()
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case let .status(s):
            status = s
            if case .restarting = s {
                // The backend resumes its threads itself; the turn that was running has failed.
                for session in sessions.values { session.busy = false }
            }
        case let .turnStarted(threadID, turnID):
            guard let session = session(of: threadID), session.threadID == threadID else { return }
            session.turnID = turnID
            session.busy = false
        case let .turnCompleted(threadID, turnID, status, error):
            guard let session = session(of: threadID) else { return }
            if session.turnID == turnID || session.turnID == nil { session.turnID = nil }
            session.busy = false
            session.streaming = [:]
            closeCards(in: session, thread: threadID, answer: .stop)
            try? browser?.data?.agent.touchThread(id: threadID)
            guard session.threadID == threadID else { return }
            switch status {
            case .failed: append(.problem(error ?? "The turn failed."), to: session)
            case .interrupted: append(.notice("Stopped."), to: session)
            default: break
            }
        case let .itemStarted(threadID, _, item), let .itemCompleted(threadID, _, item):
            guard let session = session(of: threadID), session.threadID == threadID else { return }
            apply(item, to: session)
        case let .messageDelta(threadID, _, itemID, delta):
            guard let session = session(of: threadID), session.threadID == threadID else { return }
            let text = (session.streaming[itemID] ?? "") + delta
            session.streaming[itemID] = text
            upsert(AgentEntry(id: itemID, kind: .agent(text)), in: session)
        case .reasoningDelta:
            break
        case let .error(threadID, _, message, willRetry):
            guard let threadID, let session = session(of: threadID), session.threadID == threadID else {
                problem = message
                return
            }
            append(willRetry ? .notice("\(message) Retrying…") : .problem(message), to: session)
        case let .notice(threadID, message):
            if let threadID, let session = session(of: threadID), session.threadID == threadID {
                append(.notice(message), to: session)
            }
        case let .threadNameChanged(threadID, name):
            try? browser?.data?.agent.renameThread(id: threadID, name: name)
        case let .requestResolved(requestID):
            for session in sessions.values {
                for card in session.cards where card.requestID == requestID { card.answer(.stop) }
                session.cards.removeAll { $0.requestID == requestID }
            }
        }
    }

    private func session(of threadID: String) -> AgentSession? {
        threadSpace[threadID].map(session)
    }

    // MARK: - Chats

    func newChat(in spaceID: String) {
        let session = session(spaceID)
        guard !session.running else { return }
        session.threadID = nil
        session.entries = []
        session.streaming = [:]
        session.activeModel = nil
    }

    /// Shows a saved chat: the backend loads it (with its earlier turns) so it can continue.
    func openThread(_ id: String, in spaceID: String) {
        let session = session(spaceID)
        guard !session.running, session.threadID != id else { return }
        session.threadID = id
        session.entries = []
        session.streaming = [:]
        threadSpace[id] = spaceID
        session.loadingThread = true
        Task {
            defer { session.loadingThread = false }
            guard await prepare(), let backend else { return }
            do {
                let info = try await backend.resumeThread(id: id, options: options(for: session))
                loaded.insert(id)
                guard session.threadID == id else { return }
                session.entries = Self.entries(from: info.turns)
                session.activeModel = info.model
            } catch {
                if session.threadID == id { append(.problem("This chat couldn't be opened: \(error)"), to: session) }
            }
        }
    }

    func removeThread(_ id: String, in spaceID: String) {
        try? browser?.data?.agent.removeThread(id: id)
        if session(spaceID).threadID == id { newChat(in: spaceID) }
    }

    /// Sends the user's message: starts a chat if there's none (named after the message), loads
    /// a saved one if needed, then starts a turn.
    func send(_ text: String, in spaceID: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = session(spaceID)
        guard !text.isEmpty, !session.running else { return }
        session.busy = true
        session.draft = ""
        append(.user(text), to: session)
        Task {
            guard await prepare(), let backend else {
                session.busy = false
                append(.problem(problem ?? "The agent couldn't start."), to: session)
                return
            }
            do {
                let threadID: String
                if let current = session.threadID {
                    threadID = current
                    if !loaded.contains(current) {
                        _ = try await backend.resumeThread(id: current, options: options(for: session))
                        loaded.insert(current)
                    }
                } else {
                    let info = try await backend.startThread(options(for: session))
                    threadID = info.id
                    threadSpace[threadID] = spaceID
                    loaded.insert(threadID)
                    session.threadID = threadID
                    session.activeModel = info.model
                    let name = Self.name(for: text)
                    try? browser?.data?.agent.saveThread(AgentThreadRecord(id: threadID, space: spaceID, backend: "codex",
                                                                           name: name, model: info.model))
                    Task { try? await backend.setThreadName(id: threadID, name: name) }
                }
                threadSpace[threadID] = spaceID
                let turn = try await backend.startTurn(threadID: threadID, text: text,
                                                       settings: AgentTurnSettings(cwd: session.workingFolder, model: session.model, mode: session.mode))
                if session.threadID == threadID, session.busy { session.turnID = turn }
                session.busy = false
                try? browser?.data?.agent.touchThread(id: threadID)
            } catch {
                session.busy = false
                append(.problem("\(error)"), to: session)
            }
        }
    }

    /// Stop: interrupts the turn, and every question waiting in the panel is answered "no".
    func stop(in spaceID: String) {
        let session = session(spaceID)
        if let threadID = session.threadID { closeCards(in: session, thread: threadID, answer: .stop) }
        guard let threadID = session.threadID, let turnID = session.turnID, let backend else {
            session.busy = false
            return
        }
        Task { try? await backend.interruptTurn(threadID: threadID, turnID: turnID) }
    }

    func setMode(_ mode: AgentMode, in spaceID: String) {
        let session = session(spaceID)
        let stricter = AgentMode.allCases.firstIndex(of: mode)! < AgentMode.allCases.firstIndex(of: session.mode)!
        session.mode = mode
        session.saveSettings()
        // The browser tools follow the new mode at once; Codex's sandbox and approvals for the
        // turn already running don't, so a stricter mode stops it.
        if stricter, session.turnID != nil {
            append(.notice("The mode changed to \(mode.title), so the running turn was stopped. Send a message to continue."), to: session)
            stop(in: spaceID)
        }
        // The next message loads the chat again with the new mode's thread settings (which of
        // Codex's own servers and tools are on); each turn also carries the mode.
        if let thread = session.threadID { loaded.remove(thread) }
    }

    func setModel(_ model: String?, in spaceID: String) {
        let session = session(spaceID)
        session.model = model
        session.saveSettings()
    }

    func setWorkingFolder(_ path: String, in spaceID: String) {
        let session = session(spaceID)
        session.workingFolder = path
        session.saveSettings()
    }

    /// A space's own empty working folder, next to (never inside) the app's data folder:
    /// `~/Library/Application Support/iSmith Agent/<space>`. Commands may write only there
    /// (outside YOLO), so a page that talks the agent round can't reach the shell's startup
    /// files, LaunchAgents or iSmith's own data. The user can pick another folder.
    func defaultFolder(for spaceID: String) -> URL {
        let data = browser?.paths.dataDir ?? FileManager.default.temporaryDirectory
        let safe = spaceID.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "..", with: "-")
        return data.deletingLastPathComponent()
            .appendingPathComponent(data.lastPathComponent + " Agent", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    private func options(for session: AgentSession) -> AgentThreadOptions {
        try? FileManager.default.createDirectory(atPath: session.workingFolder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let name = browser?.space(session.spaceID)?.def.name ?? session.spaceID
        return AgentThreadOptions(cwd: session.workingFolder, model: session.model, mode: session.mode,
                                  developerInstructions: AgentBrowserTools.instructions(spaceName: name),
                                  tools: AgentBrowserTools.specs,
                                  extraConfig: Self.mcpOverrides(mode: session.mode, configText: Self.codexConfigText()))
    }

    /// Codex's own MCP servers (from the user's `~/.codex/config.toml`) act outside the browser
    /// and outside the space's mode, so panel threads switch them off: all of them unless the
    /// mode is YOLO, and in YOLO the ones that drive the screen or another browser (computer use,
    /// AppleScript, Chrome, Playwright), which the panel replaces with its own per-tab tools.
    static func mcpOverrides(mode: AgentMode, configText: String?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let text = configText ?? ""
        for name in mcpServerNames(in: text) {
            // The server's whole table (command, args, env) counts: a REPL server that can drive
            // Chrome or the screen says so in its environment.
            if mode != .yolo || drivesScreen(name + "\n" + section(of: "mcp_servers", name, in: text)) {
                out["mcp_servers.\(name).enabled"] = false
            }
        }
        // Plugins are off outside YOLO (Codex's feature switch); in YOLO the ones that drive a
        // browser or the screen are switched off by name.
        if mode == .yolo {
            for name in pluginNames(in: text) where drivesScreen(name) { out["plugins.\(name).enabled"] = false }
        }
        return out
    }

    static func drivesScreen(_ text: String) -> Bool {
        text.range(of: #"computer|applescript|osascript|browser|chrome|playwright|puppeteer|screen|desktop|cua|sky"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The lines of `[<table>.<name>]` and its subtables, up to the next other table.
    static func section(of table: String, _ name: String, in text: String) -> String {
        var out: [Substring] = []
        var inside = false
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                inside = t.hasPrefix("[\(table).\(name)]") || t.hasPrefix("[\(table).\(name).")
                    || t.hasPrefix("[\(table).\"\(name)\"")
            }
            if inside { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// The `[plugins."<name>"]` tables in a Codex config file.
    static func pluginNames(in text: String) -> [String] {
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[plugins.\""), let end = t.dropFirst("[plugins.\"".count).firstIndex(of: "\"") else { continue }
            let name = String(t[t.index(t.startIndex, offsetBy: "[plugins.\"".count)..<end])
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The `[mcp_servers.<name>]` tables in a Codex config file.
    static func mcpServerNames(in text: String) -> [String] {
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[mcp_servers."), t.hasSuffix("]") else { continue }
            var name = String(t.dropFirst("[mcp_servers.".count).dropLast())
            if name.hasPrefix("\"") {
                guard let end = name.dropFirst().firstIndex(of: "\"") else { continue }
                name = String(name[name.index(after: name.startIndex)..<end])
            } else if let dot = name.firstIndex(of: ".") {
                name = String(name[..<dot])
            }
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The user's Codex config, read once per thread start (it's small).
    static func codexConfigText() -> String? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
    }

    static func name(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    // MARK: - Calls from the backend

    private func handleToolCall(_ call: AgentToolCall) async -> AgentToolResult {
        guard let spaceID = threadSpace[call.threadID] ?? (try? browser?.data?.agent.thread(id: call.threadID))??.space else {
            return .text("This chat isn't attached to a browser space.", success: false)
        }
        threadSpace[call.threadID] = spaceID
        return await tools.call(call.tool, arguments: call.arguments,
                                context: AgentToolContext(spaceID: spaceID, threadID: call.threadID, requestID: call.requestID))
    }

    private func handleApproval(_ request: AgentApprovalRequest) async -> AgentApprovalDecision {
        guard let session = session(of: request.threadID) else { return .decline }
        if session.mode == .readOnly { return .decline }
        let answer = await ask(session, id: request.id, requestID: request.id, threadID: request.threadID, kind: .backend(request))
        switch answer {
        case .allow, .proceed: return .accept
        case .allowForSession: return .acceptForSession
        case .deny: return .decline
        case .stop: return .cancel
        }
    }

    // MARK: - AgentToolHost

    func mode(for spaceID: String) -> AgentMode { session(spaceID).mode }

    func approveBrowserAction(_ request: BrowserApprovalRequest) async -> Bool {
        let answer = await ask(session(request.spaceID), id: UUID().uuidString, requestID: request.requestID, threadID: request.threadID, kind: .browser(request))
        return answer == .allow || answer == .allowForSession
    }

    func stopTurn(in spaceID: String) { stop(in: spaceID) }

    func handOff(_ request: HandOffRequest) async -> Bool {
        let session = session(request.spaceID)
        let answer = await ask(session, id: UUID().uuidString, requestID: request.requestID, threadID: request.threadID, kind: .handOff(request))
        return answer == .proceed
    }

    /// Shows a card and waits for the user's answer (no time limit; Stop answers it).
    private func ask(_ session: AgentSession, id: String, requestID: String?, threadID: String, kind: AgentCard.Kind) async -> AgentCard.Answer {
        if Task.isCancelled { return .stop }
        return await withCheckedContinuation { continuation in
            let card = AgentCard(id: id, kind: kind, threadID: threadID, requestID: requestID) { [weak session] answer in
                session?.cards.removeAll { $0.id == id }
                continuation.resume(returning: answer)
            }
            session.cards.append(card)
            NSApp?.requestUserAttention(.informationalRequest)
        }
    }

    private func closeCards(in session: AgentSession, thread: String, answer: AgentCard.Answer) {
        for card in session.cards where card.threadID == thread { card.answer(answer) }
    }

    /// Brings a card's tab forward (the hand-off's "Show Tab").
    func show(tab id: UUID) {
        browser?.focusTab(id)
    }

    // MARK: - Transcript

    private func append(_ kind: AgentEntry.Kind, to session: AgentSession) {
        session.entries.append(AgentEntry(id: UUID().uuidString, kind: kind))
    }

    private func upsert(_ entry: AgentEntry, in session: AgentSession) {
        if let i = session.entries.firstIndex(where: { $0.id == entry.id }) {
            session.entries[i] = entry
        } else {
            session.entries.append(entry)
        }
    }

    /// An item started or finished: a message, or a step added to the current run of steps.
    private func apply(_ item: AgentItem, to session: AgentSession) {
        switch item.kind {
        case .userMessage, .reasoning, .other:
            return
        case let .agentMessage(text):
            session.streaming[item.id] = text
            upsert(AgentEntry(id: item.id, kind: .agent(text)), in: session)
        default:
            guard let step = Self.step(for: item) else { return }
            // Steps join the run at the end of the chat, or start a new one.
            if let i = session.entries.lastIndex(where: { if case .steps = $0.kind { return true } else { return false } }),
               i == session.entries.count - 1 || Self.contains(session.entries[i], step.id),
               case var .steps(steps) = session.entries[i].kind {
                if let j = steps.firstIndex(where: { $0.id == step.id }) { steps[j] = step } else { steps.append(step) }
                session.entries[i].kind = .steps(steps)
            } else {
                session.entries.append(AgentEntry(id: "steps-" + item.id, kind: .steps([step])))
            }
        }
    }

    private static func contains(_ entry: AgentEntry, _ stepID: String) -> Bool {
        if case let .steps(steps) = entry.kind { return steps.contains { $0.id == stepID } }
        return false
    }

    static func step(for item: AgentItem) -> AgentStep? {
        switch item.kind {
        case let .toolCall(tool, arguments, status, success):
            let s: AgentItem.Status = status == .completed && success == false ? .failed : status
            return AgentStep(id: item.id, title: toolTitle(tool, arguments), status: s)
        case let .command(command, _, status, _, _):
            let short = command.count > 80 ? String(command.prefix(79)) + "…" : command
            return AgentStep(id: item.id, title: "Ran \(short)", status: status)
        case let .fileChange(paths, status):
            let names = paths.map { ($0 as NSString).lastPathComponent }
            return AgentStep(id: item.id, title: "Edited " + (names.isEmpty ? "files" : names.prefix(3).joined(separator: ", ")), status: status)
        case let .mcpToolCall(server, tool, status):
            return AgentStep(id: item.id, title: "\(server): \(tool)", status: status)
        case let .webSearch(query):
            return AgentStep(id: item.id, title: "Searched the web for “\(query)”", status: .completed)
        default:
            return nil
        }
    }

    /// A step's line in the panel ("Clicked element 12", "Opened example.com").
    static func toolTitle(_ tool: String, _ args: JSONValue) -> String {
        let tab = args["tab"]?.intValue.map { " in tab \($0)" } ?? ""
        let element = args["element"]?.intValue.map { " element \($0)" } ?? ""
        switch tool {
        case "list_tabs": return "Listed tabs"
        case "page_snapshot": return "Read the page" + tab
        case "screenshot": return "Took a screenshot" + tab
        case "click": return "Clicked" + element + tab
        case "click_at": return "Clicked at (\(args["x"]?.intValue ?? 0), \(args["y"]?.intValue ?? 0))" + tab
        case "type": return "Typed into" + element + tab
        case "select": return "Chose “\(args["option"]?.stringValue ?? "")” in" + element + tab
        case "scroll": return "Scrolled " + (args["direction"]?.stringValue ?? "down") + tab
        case "press_key": return "Pressed \(args["key"]?.stringValue ?? "a key")" + tab
        case "open_tab": return "Opened \(URL(string: args["url"]?.stringValue ?? "")?.host ?? args["url"]?.stringValue ?? "a tab")"
        case "navigate": return "Went to \(URL(string: args["url"]?.stringValue ?? "")?.host ?? "a page")" + tab
        case "go_back": return "Went back" + tab
        case "close_tab": return "Closed" + tab
        case "wait_for": return "Waited" + (args["text"]?.stringValue.map { " for “\($0)”" } ?? "") + tab
        case "find_text": return "Found “\(args["query"]?.stringValue ?? "")”" + tab
        default: return tool
        }
    }

    /// A saved chat's turns as panel entries.
    static func entries(from turns: [AgentTurnRecord]) -> [AgentEntry] {
        var out: [AgentEntry] = []
        for turn in turns {
            var steps: [AgentStep] = []
            func flushSteps() {
                if !steps.isEmpty { out.append(AgentEntry(id: "steps-" + (steps.first?.id ?? UUID().uuidString), kind: .steps(steps))) }
                steps = []
            }
            for item in turn.items {
                switch item.kind {
                case let .userMessage(text):
                    flushSteps()
                    out.append(AgentEntry(id: item.id, kind: .user(text)))
                case let .agentMessage(text):
                    flushSteps()
                    out.append(AgentEntry(id: item.id, kind: .agent(text)))
                default:
                    if let step = step(for: item) { steps.append(step) }
                }
            }
            flushSteps()
            if turn.status == .failed { out.append(AgentEntry(id: "error-" + turn.id, kind: .problem(turn.error ?? "The turn failed."))) }
            if turn.status == .interrupted { out.append(AgentEntry(id: "stop-" + turn.id, kind: .notice("Stopped."))) }
        }
        return out
    }
}
