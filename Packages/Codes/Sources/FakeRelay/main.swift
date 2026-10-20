import FakeRelayKit
import Foundation

// A local stand-in for the 2FASync relay, for an end-to-end run of the real iSmith Agent without
// the deployed relay: `swift run FakeRelay [port]` (default 8787) serves http://127.0.0.1:<port>.
// Test hooks: POST /test/phone/pair {"uri": "twofasync://…"} pairs a fake phone with the QR URI;
// POST /test/phone/send {"code": "123456", "domain": "example.com"} sends it a code.
let port = CommandLine.arguments.dropFirst().first.flatMap(UInt16.init) ?? 8787
let server = FakeRelayServer()
do {
    try server.start(port: port)
} catch {
    FileHandle.standardError.write(Data("FakeRelay: couldn't listen on \(port): \(error)\n".utf8))
    exit(1)
}
print("FakeRelay listening on \(server.baseURL.absoluteString)")
setvbuf(stdout, nil, _IOLBF, 0)
dispatchMain()
