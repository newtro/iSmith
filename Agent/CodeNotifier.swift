import AppKit
import Codes
import CodesXPC
import Foundation
import UserNotifications

/// One notification per accepted code: "123456", "from chase.com" (or the sender), with a Copy
/// action. With previews hidden (or the Mac locked) macOS shows only "Verification code".
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
    }

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
        content.body = Self.snippet(message.body)
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

    /// The SMS text, on one line and clipped, for context under the code.
    static func snippet(_ body: String) -> String {
        let flat = body.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 180 ? String(flat.prefix(179)) + "…" : flat
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
/// 90 seconds or when the agent quits, unless something else was copied since.
@MainActor
enum CodePasteboard {
    static let clearAfter: TimeInterval = 90
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static var pending: [Int] = []

    static func copy(_ code: String, pasteboard: NSPasteboard = .general) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(code, forType: .string)
        pasteboard.setData(Data(), forType: concealed)
        pasteboard.setData(Data(), forType: transient)
        let count = pasteboard.changeCount
        pending.append(count)
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
            clear(pasteboard, ifStill: count)
        }
    }

    static func clearAll(_ pasteboard: NSPasteboard = .general) {
        for count in pending { clear(pasteboard, ifStill: count) }
    }

    private static func clear(_ pasteboard: NSPasteboard, ifStill count: Int) {
        if pasteboard.changeCount == count { pasteboard.clearContents() }
        pending.removeAll { $0 == count }
    }
}
