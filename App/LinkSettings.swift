import Routing
import SwiftUI

/// Settings ▸ Links: the default browser, the Default space, the ordered rule list, where Outlook,
/// Teams and Gmail links go, and suggestions turned off.
struct LinkSettings: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var routing: LinkRouter
    @ObservedObject var store: RoutingStore
    /// The rule being edited in the sheet (a new one has no rule yet).
    @State private var editing: RuleDraft?

    var body: some View {
        Form {
            Section("Default browser") {
                if routing.isDefaultBrowser {
                    Label("\(AppIdentity.displayName) is your default browser.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Links from other apps open in another browser.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Make \(AppIdentity.displayName) Your Default Browser") { routing.makeDefaultBrowser() }
                    }
                }
                if let error = routing.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Picker("Default space", selection: Binding(
                    get: { store.state.effectiveDefaultSpace(in: spaceIDs) ?? "" },
                    set: { store.setDefaultSpace($0) })) {
                    ForEach(browser.spaces) { Text($0.def.name).tag($0.id) }
                }
            } header: {
                Text("Links from other apps")
            } footer: {
                Text("A link opens in the space of the first rule below that matches it. Outlook, Teams and Gmail links open in the space you last used them in. Anything else opens in the Default space.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if store.state.rules.isEmpty {
                    Text("No rules yet. Add one, such as dev.azure.com/contoso-dev → Contoso, or move a link to another space twice and iSmith offers one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(store.state.rules.enumerated()), id: \.element.id) { index, rule in
                    RuleRow(rule: rule, index: index, count: store.state.rules.count, store: store) {
                        editing = RuleDraft(rule: rule)
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Rule…") { editing = RuleDraft(rule: nil, space: store.state.effectiveDefaultSpace(in: spaceIDs) ?? "") }
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Patterns: a host (github.com), a host and path (dev.azure.com/contoso-dev), or every subdomain (*.fabrikam.com). The first match wins.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !store.state.lastUsed.isEmpty {
                Section("Last used") {
                    ForEach(store.state.lastUsed.sorted { $0.key < $1.key }, id: \.key) { host, space in
                        HStack {
                            Text(host)
                            Spacer()
                            Text(name(of: space)).foregroundStyle(.secondary)
                            Button { store.forgetLastUsed(host: host) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Forget; links open in the Default space until you use it again")
                        }
                    }
                }
            }

            if !store.state.neverSuggest.isEmpty {
                Section("Never suggested") {
                    ForEach(store.state.neverSuggest, id: \.self) { pattern in
                        HStack {
                            Text(pattern.description)
                            Spacer()
                            Button { store.allowSuggestions(pattern) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("iSmith may suggest this rule again")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { routing.refreshDefaultBrowser() }
        .sheet(item: $editing) { draft in
            RuleEditor(draft: draft, spaces: browser.spaces) { rule in
                if draft.rule == nil { store.addRule(rule) } else { store.updateRule(rule) }
                editing = nil
            } cancel: {
                editing = nil
            }
        }
    }

    private var spaceIDs: [String] { browser.spaces.map(\.id) }

    private func name(of space: String) -> String {
        browser.space(space)?.def.name ?? "Deleted space"
    }
}

private struct RuleRow: View {
    @EnvironmentObject private var browser: BrowserState
    let rule: RoutingRule
    let index: Int
    let count: Int
    @ObservedObject var store: RoutingStore
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            Text(rule.pattern.description).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Picker("", selection: Binding(get: { rule.space }, set: { space in
                var changed = rule
                changed.space = space
                store.updateRule(changed)
            })) {
                ForEach(browser.spaces) { Text($0.def.name).tag($0.id) }
            }
            .labelsHidden().fixedSize()
            Button { store.moveRule(rule.id, to: index - 1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).help("Move up")
            Button { store.moveRule(rule.id, to: index + 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == count - 1).help("Move down")
            Button(action: edit) { Image(systemName: "pencil") }.help("Edit")
            Button { store.removeRule(rule.id) } label: { Image(systemName: "minus.circle") }.help("Delete")
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rule \(index + 1): \(rule.pattern.description)")
    }
}

struct RuleDraft: Identifiable {
    let id = UUID()
    /// The rule being edited; nil adds a new one.
    var rule: RoutingRule?
    var pattern: String
    var space: String

    init(rule: RoutingRule?, space: String = "") {
        self.rule = rule
        pattern = rule?.pattern.description ?? ""
        self.space = rule?.space ?? space
    }
}

/// Adds or edits one rule: a pattern (checked as you type) and a space.
private struct RuleEditor: View {
    @State var draft: RuleDraft
    let spaces: [SpaceState]
    let save: (RoutingRule) -> Void
    let cancel: () -> Void

    var body: some View {
        let parsed = Result { try URLPattern(parsing: draft.pattern) }
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.rule == nil ? "New Rule" : "Edit Rule").font(.headline)
            Form {
                TextField("Links to", text: $draft.pattern, prompt: Text("dev.azure.com/contoso-dev"))
                Picker("Open in", selection: $draft.space) {
                    ForEach(spaces) { Text($0.def.name).tag($0.id) }
                }
            }
            Group {
                switch parsed {
                case .success(let pattern): Text(Self.explain(pattern)).foregroundStyle(.secondary)
                case .failure(let error) where !draft.pattern.trimmingCharacters(in: .whitespaces).isEmpty:
                    Text((error as? URLPattern.ParseError)?.description ?? "\(error)").foregroundStyle(.red)
                case .failure: Text(" ")
                }
            }
            .font(.caption)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard case .success(let pattern) = parsed else { return }
                    save(RoutingRule(id: draft.rule?.id ?? UUID(), pattern: pattern, space: draft.space))
                }
                .keyboardShortcut(.defaultAction)
                .disabled((try? parsed.get()) == nil || !spaces.contains { $0.id == draft.space })
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    static func explain(_ p: URLPattern) -> String {
        let host = p.includesSubdomains ? "\(p.host) and its subdomains" : p.host
        let port = p.port.map { " on port \($0)" } ?? ""
        return p.pathPrefix.isEmpty ? "Every link to \(host)\(port)." : "Links to \(host)\(port) under \(p.pathPrefix)."
    }
}
