import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var browser: BrowserState

    var body: some View {
        HStack(spacing: 0) {
            Rail()
            if let space = browser.active {
                SpaceView(space: space)
                    .id(space.id)
                    // Tinted chrome: the frame reshades to the active space's color.
                    .background(space.color.opacity(0.16))
            } else {
                VStack(spacing: 12) {
                    Text("No spaces yet").font(.title3)
                    Button("New Space…") { browser.editing = EditorRequest(spaceID: nil) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if browser.showAccounts {
                Divider()
                AccountsPanel()
                    .frame(width: 360)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.25), value: browser.activeID)
        .sheet(item: $browser.editing) { request in
            SpaceEditor(request: request)
        }
        .onAppear { browser.start() }
    }
}

// MARK: - Rail

private struct Rail: View {
    @EnvironmentObject private var browser: BrowserState

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, state in
                        RailItem(state: state, index: index)
                    }
                    Button { browser.editing = EditorRequest(spaceID: nil) } label: {
                        Image(systemName: "plus")
                            .frame(width: 40, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4])))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New space  ⇧⌘N")
                }
                .padding(.vertical, 2)
            }
            Button { browser.showAccounts.toggle() } label: {
                Image(systemName: "person.2.badge.key")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .help("Accounts and sign-ins")
        }
        .padding(.vertical, 12)
        .frame(width: 64)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct RailItem: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var state: SpaceState
    let index: Int

    var body: some View {
        let active = state.id == browser.activeID
        Button { browser.select(state) } label: {
            Text(state.def.initials)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11).fill(active ? state.color : state.color.opacity(0.18)))
                .foregroundStyle(active ? Color.white : state.color)
        }
        .buttonStyle(.plain)
        .help(state.def.name + (index < 9 ? "  ⌘\(index + 1)" : ""))
        .contextMenu {
            Button("Edit Space…") { browser.editing = EditorRequest(spaceID: state.id) }
            Divider()
            Button("Delete Space…", role: .destructive) { browser.deleteSpace(state.id) }
        }
    }
}

// MARK: - Space

private struct SpaceView: View {
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var sync: CookieSync
    @ObservedObject var space: SpaceState

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(space: space)
            if let tab = space.selected {
                Toolbar(space: space, tab: tab)
                    .id(tab.id)
                WebViewHost(webView: tab.webView)
                    .id(tab.id)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(space.color.opacity(0.6), lineWidth: 1.5))
                    .padding([.horizontal, .bottom], 8)
            } else {
                Spacer()
                Text("Opening \(space.def.name)…").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

private struct TabStrip: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var space: SpaceState

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(space.color).frame(width: 10, height: 10)
                Text(space.def.name).fontWeight(.semibold)
            }
            .padding(.trailing, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(space.tabs) { tab in
                        TabButton(tab: tab, selected: tab.id == space.selected?.id,
                                  onSelect: { space.selectedID = tab.id },
                                  onClose: { browser.close(tab, in: space) })
                    }
                }
            }
            Button { Task { await browser.newTab(in: space, url: nil) } } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New tab  ⌘T")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }
}

private struct TabButton: View {
    @ObservedObject var tab: Tab
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if tab.isLoading { ProgressView().controlSize(.mini) }
            Text(tab.title).lineLimit(1).truncationMode(.tail)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 200, minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color(nsColor: .textBackgroundColor) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct Toolbar: View {
    @EnvironmentObject private var config: Config
    @ObservedObject var space: SpaceState
    @ObservedObject var tab: Tab
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { tab.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
            Button { tab.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
            Button { tab.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
            TextField("Search or enter address", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($addressFocused)
                .onSubmit(go)
            Menu("Go") {
                ForEach(QuickLink.all) { link in
                    Button(link.name) { tab.webView.load(URLRequest(url: link.url)) }
                }
            }
            .fixedSize()
            // Only exceptions are shown; everything else uses the shared sign-ins.
            HStack(spacing: 4) {
                ForEach(exceptions, id: \.self) { label in
                    Text(label)
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(space.color.opacity(0.18)))
                        .overlay(Capsule().stroke(space.color.opacity(0.5)))
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onAppear {
            address = tab.url?.absoluteString ?? ""
            if tab.url == nil { addressFocused = true }
        }
        .onReceive(tab.$url) { url in
            if !addressFocused { address = url?.absoluteString ?? "" }
        }
    }

    private var exceptions: [String] {
        config.providers.compactMap { p in
            switch space.def.bindings[p.id] {
            case nil: return nil
            case SpaceDef.local: return "\(p.name): this space only"
            case let id?: return config.account(id).map { "\(p.name): \($0.name)" }
            }
        }
    }

    private func go() {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let url: URL?
        if text.contains("://") {
            url = URL(string: text)
        } else if text.contains("."), !text.contains(" ") {
            url = URL(string: "https://" + text)
        } else {
            var parts = URLComponents(string: "https://www.google.com/search")!
            parts.queryItems = [URLQueryItem(name: "q", value: text)]
            url = parts.url
        }
        if let url { tab.webView.load(URLRequest(url: url)) }
        addressFocused = false
    }
}

// MARK: - Space editor

private struct SpaceEditor: View {
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var config: Config
    @Environment(\.dismiss) private var dismiss
    let request: EditorRequest

    @State private var name = ""
    @State private var color = 0
    @State private var home = ""
    @State private var choices: [String: AccountChoice] = [:]
    @State private var newNames: [String: String] = [:]
    @State private var loaded = false

    private var existing: SpaceDef? { request.spaceID.flatMap(config.space) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "New Space" : "Edit \(existing!.name)")
                .font(.headline)
                .padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $name)
                Picker("Color", selection: $color) {
                    ForEach(Palette.names.indices, id: \.self) { i in
                        Label { Text(Palette.names[i]) } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Palette.color(i))
                        }
                        .tag(i)
                    }
                }
                TextField("Home page", text: $home, prompt: Text("https://… (optional)"))
                Section {
                    ForEach(config.providers) { provider in
                        providerRow(provider)
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Leave these on Shared: sign in once anywhere and every space is signed in. Add more accounts with the site's own account picker (Google's \"Add another account\", Microsoft's \"Use another account\"). Each space still keeps its own site sessions, so Outlook or Etsy can show a different account in each space. Changing a setting here clears this space's browsing data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let existing {
                    Button("Delete Space…", role: .destructive) {
                        dismiss()
                        browser.deleteSpace(existing.id)
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create Space" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 620)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func providerRow(_ provider: ProviderDef) -> some View {
        let binding = Binding<AccountChoice>(
            get: { choices[provider.id] ?? .shared },
            set: { choices[provider.id] = $0 })
        VStack(alignment: .leading, spacing: 4) {
            Picker(provider.name, selection: binding) {
                Text("Shared with all spaces").tag(AccountChoice.shared)
                ForEach(config.accounts(for: provider.id).filter { !config.isShared($0.id) }) { account in
                    Text("Separate: \(account.name)").tag(AccountChoice.existing(account.id))
                }
                Text("New separate account…").tag(AccountChoice.new)
                Text("Not shared (this space only)").tag(AccountChoice.local)
            }
            if binding.wrappedValue == .new {
                TextField("New account name", text: Binding(
                    get: { newNames[provider.id] ?? "" },
                    set: { newNames[provider.id] = $0 }),
                          prompt: Text(name.isEmpty ? "Account name" : name))
                Text("Sign in to \(provider.name) in this space after saving.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if case .existing(let id) = binding.wrappedValue {
                let others = config.spaces(using: id).filter { $0.id != existing?.id }.map(\.name)
                if !others.isEmpty {
                    Text("Shared with \(others.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let existing {
            name = existing.name
            color = existing.color
            home = existing.home
            choices = existing.bindings.mapValues { $0 == SpaceDef.local ? AccountChoice.local : .existing($0) }
        } else {
            color = config.spaces.count % Palette.names.count
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var homeURL = home.trimmingCharacters(in: .whitespaces)
        if !homeURL.isEmpty, !homeURL.contains("://") { homeURL = "https://" + homeURL }
        if let existing {
            browser.updateSpace(existing.id, name: trimmed, color: color, home: homeURL, choices: choices, newNames: newNames)
        } else {
            browser.createSpace(name: trimmed, color: color, home: homeURL, choices: choices, newNames: newNames)
        }
        dismiss()
    }
}

// MARK: - Accounts panel

private struct AccountsPanel: View {
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var config: Config
    @EnvironmentObject private var sync: CookieSync
    @State private var showAddProvider = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Accounts").font(.headline)
                Spacer()
                Button("Rescan") { sync.rescanAll() }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(config.providers) { provider in
                        let accounts = config.accounts(for: provider.id)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(provider.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                if !provider.builtIn {
                                    Button("Remove") { browser.removeProvider(provider.id) }
                                        .buttonStyle(.borderless)
                                        .disabled(!accounts.allSatisfy { config.isShared($0.id) })
                                        .help(accounts.isEmpty ? "Remove this provider" : "Remove its accounts first")
                                }
                            }
                            Text(provider.domains.joined(separator: ", "))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            if accounts.isEmpty {
                                Text("No accounts").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(accounts) { account in
                                AccountRow(account: account)
                            }
                        }
                    }
                    DisclosureGroup("Add a provider", isExpanded: $showAddProvider) {
                        AddProviderForm { showAddProvider = false }
                    }
                    .font(.subheadline)
                    Divider()
                    Text("Sync log").font(.subheadline.weight(.semibold))
                    ForEach(sync.log.reversed()) { line in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.time, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Text(line.text).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
}

private struct AccountRow: View {
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var config: Config
    @EnvironmentObject private var vault: Vault
    @EnvironmentObject private var sync: CookieSync
    let account: AccountDef
    @State private var name = ""

    var body: some View {
        let users = config.spaces(using: account.id)
        let entry = vault.entries[account.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .fontWeight(.medium)
                    .onSubmit { config.renameAccount(account.id, to: name) }
                Spacer()
                Text(entry.map { $0.cookies.isEmpty ? "signed out" : "\($0.cookies.count) cookies" } ?? "not signed in")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(config.isShared(account.id) && users.count == config.spaces.count ? "Shared by all spaces"
                 : users.isEmpty ? "Not used by any space"
                 : users.map { $0.name + (sync.attached.contains($0.id) ? "" : " (closed)") }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Sign out everywhere") { browser.signOutEverywhere(account.id) }
                    .disabled(entry?.cookies.isEmpty ?? true)
                Button("Remove") { browser.removeAccount(account.id) }
                    .disabled(!users.isEmpty || config.isShared(account.id))
                    .help(users.isEmpty ? "Remove this account" : "Switch the spaces using it to another account first")
                if let entry, !entry.cookies.isEmpty {
                    Menu("Cookies") {
                        ForEach(entry.cookies, id: \.key) { cookie in
                            Text("\(cookie.name) · \(cookie.domain)\(cookie.expires == nil ? " · session" : "")")
                        }
                    }
                    .fixedSize()
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .onAppear { name = account.name }
        .onChange(of: account.name) { _, new in name = new }
    }
}

private struct AddProviderForm: View {
    @EnvironmentObject private var config: Config
    let done: () -> Void
    @State private var name = ""
    @State private var domains = ""
    @State private var sessionNames = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Any site you want one sign-in for across spaces, such as Okta, Etsy or AWS.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Name (e.g. Okta)", text: $name)
            TextField("Cookie domains, comma separated (e.g. okta.com)", text: $domains)
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Add Provider") {
                    error = config.addProvider(name: name.trimmingCharacters(in: .whitespaces),
                                               domains: list(domains), sessionNames: list(sessionNames))
                    guard error == nil else { return }
                    name = ""; domains = ""; sessionNames = ""
                    done()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || list(domains).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.top, 6)
    }

    private func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
