import Foundation

/// The Codex backend: one `codex app-server` child process speaking JSON-RPC over stdio, running
/// any number of threads.
///
/// Liveness, not caps: turns, time and tokens are unlimited. If the process exits, or goes
/// `stallTimeout` without sending anything while a turn runs (or one of our calls waits) and
/// nothing is waiting on the app, the running turns are reported failed, the process restarts,
/// and every thread it knew is resumed. Too many restarts in a short window and it gives up
/// (`.failed`) until `start()` is called again.
///
/// Threading: handler closures are called from background threads (`event` on the process's
/// reader thread, so a UI should hop to the main actor). Events for one process arrive in
/// protocol order; tool calls and approvals run as their own tasks, so a slow answer never holds
/// up the event stream, and those tasks are cancelled when Codex withdraws the request.
public final class CodexAppServerBackend: AgentBackend, @unchecked Sendable {
    public let displayName = "Codex"

    private let explicitExecutable: URL?
    private let arguments: [String]
    private let environment: [String: String]
    private let clientName: String
    private let clientVersion: String
    private let handler: AgentBackendHandler
    private let stallTimeout: TimeInterval
    private let restartLimit: (count: Int, window: TimeInterval)

    /// Doesn't advance while the Mac sleeps, so waking up isn't mistaken for a stall.
    private typealias Instant = SuspendingClock.Instant
    private static let clock = SuspendingClock()

    private enum Phase: Equatable {
        case stopped, starting, ready, restarting
        case failed(String)
    }

    /// A server request the app is answering.
    private struct WaitingRequest {
        var generation: Int
        var turnID: String
        var token: Int
        var task: Task<Void, Never>?
    }

    private struct State {
        var phase: Phase = .stopped
        var current: CodexProcess?
        var generation = 0
        /// Calls made while starting or restarting wait here for the ready process.
        var readyWaiters: [CheckedContinuation<CodexProcess, Error>] = []
        /// Threads started or resumed in this backend, with their latest options (the mode, cwd and
        /// model follow each turn's settings), in the order they were first seen.
        var threads: [String: AgentThreadOptions] = [:]
        var threadOrder: [String] = []
        /// Subagent threads Codex spawned: child id → parent id (they share the parent's mode).
        var threadParents: [String: String] = [:]
        /// Running turns: turn id → thread id.
        var activeTurns: [String: String] = [:]
        /// Recently finished turns, so a late `turn/start` result doesn't revive one.
        var finishedTurns: [String] = []
        /// Server requests the app is still answering, by request id (text).
        var waitingRequests: [String: WaitingRequest] = [:]
        var nextRequestToken = 0
        var lastActivity: Instant = CodexAppServerBackend.clock.now
        var restartTimes: [Date] = []
        var stallMonitor: Task<Void, Never>?
        var shuttingDown = false
        /// Bumped by every `start()` and `shutdown()`, so work begun under an older one (a restart
        /// waiting between attempts, a launch racing a shutdown) can tell it has been superseded.
        var epoch = 0
    }

    private let lock = NSLock()
    private var state = State()

    /// - Parameters:
    ///   - executable: the `codex` binary; nil finds it with `locateExecutable` when starting.
    ///   - environment: the child's environment (default: this process's), with PATH extended so
    ///     Codex finds its tools even when the app was launched from Finder.
    ///   - stallTimeout: how long Codex may go without sending anything, while a turn runs (or one of
    ///     our calls waits) and nothing waits on the app, before it is treated as hung and restarted.
    ///   - restartLimit: at most `count` automatic restarts within `window` seconds.
    public init(executable: URL? = nil, arguments: [String] = ["app-server"], environment: [String: String]? = nil,
                clientName: String = "iSmith", clientVersion: String, handler: AgentBackendHandler,
                stallTimeout: TimeInterval = 600, restartLimit: (count: Int, window: TimeInterval) = (3, 300)) {
        explicitExecutable = executable
        self.arguments = arguments
        self.environment = Self.childEnvironment(environment ?? ProcessInfo.processInfo.environment)
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.handler = handler
        self.stallTimeout = stallTimeout
        self.restartLimit = restartLimit
    }

    deinit {
        state.stallMonitor?.cancel()
        for request in state.waitingRequests.values { request.task?.cancel() }
        state.current?.killNow()
    }

    // MARK: Finding Codex

    /// Directories where installers put `codex`, searched after PATH. Apps launched from Finder get
    /// a minimal PATH, so these are also added to the child's PATH.
    static let wellKnownDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The first executable `codex` in PATH, then ~/.local/bin, /opt/homebrew/bin, /usr/local/bin.
    public static func locateExecutable(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let candidates = pathDirs + [home.appendingPathComponent(".local/bin").path] + wellKnownDirectories
        let fm = FileManager.default
        for dir in candidates {
            let path = URL(fileURLWithPath: dir).appendingPathComponent("codex").path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static func childEnvironment(_ base: [String: String]) -> [String: String] {
        var env = base
        let home = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for extra in ["\(home)/.local/bin"] + wellKnownDirectories + ["/usr/bin", "/bin"] where !dirs.contains(extra) {
            dirs.append(extra)
        }
        env["PATH"] = dirs.joined(separator: ":")
        return env
    }

    private func resolveExecutable() -> URL? {
        explicitExecutable ?? Self.locateExecutable(environment: environment)
    }

    // MARK: Lifecycle

    public func start() async throws {
        enum Action { case nothing, wait, launch(epoch: Int) }
        let action: Action = locked { s in
            switch s.phase {
            case .ready: return .nothing
            case .starting, .restarting: return .wait
            case .stopped, .failed:
                s.phase = .starting
                s.shuttingDown = false
                s.restartTimes = []
                s.epoch += 1
                return .launch(epoch: s.epoch)
            }
        }
        let epoch: Int
        switch action {
        case .nothing: return
        case .wait: _ = try await readyProcess(); return
        case let .launch(e): epoch = e
        }

        guard let executable = resolveExecutable() else {
            let error = AgentBackendError.notInstalled(
                "Codex isn't installed. Install it (npm install -g @openai/codex, or brew install codex), sign in with `codex login`, then try again.")
            let waiters: [CheckedContinuation<CodexProcess, Error>]? = locked { s in
                guard s.epoch == epoch else { return nil }
                s.phase = .stopped
                defer { s.readyWaiters = [] }
                return s.readyWaiters
            }
            if let waiters {
                waiters.forEach { $0.resume(throwing: error) }
                emit(.status(.notInstalled))
            }
            throw error
        }

        emit(.status(.starting))
        startStallMonitor()
        do {
            try await launch(executable, epoch: epoch)
        } catch {
            let reason = (error as? AgentBackendError)?.description ?? error.localizedDescription
            let waiters: [CheckedContinuation<CodexProcess, Error>]? = locked { s in
                guard !s.shuttingDown, s.epoch == epoch else { return nil }
                s.phase = .failed(reason)
                defer { s.readyWaiters = [] }
                return s.readyWaiters
            }
            if let waiters {
                waiters.forEach { $0.resume(throwing: error) }
                emit(.status(.failed(reason: reason)))
            }
            throw error
        }
    }

    /// Stops Codex. Running turns are reported interrupted ("Codex was stopped."), requests the
    /// app was answering are withdrawn (their tasks cancelled), and pending calls fail with
    /// `notRunning`. Threads are forgotten: resume them after the next `start()`.
    public func shutdown() async {
        let (process, waiters, turns, requests, monitor): (CodexProcess?, [CheckedContinuation<CodexProcess, Error>], [String: String], [String: WaitingRequest], Task<Void, Never>?) = locked { s in
            s.shuttingDown = true
            s.epoch += 1
            s.phase = .stopped
            defer {
                s.current = nil
                s.readyWaiters = []
                s.activeTurns = [:]
                s.waitingRequests = [:]
                s.threads = [:]
                s.threadOrder = []
                s.threadParents = [:]
                s.stallMonitor = nil
            }
            return (s.current, s.readyWaiters, s.activeTurns, s.waitingRequests, s.stallMonitor)
        }
        monitor?.cancel()
        waiters.forEach { $0.resume(throwing: AgentBackendError.notRunning) }
        process?.connection.close(error: AgentBackendError.notRunning)
        withdraw(requests)
        for (turn, thread) in turns.sorted(by: { $0.key < $1.key }) {
            emit(.turnCompleted(threadID: thread, turnID: turn, status: .interrupted, error: "Codex was stopped."))
        }
        await process?.terminate(grace: 2)
        emit(.status(.stopped))
    }

    /// Spawns a process, handshakes, and resumes every known thread on it. On success the backend
    /// is ready; on failure the process is stopped and the error thrown. Every step re-checks that
    /// this launch hasn't been superseded (`epoch`) or shut down.
    private func launch(_ executable: URL, epoch: Int) async throws {
        let generation: Int = locked { s in
            s.generation += 1
            return s.generation
        }
        let process = try CodexProcess(
            executable: executable, arguments: arguments, environment: environment, generation: generation,
            onIncoming: { [weak self] process, incoming in self?.receive(incoming, from: process) },
            onActivity: { [weak self] process in self?.touch(process) },
            onExit: { [weak self] process, reason in self?.processExited(process, reason: reason) })
        let stillWanted: Bool = locked { s in
            guard !s.shuttingDown, s.epoch == epoch else { return false }
            s.current = process
            s.lastActivity = Self.clock.now
            return true
        }
        guard stillWanted else {
            process.stop(reason: nil)
            throw AgentBackendError.notRunning
        }
        process.startIO()

        do {
            _ = try await process.connection.request(
                "initialize", params: Self.initializeParams(clientName: clientName, clientVersion: clientVersion))
            try await process.connection.notify("initialized")

            let threads: [(String, AgentThreadOptions)] = locked { s in
                s.threadOrder.compactMap { id in s.threads[id].map { (id, $0) } }
            }
            for (id, options) in threads {
                guard isCurrent(process, epoch: epoch) else { throw AgentBackendError.notRunning }
                do {
                    _ = try await process.connection.request(
                        "thread/resume", params: Self.threadResumeParams(threadID: id, options: options))
                } catch let AgentBackendError.requestFailed(_, message) {
                    // Codex is fine but won't take this thread back: drop it and say so.
                    forgetThread(id)
                    emit(.error(threadID: id, turnID: nil, message: "Couldn't reopen this thread after Codex restarted: \(message)",
                                willRetry: false))
                }
            }

            let waiters: [CheckedContinuation<CodexProcess, Error>]? = locked { s in
                guard s.current === process, !s.shuttingDown, s.epoch == epoch else { return nil }
                s.phase = .ready
                s.lastActivity = Self.clock.now
                defer { s.readyWaiters = [] }
                return s.readyWaiters
            }
            guard let waiters else { throw AgentBackendError.notRunning }
            waiters.forEach { $0.resume(returning: process) }
            emit(.status(.ready))
        } catch {
            locked { s in if s.current === process { s.current = nil } }
            process.stop(reason: nil)
            process.connection.close(error: error)
            throw error
        }
    }

    private func isCurrent(_ process: CodexProcess, epoch: Int) -> Bool {
        locked { s in s.current === process && !s.shuttingDown && s.epoch == epoch }
    }

    /// The process exited (or was stopped for stalling). Fails what was waiting on it, reports the
    /// running turns as failed, and restarts if it had been ready.
    private func processExited(_ process: CodexProcess, reason: String) {
        let outcome: (wasReady: Bool, epoch: Int, requests: [String: WaitingRequest], turns: [String: String])? = locked { s in
            guard s.current === process, !s.shuttingDown else { return nil }
            s.current = nil
            let wasReady = s.phase == .ready
            if wasReady { s.phase = .restarting }
            let requests = s.waitingRequests.filter { $0.value.generation == process.generation }
            for id in requests.keys { s.waitingRequests[id] = nil }
            let turns = s.activeTurns
            s.activeTurns = [:]
            for turn in turns.keys { rememberFinished(turn, in: &s) }
            return (wasReady, s.epoch, requests, turns)
        }
        process.connection.close(error: AgentBackendError.processExited(reason))
        guard let outcome else { return }
        withdraw(outcome.requests)
        for (turn, thread) in outcome.turns.sorted(by: { $0.key < $1.key }) {
            emit(.turnCompleted(threadID: thread, turnID: turn, status: .failed, error: "Codex stopped: \(reason)"))
        }
        if outcome.wasReady {
            let epoch = outcome.epoch
            Task { [weak self] in await self?.recover(reason: reason, epoch: epoch) }
        }
    }

    /// Restarts Codex until it's ready again, or until the restart limit says to give up.
    private func recover(reason firstReason: String, epoch: Int) async {
        var reason = firstReason
        while true {
            let decision: (go: Bool, attempt: Int)? = locked { s in
                guard !s.shuttingDown, s.epoch == epoch, s.phase == .restarting else { return nil }
                let now = Date()
                s.restartTimes = s.restartTimes.filter { now.timeIntervalSince($0) < restartLimit.window }
                if s.restartTimes.count >= restartLimit.count {
                    s.phase = .failed(reason)
                    return (false, s.restartTimes.count)
                }
                s.restartTimes.append(now)
                return (true, s.restartTimes.count)
            }
            guard let decision else { return }
            guard decision.go else {
                let message = "Codex keeps stopping (\(decision.attempt) restarts in \(Int(restartLimit.window)) s). \(reason)"
                failWaiters(AgentBackendError.processExited(message))
                emit(.status(.failed(reason: message)))
                return
            }
            emit(.status(.restarting(reason: reason)))
            // A short, growing pause so a crash loop doesn't spin. `launch` re-checks the epoch.
            try? await Task.sleep(nanoseconds: UInt64(decision.attempt - 1) * 250_000_000)
            guard let executable = resolveExecutable() else {
                let gaveUp: Bool = locked { s in
                    guard s.phase == .restarting, !s.shuttingDown, s.epoch == epoch else { return false }
                    s.phase = .stopped
                    return true
                }
                if gaveUp {
                    failWaiters(AgentBackendError.notInstalled("Codex is no longer installed."))
                    emit(.status(.notInstalled))
                }
                return
            }
            do {
                try await launch(executable, epoch: epoch)
                return
            } catch {
                reason = (error as? AgentBackendError)?.description ?? error.localizedDescription
            }
        }
    }

    private func failWaiters(_ error: Error) {
        let waiters: [CheckedContinuation<CodexProcess, Error>] = locked { s in
            defer { s.readyWaiters = [] }
            return s.readyWaiters
        }
        waiters.forEach { $0.resume(throwing: error) }
    }

    // MARK: Stall detection

    private func startStallMonitor() {
        let interval = max(min(stallTimeout / 4, 15), 0.05)
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                self.checkForStall()
            }
        }
        let old: Task<Void, Never>? = locked { s in
            defer { s.stallMonitor = task }
            return s.stallMonitor
        }
        old?.cancel()
    }

    /// Stops Codex if it owes us something (a running turn, or an answer to one of our calls),
    /// nothing is waiting on the app, and it has said nothing for `stallTimeout`. A pending tool
    /// call or approval means the app (or the user) is the slow one, so it never counts as a stall.
    private func checkForStall() {
        let hung: CodexProcess? = locked { s in
            guard s.phase == .ready, let current = s.current, !current.isStopping,
                  !s.activeTurns.isEmpty || current.connection.hasPendingRequests,
                  !s.waitingRequests.values.contains(where: { $0.generation == current.generation }),
                  s.lastActivity.duration(to: Self.clock.now) >= .seconds(stallTimeout) else { return nil }
            return current
        }
        hung?.stop(reason: "Codex stopped responding (nothing for \(Int(stallTimeout.rounded())) s).")
    }

    private func touch(_ process: CodexProcess) {
        locked { s in if s.current === process { s.lastActivity = Self.clock.now } }
    }

    // MARK: Calls

    /// The running process, waiting for a start or restart in progress to finish.
    private func readyProcess() async throws -> CodexProcess {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CodexProcess, Error>) in
            let result: Result<CodexProcess, Error>? = locked { s in
                switch s.phase {
                case .ready:
                    if let current = s.current { return .success(current) }
                    return .failure(AgentBackendError.notRunning)
                case .starting, .restarting:
                    s.readyWaiters.append(continuation)
                    return nil
                case .stopped:
                    return .failure(AgentBackendError.notRunning)
                case let .failed(reason):
                    return .failure(AgentBackendError.processExited(reason))
                }
            }
            if let result { continuation.resume(with: result) }
        }
    }

    private func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await readyProcess().connection.request(method, params: params)
    }

    public func models() async throws -> [AgentModel] {
        var models: [AgentModel] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            var params: [String: JSONValue] = ["includeHidden": false]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = Self.modelPage(from: try await call("model/list", .object(params)))
            models += page.models
            cursor = page.nextCursor
            if let c = cursor, !seenCursors.insert(c).inserted { break }
        } while cursor != nil
        return models
    }

    public func startThread(_ options: AgentThreadOptions) async throws -> AgentThreadInfo {
        let result = try await call("thread/start", Self.threadStartParams(options, serviceName: clientName))
        let info = try Self.threadInfo(from: result, method: "thread/start")
        rememberThread(info.id, options: options)
        return info
    }

    /// Codex keeps a loaded thread's config (its MCP servers, tools, features) as it was loaded:
    /// a `thread/resume` of a thread this process already has changes nothing (checked live,
    /// codex-cli 0.160). So a thread that's loaded is unsubscribed first, which unloads it, and
    /// the resume then applies `options` (a stricter mode's config) afresh.
    public func resumeThread(id: String, options: AgentThreadOptions) async throws -> AgentThreadInfo {
        let loaded = locked { s in s.threads[id] != nil }
        // A failed unload fails the resume: the thread must not carry on under its old config.
        if loaded { _ = try await call("thread/unsubscribe", ["threadId": .string(id)]) }
        let result = try await call("thread/resume", Self.threadResumeParams(threadID: id, options: options))
        let info = try Self.threadInfo(from: result, method: "thread/resume")
        rememberThread(info.id, options: options)
        return info
    }

    public func setThreadName(id: String, name: String) async throws {
        _ = try await call("thread/name/set", ["threadId": .string(id), "name": .string(name)])
    }

    public func startTurn(threadID: String, text: String, settings: AgentTurnSettings) async throws -> String {
        // Record the mode first: approvals for this turn can arrive before turn/start answers.
        locked { s in
            guard var options = s.threads[threadID] else { return }
            options.mode = settings.mode
            options.cwd = settings.cwd
            if let model = settings.model { options.model = model }
            s.threads[threadID] = options
        }
        let process = try await readyProcess()
        let result = try await process.connection.request(
            "turn/start", params: Self.turnStartParams(threadID: threadID, text: text, settings: settings))
        guard let turnID = result["turn"]?["id"]?.stringValue else {
            throw AgentBackendError.badResponse(method: "turn/start", detail: "no turn id")
        }
        locked { s in
            // Only on the process that runs it: a turn on a process that has since died was already
            // reported failed, and must not keep the new process under stall watch.
            guard s.current === process, !s.finishedTurns.contains(turnID), s.activeTurns[turnID] == nil else { return }
            s.activeTurns[turnID] = threadID
            s.lastActivity = Self.clock.now
        }
        return turnID
    }

    public func interruptTurn(threadID: String, turnID: String) async throws {
        _ = try await call("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)])
    }

    private func rememberThread(_ id: String, options: AgentThreadOptions) {
        locked { s in
            if s.threads[id] == nil { s.threadOrder.append(id) }
            s.threads[id] = options
        }
    }

    private func forgetThread(_ id: String) {
        locked { s in
            s.threads[id] = nil
            s.threadOrder.removeAll { $0 == id }
        }
    }

    private func rememberFinished(_ turnID: String, in s: inout State) {
        s.finishedTurns.append(turnID)
        if s.finishedTurns.count > 200 { s.finishedTurns.removeFirst(s.finishedTurns.count - 200) }
    }

    /// A thread's current mode; a subagent thread has its parent's. nil if the thread is unknown.
    private func mode(of threadID: String, in s: State) -> AgentMode? {
        var id = threadID
        for _ in 0..<16 {
            if let options = s.threads[id] { return options.mode }
            guard let parent = s.threadParents[id] else { return nil }
            id = parent
        }
        return nil
    }

    // MARK: Incoming

    private func receive(_ incoming: JSONRPCConnection.Incoming, from process: CodexProcess) {
        // Messages from a process we've already given up on are ignored.
        guard locked({ s in s.current === process }) else { return }
        switch incoming {
        case let .notification(method, params): handleNotification(method, params)
        case let .request(id, method, params): handleServerRequest(id: id, method: method, params: params, process: process)
        }
    }

    private func handleNotification(_ method: String, _ params: JSONValue) {
        let threadID = params["threadId"]?.stringValue
        switch method {
        case "thread/started":
            // Subagent threads: remember the parent so they follow its mode.
            guard let thread = params["thread"], let id = thread["id"]?.stringValue else { return }
            let parent = thread["parentThreadId"]?.stringValue
                ?? thread["source"]?["subAgent"]?["thread_spawn"]?["parent_thread_id"]?.stringValue
            if let parent, parent != id { locked { s in s.threadParents[id] = parent } }
        case "turn/started":
            guard let threadID, let turnID = params["turn"]?["id"]?.stringValue else { return }
            locked { s in if !s.finishedTurns.contains(turnID) { s.activeTurns[turnID] = threadID } }
            emit(.turnStarted(threadID: threadID, turnID: turnID))
        case "turn/completed":
            guard let threadID, let turn = params["turn"], let turnID = turn["id"]?.stringValue else { return }
            let leftovers: [String: WaitingRequest] = locked { s in
                s.activeTurns[turnID] = nil
                rememberFinished(turnID, in: &s)
                let leftovers = s.waitingRequests.filter { $0.value.turnID == turnID }
                for id in leftovers.keys { s.waitingRequests[id] = nil }
                return leftovers
            }
            // Anything the app was still answering for this turn is moot now.
            withdraw(leftovers)
            emit(.turnCompleted(threadID: threadID, turnID: turnID, status: Self.turnStatus(turn["status"]),
                                error: turn["error"]?["message"]?.stringValue))
        case "item/started", "item/completed":
            guard let threadID, let turnID = params["turnId"]?.stringValue,
                  let raw = params["item"], let item = Self.item(from: raw) else { return }
            emit(method == "item/started" ? .itemStarted(threadID: threadID, turnID: turnID, item: item)
                                          : .itemCompleted(threadID: threadID, turnID: turnID, item: item))
        case "item/agentMessage/delta", "item/reasoning/summaryTextDelta":
            guard let threadID, let turnID = params["turnId"]?.stringValue, let itemID = params["itemId"]?.stringValue,
                  let delta = params["delta"]?.stringValue else { return }
            emit(method == "item/agentMessage/delta"
                 ? .messageDelta(threadID: threadID, turnID: turnID, itemID: itemID, delta: delta)
                 : .reasoningDelta(threadID: threadID, turnID: turnID, itemID: itemID, delta: delta))
        case "error":
            let message = params["error"]?["message"]?.stringValue ?? params["message"]?.stringValue ?? "Codex reported an error."
            emit(.error(threadID: threadID, turnID: params["turnId"]?.stringValue, message: message,
                        willRetry: params["willRetry"]?.boolValue ?? false))
        case "warning", "configWarning", "deprecationNotice", "guardianWarning":
            guard let text = Self.noticeText(params) else { return }
            emit(.notice(threadID: threadID, message: text))
        case "thread/name/updated":
            // A null name means the name was cleared.
            guard let threadID else { return }
            emit(.threadNameChanged(threadID: threadID, name: params["threadName"]?.stringValue ?? params["name"]?.stringValue ?? ""))
        case "serverRequest/resolved":
            guard let requestID = params["requestId"], requestID != .null else { return }
            let idText = requestID.idText
            let request: WaitingRequest? = locked { s in s.waitingRequests.removeValue(forKey: idText) }
            request?.task?.cancel()
            emit(.requestResolved(requestID: idText))
        default:
            break
        }
    }

    /// Cancels the app's tasks for these requests and tells the app they're gone.
    private func withdraw(_ requests: [String: WaitingRequest]) {
        for (id, request) in requests.sorted(by: { $0.key < $1.key }) {
            request.task?.cancel()
            emit(.requestResolved(requestID: id))
        }
    }

    private enum AppRequest {
        case tool(AgentToolCall)
        case approval(AgentApprovalRequest, requestedPermissions: JSONValue?)
    }

    private func handleServerRequest(id: JSONValue, method: String, params: JSONValue, process: CodexProcess) {
        let connection = process.connection
        let idText = id.idText
        let threadID = params["threadId"]?.stringValue ?? ""
        let turnID = params["turnId"]?.stringValue ?? ""
        let itemID = params["itemId"]?.stringValue ?? ""

        let request: AppRequest
        switch method {
        case "item/tool/call":
            guard let tool = params["tool"]?.stringValue else {
                connection.replyError(id: id, code: -32602, message: "missing tool")
                return
            }
            request = .tool(AgentToolCall(threadID: threadID, turnID: turnID, callID: params["callId"]?.stringValue ?? idText,
                                          tool: tool, arguments: params["arguments"] ?? .null, requestID: idText))
        case "item/commandExecution/requestApproval":
            request = .approval(AgentApprovalRequest(
                id: idText, threadID: threadID, turnID: turnID, itemID: itemID,
                kind: .command(command: params["command"]?.stringValue, cwd: params["cwd"]?.stringValue,
                               reason: params["reason"]?.stringValue)), requestedPermissions: nil)
        case "item/fileChange/requestApproval":
            request = .approval(AgentApprovalRequest(
                id: idText, threadID: threadID, turnID: turnID, itemID: itemID,
                kind: .fileChange(reason: params["reason"]?.stringValue, grantRoot: params["grantRoot"]?.stringValue)),
                requestedPermissions: nil)
        case "item/permissions/requestApproval":
            let requested = params["permissions"] ?? .object([:])
            request = .approval(AgentApprovalRequest(
                id: idText, threadID: threadID, turnID: turnID, itemID: itemID,
                kind: .permissions(reason: params["reason"]?.stringValue, summary: Self.permissionsSummary(requested))),
                requestedPermissions: requested)
        case "currentTime/read":
            connection.reply(id: id, result: ["currentTimeAt": .number(Date().timeIntervalSince1970.rounded(.down))])
            return
        default:
            connection.replyError(id: id, code: -32601, message: "unsupported: \(method)")
            return
        }

        // Read-only spaces never run commands, change files or widen the sandbox: decline here,
        // without bothering the user. So is a thread we don't know (not started, resumed or
        // spawned by one of ours): it has no mode that could allow anything.
        if case let .approval(_, requestedPermissions) = request {
            let mode: AgentMode? = locked { s in self.mode(of: threadID, in: s) }
            if mode == nil || mode == .readOnly {
                connection.reply(id: id, result: requestedPermissions == nil
                                 ? Self.decisionResponse(.decline)
                                 : Self.permissionsResponse(.decline, requested: .object([:])))
                return
            }
        }

        let token: Int = locked { s in
            s.nextRequestToken += 1
            s.waitingRequests[idText] = WaitingRequest(generation: process.generation, turnID: turnID,
                                                       token: s.nextRequestToken, task: nil)
            return s.nextRequestToken
        }
        let handler = handler
        let task = Task.detached { [weak self] in
            let result: JSONValue
            switch request {
            case let .tool(call):
                result = Self.toolCallResponse(await handler.toolCall(call))
            case let .approval(approval, requestedPermissions):
                let decision = await handler.approval(approval)
                result = requestedPermissions.map { Self.permissionsResponse(decision, requested: $0) }
                    ?? Self.decisionResponse(decision)
            }
            self?.finishServerRequest(id: id, idText: idText, token: token, result: result, process: process)
        }
        let withdrawn: Bool = locked { s in
            guard s.waitingRequests[idText]?.token == token else { return true }
            s.waitingRequests[idText]?.task = task
            return false
        }
        // Withdrawn before we could record the task (or already answered): cancelling is harmless.
        if withdrawn { task.cancel() }
    }

    /// Sends the app's answer, unless the request was withdrawn (resolved by Codex, its turn
    /// ended, or the process it came from is gone) in the meantime.
    private func finishServerRequest(id: JSONValue, idText: String, token: Int, result: JSONValue, process: CodexProcess) {
        let send: Bool = locked { s in
            guard s.waitingRequests[idText]?.token == token, s.current === process else { return false }
            s.waitingRequests[idText] = nil
            // The clock restarts now: Codex had nothing to do while it waited on us.
            s.lastActivity = Self.clock.now
            return true
        }
        if send { process.connection.reply(id: id, result: result) }
    }

    // MARK: Helpers

    private func emit(_ event: AgentEvent) {
        handler.event(event)
    }

    @discardableResult
    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
