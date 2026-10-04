import Foundation

/// Newline-delimited JSON-RPC 2.0 over a pair of pipes (a child process's stdin and stdout).
///
/// The Codex app server talks both ways on the same pipes: we send requests and notifications,
/// and it sends responses, notifications, and its own requests (tool calls, approvals) that we
/// answer. Lines can be many megabytes (screenshots travel as base64 data URLs), so stdout is read
/// incrementally on a dedicated thread and split on "\n" with no size limit.
///
/// Incoming notifications and requests are delivered in order on the reader thread; handlers must
/// return quickly (spawn a task for anything slow). Writes go through one serial queue so lines
/// never interleave. Everything here is safe to call from any thread.
final class JSONRPCConnection: @unchecked Sendable {
    /// Something the other side sent that the owner has to deal with.
    enum Incoming {
        case notification(method: String, params: JSONValue)
        /// A request from the server; answer with `reply` or `replyError` using the same `id`
        /// (an integer or a string, echoed back exactly).
        case request(id: JSONValue, method: String, params: JSONValue)
    }

    private struct Pending {
        var method: String
        var continuation: CheckedContinuation<JSONValue, Error>
    }

    private let output: FileHandle
    private let input: FileHandle
    private let label: String
    private let onIncoming: (Incoming) -> Void
    private let onActivity: () -> Void
    private let onEOF: () -> Void

    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var closedError: Error?
    private let writeQueue: DispatchQueue

    /// - Parameters:
    ///   - output: where we write (the child's stdin).
    ///   - input: where we read (the child's stdout).
    ///   - onIncoming: notifications and server requests, in arrival order, on the reader thread.
    ///   - onActivity: called for every message received (responses too), for liveness tracking.
    ///   - onEOF: the other side closed its output.
    init(output: FileHandle, input: FileHandle, label: String,
         onIncoming: @escaping (Incoming) -> Void,
         onActivity: @escaping () -> Void = {},
         onEOF: @escaping () -> Void = {}) {
        self.output = output
        self.input = input
        self.label = label
        self.onIncoming = onIncoming
        self.onActivity = onActivity
        self.onEOF = onEOF
        writeQueue = DispatchQueue(label: "AgentKit.JSONRPC.write.\(label)")
        // Writing to a pipe whose reader has died must fail with EPIPE, not kill the app.
        _ = fcntl(output.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Starts the reader thread. Call once, after the owner is ready to receive callbacks.
    func startReading() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "AgentKit.JSONRPC.read.\(label)"
        thread.stackSize = 1 << 20
        thread.start()
    }

    // MARK: Sending

    /// Sends a request and waits for its result. Throws `AgentBackendError.requestFailed` when the
    /// other side answers with an error, or the connection's close error if it closes first.
    /// Cancelling the calling task stops the wait (throwing `CancellationError`); a late answer
    /// is ignored.
    func request(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        let id = allocateID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                lock.lock()
                if let closedError {
                    lock.unlock()
                    continuation.resume(throwing: closedError)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = Pending(method: method, continuation: continuation)
                lock.unlock()

                var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
                if let params { message["params"] = params }
                enqueueWrite(.object(message)) { [weak self] error in
                    self?.writeFailed(id: id, error: error)
                }
            }
        } onCancel: {
            failPending(id: id, error: CancellationError())
        }
    }

    private func allocateID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    /// True while any request is waiting for its answer (for spotting a hung process).
    var hasPendingRequests: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    /// Sends a notification (no answer expected). Throws if the line couldn't be written.
    func notify(_ method: String, params: JSONValue? = nil) async throws {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let error = currentClosedError() {
                continuation.resume(throwing: error)
                return
            }
            enqueueWrite(.object(message), onFailure: { [weak self] error in
                self?.afterWriteFailure { continuation.resume(throwing: $0 ?? error) } ?? continuation.resume(throwing: error)
            }, onSuccess: { continuation.resume() })
        }
    }

    /// Answers a server request. Errors (a dead pipe) are dropped: the process is going away and
    /// its exit is handled elsewhere.
    func reply(id: JSONValue, result: JSONValue) {
        enqueueWrite(.object(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    func replyError(id: JSONValue, code: Int, message: String) {
        enqueueWrite(.object(["jsonrpc": "2.0", "id": id,
                              "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }

    /// Fails every request still waiting and refuses new ones with `error`. Idempotent; the first
    /// error wins.
    func close(error: Error) {
        lock.lock()
        if closedError == nil { closedError = error }
        let failed = pending
        pending = [:]
        let reason = closedError ?? error
        lock.unlock()
        for (_, p) in failed { p.continuation.resume(throwing: reason) }
    }

    private func currentClosedError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return closedError
    }

    /// A failed write almost always means the process is dying; its exit closes the connection
    /// with the real reason (exit status, stderr). Give that a moment to arrive before failing the
    /// request with the bare write error.
    private func writeFailed(id: Int, error: Error) {
        afterWriteFailure { [weak self] closed in self?.failPending(id: id, error: closed ?? error) }
    }

    private func afterWriteFailure(_ body: @escaping (Error?) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            body(self?.currentClosedError())
        }
    }

    private func failPending(id: Int, error: Error) {
        lock.lock()
        let p = pending.removeValue(forKey: id)
        lock.unlock()
        p?.continuation.resume(throwing: error)
    }

    private func enqueueWrite(_ message: JSONValue, onFailure: ((Error) -> Void)? = nil, onSuccess: (() -> Void)? = nil) {
        writeQueue.async { [output] in
            do {
                var data = try Self.encoder.encode(message)
                data.append(0x0A)
                try Self.writeAll(data, to: output.fileDescriptor)
                onSuccess?()
            } catch {
                onFailure?(AgentBackendError.processExited("Couldn't write to the agent process: \(error.localizedDescription)"))
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += n
            }
        }
    }

    // MARK: Receiving

    private func readLoop() {
        let fd = input.fileDescriptor
        let chunkSize = 256 * 1024
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }
        var line = Data()
        while true {
            let n = Darwin.read(fd, chunk, chunkSize)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            if n == 0 { break }
            var start = 0
            while start < n, let found = memchr(chunk + start, 0x0A, n - start) {
                let end = found.assumingMemoryBound(to: UInt8.self) - chunk
                line.append(chunk + start, count: end - start)
                handleLine(line)
                line = Data()
                start = end + 1
            }
            if start < n { line.append(chunk + start, count: n - start) }
        }
        if !line.isEmpty { handleLine(line) }
        onEOF()
    }

    private func handleLine(_ data: Data) {
        // Skip blank lines and anything that isn't a JSON object (stray log output).
        guard data.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              case let .object(message) = JSONValue(foundation: object)
        else { return }
        onActivity()

        let id = message["id"].flatMap { $0 == .null ? nil : $0 }
        if case let .string(method)? = message["method"] {
            let params = message["params"] ?? .null
            if let id {
                onIncoming(.request(id: id, method: method, params: params))
            } else {
                onIncoming(.notification(method: method, params: params))
            }
            return
        }
        // A response to one of our requests (ids are ours, so integers; accept "7" too).
        guard let intID = id?.intValue else { return }
        lock.lock()
        let p = pending.removeValue(forKey: intID)
        lock.unlock()
        guard let p else { return }
        if let error = message["error"], error != .null {
            let text = error["message"]?.stringValue ?? error.jsonText
            p.continuation.resume(throwing: AgentBackendError.requestFailed(method: p.method, message: text))
        } else {
            p.continuation.resume(returning: message["result"] ?? .null)
        }
    }
}

extension JSONValue {
    /// Converts what `JSONSerialization` produces. It is much faster than `JSONDecoder` for the
    /// multi-megabyte lines the app server can send.
    init(foundation value: Any) {
        switch value {
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let a as [Any]:
            self = .array(a.map(JSONValue.init(foundation:)))
        case let o as [String: Any]:
            self = .object(o.mapValues(JSONValue.init(foundation:)))
        default:
            self = .null
        }
    }

    /// A JSON-RPC id as text: `7` → "7", `"req-1"` → "req-1".
    var idText: String {
        switch self {
        case let .string(s): return s
        case let .number(n): return n.rounded() == n && abs(n) < 9.007e15 ? String(Int64(n)) : String(n)
        default: return jsonText
        }
    }
}
