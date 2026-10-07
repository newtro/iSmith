import AgentKit
import AppKit
import BrowserData
import SwiftUI

/// The agent panel (v1.1, AGENT_PANEL.md): docked on the right (chat, with the activity log a
/// click away) or at the bottom (chat and activity log side by side), tinted with the space's
/// color like the rest of the chrome. It shows the space's chat: streamed replies, a collapsible
/// list of steps, cards for approvals and sign-ins, the mode and model, Stop, and the chat list.
struct AgentPanel: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var agent: AgentController
    @ObservedObject var session: AgentSession
    @ObservedObject var space: SpaceState
    @ObservedObject var window: WindowState
    let dock: AgentDock
    @State private var showingLog = false

    var body: some View {
        Group {
            if dock == .bottom {
                HStack(spacing: 0) {
                    chatColumn
                    Divider()
                    AgentActivityLog(session: session, spaceName: space.def.name)
                        .frame(minWidth: 280, idealWidth: 420)
                }
            } else {
                VStack(spacing: 0) {
                    if showingLog {
                        header(compact: false)
                        AgentActivityLog(session: session, spaceName: space.def.name, showsHeader: false)
                    } else {
                        chatColumn
                    }
                }
            }
        }
        .font(.system(size: 12.5))
        .environment(\.openURL, OpenURLAction { open($0) })
        .background(space.color.opacity(0.06))
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await agent.prepare() }
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            header(compact: dock == .bottom)
            AgentStatusBanner(agent: agent)
            AgentTranscript(agent: agent, session: session, spaceName: space.def.name)
            AgentComposer(agent: agent, session: session, spaceName: space.def.name)
        }
    }

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(space.color)
                AgentThreadMenu(agent: agent, session: session)
                Spacer(minLength: 4)
                if dock == .right {
                    Button { showingLog.toggle() } label: {
                        Image(systemName: showingLog ? "bubble.left.and.text.bubble.right" : "list.bullet.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .help(showingLog ? "Show the chat" : "Show the activity log")
                }
                Button { agent.newChat(in: session.spaceID) } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .disabled(session.running)
                    .help("New chat")
            }
            HStack(spacing: 6) {
                Picker("Mode", selection: Binding(get: { session.mode }, set: { agent.setMode($0, in: session.spaceID) })) {
                    ForEach(AgentMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("What the agent may do in \(space.def.name). Read-only: read pages. Ask: every click or keystroke asks you. Confirm submits: asks before sending, submitting, deleting or paying. YOLO: anything, without asking.")
                .accessibilityLabel("Agent mode")
                Picker("Model", selection: Binding(get: { session.model ?? "" }, set: { agent.setModel($0.isEmpty ? nil : $0, in: session.spaceID) })) {
                    Text(defaultModelTitle).tag("")
                    ForEach(agent.models) { Text($0.displayName).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Model")
                Spacer(minLength: 0)
                AgentFolderButton(agent: agent, session: session)
            }
            .controlSize(.small)
            Text([agent.backendName, session.activeModel, "subscription", space.def.name].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// "Default": whatever Codex's own settings pick (config.toml), which may not be the list's
    /// default, so it isn't named here; the line below shows the model a chat actually runs on.
    private var defaultModelTitle: String { "Default model" }
}

/// The chat's name, and a menu of the space's other chats.
extension AgentPanel {
    /// A link in the chat. The agent links web pages, and files by absolute path (often with a
    /// `:line` suffix and no scheme), which the system can't open as they are (error -50).
    fileprivate func open(_ url: URL) -> OpenURLAction.Result {
        switch AgentLink(url, workingFolder: session.workingFolder) {
        case let .web(url):
            browser.openTab(in: window, space: session.spaceID, url: url)
            return .handled
        case let .file(file):
            guard FileManager.default.fileExists(atPath: file.path) else { NSSound.beep(); return .discarded }
            NSWorkspace.shared.open(file)
            return .handled
        case nil:
            return .systemAction
        }
    }
}

/// Where a chat link goes: web pages open in a tab in the space, file paths open as files.
enum AgentLink: Equatable {
    case web(URL)
    case file(URL)

    init?(_ url: URL, workingFolder: String) {
        let path: String
        switch url.scheme?.lowercased() {
        case "http", "https": self = .web(url); return
        case "file": path = url.path
        case nil: path = url.path
        // `app.py:12` parses as scheme `app.py`; a real scheme has no dot in it.
        case let scheme? where scheme.contains("."): path = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        default: return nil
        }
        guard !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded
            : URL(fileURLWithPath: workingFolder, isDirectory: true).appendingPathComponent(expanded).path
        self = .file(URL(fileURLWithPath: Self.strippingLine(full)))
    }

    /// `/a/b.swift:12` or `/a/b.swift:12:5` → `/a/b.swift`, unless the path with the suffix exists.
    static func strippingLine(_ path: String) -> String {
        guard !FileManager.default.fileExists(atPath: path),
              let range = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) else { return path }
        return String(path[..<range.lowerBound])
    }
}

private struct AgentThreadMenu: View {
    @ObservedObject var agent: AgentController
    @ObservedObject var session: AgentSession

    var body: some View {
        Menu {
            Button("New Chat") { agent.newChat(in: session.spaceID) }
            if !session.threads.isEmpty {
                Divider()
                ForEach(session.threads.prefix(30)) { thread in
                    Button {
                        agent.openThread(thread.id, in: session.spaceID)
                    } label: {
                        Text(thread.name + "  —  " + thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            if let current = session.currentThread {
                Divider()
                Button("Remove “\(current.name)” from the List") { agent.removeThread(current.id, in: session.spaceID) }
            }
        } label: {
            Text(session.currentThread?.name ?? "New chat")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(session.running)
        .help("Chats in this space")
        .accessibilityLabel("Chats")
    }
}

/// The working folder for commands and file edits.
private struct AgentFolderButton: View {
    @ObservedObject var agent: AgentController
    @ObservedObject var session: AgentSession

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: session.workingFolder)
            panel.message = "The folder the agent works in for commands and file edits."
            panel.prompt = "Use Folder"
            if panel.runModal() == .OK, let url = panel.url { agent.setWorkingFolder(url.path, in: session.spaceID) }
        } label: {
            Label((session.workingFolder as NSString).lastPathComponent, systemImage: "folder")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .help("Working folder: \(session.workingFolder)")
    }
}

/// The backend's state when it isn't simply running: not installed, failed, restarting.
private struct AgentStatusBanner: View {
    @ObservedObject var agent: AgentController

    var body: some View {
        switch agent.status {
        case .notInstalled:
            banner(symbol: "exclamationmark.triangle", title: "Codex isn't installed",
                   text: "The agent panel runs OpenAI's Codex with your ChatGPT subscription. In Terminal, install it with “npm install -g @openai/codex” (or “brew install codex”), then sign in with “codex login”. iSmith looks for it on your PATH, in ~/.local/bin and in /opt/homebrew/bin.",
                   button: "Check Again")
        case let .failed(reason):
            banner(symbol: "exclamationmark.triangle", title: "Codex couldn't run", text: reason, button: "Try Again")
        case let .restarting(reason):
            banner(symbol: "arrow.clockwise", title: "Codex stopped; starting it again", text: reason, button: nil)
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting Codex…").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        default:
            EmptyView()
        }
    }

    private func banner(symbol: String, title: String, text: String, button: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 12.5, weight: .semibold))
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let button { Button(button) { agent.retry() }.controlSize(.small) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
        .padding(.horizontal, 10).padding(.top, 8)
    }
}

/// The chat: messages, steps and cards, scrolled to the newest.
private struct AgentTranscript: View {
    @ObservedObject var agent: AgentController
    @ObservedObject var session: AgentSession
    let spaceName: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.entries.isEmpty, session.cards.isEmpty {
                        Text(session.loadingThread ? "Loading the chat…" : "Nothing running in \(spaceName). The agent works in this space's tabs, signed in as its accounts, and opens its own tabs in the Agent group.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    ForEach(session.entries) { entry in
                        AgentEntryView(entry: entry)
                            .id(entry.id)
                    }
                    ForEach(session.cards) { card in
                        AgentCardView(agent: agent, card: card)
                            .id(card.id)
                    }
                    if session.running, session.cards.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working…").foregroundStyle(.secondary)
                        }
                        .id("working")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: session.entries) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.cards.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct AgentEntryView: View {
    let entry: AgentEntry
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case let .user(text):
            HStack {
                Spacer(minLength: 30)
                Text(text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 2, topTrailingRadius: 10)
                        .fill(Color.accentColor))
            }
        case let .agent(text):
            if !text.isEmpty {
                Text(AgentEntryView.markdown(text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 2, bottomTrailingRadius: 10, topTrailingRadius: 10)
                        .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 2, bottomTrailingRadius: 10, topTrailingRadius: 10)
                        .stroke(Color(nsColor: .separatorColor)))
            }
        case let .steps(steps):
            VStack(alignment: .leading, spacing: 4) {
                // One or two steps are listed as they are; a longer run folds under a count.
                if steps.count > 2 {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text(summary(steps)).foregroundStyle(.secondary)
                        if steps.contains(where: { $0.status == .inProgress }) { ProgressView().controlSize(.mini) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide steps" : "Show steps")
                }
                if expanded || steps.count <= 2 {
                    ForEach(steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: symbol(step.status))
                                .foregroundStyle(color(step.status))
                                .font(.system(size: 10))
                            Text(step.title).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .font(.system(size: 12))
                        .padding(.leading, 14)
                    }
                } else if let last = steps.last {
                    Text(last.title).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1).padding(.leading, 14)
                }
            }
        case let .problem(text):
            Label(text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .notice(text):
            Text(text).foregroundStyle(.secondary).font(.system(size: 11.5))
        }
    }

    private func summary(_ steps: [AgentStep]) -> String { "\(steps.count) steps" }

    private func symbol(_ status: AgentItem.Status) -> String {
        switch status {
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark"
        case .failed: return "xmark"
        case .declined: return "hand.raised"
        }
    }

    private func color(_ status: AgentItem.Status) -> Color {
        switch status {
        case .completed: return .green
        case .failed, .declined: return .orange
        case .inProgress: return .secondary
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// An approval or a sign-in waiting for the user.
private struct AgentCardView: View {
    @ObservedObject var agent: AgentController
    @ObservedObject var card: AgentCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch card.kind {
            case let .browser(request):
                Label("Allow this?", systemImage: "hand.tap").font(.system(size: 12.5, weight: .semibold))
                Text(request.action).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text("In the tab “\(request.tabTitle)” (names come from the page). \(request.reason)").foregroundStyle(.secondary).font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let tab = request.tabID { Button("Show Tab") { agent.show(tab: tab) } }
                    Spacer()
                    Button("Deny") { card.answer(.deny) }
                    Button("Allow") { card.answer(.allow) }.buttonStyle(.borderedProminent)
                }
            case let .backend(request):
                switch request.kind {
                case let .command(command, cwd, reason):
                    Label("Run this command?", systemImage: "terminal").font(.system(size: 12.5, weight: .semibold))
                    Text(command ?? "(a command)").font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let cwd { Text("In \(cwd)").foregroundStyle(.secondary).font(.system(size: 11)) }
                    if let reason { Text(reason).foregroundStyle(.secondary).font(.system(size: 11.5)) }
                case let .fileChange(reason, root):
                    Label("Change files?", systemImage: "doc.badge.gearshape").font(.system(size: 12.5, weight: .semibold))
                    if let root { Text("In \(root)").foregroundStyle(.secondary).font(.system(size: 11)) }
                    if let reason { Text(reason).foregroundStyle(.secondary).font(.system(size: 11.5)) }
                case let .permissions(reason, summary):
                    Label("Allow more access?", systemImage: "lock.open").font(.system(size: 12.5, weight: .semibold))
                    Text(summary).fixedSize(horizontal: false, vertical: true)
                    if let reason { Text(reason).foregroundStyle(.secondary).font(.system(size: 11.5)) }
                }
                HStack {
                    Button("Stop") { card.answer(.stop) }
                    Spacer()
                    Button("Deny") { card.answer(.deny) }
                    Button("Allow for This Chat") { card.answer(.allowForSession) }
                    Button("Allow") { card.answer(.allow) }.buttonStyle(.borderedProminent)
                }
            case let .handOff(request):
                Label("Waiting for you", systemImage: "person.badge.key").font(.system(size: 12.5, weight: .semibold))
                Text(request.message).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show Tab") { agent.show(tab: request.tabID) }
                    Spacer()
                    Button("Stop") { card.answer(.stop) }
                    Button("Continue") { card.answer(.proceed) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent question")
    }
}

/// Where the user types; Return sends, ⇧Return adds a line. Stop while a turn runs.
private struct AgentComposer: View {
    @ObservedObject var agent: AgentController
    @ObservedObject var session: AgentSession
    let spaceName: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Ask about \(spaceName)…", text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                .accessibilityLabel("Message to the agent")
            if session.running {
                Button { agent.stop(in: session.spaceID) } label: { Image(systemName: "stop.circle.fill").font(.system(size: 17)) }
                    .buttonStyle(.borderless)
                    .help("Stop")
                    .accessibilityLabel("Stop")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 17)) }
                    .buttonStyle(.borderless)
                    .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || unavailable)
                    .help("Send  ↩")
                    .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor)))
        .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 4)
    }

    private var unavailable: Bool {
        if case .notInstalled = agent.status { return true }
        return false
    }

    private func send() {
        guard !unavailable else { return }
        agent.send(session.draft, in: session.spaceID)
    }
}

/// The space's activity log: every browser tool call, newest first, with time, tab and target.
struct AgentActivityLog: View {
    @ObservedObject var session: AgentSession
    let spaceName: String
    var showsHeader = true

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack {
                    Text("Activity log").font(.system(size: 13, weight: .semibold))
                    Text(spaceName).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .overlay(alignment: .bottom) { Divider() }
            }
            if session.activity.isEmpty {
                Text("No agent activity yet.").foregroundStyle(.secondary).padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(session.activity) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.at.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Image(systemName: Self.symbol(row.outcome)).foregroundStyle(Self.color(row.outcome)).font(.system(size: 10))
                            .help(row.outcome.rawValue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(row.tool) · \(row.target)").lineLimit(1)
                            if let title = row.tabTitle {
                                Text(title + (row.tabURL.map { " — \($0)" } ?? "")).foregroundStyle(.secondary).lineLimit(1)
                                    .font(.system(size: 11))
                            }
                        }
                    }
                    .font(.system(size: 11.5))
                    .help(row.tabURL ?? "")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    static func symbol(_ outcome: AgentActivity.Outcome) -> String {
        switch outcome {
        case .done: return "checkmark"
        case .failed: return "xmark"
        case .blocked: return "nosign"
        case .denied: return "hand.raised"
        case .waiting: return "hourglass"
        }
    }

    static func color(_ outcome: AgentActivity.Outcome) -> Color {
        switch outcome {
        case .done: return .green
        case .failed, .blocked, .denied: return .orange
        case .waiting: return .secondary
        }
    }
}

/// The toolbar's three-button dock control: panel on the right, at the bottom, or hidden.
struct AgentDockControl: View {
    @ObservedObject var window: WindowState

    var body: some View {
        HStack(spacing: 0) {
            button(.right, "sidebar.right", "Agent panel on the right")
            Divider().frame(height: 16)
            button(.bottom, "rectangle.bottomthird.inset.filled", "Agent panel at the bottom")
            Divider().frame(height: 16)
            button(.hidden, "rectangle", "Hide the agent panel")
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent panel position")
    }

    private func button(_ dock: AgentDock, _ symbol: String, _ help: String) -> some View {
        Button {
            window.agentDock = dock
            AgentDock.preferred = dock
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11.5))
                .frame(width: 28, height: 24)
                .foregroundStyle(window.agentDock == dock ? Color.accentColor : Color.secondary)
                .background(window.agentDock == dock ? Color.accentColor.opacity(0.16) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(window.agentDock == dock ? [.isSelected] : [])
    }
}
