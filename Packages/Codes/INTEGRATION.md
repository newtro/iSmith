# Codes: how iSmith, iSmith Agent and the relay connect

SMS verification codes from Scott's Android phone (2FASync) reach the Mac end-to-end encrypted
and show within about a second, even when iSmith isn't open. The wire contract is
`2FASync/protocol/PROTOCOL.md`; `Tests/CodesTests/Resources/crypto_vectors.json` is a copy of its
test vectors, which the package tests reproduce byte for byte.

```
phone ──POST /v1/messages──► relay (2fa.johnnycode.ai) ──WebSocket /v1/stream──► iSmith Agent ◄──XPC── iSmith
         sealed envelope       ciphertext only, deleted       Authorization:        notification,
                               on ack or after 10 min         Bearer <Mac token>    clipboard, recent codes
```

## Pieces

| Piece | Where | What it does |
|---|---|---|
| `CodesXPC` (library) | `Sources/CodesXPC` | The XPC protocol `CodesAgentProtocol`, the `Codable` values it carries, `CodesIdentity` (every Debug/Release name and code-signing requirement). The app links only this. |
| `Codes` (library) | `Sources/Codes` | The agent's engine, no UI: wire types, libsodium `crypto_box` (swift-sodium's `Clibsodium`, pinned 0.9.1), pairing, relay HTTP client, the WebSocket stream, receiver rules, the seen set, recent codes, settings, the Keychain store. `CodesEngine` ties them together. |
| `FakeRelayKit`, `FakeRelay` | `Sources/FakeRelay*` | A stand-in relay (HTTP and WebSocket on one 127.0.0.1 port, real sockets) and phone, for the tests and a local end-to-end run. Never shipped. |
| iSmith Agent | `Agent/` (target `iSmithAgent`) | `iSmith.app/Contents/Library/LoginItems/iSmith Agent.app`, LSUIElement. Runs `CodesEngine`, publishes the XPC service, posts notifications, copies codes. |
| launchd plist | written at build time | `iSmith.app/Contents/Library/LaunchAgents/<agent id>.plist`, from build settings by the app target's "Write the iSmith Agent launchd plist" script (XcodeGen can't vary a file per configuration). |
| App side | `App/CodesClient.swift`, `App/CodesSettings.swift` | `CodesClient` (XPC), `CodesController` and Settings ▸ Codes. |

## Debug vs Release

| | Release | Debug ("iSmith Dev") |
|---|---|---|
| App bundle id | `com.scottsmith.ismith` | `com.scottsmith.ismith.debug` |
| Agent bundle id, launchd label | `com.scottsmith.ismith.agent` | `com.scottsmith.ismith.debug.agent` |
| Mach service | `232A77467G.com.scottsmith.ismith.agent` | `232A77467G.com.scottsmith.ismith.debug.agent` |
| Plist | `com.scottsmith.ismith.agent.plist` | `com.scottsmith.ismith.debug.agent.plist` |
| Agent display name | iSmith Agent | iSmith Dev Agent |
| Agent data | `~/Library/Application Support/com.scottsmith.ismith.agent/` | `…/com.scottsmith.ismith.debug.agent/` |
| Keychain items | `com.scottsmith.ismith.agent.mac-key`, `.mac-token` | `com.scottsmith.ismith.debug.agent.mac-key`, `.mac-token` |
| Relay | always `https://2fa.johnnycode.ai` | same, unless `defaults write com.scottsmith.ismith.debug.agent CodesRelayURL http://127.0.0.1:8787` |

The agent requires its caller to satisfy
`anchor apple generic and certificate leaf[subject.OU] = "232A77467G" and identifier "<app id>"`
(`NSXPCListener.setConnectionCodeSigningRequirement`), and the app requires the same of the agent
with the agent's id (`NSXPCConnection.setCodeSigningRequirement`). So Debug and Release never talk
to each other, and nothing unsigned or from another team reaches either. `Tools/update-test.sh`
gives its test builds their own agent id as well.

The plist: `Label`, `BundleProgram` (`Contents/Library/LoginItems/iSmith Agent.app/Contents/MacOS/iSmith Agent`),
`AssociatedBundleIdentifiers` (the app, so Login Items shows iSmith), `MachServices`,
`KeepAlive` and `RunAtLoad` true, `ProcessType` Interactive (no App Nap delay on a code). The
build script checks that the embedded agent's bundle id is the one it names.

## What the agent owns

- The Mac's X25519 key pair (the secret key; the public one is derived) and the Mac bearer token,
  as generic passwords in the login Keychain, created by the agent, so their access list trusts
  the agent and not iSmith. iSmith never reads them.
- `pairing.json` (0600, folder 0700): relay URL, pairing id, the phone's public key and name, the
  Mac's public key, when it paired.
- `seen.json` (0600): the `(id, ctr)` pairs accepted in the last 20 minutes, for the pairing in use.
- `settings.json` (0600): notifications (on), clipboard copy (off), offer in iSmith (on).
- Recent codes: memory only, 10 minutes.

## Pairing (PROTOCOL.md §2)

`startPairing` → `POST /v1/pair/start`, a fresh key pair and 32-byte secret `S`, the QR URI
`2fasync://pair?v=1&u=…&p=…&t=…&k=…&s=…&n=…`. The agent polls `GET /v1/pair` every second; on
`pending` it checks the phone's HMAC proof against `S` in constant time. A mismatch (a relay that
swapped the key) deletes the pairing: "Pairing failed: the phone's key didn't check out." Otherwise
`pairingState` reports `verify` with the fingerprint ("123 456") and phone name; `confirmPairing`
(the user's "They match") posts `/v1/pair/confirm`, saves the key and token in the Keychain, writes
`pairing.json`, clears the seen set and opens the stream. Pairing expires after 10 minutes.
Starting a pairing while paired is refused (unpair first).

Note: "2fasync" starts with a digit, which RFC 3986 doesn't allow in a URI scheme; Foundation's
`URL`/`URLComponents` reject the whole string. The Mac only writes it; the test phone splits it by hand.

## Receiving (PROTOCOL.md §3)

Each stream frame is handled one at a time: the box must open with the paired phone's key, the
plaintext must be v1 JSON with valid fields, the inner id must equal the envelope's, `ts` within
−10 min / +2 min, and neither the id nor the counter seen before. An accepted code goes to recent
codes, then the notification and (if on) the clipboard; only then is it acked
(`{"type":"ack","ids":[…]}` on the socket, `POST /v1/ack` if the socket closed meanwhile).
Dropped messages are acked too, and logged by reason only. Nothing logs a code, body, key or token.

The stream reconnects with exponential backoff (1 s doubling to 60 s, times a random 0.5–1.0),
reset after 30 s of a stable connection. URLSession answers the relay's pings without telling us,
so the agent pings every 25 s itself and treats 60 s without a frame or a pong as a dead
connection. Close 4409 (another stream for the pairing took over) waits at least 30 s.
`{"type":"revoked"}`, close 4401, a 401 at the upgrade or a 401 on `POST /v1/ack` mean the
pairing is gone: the agent forgets the keys, token, phone and codes, and Settings says so.

## Notifications and the clipboard

Title the code ("123456"), subtitle "from chase.com" (the WebOTP domain, else the SMS sender),
body a one-line snippet of the text; category with a Copy action and
`hiddenPreviewsBodyPlaceholder` "Verification code", so with previews hidden or the Mac locked
only that shows. `userInfo` holds only the message id; Copy looks the code up in memory. Copies
work like the Passwords package's `SecretPasteboard` (this Mac only, concealed and transient
types, cleared after 90 s or at quit unless something else was copied). The agent doesn't link
the Passwords package (it would pull in GRDB and SignInSync), so `CodePasteboard` in
`Agent/CodeNotifier.swift` repeats that logic.

## The XPC interface (`CodesAgentProtocol`)

Plain types only: strings, `Data` holding JSON of the `CodesXPC` values (dates as Unix ms). Every
call replies; `CodesClient` gives up after 30 s.

| Call | Reply |
|---|---|
| `status` | `AgentStatus`: paired, phone name, connected, last message time, agent version "1.3.7 (42)", problem, process id |
| `startPairing` | QR URI and pairing id, or an error |
| `pairingState` | `PairingInfo`: idle / waiting / verify / active / failed, fingerprint, phone name, message |
| `confirmPairing`, `cancelPairing`, `unpair` | error or warning, or nil |
| `recentCodes(forHost:)` | `[CodeOffer]` (id, code, sender, domain, receivedAt). With a host: unused codes bound to that host or a parent domain (`login.chase.com` gets `chase.com`'s; `evilchase.com` doesn't), plus unbound codes under 2 minutes old, and nothing when "offer in iSmith" is off. With nil: every code still kept (Settings). |
| `markUsed(id)` | the code isn't offered again |
| `settings`, `setSettings` | `CodesSettings` |
| `quit` | the agent replies, then exits; launchd starts it again |

`CodesClient.recentCodes(for:)` and `markUsed` are what the code-field autofill (next phase) uses.

## The Sparkle relaunch rule

A Sparkle update replaces iSmith.app, agent included, but the running agent is the old binary.
At launch, when codes are on, iSmith makes sure the agent is registered and compares
`AgentStatus.agentVersion` with its own "short (build)" version; when they differ it calls `quit`,
and launchd's KeepAlive starts the new binary from the bundle now on disk (about 10 s later,
launchd's throttle). The end-to-end test checks that the process id changes and the pairing survives.

## Settings ▸ Codes

"Receive codes from my phone" registers or unregisters the agent (`SMAppService.agent`); when macOS
wants approval (`.requiresApproval`) the pane says so with a button to
`SMAppService.openSystemSettingsLoginItems()`. "Pair Phone…" shows the QR code (CoreImage
`CIQRCodeGenerator`), the URI as selectable text and "Copy Link" (for the Android emulator;
copied like a password since it holds `S`), then the fingerprint with "They match" / "Cancel", then
"Paired with Galaxy S24" and "Unpair". Toggles for notifications, clipboard copy (off, with the
reason) and offering codes in iSmith; recent codes are listed masked, with an eye button.

## Tests

- `swift test` here: the vectors (keys from seeds, proof, fingerprint, the swapped-key proof,
  opening and re-sealing each message byte for byte, both must-fail envelopes), the receiver rules
  (replay by id and by counter, out-of-order counters, stale and future `ts`, id mismatch, a
  stranger's key, bad plaintext, the seen set on disk, owner-only, per pairing), the WebOTP binding,
  and the engine against `FakeRelayServer`: pairing, a key-swapping relay, cancel, delivery and
  acks, replays and forgeries acked but not delivered, reconnect with queued messages, the
  liveness timeout, 4409 backoff, revocation, unpair, restart, settings, a refused token.
- `AppTests/CodesWiringTests`: the built Debug bundle's agent and plist names, and the QR code
  decoding back to the URI. `testEndToEndThroughLaunchdAndXPC` is opt-in (it registers the Debug
  agent, then unregisters it):

```bash
(cd Packages/Codes && swift run FakeRelay 8787) &
defaults write com.scottsmith.ismith.debug.agent CodesRelayURL http://127.0.0.1:8787
TEST_RUNNER_ISMITH_CODES_E2E_RELAY=http://127.0.0.1:8787 xcodebuild -project iSmith.xcodeproj \
  -scheme iSmith -configuration Debug -derivedDataPath build test -only-testing:iSmithTests/CodesWiringTests
defaults delete com.scottsmith.ismith.debug.agent CodesRelayURL
```

To run it against the real relay locally, start the relay on 127.0.0.1:3321, point `CodesRelayURL`
and `TEST_RUNNER_ISMITH_CODES_E2E_RELAY` at it, and set
`TEST_RUNNER_ISMITH_CODES_E2E_PHONE=http://127.0.0.1:8787` (FakeRelay's phone hooks pair through
whatever relay the URI names).
