import AppKit
import LocalAuthentication
import Passwords
import SwiftUI

// P4: the Passwords window (⌥⌘P): search, view, reveal and copy (behind Touch ID or the Mac
// password), edit, add, delete, the "never save" list, and weak or reused passwords.
//
// The list holds usernames and sites only. A password is read from the store when it's revealed,
// copied or edited, after LocalAuthentication, and the unlock lasts 60 seconds while the window
// stays key; it locks again when the window resigns key, the screen locks or the Mac sleeps.

@MainActor
final class PasswordsModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All Passwords", weak = "Weak", reused = "Reused"
        var id: String { rawValue }
    }

    enum Detail: Equatable {
        case none, login(UUID), add, neverSave
    }

    struct Row: Identifiable, Equatable {
        let summary: LoginSummary
        let weak: Bool
        let reused: Bool
        var id: UUID { summary.id }
        static func == (a: Row, b: Row) -> Bool { a.id == b.id && a.weak == b.weak && a.reused == b.reused && a.summary == b.summary }
    }

    /// An edit or a new login, with the password in the clear while the editor is open.
    struct Draft: Equatable {
        var id: UUID?
        var site = ""
        var username = ""
        var password = ""
    }

    static let unlockDuration: TimeInterval = 60

    let store: PasswordStore?
    let problem: String?
    @Published var query = "" { didSet { reload() } }
    @Published var filter: Filter = .all { didSet { reload() } }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var total = 0
    @Published private(set) var weakCount = 0
    @Published private(set) var reusedCount = 0
    @Published private(set) var unreadable = 0
    @Published private(set) var neverSave: [Origin] = []
    @Published var detail: Detail = .none {
        didSet { if detail != oldValue { revealed = nil; draft = nil } }
    }
    /// The revealed password of the login on screen, while unlocked.
    @Published private(set) var revealed: (id: UUID, password: String)?
    @Published var draft: Draft?
    @Published var message: String?
    @Published private(set) var unlockedUntil: Date?
    private var reuse: [UUID: [UUID]] = [:]
    private var hosts: [UUID: String] = [:]
    private var relock: Timer?
    private var observers: [NSObjectProtocol] = []
    /// LocalAuthentication; injectable so tests never prompt.
    var authenticate: (String) async -> Bool = PasswordsModel.deviceOwnerAuthentication

    init(store: PasswordStore?, problem: String?) {
        self.store = store
        self.problem = problem
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
        reload()
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    /// The window the unlock belongs to (nil in tests).
    private weak var window: NSWindow?

    /// Locks when the window stops being key.
    func watch(_ window: NSWindow) {
        self.window = window
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
    }

    // MARK: Loading

    func reload() {
        guard let store else { return }
        do {
            let all = try store.allLogins()
            let report = SecurityReport(logins: all)
            var reuse: [UUID: [UUID]] = [:]
            for group in report.reused { for id in group { reuse[id] = group.filter { $0 != id } } }
            self.reuse = reuse
            hosts = Dictionary(all.map { ($0.id, PasswordOffer.name(of: $0.origin)) }, uniquingKeysWith: { a, _ in a })
            total = all.count
            weakCount = report.weak.count
            reusedCount = reuse.count
            let matching = query.trimmingCharacters(in: .whitespaces).isEmpty ? all : try store.search(query)
            rows = matching.compactMap { login in
                let row = Row(summary: login.summary, weak: report.weak.contains(login.id), reused: reuse[login.id] != nil)
                switch filter {
                case .all: return row
                case .weak: return row.weak ? row : nil
                case .reused: return row.reused ? row : nil
                }
            }
            unreadable = try store.unreadableCount()
            neverSave = try store.neverSaveOrigins()
            if case .login(let id) = detail, !all.contains(where: { $0.id == id }) { detail = .none }
        } catch {
            message = "Saved passwords couldn't be read: \(error)"
        }
    }

    func row(_ id: UUID) -> Row? { rows.first { $0.id == id } }

    /// The other sites a reused password is on.
    func reusedOn(_ id: UUID) -> [String] {
        Array(Set((reuse[id] ?? []).compactMap { hosts[$0] })).sorted()
    }

    // MARK: Unlocking

    var isUnlocked: Bool { (unlockedUntil ?? .distantPast) > Date() }

    /// Touch ID or the Mac password, unless unlocked in the last minute.
    func unlock(_ reason: String) async -> Bool {
        if isUnlocked, window?.isKeyWindow != false { return true }
        guard await authenticate(reason) else { return false }
        // The unlock holds only while this window is key. macOS's prompt takes the focus while
        // it's up; if the user went to another window meanwhile, nothing is shown.
        if let window {
            let deadline = Date().addingTimeInterval(1.5)
            while !window.isKeyWindow, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard window.isKeyWindow else { return false }
        }
        unlockedUntil = Date().addingTimeInterval(Self.unlockDuration)
        relock?.invalidate()
        let timer = Timer(timeInterval: Self.unlockDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        // Also while scrolling or tracking a menu.
        RunLoop.main.add(timer, forMode: .common)
        relock = timer
        return true
    }

    func lock() {
        relock?.invalidate()
        relock = nil
        unlockedUntil = nil
        revealed = nil
        // An open editor shows a password: it closes without saving.
        if draft?.id != nil { draft = nil }
    }

    static func deviceOwnerAuthentication(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    // MARK: Actions

    func reveal(_ id: UUID) async {
        if revealed?.id == id {
            revealed = nil
            return
        }
        guard await unlock("show your saved password"), let login = try? store?.login(id: id) else { return }
        revealed = (id, login.password)
    }

    func copyPassword(_ id: UUID) async {
        guard await unlock("copy your saved password"), let login = try? store?.login(id: id) else { return }
        SecretPasteboard.copy(login.password)
        message = "Password copied. It's cleared from the clipboard in a minute."
    }

    func copyUsername(_ id: UUID) {
        guard let login = try? store?.login(id: id) else { return }
        SecretPasteboard.copy(login.username)
        message = "Username copied."
    }

    func startEditing(_ id: UUID) async {
        guard await unlock("edit your saved password"), let login = try? store?.login(id: id) else { return }
        draft = Draft(id: id, site: login.origin.serialized, username: login.username, password: login.password)
    }

    func startAdding() {
        detail = .add
        draft = Draft(id: nil, site: "https://", username: "", password: "")
    }

    /// Saves the open editor. Returns false (with `message` set) when it can't.
    @discardableResult
    func saveDraft() -> Bool {
        guard let store, let draft else { return false }
        guard let origin = Self.origin(from: draft.site) else {
            message = "Enter the site as an address, such as https://example.com."
            return false
        }
        guard !draft.password.isEmpty else {
            message = "The password can't be empty."
            return false
        }
        do {
            if let id = draft.id {
                guard var login = try store.login(id: id) else { throw PasswordStoreError.notFound }
                login.origin = origin
                login.username = draft.username
                login.password = draft.password
                try store.update(login)
                detail = .login(id)
            } else {
                let login = try store.add(origin: origin, username: draft.username, password: draft.password)
                reload()
                detail = .login(login.id)
            }
            self.draft = nil
            revealed = nil
            reload()
            return true
        } catch {
            message = (error as? PasswordStoreError)?.description ?? error.localizedDescription
            return false
        }
    }

    /// "example.com" or "https://example.com/login" → https://example.com.
    static func origin(from text: String) -> Origin? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("://") { return Origin(string: trimmed) }
        return Origin(string: "https://" + trimmed)
    }

    func delete(_ id: UUID) {
        do {
            try store?.delete(id: id)
            detail = .none
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    func removeNeverSave(_ origin: Origin) {
        try? store?.removeNeverSave(origin)
        reload()
    }
}

// MARK: - Views

struct PasswordsView: View {
    @ObservedObject var model: PasswordsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let problem = model.problem {
                banner(problem, symbol: "exclamationmark.triangle")
            }
            if model.unreadable > 0 {
                banner("\(model.unreadable) saved login\(model.unreadable == 1 ? "" : "s") couldn't be decrypted.", symbol: "exclamationmark.triangle")
            }
            HSplitView {
                list.frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                detail.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Search sites and usernames", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Picker("Show", selection: $model.filter) {
                ForEach(PasswordsModel.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            Text(summary).font(.caption).foregroundStyle(.secondary)
            Button { model.startAdding() } label: { Image(systemName: "plus") }
                .help("Add a password")
                .disabled(model.store == nil)
        }
        .padding(10)
    }

    private var summary: String {
        var parts = ["\(model.total) password\(model.total == 1 ? "" : "s")"]
        if model.weakCount > 0 { parts.append("\(model.weakCount) weak") }
        if model.reusedCount > 0 { parts.append("\(model.reusedCount) reused") }
        return parts.joined(separator: " · ")
    }

    private func banner(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: {
                if case .login(let id) = model.detail { return id }
                return nil
            }, set: { id in model.detail = id.map(PasswordsModel.Detail.login) ?? .none })) {
                ForEach(model.rows) { row in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(PasswordOffer.name(of: row.summary.origin)).lineLimit(1)
                            Text(row.summary.username.isEmpty ? "(no username)" : row.summary.username)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if row.weak || row.reused {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(row.weak && row.reused ? "Weak and reused" : row.weak ? "Weak password" : "Reused on another site")
                        }
                    }
                    .tag(row.id)
                }
            }
            if model.rows.isEmpty {
                Text(model.total == 0 ? "No saved passwords yet. iSmith offers to save them when you sign in, or import them from Brave (File ▸ Import from Brave…)." : "No matches.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
            Divider()
            Button { model.detail = .neverSave } label: {
                Label("Never saved for \(model.neverSave.count) site\(model.neverSave.count == 1 ? "" : "s")", systemImage: "nosign")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.detail {
        case .none:
            Text(model.total == 0 ? "" : "Select a password").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .add:
            if model.draft != nil { DraftEditor(model: model, title: "New Password") } else { Color.clear }
        case .neverSave:
            NeverSaveList(model: model)
        case .login(let id):
            if model.draft?.id == id {
                DraftEditor(model: model, title: "Edit Password")
            } else if let row = model.row(id) {
                LoginDetail(model: model, row: row)
            } else {
                Color.clear
            }
        }
    }
}

private struct LoginDetail: View {
    @ObservedObject var model: PasswordsModel
    let row: PasswordsModel.Row
    @State private var confirmDelete = false

    var body: some View {
        let id = row.id
        Form {
            Section {
                LabeledContent("Website") { Text(row.summary.origin.serialized).textSelection(.enabled) }
                LabeledContent("Username") {
                    HStack {
                        Text(row.summary.username.isEmpty ? "(none)" : row.summary.username).textSelection(.enabled)
                        Button { model.copyUsername(id) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy username")
                    }
                }
                LabeledContent("Password") {
                    HStack {
                        if let revealed = model.revealed, revealed.id == id {
                            // Not selectable: the copy button (SecretPasteboard) is the only way out.
                            Text(revealed.password).font(.system(.body, design: .monospaced))
                        } else {
                            Text("••••••••••").foregroundStyle(.secondary)
                        }
                        Button(model.revealed?.id == id ? "Hide" : "Show") { Task { await model.reveal(id) } }
                            .buttonStyle(.borderless)
                        Button { Task { await model.copyPassword(id) } } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy password")
                    }
                }
                if let used = row.summary.lastUsed {
                    LabeledContent("Last used") { Text(used.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
            if row.weak || row.reused {
                Section("Security") {
                    if row.weak {
                        Label("This password is weak. Change it on the site, then update it here.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if row.reused {
                        Label("The same password is used on \(model.reusedOn(id).joined(separator: ", ")).", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                HStack {
                    Button("Edit…") { Task { await model.startEditing(id) } }
                    Spacer()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete the password for \(PasswordOffer.name(of: row.summary.origin))?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete(id) }
        } message: {
            Text("You'll have to type it the next time you sign in.")
        }
    }
}

private struct DraftEditor: View {
    @ObservedObject var model: PasswordsModel
    let title: String

    var body: some View {
        Form {
            Section(title) {
                TextField("Website", text: draftBinding(\.site))
                TextField("Username", text: draftBinding(\.username))
                // A secure field: its text can't be copied onto the ordinary pasteboard.
                SecureField("Password", text: draftBinding(\.password))
                Button("Generate a Strong Password") { model.draft?.password = PasswordGenerator.generate() }
                    .buttonStyle(.link)
            }
            Section {
                HStack {
                    Button("Cancel") {
                        let id = model.draft?.id
                        model.draft = nil
                        if id == nil { model.detail = .none }
                    }
                    Spacer()
                    Button("Save") { model.saveDraft() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func draftBinding(_ path: WritableKeyPath<PasswordsModel.Draft, String>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: path] ?? "" }, set: { model.draft?[keyPath: path] = $0 })
    }
}

private struct NeverSaveList: View {
    @ObservedObject var model: PasswordsModel

    var body: some View {
        Form {
            Section("iSmith never offers to save passwords on these sites") {
                if model.neverSave.isEmpty { Text("None.").foregroundStyle(.secondary) }
                ForEach(model.neverSave, id: \.self) { origin in
                    HStack {
                        Text(origin.serialized)
                        Spacer()
                        Button { model.removeNeverSave(origin) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Offer to save passwords on this site again")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
