import Foundation

/// One Brave profile folder (`Default`, `Profile 1`, …) and what it holds that can be imported.
public struct BraveProfile: Equatable, Sendable {
    /// The folder name, such as `Default` or `Profile 2`. Stable; use it as the identifier.
    public var directoryName: String
    /// The name the user gave the profile in Brave (from `Local State`), or the folder name.
    public var displayName: String
    public var url: URL

    public var bookmarksURL: URL { url.appendingPathComponent("Bookmarks") }
    public var loginDataURL: URL { url.appendingPathComponent("Login Data") }
    public var accountLoginDataURL: URL { url.appendingPathComponent("Login Data For Account") }

    public var hasBookmarks: Bool { FileManager.default.fileExists(atPath: bookmarksURL.path) }
    public var hasPasswords: Bool {
        FileManager.default.fileExists(atPath: loginDataURL.path)
            || FileManager.default.fileExists(atPath: accountLoginDataURL.path)
    }

    public init(directoryName: String, displayName: String, url: URL) {
        self.directoryName = directoryName
        self.displayName = displayName
        self.url = url
    }
}

/// Finds Brave's profiles. Only reads: `Local State` for the names, and the folder listing.
public enum BraveProfiles {
    /// `~/Library/Application Support/BraveSoftware/Brave-Browser`.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser", isDirectory: true)
    }

    /// The profiles under `root`, in Brave's own order where `Local State` gives one, then
    /// `Default` and `Profile N` by number. A folder counts as a profile when it is named
    /// `Default` or `Profile N`, or is listed in `Local State`, and has bookmarks or passwords.
    /// Brave's internal `System Profile` and `Guest Profile` are never returned.
    /// Returns an empty list when Brave isn't installed.
    public static func discover(root: URL = defaultRoot) throws -> [BraveProfile] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        let state = try LocalState.read(root.appendingPathComponent("Local State"))
        // Only plain folder names from Local State: never a path that leads outside `root`.
        var candidates = Set(state.names.keys.filter { !$0.isEmpty && !$0.contains("/") && !$0.hasPrefix(".") })
        for name in try BraveFiles.list(root) where isProfileFolderName(name) {
            candidates.insert(name)
        }
        candidates.subtract(["System Profile", "Guest Profile"])

        let profiles = candidates.compactMap { name -> BraveProfile? in
            let url = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let display = state.names[name].flatMap { $0.isEmpty ? nil : $0 } ?? name
            let profile = BraveProfile(directoryName: name, displayName: display, url: url)
            return profile.hasBookmarks || profile.hasPasswords ? profile : nil
        }
        return profiles.sorted { a, b in
            let ia = state.order.firstIndex(of: a.directoryName) ?? Int.max
            let ib = state.order.firstIndex(of: b.directoryName) ?? Int.max
            if ia != ib { return ia < ib }
            return folderRank(a.directoryName) < folderRank(b.directoryName)
        }
    }

    static func isProfileFolderName(_ name: String) -> Bool {
        if name == "Default" { return true }
        guard name.hasPrefix("Profile ") else { return false }
        return Int(name.dropFirst("Profile ".count)) != nil
    }

    /// `Default` first, then `Profile N` by number, then anything else by name.
    private static func folderRank(_ name: String) -> (Int, Int, String) {
        if name == "Default" { return (0, 0, name) }
        if name.hasPrefix("Profile "), let n = Int(name.dropFirst("Profile ".count)) { return (1, n, name) }
        return (2, 0, name)
    }
}

/// The parts of Brave's `Local State` used here: `profile.info_cache.<folder>.name` and
/// `profile.profiles_order`. A missing or malformed file gives no names, not an error; a file
/// macOS refuses to let us read throws, so the refusal isn't hidden.
struct LocalState {
    var names: [String: String] = [:]
    var order: [String] = []

    static func read(_ url: URL) throws -> LocalState {
        guard let data = try BraveFiles.readIfPresent(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any] else { return LocalState() }
        var state = LocalState()
        if let cache = profile["info_cache"] as? [String: Any] {
            for (folder, info) in cache {
                state.names[folder] = (info as? [String: Any])?["name"] as? String ?? ""
            }
        }
        state.order = profile["profiles_order"] as? [String] ?? []
        return state
    }
}
