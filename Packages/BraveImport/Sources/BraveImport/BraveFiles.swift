import Foundation

public enum BraveAccessError: Error, Equatable {
    /// macOS refused to let this process read Brave's data. Recent macOS versions protect other
    /// apps' data: the folder can be seen, but reading it needs the user's consent (the system
    /// prompt, or the app allowed in System Settings › Privacy & Security). The app should explain
    /// that and let the user retry; nothing here works around it.
    case permissionDenied(path: String)
}

/// Every read of Brave's files goes through here: read-only, with a refused read reported as
/// `BraveAccessError.permissionDenied` rather than a generic Cocoa error.
enum BraveFiles {
    static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .uncached)
        } catch {
            throw mapped(error, url)
        }
    }

    static func list(_ url: URL) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            throw mapped(error, url)
        }
    }

    /// Reads a file, or returns nil when it doesn't exist. Any other failure throws, so a refused
    /// read never looks like "nothing there".
    static func readIfPresent(_ url: URL) throws -> Data? {
        do {
            return try read(url)
        } catch where isMissing(error) {
            return nil
        }
    }

    static func isMissing(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == CocoaError.fileReadNoSuchFile.rawValue || ns.code == CocoaError.fileNoSuchFile.rawValue {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isMissing(underlying) }
        return false
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileReadNoPermission.rawValue { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }

    private static func mapped(_ error: Error, _ url: URL) -> Error {
        isPermissionDenied(error) ? BraveAccessError.permissionDenied(path: url.path) : error
    }
}
