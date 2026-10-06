import AppKit
import BrowserData
import Combine
import SwiftUI

/// One row under the address bar.
struct Suggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Search the chosen engine for the text.
        case search
        /// Go to an address as typed (or completed).
        case address
        case history
        case bookmark
        /// An open tab; picking it switches to it.
        case openTab(UUID)
    }

    var id: String { "\(kind)|\(url.absoluteString)" }
    let kind: Kind
    let title: String
    let url: URL
    /// The space it comes from, when that isn't the current one (history from other spaces).
    var otherSpace: String?

    var symbol: String {
        switch kind {
        case .search: return "magnifyingglass"
        case .address: return "globe"
        case .history: return "clock"
        case .bookmark: return "star"
        case .openTab: return "square.on.square"
        }
    }

    /// What the address field shows while the row is highlighted.
    var fieldText: String {
        kind == .search ? title : url.absoluteString
    }
}

/// Builds the address bar's suggestions: what Return does first, then the space's open tabs,
/// bookmarks (shared by every space, so never labelled with one) and history (the current space
/// first, then others, labelled), then a search. History queries run off the
/// main thread; a newer keystroke makes an older answer irrelevant.
@MainActor
enum AddressSuggestions {
    struct Result {
        var items: [Suggestion]
        /// Inline completion: the full text the field should show, starting with what was typed.
        var completion: String?
    }

    static func compute(for text: String, space: String, browser: BrowserState) async -> Result {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return Result(items: [], completion: nil) }
        let engine = SearchEngine.current
        let history = browser.data?.history
        let bookmarks = browser.data?.bookmarks
        let spaceNames = Dictionary(browser.spaces.map { ($0.id, $0.def.name) }, uniquingKeysWith: { a, _ in a })

        let (visited, completion, marked) = await Task.detached(priority: .userInitiated) { () -> ([HistorySuggestion], String?, [Bookmark]) in
            let visited = (try? history?.suggestions(for: typed, space: space, limit: 8)) ?? []
            let completion = typed.contains(" ") ? nil : (try? history?.inlineCompletion(for: typed, space: space)) ?? nil
            let marked = (try? bookmarks?.search(typed, limit: 4)) ?? []
            return (visited, completion, marked)
        }.value

        var items: [Suggestion] = []
        var seen = Set<String>()
        func add(_ s: Suggestion) {
            let key = s.kind == .search ? "search" : s.url.absoluteString
            guard seen.insert(key).inserted else { return }
            items.append(s)
        }

        // What Return does.
        let full = completion ?? typed
        let top = AddressInput.url(for: full, engine: engine)
        let isSearch = completion == nil && !typed.contains("://") && !AddressInput.looksLikeAddress(typed)
        if isSearch, let url = top {
            add(Suggestion(kind: .search, title: typed, url: url))
        } else if let url = top {
            add(Suggestion(kind: .address, title: full, url: url))
        }

        let words = typed.lowercased().split(separator: " ").map(String.init)
        let tabs = browser.windows.flatMap { window in
            window.spaces.values.filter { $0.spaceID == space }.flatMap(\.ordered)
        }
        for tab in tabs where tab.url != nil {
            let hay = (tab.title + " " + (tab.url?.absoluteString ?? "")).lowercased()
            guard words.allSatisfy(hay.contains), let url = tab.url else { continue }
            add(Suggestion(kind: .openTab(tab.id), title: tab.title, url: url))
            if items.count >= 3 { break }
        }
        for mark in marked {
            guard let s = mark.url, let url = URL(string: s) else { continue }
            add(Suggestion(kind: .bookmark, title: mark.title, url: url))
        }
        for visit in visited {
            guard let url = URL(string: visit.url) else { continue }
            add(Suggestion(kind: .history, title: visit.title ?? url.host ?? visit.url, url: url,
                           otherSpace: visit.space == space ? nil : spaceNames[visit.space]))
            if items.count >= 9 { break }
        }
        if !isSearch, let url = engine.searchURL(typed) {
            add(Suggestion(kind: .search, title: typed, url: url))
        }
        return Result(items: items, completion: completion)
    }
}

/// The address field: an AppKit text field, so typing can show an inline completion (the rest of
/// the address, selected) and the arrow keys can move through the suggestions.
struct AddressField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Text the user typed (not completed), and whether the last edit deleted.
    var edited: (_ typed: String, _ deleting: Bool) -> Void
    var focusChanged: (Bool) -> Void
    /// Return; ⌘Return opens in a new tab.
    var commit: (_ newTab: Bool) -> Void
    var cancel: () -> Void
    /// ↑ (-1) and ↓ (+1); returns whether a suggestion list handled it.
    var move: (Int) -> Bool
    let bridge: AddressBridge

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AddressTextField {
        let field = AddressTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.focused = { [weak coordinator = context.coordinator] in coordinator?.parent.focusChanged(true) }
        field.setAccessibilityLabel("Address and search")
        context.coordinator.field = field
        bridge.field = field
        context.coordinator.subscriptions = [
            bridge.focus.sink { [weak field] in
                guard let field else { return }
                DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
            },
            bridge.completions.sink { [weak coordinator = context.coordinator] typed, full in
                coordinator?.complete(typed: typed, full: full)
            },
            bridge.displays.sink { [weak coordinator = context.coordinator] text in
                coordinator?.show(text)
            },
        ]
        return field
    }

    func updateNSView(_ field: AddressTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        weak var field: AddressTextField?
        var subscriptions: [AnyCancellable] = []
        private var deleting = false
        /// What the user typed, without any completion.
        private var typed = ""

        init(_ parent: AddressField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field else { return }
            typed = field.stringValue
            parent.bridge.typed = typed
            parent.text = typed
            parent.edited(typed, deleting)
            deleting = false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.focusChanged(false)
        }

        /// Shows `full` with the part after what was typed selected, if the field still holds
        /// exactly what was typed and the caret is at its end.
        func complete(typed: String, full: String) {
            guard let field, let editor = field.currentEditor() as? NSTextView, editor.string == typed, typed == self.typed,
                  editor.selectedRange() == NSRange(location: (typed as NSString).length, length: 0),
                  full.count > typed.count, full.lowercased().hasPrefix(typed.lowercased()) else { return }
            let rest = String(full.dropFirst(typed.count))
            editor.string = typed + rest
            editor.setSelectedRange(NSRange(location: (typed as NSString).length, length: (rest as NSString).length))
            parent.text = typed + rest
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteToBeginningOfLine(_:)):
                deleting = true
                return false
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = textView.string
                parent.commit(NSApp.currentEvent?.modifierFlags.contains(.command) == true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.cancel()
                return true
            case #selector(NSResponder.moveUp(_:)):
                return parent.move(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.move(1)
            default:
                return false
            }
        }

        /// Shows a highlighted suggestion's text without treating it as typed.
        func show(_ text: String) {
            guard let field else { return }
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            } else {
                field.stringValue = text
            }
            parent.text = text
        }
    }
}

/// Connects the toolbar to its address field: focus requests, inline completions, the text of a
/// highlighted suggestion, and the field itself (the suggestion list sits under it).
@MainActor
final class AddressBridge: ObservableObject {
    let focus = PassthroughSubject<Void, Never>()
    /// (typed, full)
    let completions = PassthroughSubject<(String, String), Never>()
    let displays = PassthroughSubject<String, Never>()
    weak var field: NSView?
    /// What the user typed last (shown again when the highlight goes back above the list).
    var typed = ""
}

/// Selects all of its text when it takes focus, as browsers' address bars do.
final class AddressTextField: NSTextField {
    var focused: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            focused?()
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
        return ok
    }
}

/// The suggestion list: a borderless child window under the address field, so it draws over the
/// page (a web view is an AppKit view and would cover a SwiftUI overlay).
@MainActor
final class SuggestionPopup: ObservableObject {
    @Published var items: [Suggestion] = []
    /// Highlighted with the arrow keys; Return opens it.
    @Published var selected: Int?
    /// Under the mouse; only a click opens it.
    @Published var hovered: Int?
    var picked: ((Suggestion) -> Void)?
    private var panel: NSPanel?

    var isShown: Bool { panel?.isVisible == true && !items.isEmpty }

    func show(_ items: [Suggestion], below anchor: NSView) {
        // The same list again (a late answer) keeps the highlight the arrow keys moved.
        if items.map(\.id) != self.items.map(\.id) {
            selected = nil
            hovered = nil
        }
        self.items = items
        guard !items.isEmpty, let window = anchor.window else { return hide() }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let rect = anchor.convert(anchor.bounds, to: nil)
        let onScreen = window.convertToScreen(rect)
        let height = CGFloat(items.count) * 30 + 8
        let width = max(onScreen.width, 420)
        panel.setFrame(NSRect(x: onScreen.minX - 10, y: onScreen.minY - height - 6, width: width + 20, height: height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        items = []
        selected = nil
        hovered = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    /// Moves the highlight; returns the newly highlighted suggestion (nil: back to the typed text).
    func move(_ step: Int) -> Suggestion? {
        guard !items.isEmpty else { return nil }
        let next = (selected ?? -1) + step
        if next < 0 { selected = nil; return nil }
        selected = min(next, items.count - 1)
        return items[selected!]
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.contentView = NSHostingView(rootView: SuggestionList(popup: self))
        return panel
    }
}

private struct SuggestionList: View {
    @ObservedObject var popup: SuggestionPopup

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(popup.items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: item.symbol).frame(width: 16).foregroundStyle(.secondary)
                    Text(item.kind == .search ? "\(item.title) — Search \(SearchEngine.current.name)" : item.title)
                        .lineLimit(1)
                    if item.kind != .search {
                        Text(item.url.absoluteString).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary).font(.system(size: 11))
                    }
                    Spacer(minLength: 4)
                    if case .openTab = item.kind {
                        Text("Switch to Tab").font(.caption).foregroundStyle(.secondary)
                    } else if let space = item.otherSpace {
                        Text(space).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(index == popup.selected ? Color.accentColor.opacity(0.25)
                      : index == popup.hovered ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
                .onHover { popup.hovered = $0 ? index : (popup.hovered == index ? nil : popup.hovered) }
                .onTapGesture { popup.picked?(item) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
        .padding(.horizontal, 10)
    }
}
