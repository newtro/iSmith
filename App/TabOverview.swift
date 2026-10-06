import AppKit
import SwiftUI

/// One tab as the tab overview lists it.
struct TabSearchEntry: Identifiable, Equatable {
    let id: UUID
    let title: String
    let host: String
    let group: TabGroup?
    let pinned: Bool
    let selected: Bool
}

/// The overview's search: every word typed must appear in the tab's title, its site or its
/// group's name, ignoring case and accents. Tabs stay in strip order.
enum TabSearch {
    @MainActor
    static func entries(_ tabs: SpaceTabs) -> [TabSearchEntry] {
        let layout = tabs.layout
        return layout.ids.compactMap { id in
            guard let tab = tabs.tab(id) else { return nil }
            var host = tab.url?.host ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return TabSearchEntry(id: id, title: tab.title, host: host, group: layout.group(of: id),
                                  pinned: layout.isPinned(id), selected: layout.selected == id)
        }
    }

    static func filter(_ entries: [TabSearchEntry], query: String) -> [TabSearchEntry] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = fold([entry.title, entry.host, entry.group?.name ?? ""].joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// ⌘⇧A: the space's tabs as a searchable list (icon, title, site, group). Type to filter; ↑ and ↓
/// move, Return goes to the tab, Esc closes. ⇧↑ and ⇧↓ (or ⌘-click and ⇧-click) pick several
/// tabs; ⌘⌫ closes the picked tabs (or the highlighted one) and "Move To" moves them to a group,
/// a new group, another space or a new window.
struct TabOverview: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var window: WindowState
    @ObservedObject var tabs: SpaceTabs
    let spaceName: String
    @ObservedObject private var favicons = Favicons.shared
    @State private var query = ""
    @State private var highlighted: UUID?
    @State private var picked: Set<UUID> = []
    @State private var anchor: UUID?

    private var results: [TabSearchEntry] { TabSearch.filter(TabSearch.entries(tabs), query: query) }

    /// What the actions apply to: the picked tabs, or the highlighted one.
    private var targets: [UUID] {
        let ids = results.map(\.id)
        if !picked.isEmpty { return ids.filter(picked.contains) }
        return highlighted.map { [$0] } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                OverviewSearchField(text: $query, placeholder: "Search tabs in \(spaceName)", command: handle)
                    .frame(height: 22)
                Text("\(results.count) of \(tabs.layout.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { entry in
                            row(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id, anchor: nil) }
                }
            }
            .overlay {
                if results.isEmpty {
                    Text(query.isEmpty ? "No tabs" : "No tabs match “\(query)”").foregroundStyle(.secondary)
                }
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 480)
        .onAppear {
            highlighted = tabs.layout.selected ?? results.first?.id
            if let selected = tabs.layout.selected {
                let strip = tabs.targets(for: selected)
                picked = strip.count > 1 ? Set(strip) : []
            }
        }
        .onChange(of: query) { _, _ in
            // Picks hidden by the filter are dropped, so the actions only touch tabs on screen.
            picked.formIntersection(results.map(\.id))
            // The highlight stays on a visible tab.
            if let h = highlighted, results.contains(where: { $0.id == h }) { return }
            highlighted = results.first?.id
        }
        .onChange(of: tabs.layout.ids) { _, ids in
            picked.formIntersection(ids)
            if let h = highlighted, !ids.contains(h) { highlighted = results.first?.id }
        }
    }

    private func row(_ entry: TabSearchEntry) -> some View {
        let isHighlighted = highlighted == entry.id
        let isPicked = picked.contains(entry.id)
        return HStack(spacing: 10) {
            Image(nsImage: tabs.tab(entry.id).map { favicons.image(for: $0) } ?? Favicons.placeholder(for: nil, title: entry.title))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                if !entry.host.isEmpty {
                    Text(entry.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if entry.pinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).help("Pinned")
            }
            if let group = entry.group {
                Text(group.name.isEmpty ? "Group" : group.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: group.color.nsColor)))
            }
            if entry.selected {
                Text("Showing").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHighlighted ? Color.accentColor.opacity(0.22) : isPicked ? Color.accentColor.opacity(0.12) : .clear)
        )
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isPicked ? Color.accentColor.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { click(entry.id) }
        .contextMenu {
            // The same actions as the strip's menu, on the picked tabs (or this one).
            let ids = picked.contains(entry.id) ? targets : [entry.id]
            Button(ids.count > 1 ? "Close \(ids.count) Tabs" : "Close Tab") { browser.closeTabs(ids, in: tabs) }
            moveMenu(ids)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { jump(to: entry.id) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(picked.isEmpty ? "↑↓ move · Return opens · ⇧↑↓ or ⌘-click picks · ⌘⌫ closes tabs · Esc"
                 : "\(picked.count) picked")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu("Move To") { moveMenu(targets) }
                .fixedSize()
                .disabled(targets.isEmpty)
            Button(targets.count > 1 ? "Close \(targets.count) Tabs" : "Close Tab") { closeTargets() }
                .disabled(targets.isEmpty)
                .help("⌘⌫")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func moveMenu(_ ids: [UUID]) -> some View {
        let groups = tabs.layout.groups.filter { !$0.agent }
        if !groups.isEmpty {
            Menu("Group") {
                ForEach(groups) { group in
                    Button(group.name.isEmpty ? "Unnamed group" : group.name) {
                        browser.move(ids, toGroup: group.id, in: tabs)
                        picked = []
                    }
                }
            }
        }
        Button("New Group") {
            browser.createGroup(with: ids, in: tabs)
            picked = []
        }
        let others = browser.spaces.filter { $0.id != tabs.spaceID }
        if !others.isEmpty {
            Menu("Space") {
                ForEach(others) { space in
                    Button(space.def.name) {
                        browser.moveTabs(ids, from: tabs, in: window, toSpace: space.id)
                        picked = []
                    }
                }
            }
        }
        Button("New Window") {
            window.overviewShown = false
            browser.moveToNewWindow(ids, from: tabs, in: window)
        }
    }

    // MARK: Actions

    private func click(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
            anchor = id
            highlighted = id
        } else if flags.contains(.shift) {
            pickRange(to: id)
        } else {
            jump(to: id)
        }
    }

    private func pickRange(to id: UUID) {
        let ids = results.map(\.id)
        // The anchor may have been filtered out: start again from the highlighted row.
        let start = [anchor, highlighted].compactMap { $0 }.first(where: ids.contains) ?? id
        guard let a = ids.firstIndex(of: start), let b = ids.firstIndex(of: id) else { return }
        picked = Set(ids[min(a, b)...max(a, b)])
        anchor = start
        highlighted = id
    }

    private func jump(to id: UUID) {
        window.overviewShown = false
        browser.selectTab(id, in: tabs)
        if let webView = tabs.tab(id)?.webView { webView.window?.makeFirstResponder(webView) }
    }

    private func closeTargets() {
        let ids = targets
        guard !ids.isEmpty else { return NSSound.beep() }
        let rows = results.map(\.id)
        let next = rows.first { !ids.contains($0) && (rows.firstIndex(of: $0) ?? 0) > (rows.firstIndex(of: ids.last!) ?? 0) }
            ?? rows.last { !ids.contains($0) }
        browser.closeTabs(ids, in: tabs)
        picked = []
        highlighted = next
    }

    private func handle(_ command: OverviewSearchField.Command) -> Bool {
        let ids = results.map(\.id)
        switch command {
        case let .move(step, extend):
            guard !ids.isEmpty else { return true }
            let current = highlighted.flatMap(ids.firstIndex(of:)) ?? (step > 0 ? -1 : ids.count)
            let next = ids[min(max(current + step, 0), ids.count - 1)]
            if extend {
                if anchor == nil || picked.isEmpty { anchor = highlighted ?? next }
                pickRange(to: next)
            } else {
                highlighted = next
            }
        case .open:
            if let id = highlighted ?? ids.first { jump(to: id) } else { NSSound.beep() }
        case .close:
            closeTargets()
        case .cancel:
            if !picked.isEmpty { picked = [] } else { window.overviewShown = false }
        }
        return true
    }
}

/// The overview's search field: an AppKit field, so ↑, ↓, ⇧↑, ⇧↓, Return, Esc and ⌘⌫ reach the
/// list while typing goes to the field.
struct OverviewSearchField: NSViewRepresentable {
    enum Command {
        case move(Int, extend: Bool)
        case open, close, cancel
    }

    @Binding var text: String
    let placeholder: String
    let command: (Command) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search tabs")
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OverviewSearchField

        init(_ parent: OverviewSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.command(.move(-1, extend: false))
            case #selector(NSResponder.moveDown(_:)): return parent.command(.move(1, extend: false))
            case #selector(NSResponder.moveUpAndModifySelection(_:)): return parent.command(.move(-1, extend: true))
            case #selector(NSResponder.moveDownAndModifySelection(_:)): return parent.command(.move(1, extend: true))
            case #selector(NSResponder.insertNewline(_:)): return parent.command(.open)
            case #selector(NSResponder.cancelOperation(_:)): return parent.command(.cancel)
            // ⌘⌫ clears typed text first; in an empty field it closes tabs.
            case #selector(NSResponder.deleteToBeginningOfLine(_:)):
                return textView.string.isEmpty ? parent.command(.close) : false
            default: return false
            }
        }
    }
}
