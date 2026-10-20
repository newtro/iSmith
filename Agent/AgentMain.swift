import AppKit
import Codes
import CodesXPC
import Foundation
import os
import UserNotifications

/// iSmith Agent: the background helper that receives SMS verification codes from the paired
/// phone (2FASync), with no Dock icon or menu bar (LSUIElement). launchd starts it at login and
/// keeps it alive once iSmith registers it (`SMAppService.agent`). It holds the relay stream,
/// owns the Mac's key pair and relay token (its own Keychain items), shows a notification per
/// code and answers iSmith over XPC. See Packages/Codes/INTEGRATION.md.
@main
enum AgentLauncher {
    @MainActor private static var delegate: AgentDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AgentDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

let agentLog = Logger(subsystem: "com.scottsmith.ismith.codes", category: "agent")

@MainActor
final class AgentDelegate: NSObject, NSApplicationDelegate {
    private var engine: CodesEngine?
    private var service: AgentService?
    private var listener: NSXPCListener?
    private var notifier: CodeNotifier?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard let identity = CodesIdentity(agentBundleID: bundleID) else {
            agentLog.fault("unexpected bundle id \(bundleID, privacy: .public); exiting")
            exit(1)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Its own folder, named by its bundle id: the Debug and Release agents never share one.
        let dataDir = support.appendingPathComponent(identity.agentBundleID, isDirectory: true)
        let config = CodesEngine.Config(
            dataDir: dataDir, relayURL: Self.relayURL(), macName: Host.current().localizedName ?? "Mac",
            agentVersion: Self.version,
            secrets: KeychainSecretStore(servicePrefix: identity.agentBundleID, labelPrefix: Self.displayName))
        let engine = CodesEngine(config: config)
        let notifier = CodeNotifier(engine: engine)
        engine.sink = notifier
        self.engine = engine
        self.notifier = notifier

        let service = AgentService(engine: engine)
        self.service = service
        let listener = NSXPCListener(machServiceName: identity.machServiceName)
        // Only the iSmith app of this configuration, signed by the team, may connect.
        listener.setConnectionCodeSigningRequirement(identity.appRequirement)
        listener.delegate = service
        listener.resume()
        self.listener = listener

        if engine.settings.notifications { notifier.requestAuthorization() }
        engine.start()
        agentLog.info("agent \(Self.version, privacy: .public) started; service \(identity.machServiceName, privacy: .public); paired \(engine.isPaired, privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
        CodePasteboard.clearAll()
    }

    /// The relay new pairings use. A Debug agent may be pointed at a local stand-in
    /// (`defaults write com.scottsmith.ismith.debug.agent CodesRelayURL http://127.0.0.1:8787`);
    /// a Release agent always uses the real one.
    static func relayURL() -> URL {
        let standard = URL(string: "https://2fa.johnnycode.ai")!
        #if DEBUG
        if let s = UserDefaults.standard.string(forKey: "CodesRelayURL") ?? ProcessInfo.processInfo.environment["ISMITH_CODES_RELAY"],
           let url = URL(string: s), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        #endif
        return standard
    }

    /// "1.3.7 (42)", compared with the app's own by the app after an update.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "iSmith Agent"
    }
}

/// The XPC service: decodes nothing but plain values, and runs each call on the main actor,
/// where the engine lives.
final class AgentService: NSObject, NSXPCListenerDelegate, CodesAgentProtocol, @unchecked Sendable {
    private let engine: CodesEngine

    init(engine: CodesEngine) {
        self.engine = engine
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: CodesAgentProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    private func onMain(_ work: @escaping @MainActor (CodesEngine) async -> Void) {
        let engine = engine
        Task { @MainActor in await work(engine) }
    }

    func status(reply: @escaping (Data) -> Void) {
        onMain { reply(CodesJSON.encode($0.status())) }
    }

    func startPairing(reply: @escaping (String?, String?, String?) -> Void) {
        onMain { engine in
            do {
                let started = try await engine.startPairing()
                reply(started.uri, started.pairingID, nil)
            } catch {
                agentLog.error("pairing didn't start: \(String(describing: error), privacy: .public)")
                reply(nil, nil, "\(error)")
            }
        }
    }

    func pairingState(reply: @escaping (Data) -> Void) {
        onMain { reply(CodesJSON.encode($0.pairingState())) }
    }

    func confirmPairing(reply: @escaping (String?) -> Void) {
        onMain { engine in
            do {
                try await engine.confirmPairing()
                reply(nil)
            } catch {
                reply("\(error)")
            }
        }
    }

    func cancelPairing(reply: @escaping () -> Void) {
        onMain { engine in
            await engine.cancelPairing()
            reply()
        }
    }

    func unpair(reply: @escaping (String?) -> Void) {
        onMain { engine in reply(await engine.unpair()) }
    }

    func recentCodes(forHost host: String?, reply: @escaping (Data) -> Void) {
        onMain { reply(CodesJSON.encode($0.recentCodes(for: host))) }
    }

    func markUsed(_ id: String, reply: @escaping () -> Void) {
        onMain { engine in
            engine.markUsed(id)
            reply()
        }
    }

    func settings(reply: @escaping (Data) -> Void) {
        onMain { reply(CodesJSON.encode($0.settings)) }
    }

    func setSettings(_ json: Data, reply: @escaping (String?) -> Void) {
        onMain { engine in
            guard let new = CodesJSON.decode(CodesSettings.self, from: json) else { return reply("Settings weren't understood.") }
            do {
                let turnedOn = new.notifications && !engine.settings.notifications
                try engine.setSettings(new)
                if turnedOn { (engine.sink as? CodeNotifier)?.requestAuthorization() }
                reply(nil)
            } catch {
                reply("Settings couldn't be saved (\(error)).")
            }
        }
    }

    func quit(reply: @escaping () -> Void) {
        onMain { _ in
            agentLog.info("asked to quit (the app has another version); launchd starts the new one")
            reply()
            // Give the reply a moment to leave, then exit; KeepAlive relaunches from the bundle on disk.
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        }
    }
}
