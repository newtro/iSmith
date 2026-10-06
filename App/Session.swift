import CryptoKit
import Foundation
import SignInSync

/// What's open: windows → spaces → groups → tabs with their URLs. Saved to `session.json` next to
/// `config.json`, owner-only, and read at launch.
///
/// Config holds what a space *is* (name, color, accounts, rail order); the session holds what's
/// open in it. They're separate files because the session changes every time a page navigates,
/// and config is rewritten rarely and carefully.
///
/// Each tab also keeps its back/forward history: WebKit's `interactionState`, an opaque blob that
/// can hold form posts (a sign-in's code or password). It's sealed with AES-GCM under a key
/// derived from the vault key (`HistorySealer`) and stored base64 in the JSON. Crash safety: the
/// file is written atomically a second after a navigation or a change to the tabs (title-only
/// changes ride along with the next write), so a crash loses at most that. Fields added later
/// decode with defaults, so older files still load.
struct SessionFile: Codable, Equatable {
    /// 1: P1 (no histories). 2: histories sealed with `HistorySealer`.
    var version = 2
    var windows: [WindowRecord] = []

    init(windows: [WindowRecord] = []) {
        self.windows = windows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        windows = try c.decodeIfPresent([WindowRecord].self, forKey: .windows) ?? []
    }

    /// Replaces every tab's history (sealing on save, opening on load).
    mutating func mapHistories(_ transform: (Data) -> Data?) {
        for w in windows.indices {
            for s in windows[w].spaces.indices {
                for t in windows[w].spaces[s].tabs.indices {
                    windows[w].spaces[s].tabs[t].history = windows[w].spaces[s].tabs[t].history.flatMap(transform)
                }
            }
        }
    }
}

/// Seals tab histories for session.json with a key derived (HKDF-SHA256) from the vault key, so
/// the file never holds form posts in the clear and the vault key itself has one use.
struct HistorySealer {
    /// The HKDF info for the history key.
    static let purpose = "iSmith session history v1"
    private let key: SymmetricKey

    /// A key already derived for this purpose (`Vault.derivedKey(purpose:)`).
    init(key: SymmetricKey) {
        self.key = key
    }

    init(vaultKey: SymmetricKey) {
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, info: Data(Self.purpose.utf8), outputByteCount: 32)
    }

    func seal(_ plain: Data) -> Data? {
        try? AES.GCM.seal(plain, using: key).combined
    }

    func open(_ sealed: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

struct WindowRecord: Codable, Equatable {
    var id: UUID
    /// `NSWindow.frameDescriptor`.
    var frame: String?
    var activeSpace: String?
    var spaces: [SpaceRecord]
    /// Where the window shows the agent panel; nil in files from before v1.1.
    var agentDock: AgentDock?
    /// The window shows its tabs in a sidebar instead of the top strip; nil in older files (the
    /// Settings default applies).
    var verticalTabs: Bool?

    init(id: UUID, frame: String?, activeSpace: String?, spaces: [SpaceRecord], agentDock: AgentDock? = nil,
         verticalTabs: Bool? = nil) {
        (self.id, self.frame, self.activeSpace, self.spaces, self.agentDock) = (id, frame, activeSpace, spaces, agentDock)
        self.verticalTabs = verticalTabs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        frame = try c.decodeIfPresent(String.self, forKey: .frame)
        activeSpace = try c.decodeIfPresent(String.self, forKey: .activeSpace)
        spaces = try c.decodeIfPresent([SpaceRecord].self, forKey: .spaces) ?? []
        agentDock = try c.decodeIfPresent(AgentDock.self, forKey: .agentDock)
        verticalTabs = try c.decodeIfPresent(Bool.self, forKey: .verticalTabs)
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
        TabLayout(slots: tabs.map { TabLayout.Slot(id: $0.id, group: $0.group, pinned: $0.pinned == true) },
                  groups: groups, selected: selected)
    }
}

struct TabRecord: Codable, Equatable {
    var id: UUID
    var url: URL?
    var title: String
    var group: UUID?
    /// The tab's own Keep alive setting; nil follows the automatic rule for its page.
    var keepAlive: Bool?
    /// The tab's back/forward history (`WKWebView.interactionState`). Dropped when larger than
    /// `TabRecord.maxHistoryBytes`; the tab then reopens on its URL alone.
    var history: Data?
    /// Pinned to the start of the strip; nil (not written) for an ordinary tab.
    var pinned: Bool?

    /// WebKit's state for a long history with form data can be large; 40 tabs must still save fast.
    static let maxHistoryBytes = 512 * 1024

    init(id: UUID, url: URL?, title: String, group: UUID?, keepAlive: Bool?, history: Data? = nil, pinned: Bool = false) {
        (self.id, self.url, self.title, self.group, self.keepAlive) = (id, url, title, group, keepAlive)
        self.history = history.flatMap { $0.count <= Self.maxHistoryBytes ? $0 : nil }
        self.pinned = pinned ? true : nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        group = try c.decodeIfPresent(UUID.self, forKey: .group)
        keepAlive = try c.decodeIfPresent(Bool.self, forKey: .keepAlive)
        // A damaged history blob mustn't cost the tab: it reopens on its URL.
        history = (try? c.decodeIfPresent(Data.self, forKey: .history)) ?? nil
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) == true ? true : nil
    }
}

/// Reads and writes session.json. A file that can't be read is copied aside (as config.json is)
/// and the app starts with fresh windows; it's never written over without that copy.
struct SessionStore {
    let fileURL: URL
    /// Seals each tab's history in the file. Without one, histories aren't saved at all.
    let sealer: HistorySealer?
    private(set) var canSave = true

    init(fileURL: URL, sealer: HistorySealer? = nil) {
        self.fileURL = fileURL
        self.sealer = sealer
    }

    /// The saved session, or nil on a first launch or after a file that couldn't be read.
    mutating func load() -> SessionFile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            var file = try JSONDecoder().decode(SessionFile.self, from: Data(contentsOf: fileURL))
            // Histories are sealed from version 2 on; one that won't open (another key, a damaged
            // file) is dropped and the tab reopens on its URL.
            let sealed = file.version >= 2
            let open: (Data) -> Data? = { [sealer] blob in sealed ? sealer?.open(blob) : nil }
            file.mapHistories(open)
            return file
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
        guard let data = encode(session) else { return }
        write(data)
    }

    /// The file's bytes: histories sealed (or left out without a sealer).
    func encode(_ session: SessionFile) -> Data? {
        guard canSave else { return nil }
        var file = session
        file.version = 2
        file.mapHistories { [sealer] plain in sealer?.seal(plain) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(file)
        } catch {
            NSLog("iSmith: session could not be encoded: \(error)")
            return nil
        }
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        guard canSave else { return false }
        do {
            try SecureFile.prepareDirectory(fileURL.deletingLastPathComponent())
            try SecureFile.write(data, to: fileURL)
            return true
        } catch {
            NSLog("iSmith: session save failed: \(error)")
            return false
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
