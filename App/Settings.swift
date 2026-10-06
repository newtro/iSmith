import AgentKit
import AppKit
import BrowserData
import SwiftUI

/// The Settings window (⌘,): accounts and sign-ins, general choices, and what each website may do.
struct SettingsView: View {
    @EnvironmentObject private var browser: BrowserState

    var body: some View {
        TabView {
            AccountsPanel()
                .tabItem { Label("Accounts", systemImage: "person.2") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PrivacySettings(shields: browser.shields)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            PasswordSettings()
                .tabItem { Label("Passwords", systemImage: "key") }
            WebsiteSettings()
                .tabItem { Label("Websites", systemImage: "globe") }
            LinkSettings(routing: browser.routing, store: browser.routing.store)
                .tabItem { Label("Links", systemImage: "arrow.triangle.branch") }
            AgentSettings()
                .tabItem { Label("Agents", systemImage: "sparkles") }
        }
        .padding(.top, 6)
    }
}

/// Where saved passwords live and how to get to them.
private struct PasswordSettings: View {
    @EnvironmentObject private var browser: BrowserState

    var body: some View {
        Form {
            Section {
                if let problem = browser.passwordsProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                LabeledContent("Saved passwords") {
                    Button("Open Passwords…") { browser.openPasswords?() }
                        .disabled(browser.passwords == nil)
                }
                LabeledContent("From Brave") {
                    Button("Import from Brave…") { browser.openImport?() }
                }
            }
            Section("Autofill") {
                Text("Click a username or password field to pick a saved login, or press ⌘\\ to fill the one saved for the site. iSmith offers to save passwords when you sign in, and suggests a strong password on sign-up forms.")
                    .foregroundStyle(.secondary)
                Text("Passwords are encrypted with a key in your login Keychain. Showing or copying one asks for Touch ID or your Mac password.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The agent panel: the mode new spaces start in, and which backend runs it.
private struct AgentSettings: View {
    @EnvironmentObject private var browser: BrowserState
    @AppStorage(AgentController.defaultModeKey) private var defaultMode = AgentMode.yolo.rawValue

    var body: some View {
        Form {
            Picker("Mode for spaces", selection: $defaultMode) {
                ForEach(AgentMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Text("Each space keeps its own mode once you change it in the agent panel. Read-only: the agent reads pages and moves between them. Ask: every click, keystroke and command asks you first. Confirm submits: it asks before submitting, sending, deleting or paying. YOLO: it does anything without asking, including shell commands; the activity log is the record.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Backend") {
                Text(CodexAppServerBackend.locateExecutable()?.path ?? "Codex isn't installed")
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("The agent runs OpenAI's Codex (codex app-server) with your ChatGPT subscription. Its browser tools see only the space it works in and act through that space's tabs; they never get saved passwords, cookies or other spaces. Shell commands (outside Read-only) run in Codex's sandbox, which can read files on this Mac; outside YOLO they may write only the space's own folder.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var browser: BrowserState
    @AppStorage(SearchEngine.defaultsKey) private var engine = SearchEngine.google.rawValue
    @AppStorage("showBookmarksBar") private var showBookmarksBar = true
    @AppStorage(TabLayoutStyle.defaultsKey) private var verticalTabs = false

    var body: some View {
        Form {
            Picker("Search engine", selection: $engine) {
                ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
            }
            Picker("Tabs", selection: $verticalTabs) {
                Text("Across the top").tag(false)
                Text("In a sidebar (vertical)").tag(true)
            }
            .onChange(of: verticalTabs) { _, vertical in
                // Every open window follows; View ▸ Use Vertical Tabs changes one window.
                for window in browser.windows { window.verticalTabs = vertical }
                browser.scheduleRefresh()
            }
            Toggle("Show the bookmarks bar", isOn: $showBookmarksBar)
            LabeledContent("Downloads go to") {
                Text(browser.downloads.folder.path).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent("Background tabs") {
                Text("Unloaded after 30 minutes, except Keep alive tabs").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Saved answers: camera, microphone, location and notification permission per site; which
/// app links open; per-site zoom. Removing one means the site (or link) asks again.
private struct WebsiteSettings: View {
    @EnvironmentObject private var browser: BrowserState
    @State private var permissions: [SitePermissionEntry] = []
    @State private var appLinks: [(scheme: String, decision: AppLinkDecision)] = []
    @State private var zooms: [(host: String, factor: Double)] = []

    var body: some View {
        Form {
            Section("Permissions") {
                if permissions.isEmpty { Text("No site has asked yet.").foregroundStyle(.secondary) }
                ForEach(permissions, id: \.key) { entry in
                    HStack {
                        Text(entry.origin).lineLimit(1)
                        Spacer()
                        Text(Self.name(entry.permission)).foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { entry.decision }, set: { set(entry, $0) })) {
                            Text("Allow").tag(PermissionDecision.allow)
                            Text("Don't Allow").tag(PermissionDecision.deny)
                        }
                        .labelsHidden().fixedSize()
                        Button { remove(entry) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Forget; the site asks again")
                    }
                }
            }
            Section("Links that open apps") {
                if appLinks.isEmpty { Text("None yet. iSmith asks the first time a page opens an app.").foregroundStyle(.secondary) }
                ForEach(appLinks, id: \.scheme) { link in
                    HStack {
                        Text("\(link.scheme):")
                        if let app = URL(string: "\(link.scheme):x").flatMap(AppLinks.defaultApp) {
                            Text(AppLinks.appName(app)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(get: { link.decision }, set: { setAppLink(link.scheme, $0) })) {
                            Text("Open").tag(AppLinkDecision.open)
                            Text("Don't Open").tag(AppLinkDecision.block)
                        }
                        .labelsHidden().fixedSize()
                        Button { setAppLink(link.scheme, nil) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Forget; iSmith asks again")
                    }
                }
            }
            Section("Zoom") {
                if zooms.isEmpty { Text("Every site is at 100%.").foregroundStyle(.secondary) }
                ForEach(zooms, id: \.host) { zoom in
                    HStack {
                        Text(zoom.host)
                        Spacer()
                        Text("\(Int((zoom.factor * 100).rounded()))%").foregroundStyle(.secondary)
                        Button { try? browser.data?.sites.setZoom(nil, host: zoom.host); reload() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: SiteSettingsStore.didChange)) { _ in reload() }
    }

    private func reload() {
        let sites = browser.data?.sites
        permissions = ((try? sites?.allDecisions()) ?? []).sorted { ($0.origin, $0.permission.rawValue) < ($1.origin, $1.permission.rawValue) }
        appLinks = ((try? sites?.allAppLinkDecisions()) ?? [:]).map { ($0.key, $0.value) }.sorted { $0.scheme < $1.scheme }
        zooms = ((try? sites?.allZooms()) ?? [:]).map { ($0.key, $0.value) }.sorted { $0.host < $1.host }
    }

    private func set(_ entry: SitePermissionEntry, _ decision: PermissionDecision?) {
        try? browser.data?.sites.setDecision(decision, for: entry.permission, origin: entry.origin)
        if entry.permission == .notifications {
            browser.notifications.permissionChanged(origin: entry.origin, in: browser.windows.flatMap(\.allTabs).compactMap(\.webView))
        }
        reload()
    }

    private func remove(_ entry: SitePermissionEntry) { set(entry, nil) }

    private func setAppLink(_ scheme: String, _ decision: AppLinkDecision?) {
        try? browser.data?.sites.setAppLinkDecision(decision, scheme: scheme)
        reload()
    }

    static func name(_ permission: SitePermission) -> String {
        switch permission {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .cameraAndMicrophone: return "Camera and microphone"
        case .location: return "Location"
        case .notifications: return "Notifications"
        }
    }
}

private extension SitePermissionEntry {
    var key: String { "\(origin)|\(permission.rawValue)" }
}
