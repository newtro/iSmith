import AppKit

/// Copies a password or username for the manager window's "Copy". The item stays on this Mac
/// (no Universal Clipboard), is marked concealed and transient (the nspasteboard.org markers
/// clipboard managers honor, so they don't record it), and is cleared after `clearAfter` seconds,
/// or when the app quits, unless something else was copied since.
@MainActor
public enum SecretPasteboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// Pasteboards holding a secret we copied, with the change count that copy produced.
    private static var pending: [(pasteboard: NSPasteboard, count: Int)] = []
    private static var quitObserver: NSObjectProtocol?

    public static func copy(_ secret: String, clearAfter seconds: TimeInterval = 60,
                            pasteboard: NSPasteboard = .general) {
        // No declareTypes here: it would start the contents over without the current-host option.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: concealed)
        pasteboard.setData(Data(), forType: transient)
        let count = pasteboard.changeCount
        pending.append((pasteboard, count))
        watchForQuit()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            clear(pasteboard, ifStill: count)
        }
    }

    /// Clears every secret this app copied that is still on its pasteboard. Called at quit.
    public static func clearAll() {
        for item in pending { clear(item.pasteboard, ifStill: item.count) }
    }

    private static func clear(_ pasteboard: NSPasteboard, ifStill count: Int) {
        if pasteboard.changeCount == count { pasteboard.clearContents() }
        pending.removeAll { $0.pasteboard === pasteboard && $0.count == count }
    }

    private static func watchForQuit() {
        guard quitObserver == nil else { return }
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { clearAll() }
        }
    }
}
