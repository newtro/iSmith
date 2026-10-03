import SignInSync
import SwiftUI
import WebKit

// MARK: - Space editor

struct SpaceEditor: View {
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var config: Config
    @Environment(\.dismiss) private var dismiss
    let request: EditorRequest
    let window: WindowState

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
            choices = AccountChoice.current(in: existing)
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
            browser.createSpace(name: trimmed, color: color, home: homeURL, choices: choices, newNames: newNames, in: window)
        }
        dismiss()
    }
}

// MARK: - Accounts panel

struct AccountsPanel: View {
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

