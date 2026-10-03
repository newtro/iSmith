import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var browser: BrowserState

    var body: some View {
        let space = browser.active
        HStack(spacing: 0) {
            Rail()
            SpaceView(space: space)
                .id(space.id)
            if browser.showVault {
                Divider()
                VaultPanel()
                    .frame(width: 340)
            }
        }
        // Tinted chrome: the whole frame reshades to the active space's color.
        .background(space.space.color.opacity(0.16))
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.25), value: browser.activeID)
        .onAppear { browser.start() }
    }
}

private struct Rail: View {
    @EnvironmentObject private var browser: BrowserState

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, state in
                let active = state.id == browser.activeID
                Button { browser.select(state) } label: {
                    Text(state.space.initials)
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 11)
                            .fill(active ? state.space.color : state.space.color.opacity(0.18)))
                        .foregroundStyle(active ? Color.white : state.space.color)
                }
                .buttonStyle(.plain)
                .help("\(state.space.name)  ⌘\(index + 1)")
            }
            Spacer()
            Button { browser.showVault.toggle() } label: {
                Image(systemName: "key.horizontal")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .help("Show or hide the vault panel")
        }
        .padding(.vertical, 12)
        .frame(width: 64)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct SpaceView: View {
    @EnvironmentObject private var browser: BrowserState
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
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(space.space.color.opacity(0.6), lineWidth: 1.5))
                    .padding([.horizontal, .bottom], 8)
            } else {
                Spacer()
                Text("Opening \(space.space.name)…").foregroundStyle(.secondary)
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
                RoundedRectangle(cornerRadius: 3).fill(space.space.color).frame(width: 10, height: 10)
                Text(space.space.name).fontWeight(.semibold)
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
                ForEach(Seed.quickLinks) { link in
                    Button(link.name) { tab.webView.load(URLRequest(url: link.url)) }
                }
            }
            .fixedSize()
            HStack(spacing: 4) {
                ForEach(space.space.accounts) { account in
                    Text(account.label)
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(space.space.color.opacity(0.18)))
                        .overlay(Capsule().stroke(space.space.color.opacity(0.5)))
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

private struct VaultPanel: View {
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var vault: Vault
    @EnvironmentObject private var sync: CookieSync

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Vault").font(.headline)
                Spacer()
                Button("Rescan") { sync.rescanAll() }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Seed.accounts) { account in
                        AccountRow(account: account, entry: vault.entries[account.id])
                    }
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
    @EnvironmentObject private var sync: CookieSync
    let account: Account
    let entry: Vault.Entry?

    var body: some View {
        let users = browser.spaces.filter { $0.space.accounts.contains(account) }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(account.label).fontWeight(.semibold)
                Spacer()
                Text(entry.map { "\($0.cookies.count) cookies" } ?? "not seen")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(users.map { $0.space.name + (sync.attached.contains($0.id) ? "" : " (not open)") }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let entry, !entry.cookies.isEmpty {
                DisclosureGroup("Cookie names") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entry.cookies, id: \.key) { cookie in
                            Text("\(cookie.name)  ·  \(cookie.domain)\(cookie.expires == nil ? "  · session" : "")")
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                Text("Updated \(entry.updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
