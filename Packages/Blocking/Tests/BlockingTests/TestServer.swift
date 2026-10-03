import Foundation
import Network

/// A tiny HTTP/1.1 server on 127.0.0.1 for web view tests. It answers every request with a
/// canned body by path, closes each connection, and records which host asked for which path, so
/// a test can tell a blocked request (never sent) from one that was answered.
final class TestServer: @unchecked Sendable {
    struct Request: Hashable {
        let host: String
        let path: String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "BlockingTests.TestServer")
    private let lock = NSLock()
    private var _requests: [Request] = []
    private let routes: [String: (type: String, body: String)]
    /// Paths that are never answered, for navigations that stay loading.
    var hangingPaths: Set<String> = []
    private var hanging: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var requests: [Request] { lock.withLock { _requests } }

    init(routes: [String: (type: String, body: String)]) throws {
        self.routes = routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // State updates arrive on the server's serial queue.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume()
                case let .failed(error):
                    once.done = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
        queue.sync { hanging.forEach { $0.cancel() } }
    }

    func didRequest(host: String, path: String) -> Bool {
        requests.contains(Request(host: host, path: path))
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let hostHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
        var host = hostHeader.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? ""
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") { host = String(host[..<colon]) }
        lock.withLock { _requests.append(Request(host: host, path: path)) }
        if hangingPaths.contains(path) {
            hanging.append(connection)
            return
        }

        let route = routes[path] ?? routes[String(path.prefix { $0 != "?" })]
        let status = route == nil ? "404 Not Found" : "200 OK"
        let body = Data((route?.body ?? "not found").utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(route?.type ?? "text/plain"); charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
