import Foundation
import XCTest
@testable import AgentKit

final class JSONRPCConnectionTests: XCTestCase {
    /// Reads one newline-terminated line the connection wrote.
    private func readLine(_ handle: FileHandle) -> JSONValue? {
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty || byte == Data([0x0A]) { break }
            data.append(byte)
        }
        return JSONValue.parse(String(decoding: data, as: UTF8.self))
    }

    func testSplitsLinesRoutesMessagesAndEchoesIDs() async throws {
        let toServer = Pipe(), fromServer = Pipe()
        let incoming = Box<String>()
        let connection = JSONRPCConnection(
            output: toServer.fileHandleForWriting, input: fromServer.fileHandleForReading, label: "test",
            onIncoming: { message in
                switch message {
                case let .notification(method, params): incoming.append("note \(method) \(params.jsonText)")
                case let .request(id, method, _): incoming.append("request \(id.jsonText) \(method)")
                }
            })
        connection.startReading()

        async let first = connection.request("ping", params: ["n": 1])
        async let second = connection.request("fail")
        let sent = [readLine(toServer.fileHandleForReading), readLine(toServer.fileHandleForReading)].compactMap { $0 }
        XCTAssertEqual(Set(sent.compactMap { $0["method"]?.stringValue }), ["ping", "fail"])
        XCTAssertTrue(sent.allSatisfy { $0["jsonrpc"] == "2.0" && $0["id"]?.intValue != nil })
        let pingID = try XCTUnwrap(sent.first { $0["method"] == "ping" }?["id"]?.intValue)
        let failID = try XCTUnwrap(sent.first { $0["method"] == "fail" }?["id"]?.intValue)

        // One write holding several messages (no "jsonrpc" field), then a response split mid-line,
        // plus noise that isn't JSON.
        let out = fromServer.fileHandleForWriting
        out.write(Data(("""
        {"method":"turn/started","params":{"a":1}}
        not json
        {"id":"req-7","method":"item/tool/call","params":{}}
        {"id":12,"method":"currentTime/read"}

        {"id":\(failID),"error":{"code":-1,"message":"nope"}}
        {"id":\(pingID),"res
        """).utf8))
        out.write(Data(#"ult":{"pong":true}}"#.utf8 + [0x0A]))

        let pong = try await first
        XCTAssertEqual(pong, ["pong": true])
        do {
            _ = try await second
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentBackendError, .requestFailed(method: "fail", message: "nope"))
        }
        XCTAssertEqual(incoming.all, [#"note turn/started {"a":1}"#, #"request "req-7" item/tool/call"#, "request 12 currentTime/read"])

        connection.reply(id: "req-7", result: ["ok": true])
        connection.replyError(id: 12, code: -32601, message: "unsupported")
        XCTAssertEqual(readLine(toServer.fileHandleForReading), ["jsonrpc": "2.0", "id": "req-7", "result": ["ok": true]])
        XCTAssertEqual(readLine(toServer.fileHandleForReading),
                       ["jsonrpc": "2.0", "id": 12, "error": ["code": -32601, "message": "unsupported"]])

        // Closing fails what's pending and anything sent later.
        async let hanging = connection.request("never")
        _ = readLine(toServer.fileHandleForReading)
        connection.close(error: AgentBackendError.notRunning)
        do { _ = try await hanging; XCTFail() } catch { XCTAssertEqual(error as? AgentBackendError, .notRunning) }
        do { _ = try await connection.request("later"); XCTFail() } catch { XCTAssertEqual(error as? AgentBackendError, .notRunning) }
        try out.close()
    }
}
