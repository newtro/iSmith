import Foundation

/// One run of the app-server child process: the `Process`, its JSON-RPC connection, and the tail
/// of its stderr. `CodexAppServerBackend` makes a new one each time it starts or restarts Codex.
///
/// It reports its exit once, after the process has terminated *and* stdout and stderr have been
/// read to the end (or a second after termination, in case a grandchild holds them open), so the
/// last events and log lines a dying process wrote are in hand before the backend reacts.
final class CodexProcess: @unchecked Sendable {
    let generation: Int
    let connection: JSONRPCConnection
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe

    private let lock = NSLock()
    private var stderrLines: [String] = []
    private var stderrPartial = Data()
    private var terminated = false
    private var stdoutClosed = false
    private var stderrClosed = false
    private var stopping = false
    private var exitReported = false
    private var stopReason: String?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var onExit: ((String) -> Void)?

    private static let stderrLineLimit = 50

    /// Spawns the process. Messages are delivered once `startIO()` is called.
    /// - Parameters:
    ///   - onActivity: called for every message received from this process.
    ///   - onExit: called once with a sentence describing why it stopped.
    init(executable: URL, arguments: [String], environment: [String: String], cwd: URL? = nil, generation: Int,
         onIncoming: @escaping (CodexProcess, JSONRPCConnection.Incoming) -> Void,
         onActivity: @escaping (CodexProcess) -> Void,
         onExit: @escaping (CodexProcess, String) -> Void) throws {
        self.generation = generation
        process = Process()
        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // The connection's callbacks need `self`, which doesn't exist yet: go through a weak box.
        weak var weakSelf: CodexProcess?
        connection = JSONRPCConnection(
            output: stdinPipe.fileHandleForWriting, input: stdoutPipe.fileHandleForReading, label: "codex.\(generation)",
            onIncoming: { incoming in if let me = weakSelf { onIncoming(me, incoming) } },
            onActivity: { if let me = weakSelf { onActivity(me) } },
            onEOF: { weakSelf?.noteStdoutClosed() })
        weakSelf = self
        self.onExit = { [weak self] reason in if let self { onExit(self, reason) } }

        process.terminationHandler = { [weak self] _ in self?.noteTerminated() }
        do {
            try process.run()
        } catch {
            throw AgentBackendError.processExited("Couldn't start \(executable.lastPathComponent): \(error.localizedDescription)")
        }
        // Our copies of the child's ends; FileHandle tracks its own state, so this is safe even if
        // Foundation already closed them.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdinPipe.fileHandleForReading.close()
    }

    /// Starts reading stdout and stderr. Separate from `init` so the owner can record this process
    /// as its current one before the first message arrives.
    func startIO() {
        startStderrReader()
        connection.startReading()
    }

    var processIdentifier: Int32 { process.processIdentifier }

    /// The last lines Codex wrote to stderr, for error messages. (Codex logs there; tool payloads
    /// never go there.)
    var stderrTail: String {
        lock.lock()
        defer { lock.unlock() }
        return stderrLines.suffix(8).joined(separator: "\n")
    }

    /// Kills the process now (SIGKILL), for when nothing else will wait for it (deinit).
    func killNow() {
        if !hasTerminated { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    /// True once `stop` has been called (so a stall isn't acted on twice while it winds down).
    var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    /// SIGTERM, so Codex can stop the commands it started, then SIGKILL if it is still running
    /// after `grace` seconds. Returns at once; the exit is reported as usual, with `reason` (if
    /// given) in place of the exit status.
    func stop(reason: String?, grace: TimeInterval = 2) {
        lock.lock()
        if stopReason == nil { stopReason = reason }
        let alreadyStopping = stopping
        stopping = true
        let done = terminated
        lock.unlock()
        guard !done, !alreadyStopping else { return }
        let pid = process.processIdentifier
        Darwin.kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, !self.hasTerminated else { return }
            Darwin.kill(pid, SIGKILL)
        }
    }

    /// `stop`, then waits until the process has exited.
    func terminate(grace: TimeInterval = 2) async {
        stop(reason: nil, grace: grace)
        await waitForTermination()
    }

    private var hasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    private func waitForTermination() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if terminated {
                lock.unlock()
                continuation.resume()
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    // MARK: Exit bookkeeping

    private func noteTerminated() {
        lock.lock()
        terminated = true
        let waiters = exitWaiters
        exitWaiters = []
        let drained = stdoutClosed && stderrClosed
        lock.unlock()
        waiters.forEach { $0.resume() }
        if drained {
            reportExit()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.reportExit() }
        }
    }

    private func noteStdoutClosed() {
        lock.lock()
        stdoutClosed = true
        let done = terminated
        let drained = stderrClosed
        lock.unlock()
        if done {
            if drained { reportExit() }
        } else {
            // Codex closed its output but is still running: it can't answer us any more.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.hasTerminated else { return }
                self.stop(reason: "Codex closed its connection.")
            }
        }
    }

    private func noteStderrClosed() {
        lock.lock()
        stderrClosed = true
        if !stderrPartial.isEmpty {
            addStderrLine(stderrPartial)
            stderrPartial.removeAll()
        }
        let ready = terminated && stdoutClosed
        lock.unlock()
        if ready { reportExit() }
    }

    private func reportExit() {
        lock.lock()
        guard !exitReported else { lock.unlock(); return }
        exitReported = true
        let reason = stopReason
        let callback = onExit
        onExit = nil
        lock.unlock()
        callback?(reason ?? exitDescription())
    }

    private func exitDescription() -> String {
        var text: String
        switch process.terminationReason {
        case .uncaughtSignal: text = "Codex was killed (signal \(process.terminationStatus))."
        default: text = "Codex exited with status \(process.terminationStatus)."
        }
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { text += " Last output: \(tail)" }
        return text
    }

    // MARK: stderr

    /// Drains stderr so Codex never blocks on a full pipe, keeping only the last lines.
    private func startStderrReader() {
        let handle = stderrPipe.fileHandleForReading
        let thread = Thread { [weak self] in
            let fd = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                self?.appendStderr(Data(buffer[0..<n]))
            }
            _ = handle // Keep the handle (and its descriptor) alive while reading.
            self?.noteStderrClosed()
        }
        thread.name = "AgentKit.codex.stderr.\(generation)"
        thread.start()
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderrPartial.append(data)
        while let newline = stderrPartial.firstIndex(of: 0x0A) {
            let lineData = Data(stderrPartial[stderrPartial.startIndex..<newline])
            stderrPartial.removeSubrange(stderrPartial.startIndex...newline)
            addStderrLine(lineData)
        }
        // A runaway line without a newline still has to stay bounded.
        if stderrPartial.count > 64 * 1024 { stderrPartial.removeAll() }
    }

    /// Call with the lock held.
    private func addStderrLine(_ data: Data) {
        let line = String(decoding: data.prefix(2000), as: UTF8.self)
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stderrLines.append(line)
        if stderrLines.count > Self.stderrLineLimit { stderrLines.removeFirst(stderrLines.count - Self.stderrLineLimit) }
    }
}
