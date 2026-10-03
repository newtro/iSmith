import AppKit
import BraveImport
import BrowserData
import Passwords
import SwiftUI

// P5: bookmarks and passwords from Brave. The BraveImport package reads Brave (read-only); this
// maps its bookmark tree into a space's bookmarks (BrowserData) and its logins into the P4
// password store, and draws the first-run screen and File ▸ Import from Brave….
//
// The "Brave Safe Storage" Keychain item is only read once the user starts a password import,
// after a screen saying macOS will ask for the Mac password.

/// What an import did, for the result screen.
struct BookmarkImportSummary: Equatable {
    var space: String
    /// In the Brave profile.
    var bookmarksInBrave = 0
    var foldersInBrave = 0
    var bookmarksAdded = 0
    var foldersAdded = 0
    /// Already imported earlier (matched by Brave's id), so not added again.
    var alreadyThere = 0
}

struct PasswordImportSummary: Equatable {
    /// Logins Brave holds, after merging the same login saved twice (as Brave lists them).
    var inBrave = 0
    var added = 0
    /// Same site and username with another password: iSmith's copy was replaced, because Brave's
    /// was changed more recently.
    var updated = 0
    /// Already saved in iSmith with the same password.
    var unchanged = 0
    /// iSmith's own copy was changed after Brave's, so it was kept.
    var keptNewer = 0
    /// Rows Brave keeps for sites marked "Never save": they have no password.
    var skippedNeverSave = 0
    /// Logins for something other than a website (an Android app, say), or with no password.
    var skippedNotWebsite = 0
    var skippedEmpty = 0
    /// Passwords that couldn't be decrypted.
    var failed = 0
    /// Notes saved with passwords: iSmith has no notes yet, so they're not imported.
    var notesNotImported = 0

    var imported: Int { added + updated }
}

enum BraveImporter {
    /// Brave's profile folder; a Debug build can point it at a fixture with `ISMITH_BRAVE_ROOT`.
    static var root: URL {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["ISMITH_BRAVE_ROOT"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        #endif
        return BraveProfiles.defaultRoot
    }

    /// The real "Brave Safe Storage" Keychain item. A Debug build pointed at a fixture profile
    /// (`ISMITH_BRAVE_ROOT`) never reads it: it uses `ISMITH_BRAVE_SAFE_STORAGE`, or no key.
    static func safeStorage() -> SafeStoragePasswordSource {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["ISMITH_BRAVE_ROOT"]?.isEmpty == false {
            return FixtureSafeStorage(password: env["ISMITH_BRAVE_SAFE_STORAGE"])
        }
        #endif
        return KeychainSafeStorage()
    }

    #if DEBUG
    struct FixtureSafeStorage: SafeStoragePasswordSource {
        let password: String?
        func safeStoragePassword() throws -> Data {
            guard let password, !password.isEmpty else { throw SafeStorageError.notFound }
            return Data(password.utf8)
        }
    }
    #endif

    // MARK: Bookmarks

    static func node(_ brave: BookmarkNode) -> BookmarkImportNode {
        switch brave.kind {
        case .bookmark(let url):
            return BookmarkImportNode(title: brave.title, url: url, dateAdded: brave.dateAdded, externalID: brave.guid)
        case .folder(let children):
            return BookmarkImportNode(title: brave.title, url: nil, children: children.map(node), dateAdded: brave.dateAdded,
                                      externalID: brave.guid)
        }
    }

    /// Brave's roots mapped to a space's (BrowserData's rule): the bookmarks bar's contents into
    /// the space's bar, "Other bookmarks" into Other Bookmarks, and "Mobile bookmarks" (and any
    /// root this version doesn't know) as a folder of its own in Other Bookmarks. Folders and
    /// order are kept; Brave's ids make a second import add only what's new.
    static func plan(_ bookmarks: BraveBookmarks) -> (bar: [BookmarkImportNode], other: [BookmarkImportNode]) {
        var bar: [BookmarkImportNode] = []
        var other: [BookmarkImportNode] = []
        for entry in bookmarks.roots {
            switch entry.root {
            case .bookmarkBar:
                bar += entry.folder.children.map(node)
            case .other:
                other += entry.folder.children.map(node)
            case .mobile, .unknown:
                guard !entry.folder.children.isEmpty else { continue }
                var folder = node(entry.folder)
                if entry.root == .mobile { folder.title = "Mobile Bookmarks" }
                if folder.title.isEmpty { folder.title = "Imported Bookmarks" }
                other.append(folder)
            }
        }
        return (bar, other)
    }

    static func importBookmarks(_ bookmarks: BraveBookmarks, space: String, spaceName: String,
                                into store: BookmarkStore) throws -> BookmarkImportSummary {
        let (bar, other) = plan(bookmarks)
        var summary = BookmarkImportSummary(space: spaceName, bookmarksInBrave: bookmarks.bookmarkCount,
                                            foldersInBrave: bookmarks.folderCount)
        for (nodes, root) in [(bar, BookmarkRoot.bar), (other, .other)] where !nodes.isEmpty {
            let result = try store.importTree(nodes, space: space, into: store.root(root, space: space).id)
            summary.bookmarksAdded += result.bookmarksAdded
            summary.foldersAdded += result.foldersAdded
            summary.alreadyThere += result.skipped
        }
        return summary
    }

    // MARK: Passwords

    /// Moves Brave's logins into the password store. A login whose site and username are already
    /// saved keeps whichever password changed last. Nothing is logged.
    static func importPasswords(_ result: PasswordImport, into store: PasswordStore) throws -> PasswordImportSummary {
        var summary = PasswordImportSummary(inBrave: result.logins.count, skippedNeverSave: result.skippedNeverSave,
                                            failed: result.failures.filter { $0.part == .password }.count)
        // Oldest change first, so when Brave holds two passwords for one login the newest wins.
        let logins = result.logins.sorted { changed($0) < changed($1) }
        for imported in logins {
            if imported.note != nil { summary.notesNotImported += 1 }
            guard let origin = origin(of: imported) else {
                summary.skippedNotWebsite += 1
                continue
            }
            guard !imported.password.isEmpty else {
                summary.skippedEmpty += 1
                continue
            }
            let existing = try store.logins(for: origin).first { $0.kind == .exact && $0.login.username == imported.username }?.login
            if var login = existing {
                if login.password == imported.password {
                    summary.unchanged += 1
                } else if login.updated > changed(imported) {
                    summary.keptNewer += 1
                } else {
                    login.password = imported.password
                    try store.update(login, date: changed(imported))
                    summary.updated += 1
                }
                continue
            }
            // Dated when Brave last changed the password, so a later import or capture compares
            // against that; the last use carries over for the popover's order.
            var login = try store.add(origin: origin, username: imported.username, password: imported.password,
                                      date: changed(imported) == .distantPast ? Date() : changed(imported))
            if imported.dateLastUsed != nil || imported.timesUsed > 0 {
                login.lastUsed = imported.dateLastUsed
                login.timesUsed = imported.timesUsed
                try store.update(login)
            }
            summary.added += 1
        }
        return summary
    }

    private static func changed(_ login: ImportedLogin) -> Date {
        login.datePasswordModified ?? login.dateCreated ?? .distantPast
    }

    /// The website a Brave login belongs to: its sign-on realm (`https://example.com/`), else the
    /// page it was saved on. nil for anything that isn't an http(s) site (Android apps).
    static func origin(of login: ImportedLogin) -> Origin? {
        for candidate in [login.signonRealm, login.origin] {
            // HTTP-auth realms read "https://host/Realm name": the part before the space.
            let address = candidate.split(separator: " ", maxSplits: 1).first.map(String.init) ?? candidate
            if let origin = Origin(string: address) { return origin }
        }
        return nil
    }
}

// MARK: - The import screen

@MainActor
final class ImportFromBraveModel: ObservableObject {
    struct ProfileInfo: Identifiable, Equatable {
        let profile: BraveProfile
        let bookmarks: Int
        var id: String { profile.directoryName }
    }

    enum Phase: Equatable {
        case loading
        case noBrave
        /// macOS refused access to Brave's folder (Files & Folders / Full Disk Access).
        case permissionDenied
        case choose
        /// Explaining macOS's Keychain prompt before the password import starts.
        case keychainNotice
        case importing(String)
        case done
        case failed(String)
    }

    let browser: BrowserState
    let firstRun: Bool
    let root: URL
    /// The "Brave Safe Storage" password; the real Keychain item in the app, a fixed one in tests.
    var safeStorage: () -> SafeStoragePasswordSource = BraveImporter.safeStorage
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var profiles: [ProfileInfo] = []
    @Published var profileID = ""
    @Published var importBookmarks = true
    @Published var importPasswords = true
    @Published var spaceID: String
    @Published private(set) var bookmarkSummary: BookmarkImportSummary?
    @Published private(set) var passwordSummary: PasswordImportSummary?
    @Published private(set) var passwordProblem: String?
    var close: () -> Void = {}

    init(browser: BrowserState, firstRun: Bool, root: URL = BraveImporter.root) {
        self.browser = browser
        self.firstRun = firstRun
        self.root = root
        spaceID = browser.currentWindow?.activeSpaceID ?? browser.spaces.first?.id ?? ""
    }

    var profile: BraveProfile? { profiles.first { $0.id == profileID }?.profile }
    var canImportPasswords: Bool { browser.passwords != nil && profile?.hasPasswords == true }
    var canImportBookmarks: Bool { browser.data != nil && (profiles.first { $0.id == profileID }?.bookmarks ?? 0) > 0 }

    /// Finds Brave's profiles and counts their bookmarks. Reading Brave's folder is what macOS
    /// may ask about (or refuse), so it happens when this screen opens, not before.
    /// Off the main thread: the first read may wait on macOS's "access your Brave Browser data?"
    /// question.
    func load() async {
        phase = .loading
        let root = root
        let found = await Task.detached(priority: .userInitiated) { () -> Result<[ProfileInfo], Error> in
            Result {
                try BraveProfiles.discover(root: root).map { profile in
                    ProfileInfo(profile: profile, bookmarks: profile.hasBookmarks ? try BookmarksReader.read(profile: profile).bookmarkCount : 0)
                }
            }
        }.value
        switch found {
        case .success(let found) where found.isEmpty:
            phase = .noBrave
        case .success(let found):
            profiles = found
            if profile == nil { profileID = profiles[0].id }
            importBookmarks = canImportBookmarks
            importPasswords = canImportPasswords
            phase = .choose
        case .failure(BraveAccessError.permissionDenied):
            phase = .permissionDenied
        case .failure(let error):
            phase = .failed("Brave's profiles couldn't be read: \(error.localizedDescription)")
        }
    }

    func profileChanged() {
        importBookmarks = canImportBookmarks
        importPasswords = canImportPasswords
    }

    /// "Import": bookmarks at once; passwords after the Keychain notice.
    func start() {
        if importPasswords, canImportPasswords {
            phase = .keychainNotice
        } else {
            Task { await run(passwords: false) }
        }
    }

    func run(passwords: Bool) async {
        guard let profile else { return }
        bookmarkSummary = nil
        passwordSummary = nil
        passwordProblem = nil
        if importBookmarks, let store = browser.data?.bookmarks, let space = browser.space(spaceID) {
            phase = .importing("Importing bookmarks…")
            do {
                let bookmarks = try BookmarksReader.read(profile: profile)
                bookmarkSummary = try BraveImporter.importBookmarks(bookmarks, space: space.id, spaceName: space.def.name, into: store)
            } catch BraveAccessError.permissionDenied {
                phase = .permissionDenied
                return
            } catch {
                phase = .failed("The bookmarks couldn't be imported: \(error.localizedDescription)")
                return
            }
        }
        if passwords, let store = browser.passwords?.store {
            phase = .importing("Importing passwords… macOS may ask for your Mac password.")
            let source = safeStorage()
            // Synchronous, and waits while macOS shows its Keychain prompt: off the main thread.
            let read = await Task.detached(priority: .userInitiated) { () -> Result<PasswordImport, Error> in
                Result { try BravePasswordReader(passwordSource: source).read(profile: profile) }
            }.value
            switch read {
            case .success(let result):
                do {
                    passwordSummary = try BraveImporter.importPasswords(result, into: store)
                } catch {
                    passwordProblem = "The passwords couldn't be saved: \((error as? PasswordStoreError)?.description ?? error.localizedDescription)"
                }
            case .failure(BraveAccessError.permissionDenied):
                phase = .permissionDenied
                return
            case .failure(let error):
                passwordProblem = Self.explain(error)
            }
        }
        phase = .done
    }

    static func explain(_ error: Error) -> String {
        switch error {
        case SafeStorageError.denied:
            return "macOS didn't give iSmith Brave's password key (the Keychain prompt was denied or cancelled). No passwords were imported. Try again and enter your Mac password, then click Allow."
        case SafeStorageError.notFound:
            return "Brave hasn't stored a password key on this Mac (\"Brave Safe Storage\" isn't in the Keychain), so its saved passwords can't be read."
        case SafeStorageError.keychain(_, let message):
            return "The Keychain couldn't be read: \(message)."
        case PasswordImportError.wrongKey:
            return "Brave's password key in the Keychain doesn't match its saved passwords, so none could be decrypted."
        case LoginDatabaseError.copyInconsistent:
            return "Brave kept changing its password file while iSmith copied it. Quit Brave and try again."
        default:
            return "The passwords couldn't be read: \(error.localizedDescription)"
        }
    }

    /// System Settings ▸ Privacy & Security ▸ Files & Folders. On macOS 15 and later, reading
    /// another app's data is the "App Data" permission (`kTCCServiceSystemPolicyAppDataDetailed`):
    /// macOS asks "Allow iSmith to access your Brave Browser data?", and if that was declined,
    /// it's turned on under Files & Folders. Full Disk Access also covers it.
    static let filesAndFoldersURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

struct ImportFromBraveView: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var model: ImportFromBraveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.firstRun ? "Bring your bookmarks and passwords from Brave" : "Import from Brave").font(.title2.weight(.semibold))
                    Text("Brave isn't changed. You can import again any time from the File menu.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            content
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .onAppear { if model.phase == .loading { Task { await model.load() } } }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Looking for Brave…")
        case .noBrave:
            Text("No Brave profiles were found on this Mac.").foregroundStyle(.secondary)
            buttons { Button(model.firstRun ? "Continue" : "Close") { model.close() }.keyboardShortcut(.defaultAction) }
        case .permissionDenied:
            permission
        case .choose:
            chooser
        case .keychainNotice:
            keychainNotice
        case .importing(let what):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(what)
            }
        case .done:
            results
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Close") { model.close() }
                Button("Try Again") { Task { await model.load() } }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var chooser: some View {
        Form {
            Picker("Brave profile", selection: $model.profileID) {
                ForEach(model.profiles) { info in
                    Text("\(info.profile.displayName) (\(info.bookmarks) bookmark\(info.bookmarks == 1 ? "" : "s"))").tag(info.id)
                }
            }
            .onChange(of: model.profileID) { _, _ in model.profileChanged() }
            Toggle("Bookmarks", isOn: $model.importBookmarks).disabled(!model.canImportBookmarks)
            Picker("Into space", selection: $model.spaceID) {
                ForEach(browser.spaces) { space in Text(space.def.name).tag(space.id) }
            }
            .disabled(!model.importBookmarks)
            Text("The bookmarks bar goes to the space's bookmarks bar, everything else to Other Bookmarks, folders and all.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Passwords", isOn: $model.importPasswords).disabled(!model.canImportPasswords)
            Text(model.canImportPasswords ? "Passwords work in every space."
                 : browser.passwords == nil ? "Saved passwords are off: \(browser.passwordsProblem ?? "the store couldn't be opened")."
                 : "This profile has no saved passwords.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .overlay(alignment: .bottomTrailing) {
            buttons {
                Button(model.firstRun ? "Not Now" : "Cancel") { model.close() }
                Button("Import") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(model.importBookmarks || model.importPasswords))
            }
            .padding(.top, 8)
            .offset(y: 44)
        }
        .padding(.bottom, 40)
    }

    private var keychainNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("macOS will ask for your Mac password", systemImage: "lock.shield").font(.headline)
            Text("Brave keeps the key to its saved passwords in your Keychain, under \"Brave Safe Storage\". When you continue, macOS asks whether iSmith may use it. Enter your Mac password and click Allow (Always Allow means it won't ask again for later imports).")
                .fixedSize(horizontal: false, vertical: true)
            Text("iSmith reads a private copy of Brave's password files, decrypts them on this Mac and saves them in its own encrypted store. Nothing is sent anywhere, and Brave isn't changed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Back") { model.profileChanged(); model.backToChoose() }
                Button("Continue") { Task { await model.run(passwords: true) } }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("macOS is keeping Brave's data private", systemImage: "hand.raised").font(.headline)
            Text("macOS lets an app read another app's data only with your permission. Allow \(AppIdentity.displayName) to access your Brave Browser data in System Settings ▸ Privacy & Security ▸ Files & Folders (or give it Full Disk Access), then click Try Again.")
                .fixedSize(horizontal: false, vertical: true)
            Text("If macOS asked \"Allow \(AppIdentity.displayName) to access your Brave Browser data?\" and you clicked Don't Allow, the switch is in that list. You may need to quit and reopen \(AppIdentity.displayName) after changing it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Files & Folders Settings") { NSWorkspace.shared.open(ImportFromBraveModel.filesAndFoldersURL) }
                Button("Full Disk Access…") { NSWorkspace.shared.open(ImportFromBraveModel.fullDiskAccessURL) }
                    .buttonStyle(.link)
            }
            buttons {
                Button(model.firstRun ? "Not Now" : "Close") { model.close() }
                Button("Try Again") { Task { await model.load() } }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let b = model.bookmarkSummary {
                Label {
                    Text("Bookmarks: \(b.bookmarksAdded) added to \(b.space), in \(b.foldersAdded) new folder\(b.foldersAdded == 1 ? "" : "s").")
                    + Text(b.alreadyThere > 0 ? " \(b.alreadyThere) were already there." : "")
                    + Text(" Brave has \(b.bookmarksInBrave) bookmark\(b.bookmarksInBrave == 1 ? "" : "s") in \(b.foldersInBrave) folder\(b.foldersInBrave == 1 ? "" : "s").")
                } icon: { Image(systemName: "book") }
            }
            if let p = model.passwordSummary {
                Label {
                    Text(passwordLine(p))
                } icon: { Image(systemName: "key") }
            }
            if let problem = model.passwordProblem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            buttons {
                if model.passwordProblem != nil {
                    Button("Try Passwords Again") { model.retryPasswords() }
                }
                Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func passwordLine(_ p: PasswordImportSummary) -> String {
        var line = "Passwords: \(p.imported) imported (\(p.added) new, \(p.updated) updated) of \(p.inBrave) in Brave."
        var others: [String] = []
        if p.unchanged > 0 { others.append("\(p.unchanged) already saved") }
        if p.keptNewer > 0 { others.append("\(p.keptNewer) kept because iSmith's copy is newer") }
        if p.skippedNeverSave > 0 { others.append("\(p.skippedNeverSave) \"never save\" site\(p.skippedNeverSave == 1 ? "" : "s") skipped") }
        if p.skippedNotWebsite > 0 { others.append("\(p.skippedNotWebsite) not for a website") }
        if p.skippedEmpty > 0 { others.append("\(p.skippedEmpty) with no password") }
        if p.failed > 0 { others.append("\(p.failed) couldn't be decrypted") }
        if p.notesNotImported > 0 { others.append("\(p.notesNotImported) note\(p.notesNotImported == 1 ? "" : "s") not imported") }
        if !others.isEmpty { line += " " + others.joined(separator: ", ") + "." }
        return line
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
        }
    }
}

extension ImportFromBraveModel {
    func backToChoose() { phase = .choose }

    /// After a Keychain refusal: just the passwords again, from the notice.
    func retryPasswords() {
        importBookmarks = false
        phase = .keychainNotice
    }
}
