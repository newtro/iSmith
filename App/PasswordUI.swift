import AppKit
import os
import Passwords
import SignInSync
import SwiftUI
import WebKit

// P4: the native side of password capture and autofill. The Passwords package's script and
// controller decide what's a login field and what may be filled where (always against the
// frame's own origin); this file shows the save bar, the autofill popover and ⌘\.
//
// Secrets: a capture's password lives only in its `PasswordCapture` while the save bar is up; the
// popover never sees a saved password (it lists `LoginSummary`s, and filling goes back to the
// store by id). Nothing here logs a username or password.

/// A submitted sign-in waiting on the save bar. Dropped when answered, dismissed or the tab closes.
@MainActor
final class PasswordOffer: ObservableObject, Identifiable {
    let id = UUID()
    let capture: PasswordCapture
    /// The username to save, editable in the bar (a two-step sign-in's guess can be wrong).
    @Published var username: String

    init(_ capture: PasswordCapture) {
        self.capture = capture
        username = capture.username
    }

    var isUpdate: Bool {
        if case .update = capture.action { return true }
        return false
    }

    /// The site as the bar names it: the frame's origin (not the tab's address), without the
    /// scheme for ordinary https sites.
    var siteName: String { PasswordOffer.name(of: capture.origin) }

    static func name(of origin: Origin) -> String {
        origin.scheme == "https" && origin.isDefaultPort ? origin.host : origin.serialized
    }
}

extension BrowserState {
    /// What the user chose when the passwords store couldn't be opened.
    enum PasswordOpenChoice: Equatable {
        case tryAgain
        case continueWithout
        /// "Start a New Passwords File…", confirmed: the key is really gone. Offered only for
        /// `keyMissing`; the old file is moved aside, never deleted.
        case startOver
    }

    /// Opens the passwords store with this build's Keychain key, as the app (`OpenMode.app`).
    /// Any failure is said out loud: an alert with "Try Again", never a silently empty store.
    /// If the Keychain can't be read or the file is busy, it's "Try Again" or "Continue Without
    /// Passwords", and nothing on disk is touched. If the key is missing but the file holds
    /// logins, a third choice starts a new file (`OpenMode.appStartOver`) after a confirmation
    /// that the old file is kept. `ask` gets the reason and whether starting over is offered.
    /// Errors carry no secrets.
    static func openPasswordStore(fileURL: URL, keyStore: KeyStore,
                                  ask: (_ why: String, _ canStartOver: Bool) -> PasswordOpenChoice = BrowserState.askToRetryPasswords)
        -> (store: PasswordStore?, problem: String?) {
        var mode = PasswordStore.OpenMode.app
        while true {
            let why: String
            var canStartOver = false
            do {
                return (try PasswordStore(fileURL: fileURL, keyStore: keyStore, mode: mode), nil)
            } catch PasswordStoreError.keychainUnavailable(let reason) {
                why = "The passwords key couldn't be read from the Keychain (\(reason)). Unlock the login Keychain or allow \(AppIdentity.displayName) to use it, then try again."
            } catch PasswordStoreError.databaseUnavailable(let reason) {
                why = "The saved passwords file couldn't be read just now (\(reason)). If another copy of \(AppIdentity.displayName) is still quitting, wait a moment and try again."
            } catch PasswordStoreError.keyMissing {
                why = "The key that unlocks your saved passwords isn't in the login Keychain, but the passwords file (\(fileURL.path)) holds logins sealed with it. If the Keychain is locked, restored from a backup or being synced, wait for it and try again."
                canStartOver = true
            } catch {
                why = "The saved passwords file couldn't be opened (\((error as? PasswordStoreError)?.description ?? String(describing: error)))."
            }
            Self.passwordsLog.error("passwords store not opened: \(why, privacy: .public)")
            switch ask(why, canStartOver) {
            case .tryAgain:
                mode = .app
            case .startOver where canStartOver:
                mode = .appStartOver
            case .startOver, .continueWithout:
                return (nil, "Saved passwords are off for this session. \(why) Nothing has been changed; quit and reopen \(AppIdentity.displayName) to try again.")
            }
        }
    }

    static let passwordsLog = Logger(subsystem: "com.scottsmith.ismith", category: "passwords")

    /// "Try Again", "Continue Without Passwords", or (for a missing key) "Start a New Passwords
    /// File…", which asks again before choosing it.
    static func askToRetryPasswords(_ why: String, canStartOver: Bool) -> PasswordOpenChoice {
        while true {
            let alert = NSAlert()
            alert.messageText = "\(AppIdentity.displayName) can't open its saved passwords"
            alert.informativeText = "\(why) Nothing has been changed."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Continue Without Passwords")
            if canStartOver { alert.addButton(withTitle: "Start a New Passwords File…") }
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .tryAgain
            case .alertThirdButtonReturn where canStartOver:
                let confirm = NSAlert()
                confirm.alertStyle = .critical
                confirm.messageText = "Start a new, empty passwords file?"
                confirm.informativeText = "The current passwords file is kept, renamed to passwords.unreadable-<time>.sqlite next to it; nothing is deleted. Its logins can only be read with the key that's missing, so they won't appear in the new file. Only do this if that key is gone for good."
                confirm.addButton(withTitle: "Start New File")
                confirm.addButton(withTitle: "Cancel")
                if confirm.runModal() == .alertFirstButtonReturn { return .startOver }
            default: return .continueWithout
            }
        }
    }

    /// What the launch found in the passwords store, said once at launch: a file moved aside,
    /// logins restored from an earlier copy set aside, and logins that don't decrypt. Every
    /// launch also logs the counts (never a secret), so "my passwords are gone" can be checked
    /// against what the file held.
    struct PasswordLaunchReport: Equatable {
        var health: PasswordStore.Health?
        var movedAside: URL?
        /// The user chose "Start a New Passwords File…" (the key was missing).
        var startedOver = false
        /// Earlier copies set aside whose logins were added back, and how many.
        var restored: [(copy: URL, count: Int, backup: URL?)] = []
        /// Earlier copies sealed with another key: nothing in them can be read.
        var unopenable: [URL] = []

        static func == (a: Self, b: Self) -> Bool {
            a.health == b.health && a.movedAside == b.movedAside && a.startedOver == b.startedOver && a.unopenable == b.unopenable
                && a.restored.map(\.copy) == b.restored.map(\.copy) && a.restored.map(\.count) == b.restored.map(\.count)
        }

        /// The alert's text, or nil when there's nothing to say.
        var message: (title: String, text: String)? {
            var parts: [String] = []
            if let movedAside {
                parts.append(startedOver
                             ? "A new passwords file was started, as you chose. The old file was kept at \(movedAside.path)."
                             : "The saved passwords file couldn't be decrypted with the key in your Keychain, so a new one was started. The old file was kept at \(movedAside.path).")
            }
            for item in restored {
                parts.append("\(item.count) saved login\(item.count == 1 ? "" : "s") from an earlier copy (\(item.copy.lastPathComponent)) were added back."
                             + (item.backup.map { " The passwords file as it was before is at \($0.path)." } ?? ""))
            }
            if let health, health.unreadable > 0 {
                parts.append("\(health.unreadable) of \(health.rows) saved login\(health.rows == 1 ? "" : "s") can't be decrypted with the key in your Keychain. They're kept in the file; nothing was deleted.")
            }
            if !unopenable.isEmpty {
                parts.append("\(unopenable.count == 1 ? "An earlier copy" : "\(unopenable.count) earlier copies") of the passwords file can't be opened with the current key and \(unopenable.count == 1 ? "was" : "were") left as \(unopenable.count == 1 ? "it was" : "they were"): \(unopenable.map(\.lastPathComponent).joined(separator: ", ")).")
            }
            guard !parts.isEmpty else { return nil }
            let title = startedOver && movedAside != nil ? "A new passwords file was started"
                : movedAside != nil || (health?.unreadable ?? 0) > 0 ? "Some saved passwords couldn't be opened" : "Saved passwords were restored"
            return (title, parts.joined(separator: "\n\n"))
        }
    }

    /// Checks the store after it opened: adds back logins from earlier copies set aside (only
    /// those that decrypt with the current key and aren't already saved; a backup is made
    /// first), counts what doesn't decrypt, and logs the counts. `reported` holds the copies
    /// already told about (copies with another key are mentioned once).
    /// Only for a store the app opened (`OpenMode.app`/`.appStartOver`): restoring is app-only.
    static func checkPasswordStore(_ store: PasswordStore, reported: inout Set<String>) -> PasswordLaunchReport {
        var report = PasswordLaunchReport(movedAside: store.movedAside, startedOver: store.openMode == .appStartOver)
        guard store.openMode.isApp else { return report }
        for copy in PasswordStore.setAsideCopies(of: store.fileURL) where copy != store.movedAside {
            do {
                // Once per copy: a login deleted after it was restored stays deleted.
                if try store.wasRecovered(copy) { continue }
                if let result = try store.recover(from: copy) {
                    if result.restored > 0 { report.restored.append((copy, result.restored, result.backup)) }
                } else if !reported.contains(copy.lastPathComponent) {
                    report.unopenable.append(copy)
                }
                reported.insert(copy.lastPathComponent)
            } catch {
                // Tried again at the next launch (and reported then if it's sealed with another key).
                passwordsLog.error("an earlier copy of the passwords file couldn't be read: \(String(describing: error), privacy: .public)")
            }
        }
        if let aside = store.movedAside { reported.insert(aside.lastPathComponent) }
        do {
            let health = try store.health()
            report.health = health
            passwordsLog.notice("passwords store opened: \(health.rows, privacy: .public) logins, \(health.unreadable, privacy: .public) unreadable, \(report.restored.reduce(0) { $0 + $1.count }, privacy: .public) restored")
        } catch {
            passwordsLog.error("passwords store couldn't be counted: \(String(describing: error), privacy: .public)")
        }
        return report
    }

    /// Copies of the passwords file already mentioned, so each is reported once.
    static let reportedCopiesKey = "passwordsReportedCopies"

    /// At launch: the report above, shown as one alert when there's something to say.
    func reportPasswordStoreAtLaunch() {
        guard let store = passwords?.store else { return }
        let known = Set(UserDefaults.standard.stringArray(forKey: Self.reportedCopiesKey) ?? [])
        var reported = known
        let report = Self.checkPasswordStore(store, reported: &reported)
        if reported != known { UserDefaults.standard.set(reported.sorted(), forKey: Self.reportedCopiesKey) }
        passwordsLaunchReport = report
        guard let message = report.message else { return }
        let alert = NSAlert()
        alert.messageText = message.title
        alert.informativeText = message.text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Passwords")
        if alert.runModal() == .alertSecondButtonReturn { openPasswords?() }
    }

    // MARK: Save bar

    /// The autofill controller reported a new login or a changed password: show the save bar on
    /// the tab whose page submitted it.
    func offerToSave(_ capture: PasswordCapture) {
        guard let webView = capture.webView, let (_, _, tab) = owner(of: webView), !tab.agentControlled else { return }
        tab.passwordOffer = PasswordOffer(capture)
    }

    func savePassword(_ offer: PasswordOffer, in tab: Tab) {
        guard let passwords else { return }
        do {
            try passwords.save(offer.capture, username: offer.username.trimmingCharacters(in: .whitespacesAndNewlines))
            if tab.passwordOffer === offer { tab.passwordOffer = nil }
        } catch {
            showPasswordError("The password couldn't be saved", error)
        }
    }

    func neverSavePassword(_ offer: PasswordOffer, in tab: Tab) {
        guard let passwords else { return }
        do {
            try passwords.neverSave(offer.capture)
            if tab.passwordOffer === offer { tab.passwordOffer = nil }
        } catch {
            showPasswordError("The setting couldn't be saved", error)
        }
    }

    func dismissPasswordOffer(_ offer: PasswordOffer, in tab: Tab) {
        if tab.passwordOffer === offer { tab.passwordOffer = nil }
    }

    func showPasswordError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = (error as? PasswordStoreError)?.description ?? error.localizedDescription
        alert.runModal()
    }

    // MARK: Agent tabs

    /// A tab an agent drives (after v1: the agent panel and MCP server) gets no autofill and no
    /// capture: `PasswordAutofill` ignores its messages and refuses to fill it. The setting
    /// follows the tab to every web view it gets (rebuilt, restored, its popups).
    func setAgentControlled(_ on: Bool, for tab: Tab) {
        tab.agentControlled = on
        if on { tab.passwordOffer = nil }
        if let webView = tab.webView { passwords?.setDisabled(on, for: webView) }
        if on, passwordUI.isShowing(for: tab.webView) { passwordUI.close() }
    }

    /// Called for every new web view of a tab.
    func applyAgentControl(_ tab: Tab, to webView: WKWebView) {
        if tab.agentControlled { passwords?.setDisabled(true, for: webView) }
    }
}

// MARK: - Autofill popover

/// What the popover's keyboard handling needs of the list it shows (logins or codes).
@MainActor
protocol PopoverList: AnyObject {
    var highlighted: Int? { get }
    /// False for `AutofillPopoverModel.inputDelay` after the popover appeared.
    var acceptsInput: Bool { get }
    func move(_ step: Int)
    func pick(_ index: Int)
}

@MainActor
final class AutofillPopoverModel: ObservableObject, PopoverList {
    struct Row: Identifiable {
        enum Kind {
            case login(LoginSummary)
            /// "Use Strong Password", with the password it would fill.
            case generated(String)
        }

        let id: String
        let kind: Kind

        var loginID: UUID? {
            if case .login(let summary) = kind { return summary.id }
            return nil
        }
    }

    /// Clicks and Return are ignored this long after the popover appears, so a page that moves a
    /// field under the pointer can't turn the user's next click or key press into a fill.
    static let inputDelay: TimeInterval = 0.5

    let focus: LoginFieldFocus
    let rows: [Row]
    /// The frame is from another site than the page: say which site the login is for.
    let crossSiteHost: String?
    @Published var highlighted: Int?
    @Published var notice: String?
    let shownAt: Date
    var choose: (Int) -> Void = { _ in }
    var manage: () -> Void = {}

    init(focus: LoginFieldFocus, rows: [Row], shownAt: Date = Date()) {
        self.focus = focus
        self.rows = rows
        self.shownAt = shownAt
        crossSiteHost = focus.frame.isCrossSite ? focus.frame.origin.host : nil
        highlighted = focus.suggestedLoginID.flatMap { id in rows.firstIndex { $0.loginID == id } }
    }

    var acceptsInput: Bool { Date().timeIntervalSince(shownAt) >= Self.inputDelay }

    func pick(_ index: Int) { choose(index) }

    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        if let current = highlighted {
            highlighted = min(max(current + step, 0), rows.count - 1)
        } else {
            highlighted = step > 0 ? 0 : rows.count - 1
        }
    }

    /// The rows for a focused field: its matching logins (exact first, as the store orders them)
    /// and, for a new-password field, a generated password.
    static func rows(for focus: LoginFieldFocus, generate: (PasswordRequirements) -> String = PasswordGenerator.generate) -> [Row] {
        var rows = focus.logins.map { Row(id: $0.id.uuidString, kind: .login($0)) }
        if focus.offersGeneratedPassword {
            rows.append(Row(id: "generated", kind: .generated(generate(focus.requirements))))
        }
        return rows
    }
}

struct AutofillPopoverView: View {
    @ObservedObject var model: AutofillPopoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let notice = model.notice {
                Label(notice, systemImage: "key.fill")
                    .font(.system(size: 12.5))
                    .padding(10)
            } else {
                if let host = model.crossSiteHost {
                    (Text("Fill your login for ") + Text(host).bold() + Text(" in a frame on this page?"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
                }
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    Button { model.choose(index) } label: { label(for: row) }
                        .buttonStyle(.plain)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(model.highlighted == index ? Color.accentColor.opacity(0.22) : Color.clear))
                        .onHover { inside in if inside { model.highlighted = index } }
                }
                Divider().padding(.vertical, 2)
                Button { model.manage() } label: {
                    Text("Manage Passwords…").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 300)
    }

    @ViewBuilder
    private func label(for row: AutofillPopoverModel.Row) -> some View {
        HStack(spacing: 8) {
            switch row.kind {
            case .login(let login):
                Image(systemName: "key.fill").foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(login.username.isEmpty ? "(no username)" : login.username)
                        .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    if login.matchKind == .sameSite {
                        Text("from \(PasswordOffer.name(of: login.origin))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            case .generated(let password):
                Image(systemName: "key.viewfinder").foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use Strong Password").font(.system(size: 13))
                    Text(password).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// Shows the autofill popover for focused login fields, handles ⌘\, and forwards captures to
/// the save bar. One for the app (passwords are global).
@MainActor
final class PasswordUI: NSObject, PasswordAutofillDelegate, NSPopoverDelegate {
    weak var browser: BrowserState?
    private(set) var popover: NSPopover?
    private(set) var model: AutofillPopoverModel?
    /// The one-time-code popover's model, while that one is up.
    private(set) var codeModel: CodePopoverModel?
    /// The list the keys go to (`model` or `codeModel`).
    private weak var list: PopoverList?
    /// Codes texted to the phone, offered in one-time-code fields.
    let codeFill = CodeFill()
    private weak var anchor: WKWebView?
    /// An empty view over the field, the popover's positioning view.
    private var anchorView: NSView?
    private var monitor: Any?
    /// Opens the Passwords window ("Manage Passwords…").
    var openManager: (() -> Void)?

    // MARK: Delegate

    func passwordAutofill(_ autofill: PasswordAutofill, loginFieldFocused focus: LoginFieldFocus) {
        // Focus moved from a code field to a login field: its code popover goes.
        if let webView = focus.frame.webView { codeFill.loginFocused(in: webView) }
        // A page calling focus() by itself never opens the popover; ⌘\ can, on the user's request.
        guard focus.isUserInitiated, let webView = focus.frame.webView else { return }
        if let model, model.focus.fieldID == focus.fieldID, model.focus.frame.documentID == focus.frame.documentID,
           anchor === webView, popover?.isShown == true { return }
        show(focus, in: webView)
    }

    func passwordAutofill(_ autofill: PasswordAutofill, captured capture: PasswordCapture) {
        browser?.offerToSave(capture)
    }

    func passwordAutofill(_ autofill: PasswordAutofill, codeFieldFocused focus: CodeFieldFocus) {
        codeFill.ui = self
        codeFill.focused(focus)
    }

    func passwordAutofill(_ autofill: PasswordAutofill, codeFieldBlurred fieldID: String, in frame: PasswordFrame) {
        codeFill.blurred(fieldID, documentID: frame.documentID)
    }

    // MARK: Popover

    func isShowing(for webView: WKWebView?) -> Bool {
        guard let webView, popover?.isShown == true else { return false }
        return anchor === webView
    }

    /// Shows the logins for a focused field under it (or at the pointer, for a field in an
    /// iframe). Nothing when there's nothing to offer.
    func show(_ focus: LoginFieldFocus, in webView: WKWebView) {
        close()
        guard webView.window != nil, browser?.passwords?.isDisabled(for: webView) == false else { return }
        let rows = AutofillPopoverModel.rows(for: focus)
        guard !rows.isEmpty else { return }
        let model = AutofillPopoverModel(focus: focus, rows: rows)
        model.choose = { [weak self] index in self?.choose(index) }
        model.manage = { [weak self] in
            self?.close()
            self?.openManager?()
        }
        present(model, in: webView, at: anchorRect(for: focus, in: webView))
    }

    private func present(_ model: AutofillPopoverModel, in webView: WKWebView, at rect: NSRect) {
        present(NSHostingController(rootView: AutofillPopoverView(model: model)), list: model, in: webView, at: rect)
        self.model = model
    }

    /// Shows the code popover for a focused one-time-code field.
    func presentCodes(_ model: CodePopoverModel, in webView: WKWebView) {
        // Never at the pointer: a code popover that opens by itself mustn't land under it.
        present(NSHostingController(rootView: CodePopoverView(model: model)), list: model, in: webView,
                at: anchorRect(rectInWebView: model.focus.rectInWebView, in: webView, atPointer: false))
        codeModel = model
    }

    func isShowingCodes(fieldID: String, documentID: String) -> Bool {
        guard popover?.isShown == true, let codeModel else { return false }
        return codeModel.focus.fieldID == fieldID && codeModel.focus.frame.documentID == documentID
    }

    private func present<Content: View>(_ content: NSHostingController<Content>, list: PopoverList, in webView: WKWebView, at rect: NSRect) {
        close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // Sized before it's shown: a popover that shrinks after appearing keeps its bottom edge
        // and so drifts away from the field.
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        popover.contentSize = content.view.fittingSize
        self.popover = popover
        self.list = list
        anchor = webView
        // Positioned against a plain view over the field, removed when the popover closes.
        let host = webView.superview ?? webView
        let marker = NSView(frame: host.convert(rect, from: webView))
        host.addSubview(marker)
        anchorView = marker
        popover.show(relativeTo: marker.bounds, of: marker, preferredEdge: marker.isFlipped ? .maxY : .minY)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    /// The field's box in the web view's coordinates, or a point at the mouse for an iframe
    /// (whose offset in the page isn't known), clamped to the web view.
    func anchorRect(for focus: LoginFieldFocus, in webView: WKWebView) -> NSRect {
        anchorRect(rectInWebView: focus.rectInWebView, in: webView)
    }

    func anchorRect(rectInWebView: CGRect?, in webView: WKWebView, atPointer: Bool = true) -> NSRect {
        let bounds = webView.bounds
        if let r = rectInWebView, r.width > 0, r.height > 0 {
            // rectInWebView is top-left based.
            var rect = webView.isFlipped ? r : NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
            rect = rect.intersection(bounds)
            if !rect.isNull, !rect.isEmpty { return rect }
        }
        if atPointer, let window = webView.window {
            let point = webView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { return NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2) }
        }
        return NSRect(x: bounds.midX - 1, y: webView.isFlipped ? bounds.minY : bounds.maxY - 2, width: 2, height: 2)
    }

    /// Keys while the popover is up: ↑/↓ move, Return fills the highlighted row, Escape closes.
    /// Any other key goes to the page and closes the popover; so does scrolling.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let popover, popover.isShown, let model = list, let webView = anchor, event.window === webView.window else { return event }
        if event.type == .scrollWheel {
            close()
            return event
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // ⌘\ over the code popover fills the highlighted code (the menu would see a closed one).
        if Int(event.keyCode) == 42, flags == .command, codeModel != nil {
            model.pick(model.highlighted ?? 0)
            return nil
        }
        switch Int(event.keyCode) {
        case 125 where flags.isEmpty: // ↓
            model.move(1)
            return nil
        case 126 where flags.isEmpty: // ↑
            model.move(-1)
            return nil
        case 36, 76: // Return, Enter
            if flags.isEmpty, let index = model.highlighted {
                if model.acceptsInput { model.pick(index) }
                return nil
            }
            close()
            return event
        case 53: // Escape
            close()
            return nil
        default:
            close()
            return event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let open = popover
        popover = nil
        model = nil
        codeModel = nil
        list = nil
        anchor = nil
        open?.close()
        anchorView?.removeFromSuperview()
        anchorView = nil
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === popover { close() }
    }

    /// The page navigated, or its web view left the window (tab switch, closed): close.
    func webViewChanged(_ webView: WKWebView) {
        if anchor === webView { close() }
        codeFill.webViewChanged(webView)
    }

    // MARK: Filling (only ever from the user's click, Return or ⌘\)

    private func choose(_ index: Int) {
        guard let model, model.acceptsInput, model.rows.indices.contains(index),
              let webView = anchor, let autofill = browser?.passwords else { return }
        let focus = model.focus
        let row = model.rows[index]
        close()
        Task { @MainActor in
            do {
                switch row.kind {
                case .login(let login):
                    // A same-site login is filled only from this click, with its host shown in the row.
                    let result = try await autofill.fill(login.id, into: focus, allowSameSite: login.matchKind == .sameSite)
                    self.filled(result, focus: focus, in: webView)
                case .generated(let password):
                    try await autofill.fillGeneratedPassword(password, into: focus)
                    self.refocus(webView)
                }
            } catch {
                self.fillFailed(error)
            }
        }
    }

    /// ⌘\: fills the best exact-origin login into the field the user last clicked, or opens the
    /// popover when there's a choice to make.
    func fillShortcut(in webView: WKWebView?) {
        // A one-time-code field focused after any login field: fill a code there.
        // Not when the page moved focus to a code field after the user clicked a login field: the
        // ⌘\ is for that login.
        if let webView, let autofill = browser?.passwords, let code = autofill.lastCodeFocus(in: webView),
           code.receivedAt >= autofill.lastFocus(in: webView)?.receivedAt ?? .distantPast,
           code.isUserInitiated || autofill.lastFocus(in: webView)?.isUserInitiated != true {
            codeFill.ui = self
            codeFill.shortcut(code, in: webView)
            return
        }
        guard let webView, let autofill = browser?.passwords, let focus = autofill.lastFocus(in: webView) else {
            NSSound.beep()
            return
        }
        if let best = autofill.bestAutomaticLogin(for: focus) {
            close()
            Task { @MainActor in
                do {
                    let result = try await autofill.fill(best.id, into: focus)
                    self.filled(result, focus: focus, in: webView)
                } catch {
                    self.fillFailed(error)
                }
            }
        } else if focus.frame.webView === webView, !focus.logins.isEmpty || focus.offersGeneratedPassword {
            show(focus, in: webView)
        } else {
            NSSound.beep()
        }
    }

    private func filled(_ result: FillResult, focus: LoginFieldFocus, in webView: WKWebView) {
        refocus(webView)
        guard result == .usernameOnly, webView.window != nil else { return }
        // The password field is covered (a cookie banner): say how to finish.
        let notice = AutofillPopoverModel(focus: focus, rows: [])
        notice.notice = "Filled the username. Click the password field to finish."
        present(notice, in: webView, at: anchorRect(for: focus, in: webView))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak notice] in
            if let notice, self?.model === notice { self?.close() }
        }
    }

    func refocus(_ webView: WKWebView) {
        if let window = webView.window, window.firstResponder !== webView { window.makeFirstResponder(webView) }
    }

    private func fillFailed(_ error: Error) {
        // Refusals (stale page, field gone, too soon) carry no secrets; nothing is logged.
        NSSound.beep()
    }
}

// MARK: - Save bar

/// "Save password for [user] on example.com?" above the page of the tab that submitted it.
struct PasswordSaveBar: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var tab: Tab

    var body: some View {
        if let offer = tab.passwordOffer {
            OfferBar(offer: offer, tab: tab)
        }
    }

    private struct OfferBar: View {
        @EnvironmentObject private var browser: BrowserState
        @ObservedObject var offer: PasswordOffer
        let tab: Tab

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(.secondary)
                Text(offer.isUpdate ? "Update password for" : "Save password for")
                TextField("username", text: $offer.username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                    .help("The username to save with this password")
                    .accessibilityLabel("Username")
                (Text("on ") + Text(offer.siteName).bold() + Text("?"))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !offer.isUpdate {
                    Button("Never for This Site") { browser.neverSavePassword(offer, in: tab) }
                }
                Button("Not Now") { browser.dismissPasswordOffer(offer, in: tab) }
                Button(offer.isUpdate ? "Update" : "Save") { browser.savePassword(offer, in: tab) }
                    .buttonStyle(.borderedProminent)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            .padding(.horizontal, 8).padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Save password")
        }
    }
}
