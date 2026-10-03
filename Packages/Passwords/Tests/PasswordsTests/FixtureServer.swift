import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 for the WebKit tests. It serves the HTML files in `Fixtures/`,
/// with `{{PORT}}` replaced by its port, so pages can embed frames from another origin:
/// `http://127.0.0.1:<port>` and `http://localhost:<port>` are different origins on one server.
final class FixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FixtureServer")
    private(set) var port: UInt16 = 0
    private let files: [String: String]

    init() throws {
        guard let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw NSError(domain: "FixtureServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Fixtures folder"])
        }
        var files: [String: String] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        where url.pathExtension == "html" {
            files["/" + url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
        }
        self.files = files
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    /// Starts listening and returns once the port is known.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The handler runs on `queue` only.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    self.port = self.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    func url(_ path: String, host: String = "127.0.0.1") -> URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(connection, requestLine: head.components(separatedBy: "\r\n").first ?? "")
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.receiveRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, requestLine: String) {
        let parts = requestLine.split(separator: " ")
        let target = parts.count > 1 ? String(parts[1]) : "/"
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
        let status: String
        let body: String
        if let file = files[path] {
            status = "200 OK"
            body = file.replacingOccurrences(of: "{{PORT}}", with: String(port))
        } else {
            status = "404 Not Found"
            body = "<!doctype html><title>Not found</title>"
        }
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in connection.cancel() })
    }
}
