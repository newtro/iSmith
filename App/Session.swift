import Foundation
import SignInSync

/// What's open: windows → spaces → groups → tabs with their URLs. Saved to `session.json` next to
/// `config.json`, owner-only, and read at launch.
///
/// Config holds what a space *is* (name, color, accounts, rail order); the session holds what's
/// open in it. They're separate files because the session changes every time a page navigates,
/// and config is rewritten rarely and carefully.
///
/// P1 restores tabs, groups and each window's spaces from it. P2 extends the same records with
/// each tab's back/forward history (`interactionState`) and crash-safe saving; fields added later
/// decode with defaults, so older files still load.
struct SessionFile: Codable, Equatable {
    var version = 1
    var windows: [WindowRecord] = []

    init(windows: [WindowRecord] = []) {
        self.windows = windows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        windows = try c.decodeIfPresent([WindowRecord].self, forKey: .windows) ?? []
    }
}

struct WindowRecord: Codable, Equatable {
    var id: UUID
    /// `NSWindow.frameDescriptor`.
    var frame: String?
    var activeSpace: String?
    var spaces: [SpaceRecord]

    init(id: UUID, frame: String?, activeSpace: String?, spaces: [SpaceRecord]) {
        (self.id, self.frame, self.activeSpace, self.spaces) = (id, frame, activeSpace, spaces)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        frame = try c.decodeIfPresent(String.self, forKey: .frame)
        activeSpace = try c.decodeIfPresent(String.self, forKey: .activeSpace)
        spaces = try c.decodeIfPresent([SpaceRecord].self, forKey: .spaces) ?? []
    }
}

/// One space's tabs in one window.
struct SpaceRecord: Codable, Equatable {
    var space: String
    var selected: UUID?
    var groups: [TabGroup]
    var tabs: [TabRecord]

    init(space: String, selected: UUID?, groups: [TabGroup], tabs: [TabRecord]) {
        (self.space, self.selected, self.groups, self.tabs) = (space, selected, groups, tabs)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        space = try c.decode(String.self, forKey: .space)
        selected = try c.decodeIfPresent(UUID.self, forKey: .selected)
        groups = try c.decodeIfPresent([TabGroup].self, forKey: .groups) ?? []
        tabs = try c.decodeIfPresent([TabRecord].self, forKey: .tabs) ?? []
    }

    /// The layout these records describe, repaired if the file was edited by hand.
    var layout: TabLayout {
        TabLayout(slots: tabs.map { TabLayout.Slot(id: $0.id, group: $0.group) }, groups: groups, selected: selected)
    }
}

struct TabRecord: Codable, Equatable {
    var id: UUID
    var url: URL?
    var title: String
    var group: UUID?
    /// The tab's own Keep alive setting; nil follows the automatic rule for its page.
    var keepAlive: Bool?

    init(id: UUID, url: URL?, title: String, group: UUID?, keepAlive: Bool?) {
        (self.id, self.url, self.title, self.group, self.keepAlive) = (id, url, title, group, keepAlive)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        group = try c.decodeIfPresent(UUID.self, forKey: .group)
        keepAlive = try c.decodeIfPresent(Bool.self, forKey: .keepAlive)
    }
}

/// Reads and writes session.json. A file that can't be read is copied aside (as config.json is)
/// and the app starts with fresh windows; it's never written over without that copy.
struct SessionStore {
    let fileURL: URL
    private(set) var canSave = true

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The saved session, or nil on a first launch or after a file that couldn't be read.
    mutating func load() -> SessionFile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(SessionFile.self, from: Data(contentsOf: fileURL))
        } catch {
            do {
                let backup = try SecureFile.backUp(fileURL, reason: "unreadable")
                NSLog("iSmith: session.json could not be read (\(error)); saved a copy at \(backup.path)")
            } catch {
                canSave = false
                NSLog("iSmith: session.json could not be read or backed up (\(error)); it won't be changed")
            }
            return nil
        }
    }

    func save(_ session: SessionFile) {
        guard canSave else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try SecureFile.prepareDirectory(fileURL.deletingLastPathComponent())
            try SecureFile.write(encoder.encode(session), to: fileURL)
        } catch {
            NSLog("iSmith: session save failed: \(error)")
        }
    }

    /// Drops what no longer exists: spaces deleted since the file was saved, and windows left with
    /// nothing. A window's active space falls back to its first remaining one.
    static func pruned(_ session: SessionFile, spaces: Set<String>) -> SessionFile {
        var out = session
        out.windows = session.windows.compactMap { window in
            var w = window
            w.spaces = window.spaces.filter { spaces.contains($0.space) }
            if let active = w.activeSpace, !spaces.contains(active) { w.activeSpace = nil }
            if w.activeSpace == nil { w.activeSpace = w.spaces.first(where: { !$0.tabs.isEmpty })?.space }
            return w.activeSpace == nil && w.spaces.allSatisfy(\.tabs.isEmpty) ? nil : w
        }
        return out
    }
}
