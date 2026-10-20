import AppKit
import CodesXPC
import CoreImage
import Passwords
import ServiceManagement
import SwiftUI

/// Settings ▸ Codes: receiving SMS verification codes from the phone through iSmith Agent
/// (2FASync). Turning it on registers the agent with launchd (`SMAppService.agent`); pairing,
/// the keys and the relay stream are the agent's.
@MainActor
final class CodesController: ObservableObject {
    static let shared = CodesController()

    /// Whether the user turned codes on (the agent's registration follows it).
    static let enabledKey = "codesEnabled"

    let service = SMAppService.agent(plistName: CodesClient.identity.launchAgentPlistName)
    let client = CodesClient.shared

    @Published private(set) var serviceStatus: SMAppService.Status = .notRegistered
    @Published private(set) var agent: AgentStatus?
    @Published private(set) var pairing = PairingInfo(state: .idle)
    @Published private(set) var qrURI: String?
    @Published private(set) var settings = CodesSettings.defaults
    @Published private(set) var recent: [CodeOffer] = []
    @Published var message: String?
    @Published private(set) var busy = false

    private var poll: Task<Void, Never>?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // MARK: - Launch

    /// At launch: when codes are on, make sure the agent is registered, and replace an agent
    /// that's running another version (after a Sparkle update the old binary keeps running until
    /// told to quit; launchd's KeepAlive starts the new one).
    func launchCheck() {
        serviceStatus = service.status
        guard enabled else { return }
        if serviceStatus != .enabled {
            register()
        }
        Task { await replaceOutdatedAgent() }
    }

    func replaceOutdatedAgent() async {
        guard let status = try? await client.status() else { return }
        if status.agentVersion != CodesClient.appVersion {
            NSLog("iSmith codes: agent \(status.agentVersion) isn't app \(CodesClient.appVersion); restarting it")
            try? await client.quit()
        }
    }

    // MARK: - On and off

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            register()
        } else {
            stopPolling()
            Task {
                if pairing.state == .waiting || pairing.state == .verify { try? await client.cancelPairing() }
                do {
                    try await service.unregister()
                } catch {
                    message = "iSmith Agent couldn't be turned off (\(error.localizedDescription))."
                }
                client.reset()
                serviceStatus = service.status
                agent = nil
                qrURI = nil
                pairing = PairingInfo(state: .idle)
            }
        }
        serviceStatus = service.status
    }

    private func register() {
        do {
            try service.register()
            message = nil
        } catch {
            // `.requiresApproval` also throws; the pane explains that case.
            if service.status != .requiresApproval {
                message = "iSmith Agent couldn't be started (\(error.localizedDescription))."
            }
        }
        serviceStatus = service.status
    }

    // MARK: - Refreshing while the pane is open

    func startPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    func refresh() async {
        serviceStatus = service.status
        guard enabled, serviceStatus == .enabled else {
            agent = nil
            return
        }
        do {
            let status = try await client.status()
            agent = status
            let state = try await client.pairingState()
            pairing = state
            if state.state != .waiting { qrURI = nil }
            settings = try await client.settings()
            recent = status.paired ? try await client.recentCodeSummaries() : []
        } catch {
            agent = nil
        }
    }

    // MARK: - Pairing

    func startPairing() {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let started = try await client.startPairing()
                qrURI = started.uri
                pairing = PairingInfo(state: .waiting)
            } catch {
                message = "\(error)"
            }
        }
    }

    func confirmPairing() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await client.confirmPairing()
                message = nil
            } catch {
                message = "\(error)"
            }
            await refresh()
        }
    }

    func cancelPairing() {
        Task {
            try? await client.cancelPairing()
            qrURI = nil
            await refresh()
        }
    }

    func unpair() {
        busy = true
        Task {
            defer { busy = false }
            do {
                message = try await client.unpair()
            } catch {
                message = "\(error)"
            }
            await refresh()
        }
    }

    func update(_ change: (inout CodesSettings) -> Void) {
        var new = settings
        change(&new)
        settings = new
        Task {
            do {
                try await client.setSettings(new)
            } catch {
                message = "\(error)"
            }
            await refresh()
        }
    }

    /// The pairing URI, for pasting into the Android emulator. It holds the pairing secret, so
    /// it's copied like a password: this Mac only, concealed, cleared after a minute.
    func copyURI() {
        guard let qrURI else { return }
        SecretPasteboard.copy(qrURI)
    }

    /// A crisp QR code for the URI (CoreImage's generator, scaled without smoothing).
    static func qrImage(_ text: String, size: CGFloat = 220) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (size / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct CodesSettingsView: View {
    @ObservedObject var codes: CodesController

    var body: some View {
        Form {
            Section {
                Toggle("Receive codes from my phone", isOn: Binding(get: { codes.enabled }, set: { codes.setEnabled($0) }))
                Text("Verification codes texted to your Android phone arrive here end-to-end encrypted, through 2FASync's relay, even when \(AppIdentity.displayName) isn't open. The relay only ever sees ciphertext.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if codes.enabled, codes.serviceStatus == .requiresApproval {
                    Label("macOS needs your OK to run iSmith Agent in the background.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                } else if codes.enabled, codes.serviceStatus == .enabled, codes.agent == nil {
                    Text("Starting iSmith Agent…").foregroundStyle(.secondary)
                }
                if let message = codes.message {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let problem = codes.agent?.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            if codes.enabled, let agent = codes.agent {
                Section("Phone") { phone(agent) }
                Section("When a code arrives") {
                    Toggle("Show a notification", isOn: Binding(get: { codes.settings.notifications },
                                                                 set: { v in codes.update { $0.notifications = v } }))
                    Toggle("Copy it to the clipboard", isOn: Binding(get: { codes.settings.copyToClipboard },
                                                                      set: { v in codes.update { $0.copyToClipboard = v } }))
                    Text("Off by default: any app can read the clipboard, and codes next to saved passwords make a compromised Mac worth more. The notification's Copy button works either way; copies are cleared after 90 seconds.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Offer codes in \(AppIdentity.displayName)'s code fields", isOn: Binding(get: { codes.settings.offerInBrowser },
                                                                                                  set: { v in codes.update { $0.offerInBrowser = v } }))
                }
                if agent.paired {
                    Section("Recent codes") {
                        if codes.recent.isEmpty {
                            Text("None in the last 10 minutes.").foregroundStyle(.secondary)
                        }
                        // The agent sends these masked; the codes themselves are in the notifications.
                        ForEach(codes.recent, id: \.id) { offer in
                            HStack {
                                Text(offer.code).font(.body.monospaced())
                                Text("from \(offer.domain ?? offer.sender)").foregroundStyle(.secondary)
                                Spacer()
                                Text(offer.receivedAt, style: .time).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { codes.startPolling() }
        .onDisappear { codes.stopPolling() }
    }

    @ViewBuilder
    private func phone(_ agent: AgentStatus) -> some View {
        if agent.paired {
            LabeledContent("Paired with") { Text(agent.phoneName ?? "Phone") }
            LabeledContent("Relay") {
                Text(agent.connected ? "Connected" : "Connecting…").foregroundStyle(.secondary)
            }
            if let last = agent.lastMessageAt {
                LabeledContent("Last code") { Text(last, style: .relative).foregroundStyle(.secondary) }
            }
            Button("Unpair", role: .destructive) { codes.unpair() }.disabled(codes.busy)
        } else {
            switch codes.pairing.state {
            case .waiting:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Scan this with 2FASync on your phone.")
                    if let uri = codes.qrURI, let image = CodesController.qrImage(uri) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                            .accessibilityLabel("Pairing QR code")
                        Text(uri).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3).foregroundStyle(.secondary)
                        Button("Copy Link") { codes.copyURI() }
                            .help("For pasting into an emulator. It's cleared from the clipboard after a minute.")
                    } else {
                        Text("Waiting for the phone…").foregroundStyle(.secondary)
                    }
                    Button("Cancel") { codes.cancelPairing() }
                }
            case .verify:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check that \(codes.pairing.phoneName ?? "your phone") shows the same number:")
                    Text(codes.pairing.fingerprint ?? "").font(.system(size: 34, weight: .semibold, design: .monospaced))
                    HStack {
                        Button("They match") { codes.confirmPairing() }.keyboardShortcut(.defaultAction).disabled(codes.busy)
                        Button("Cancel") { codes.cancelPairing() }
                    }
                }
            case .failed, .idle, .active:
                if codes.pairing.state == .failed, let why = codes.pairing.message {
                    Label(why, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
                Button("Pair Phone…") { codes.startPairing() }.disabled(codes.busy)
            }
        }
    }
}
