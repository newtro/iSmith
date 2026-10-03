import Foundation
import Network
import WebKit
import XCTest

/// A tiny HTTP/1.1 server on 127.0.0.1 for web view tests: canned responses by path, one request
/// per connection.
final class TestHTTPServer: @unchecked Sendable {
    struct Response {
        var type = "text/html; charset=utf-8"
        var headers: [String: String] = [:]
        var body: Data

        static func html(_ s: String) -> Response { Response(body: Data(s.utf8)) }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "iSmithTests.TestHTTPServer")
    private let routes: [String: Response]
    private(set) var port: UInt16 = 0

    var origin: String { "http://127.0.0.1:\(port)" }
    func url(_ path: String) -> URL { URL(string: origin + path)! }

    init(routes: [String: Response]) throws {
        self.routes = routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class Flag: @unchecked Sendable { var done = false }
            let flag = Flag()
            listener.stateUpdateHandler = { state in
                guard !flag.done else { return }
                switch state {
                case .ready: flag.done = true; continuation.resume()
                case let .failed(error): flag.done = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

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
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.respond(path: String(path.split(separator: "?").first ?? ""), on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(path: String, on connection: NWConnection) {
        let response = routes[path]
        var head = response == nil ? "HTTP/1.1 404 Not Found\r\n" : "HTTP/1.1 200 OK\r\n"
        let body = response?.body ?? Data("not found".utf8)
        head += "Content-Type: \(response?.type ?? "text/plain")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in response?.headers ?? [:] { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Waits for a web view's navigations to finish.
@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {
    var finishCount = 0

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishCount += 1 }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishCount += 1 }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishCount += 1
    }

    /// Waits for the next finished (or failed) navigation, up to `timeout` seconds.
    func next(timeout: TimeInterval = 10) async {
        let start = finishCount
        let deadline = Date().addingTimeInterval(timeout)
        while finishCount == start, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Polls a condition on the main actor until it holds or time runs out.
@MainActor
func eventually(timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
    return await condition()
}
