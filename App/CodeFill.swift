import AppKit
import CodesXPC
import os
import Passwords
import ServiceManagement
import SwiftUI
import WebKit

// Verification codes from the phone (2FASync, through iSmith Agent) offered in one-time-code
// fields. The Passwords package's script finds the fields and types a code in; this file asks
// the agent for codes, applies the binding (`OneTimeCodeBinding`) and shows the popover.
//
// A code reaches the page only when the user picks it (a click, Return or ⌘\): until then it
// lives here and in the agent, never in any of the page's worlds. Nothing here logs a code.

/// Where codes come from: iSmith Agent, or a stand-in in tests.
@MainActor
protocol CodeSource: AnyObject {
    /// False while codes are off or iSmith Agent isn't running: nothing is asked of it then.
    var isAvailable: Bool { get }
    /// The codes the agent offers for a page with this top-level host (already filtered by its
    /// WebOTP binding and the "Offer codes in iSmith" setting). Empty on any error.
    func offers(forPageHost host: String) async -> [CodeOffer]
    func markUsed(_ id: String) async
}

/// iSmith Agent over XPC (`CodesClient`).
@MainActor
final class AgentCodeSource: CodeSource {
    private var status: (value: SMAppService.Status, at: Date)?

    var isAvailable: Bool {
        let codes = CodesController.shared
        guard codes.enabled else { return false }
        // SMAppService's status is a call into launchd: asked at most every 10 seconds.
        if let status, Date().timeIntervalSince(status.at) < 10 { return status.value == .enabled }
        let value = codes.service.status
        status = (value, Date())
        return value == .enabled
    }

    func offers(forPageHost host: String) async -> [CodeOffer] {
        // Not answering (not paired, stopped, an old agent): no codes, and no error to show.
        (try? await CodesClient.shared.recentCodes(for: host)) ?? []
    }

    func markUsed(_ id: String) async {
        try? await CodesClient.shared.markUsed(id)
    }
}

#if DEBUG
/// Debug builds only: codes from a JSON file instead of the agent, for trying the popover in
/// "iSmith Dev" without registering its agent. Launch with `ISMITH_TEST_CODES_FILE=<path>`; the
/// file holds a JSON array of `CodeOffer` (`receivedAt` in Unix ms) and is read on every poll, so
/// adding a code to it while a code field is focused is a code arriving. It applies the agent's
/// rule: a bound code for its domain or a subdomain, unbound codes for 2 minutes.
@MainActor
final class FileCodeSource: CodeSource {
    let url: URL
    private var used: Set<String> = []

    init(url: URL) { self.url = url }

    var isAvailable: Bool { true }

    func offers(forPageHost host: String) async -> [CodeOffer] {
        guard let data = try? Data(contentsOf: url), let all = CodesJSON.decode([CodeOffer].self, from: data) else { return [] }
        return all.filter { offer in
            guard !used.contains(offer.id) else { return false }
            if let domain = offer.domain { return OneTimeCodeBinding.hostMatches(host, domain: domain) }
            return Date().timeIntervalSince(offer.receivedAt) < 120
        }
    }

    func markUsed(_ id: String) async { used.insert(id) }
}
#endif

// MARK: - Popover

@MainActor
final class CodePopoverModel: ObservableObject, PopoverList {
    let focus: CodeFieldFocus
    /// Newest first.
    let offers: [CodeOffer]
    /// The field is in a frame from another site than the page: say which.
    let crossSiteHost: String?
    @Published var highlighted: Int?
    let shownAt: Date
    /// Clicks and Return are ignored this long: the login popover's 0.5 s when it opens on the
    /// user's own click or ⌘\, a full second when it opens by itself (a code arrived), which the
    /// user didn't see coming.
    let inputDelay: TimeInterval
    var choose: (Int) -> Void = { _ in }

    static let unexpectedInputDelay: TimeInterval = 1

    init(focus: CodeFieldFocus, offers: [CodeOffer], preselect: Bool, inputDelay: TimeInterval = AutofillPopoverModel.inputDelay,
         shownAt: Date = Date()) {
        self.focus = focus
        self.offers = offers
        self.shownAt = shownAt
        self.inputDelay = inputDelay
        crossSiteHost = focus.frame.isCrossSite ? focus.frame.origin.host : nil
        highlighted = preselect && !offers.isEmpty ? 0 : nil
    }

    var acceptsInput: Bool { Date().timeIntervalSince(shownAt) >= inputDelay }

    func pick(_ index: Int) { choose(index) }

    func move(_ step: Int) {
        guard !offers.isEmpty else { return }
        if let current = highlighted {
            highlighted = min(max(current + step, 0), offers.count - 1)
        } else {
            highlighted = step > 0 ? 0 : offers.count - 1
        }
    }

    /// "from Chase", plus "· for chase.com" for a code bound to that domain.
    static func source(of offer: CodeOffer) -> (sender: String, domain: String?) {
        (offer.sender.isEmpty ? "your phone" : offer.sender, offer.domain)
    }
}

/// "Fill 123456 from Chase · for chase.com", styled like the login popover.
struct CodePopoverView: View {
    @ObservedObject var model: CodePopoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let host = model.crossSiteHost {
                (Text("Fill a code into ") + Text(host).bold() + Text(", a frame on this page?"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
            }
            ForEach(Array(model.offers.enumerated()), id: \.element.id) { index, offer in
                Button { model.choose(index) } label: { label(for: offer) }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(model.highlighted == index ? Color.accentColor.opacity(0.22) : Color.clear))
                    .onHover { inside in if inside { model.highlighted = index } }
                    .accessibilityLabel("Fill \(offer.code) from \(CodePopoverModel.source(of: offer).sender)")
            }
        }
        .padding(6)
        .frame(width: 300)
    }

    private func label(for offer: CodeOffer) -> some View {
        let source = CodePopoverModel.source(of: offer)
        return HStack(spacing: 8) {
            Image(systemName: "message.fill").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                (Text("Fill ") + Text(offer.code).font(.system(size: 13, design: .monospaced)).bold() + Text(" from \(source.sender)"))
                    .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                if let domain = source.domain {
                    Text("· for \(domain)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let host = model.focus.pageHost {
                    // Not bound to a site: say which page it goes into.
                    Text("· into \(host)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

// MARK: - Offering codes

/// Watches the focused one-time-code field: asks the agent for codes when it's focused and every
/// second after (for 2 minutes, while it stays focused and its tab is in front), so a code that
/// arrives while the page is open shows up; shows the popover when there's a code it hasn't shown
/// yet; fills the one the user picks. Agent-driven tabs and disabled web views get nothing.
@MainActor
final class CodeFill {
    weak var ui: PasswordUI?
    lazy var source: CodeSource = Self.defaultSource()
    var pollInterval: TimeInterval = 1
    var pollDuration: TimeInterval = 120

    private final class Session {
        var focus: CodeFieldFocus
        weak var webView: WKWebView?
        var deadline: Date
        /// Codes already offered for this field: shown again only on the user's click.
        var shown: Set<String> = []
        var task: Task<Void, Never>?
        /// The user clicked or tabbed into the field (not just the page focusing it). Until then
        /// only codes bound to this site are offered: a page that focuses a field by itself
        /// can't put another site's unbound code under the pointer.
        var userFocused: Bool
        /// The next check follows the user's click: it may open with the code preselected and
        /// the short input delay.
        var answersClick: Bool

        init(focus: CodeFieldFocus, webView: WKWebView, deadline: Date) {
            self.focus = focus
            self.webView = webView
            self.deadline = deadline
            userFocused = focus.isUserInitiated
            answersClick = focus.isUserInitiated
        }
    }

    private var session: Session?
    private static let log = Logger(subsystem: "com.scottsmith.ismith", category: "codes")

    static func defaultSource() -> CodeSource {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["ISMITH_TEST_CODES_FILE"], !path.isEmpty {
            return FileCodeSource(url: URL(fileURLWithPath: path))
        }
        #endif
        return AgentCodeSource()
    }

    /// Whether the session is watching this field now.
    var isWatching: Bool { session?.task != nil }

    // MARK: Events

    func focused(_ focus: CodeFieldFocus) {
        // A tab in the background (or an agent's) can't end the front tab's watch.
        guard let webView = focus.frame.webView, mayOffer(in: webView) else { return }
        if let session, session.webView === webView, session.focus.fieldID == focus.fieldID,
           session.focus.frame.documentID == focus.frame.documentID {
            // The same field again. Only the user's click extends the watch, and asks again even
            // for codes already offered; the page focusing it again changes nothing.
            guard focus.isUserInitiated else { return }
            session.focus = focus
            session.userFocused = true
            session.deadline = Date().addingTimeInterval(pollDuration)
            if ui?.isShowingCodes(fieldID: focus.fieldID, documentID: focus.frame.documentID) != true {
                session.shown = []
                session.answersClick = true
            }
            watch(session)
            return
        }
        stop()
        if ui?.codeModel != nil { ui?.close() } // another field's codes
        guard mayOffer(in: webView), focus.pageHost != nil, source.isAvailable else { return }
        let session = Session(focus: focus, webView: webView, deadline: Date().addingTimeInterval(pollDuration))
        self.session = session
        watch(session)
    }

    func blurred(_ fieldID: String, documentID: String) {
        guard let session, session.focus.fieldID == fieldID, session.focus.frame.documentID == documentID else { return }
        // Focus going to the popover itself (a click on a code) isn't leaving: the script doesn't
        // report that. Anything else ends the watch; an open popover stays until it's answered.
        session.task?.cancel()
        session.task = nil
        if ui?.isShowingCodes(fieldID: fieldID, documentID: documentID) != true { self.session = nil }
    }

    /// The page navigated, or its web view left the window.
    func webViewChanged(_ webView: WKWebView) {
        if session?.webView === webView || session?.webView == nil { stop() }
    }

    func stop() {
        session?.task?.cancel()
        session = nil
    }

    /// A login field was focused in this web view: its code field isn't focused any more.
    func loginFocused(in webView: WKWebView) {
        guard session?.webView === webView else { return }
        if ui?.codeModel != nil { ui?.close() }
        stop()
    }

    // MARK: Watching

    private func watch(_ session: Session) {
        session.task?.cancel()
        session.task = Task { @MainActor [weak self, weak session] in
            while let self, let session, !Task.isCancelled, Date() < session.deadline {
                await self.check(session)
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
            if let session, !Task.isCancelled { session.task = nil }
        }
    }

    /// The tab may be offered codes: in front, not driven by an agent, autofill not off for it.
    private func mayOffer(in webView: WKWebView) -> Bool {
        guard let browser = ui?.browser, webView.window != nil, browser.passwords?.isDisabled(for: webView) == false,
              let (_, _, tab) = browser.owner(of: webView), !tab.agentControlled, browser.isVisible(tab) else { return false }
        return true
    }

    /// The codes for a field: what the agent offers for the top-level host, kept only where the
    /// binding allows this frame, that fit the field; newest first.
    private func offers(for focus: CodeFieldFocus, boundOnly: Bool = false) async -> [CodeOffer] {
        guard let host = focus.pageHost, source.isAvailable else { return [] }
        return await source.offers(forPageHost: host)
            .filter { (!boundOnly || $0.domain != nil) && OneTimeCodeBinding.mayOffer(domain: $0.domain, in: focus) && focus.accepts($0.code) }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    private func check(_ session: Session) async {
        guard let webView = session.webView, mayOffer(in: webView) else { return stop() }
        let offers = await offers(for: session.focus, boundOnly: !session.userFocused)
        // Still the same field after the call?
        guard self.session === session, !Task.isCancelled, mayOffer(in: webView) else { return }
        let answersClick = session.answersClick
        session.answersClick = false
        let ids = Set(offers.map(\.id))
        guard !ids.isEmpty, !ids.isSubset(of: session.shown) else { return }
        session.shown.formUnion(ids)
        // Opened right after the user's click: preselected, as the login popover. Opened later
        // by itself (a code arrived): nothing preselected, so the Return that submits a code
        // typed by hand still goes to the page, and a longer delay before clicks count.
        show(offers, for: session.focus, in: webView, preselect: answersClick,
             inputDelay: answersClick ? AutofillPopoverModel.inputDelay : CodePopoverModel.unexpectedInputDelay)
    }

    private func show(_ offers: [CodeOffer], for focus: CodeFieldFocus, in webView: WKWebView, preselect: Bool,
                      inputDelay: TimeInterval = AutofillPopoverModel.inputDelay) {
        guard let ui else { return }
        let model = CodePopoverModel(focus: focus, offers: offers, preselect: preselect, inputDelay: inputDelay)
        model.choose = { [weak self, weak model, weak webView] index in
            guard let self, let model, let webView, model.acceptsInput, model.offers.indices.contains(index) else { return }
            self.fill(model.offers[index], into: model.focus, in: webView)
        }
        ui.presentCodes(model, in: webView)
    }

    // MARK: Filling (only from the user's click, Return or ⌘\)

    private func fill(_ offer: CodeOffer, into focus: CodeFieldFocus, in webView: WKWebView) {
        ui?.close()
        guard let autofill = ui?.browser?.passwords else { return NSSound.beep() }
        Task { @MainActor in
            // Still offered (not used, not expired, still allowed here)?
            guard mayOffer(in: webView), await offers(for: focus).contains(where: { $0.id == offer.id }) else {
                return NSSound.beep()
            }
            do {
                try await autofill.fillCode(offer.code, into: focus)
            } catch {
                // Refusals (field gone, page replaced, code doesn't fit) carry no secrets.
                Self.log.notice("a code wasn't filled: \(String(describing: error), privacy: .public)")
                return NSSound.beep()
            }
            await source.markUsed(offer.id)
            if session?.focus.fieldID == focus.fieldID { stop() }
            ui?.refocus(webView)
        }
    }

    /// ⌘\ in a code field: the open popover's highlighted (or first) code, else the newest code
    /// for the field, filled directly when the user clicked or tabbed into the field outside a
    /// cross-site frame. Otherwise (the page focused the field itself, or it's in another site's
    /// frame) the popover opens, so the user sees what goes where before anything is filled.
    func shortcut(_ focus: CodeFieldFocus, in webView: WKWebView) {
        if let ui, ui.isShowingCodes(fieldID: focus.fieldID, documentID: focus.frame.documentID), let model = ui.codeModel {
            let index = model.highlighted ?? 0
            if model.offers.indices.contains(index) { fill(model.offers[index], into: model.focus, in: webView) }
            return
        }
        guard mayOffer(in: webView), source.isAvailable else { return NSSound.beep() }
        Task { @MainActor in
            let offers = await offers(for: focus)
            guard let newest = offers.first, mayOffer(in: webView) else { return NSSound.beep() }
            let userFocused = focus.isUserInitiated || (session?.focus.fieldID == focus.fieldID && session?.userFocused == true)
            if focus.frame.isCrossSite || !userFocused {
                show(offers, for: focus, in: webView, preselect: true)
            } else {
                fill(newest, into: focus, in: webView)
            }
        }
    }
}
