import AppKit

/// Copies a password or username for the manager window's "Copy". The item is marked
/// concealed and transient (the nspasteboard.org markers clipboard managers honor, so they don't
/// record it), and it's cleared after `clearAfter` seconds unless something else was copied since.
@MainActor
public enum SecretPasteboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    public static func copy(_ secret: String, clearAfter seconds: TimeInterval = 60,
                            pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed, transient], owner: nil)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: concealed)
        pasteboard.setData(Data(), forType: transient)
        let count = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if pasteboard.changeCount == count { pasteboard.clearContents() }
        }
    }
}
