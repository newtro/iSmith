import AppKit
import Codes
import CodesXPC
import Foundation
import UserNotifications

/// One notification per accepted code: "123456", "from chase.com" (or the sender), with a Copy
/// action, and no SMS text. With previews hidden (or the Mac locked) macOS shows only
/// "Verification code". Notification Center keeps what it shows, so notifications older than the
/// codes' 10 minutes are swept by wall-clock time (at launch and every minute, so sleep doesn't
/// stretch it), all of them go when the pairing goes or launchd stops the agent.
/// Copies and the automatic clipboard copy go through `CodePasteboard`.
@MainActor
final class CodeNotifier: NSObject, CodeSink, UNUserNotificationCenterDelegate {
    static let category = "code"
    static let copyAction = "copy"

    private let center = UNUserNotificationCenter.current()
    private weak var engine: CodesEngine?

    init(engine: CodesEngine) {
        self.engine = engine
        super.init()
        center.delegate = self
        let copy = UNNotificationAction(identifier: Self.copyAction, title: "Copy", options: [])
        let category = UNNotificationCategory(identifier: Self.category, actions: [copy], intentIdentifiers: [],
                                              hiddenPreviewsBodyPlaceholder: "Verification code", options: [])
        center.setNotificationCategories([category])
        sweep()
        sweeper = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    private var sweeper: Timer?

    /// Removes code notifications delivered more than 10 minutes ago (wall clock).
    func sweep() {
        let cutoff = Date().addingTimeInterval(-RecentCodes.lifetime)
        let category = Self.category
        Task { @MainActor in
            let notes = await center.deliveredNotifications()
            let old = notes.filter { $0.request.content.categoryIdentifier == category && $0.date < cutoff }
                .map(\.request.identifier)
            if !old.isEmpty { center.removeDeliveredNotifications(withIdentifiers: old) }
        }
    }

    func removeAll() {
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    func pairingForgotten() { removeAll() }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            agentLog.info("notifications allowed: \(granted, privacy: .public)")
        }
    }

    func deliver(_ message: CodeMessage, settings: CodesSettings) async {
        if settings.copyToClipboard {
            CodePasteboard.copy(message.code)
        }
        guard settings.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = message.code
        content.subtitle = "from \(message.domain ?? message.sender)"
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.threadIdentifier = "codes"
        // Only the id: the Copy action looks the code up in memory, and nothing else about the
        // message is kept with the notification.
        content.userInfo = ["id": message.id]
        do {
            try await center.add(UNNotificationRequest(identifier: message.id, content: content, trigger: nil))
        } catch {
            agentLog.error("notification not posted: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let id = response.notification.request.content.userInfo["id"] as? String
        Task { @MainActor in
            if action == Self.copyAction, let id, let offer = self.engine?.recent.code(id: id) {
                CodePasteboard.copy(offer.code)
            }
            completionHandler()
        }
    }
}

/// A code on the clipboard the way iSmith copies passwords (the Passwords package's
/// `SecretPasteboard`, whose package the agent doesn't link): this Mac only (no Universal
/// Clipboard), marked concealed and transient so clipboard managers skip it, and cleared after
/// 90 seconds unless something else was copied since. The pasteboard's change count and the
/// deadline are kept in the agent's data folder and checked by wall-clock time every 10 seconds
/// and at launch, so a restart, a SIGTERM or sleep doesn't leave the code there.
@MainActor
enum CodePasteboard {
    static let clearAfter: TimeInterval = 90
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// `clipboard.json` in the agent's data folder; set at launch.
    static var stateURL: URL?
    private static var sweeper: Timer?

    struct State: Codable {
        var changeCount: Int
        var clearAt: Date
    }

    static func copy(_ code: String, pasteboard: NSPasteboard = .general) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(code, forType: .string)
        pasteboard.setData(Data(), forType: concealed)
        pasteboard.setData(Data(), forType: transient)
        save(State(changeCount: pasteboard.changeCount, clearAt: Date().addingTimeInterval(clearAfter)))
        startSweeping()
    }

    /// At launch: clears a code an earlier run left past its deadline, and keeps watching one
    /// that isn't due yet.
    static func launch(stateURL: URL) {
        self.stateURL = stateURL
        sweep()
        if load() != nil { startSweeping() }
    }

    static func sweep(pasteboard: NSPasteboard = .general, now: Date = Date()) {
        guard let state = load() else { return stopSweeping() }
        if pasteboard.changeCount != state.changeCount {
            forget() // something else was copied since: nothing of ours is there
        } else if now >= state.clearAt {
            pasteboard.clearContents()
            forget()
        }
    }

    /// Clears our code now if it's still there (quit, SIGTERM).
    static func clearAll(_ pasteboard: NSPasteboard = .general) {
        if let state = load(), pasteboard.changeCount == state.changeCount { pasteboard.clearContents() }
        forget()
    }

    private static func startSweeping() {
        guard sweeper == nil else { return }
        sweeper = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { sweep() }
        }
    }

    private static func stopSweeping() {
        sweeper?.invalidate()
        sweeper = nil
    }

    private static var memory: State?

    private static func load() -> State? {
        if let memory { return memory }
        guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return nil }
        memory = CodesJSON.decode(State.self, from: data)
        return memory
    }

    private static func save(_ state: State) {
        memory = state
        guard let stateURL else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try CodesJSON.encode(state).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch {
            agentLog.error("clipboard deadline not saved: \(String(describing: error), privacy: .public)")
        }
    }

    private static func forget() {
        memory = nil
        if let stateURL { try? FileManager.default.removeItem(at: stateURL) }
        stopSweeping()
    }
}
