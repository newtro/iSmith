import CryptoKit
import Foundation
import os
import WebKit

/// The kinds of form the capture script recognizes.
public enum FormKind: String, Sendable {
    /// A username (optional) and one password.
    case login
    /// A username (optional) and a new password, maybe with a confirmation.
    case signup
    /// The current password and a new one.
    case change
    /// The first step of a two-step sign-in: a username and no password field yet.
    case usernameOnly
}

/// The role of a focused field.
public enum FieldKind: String, Sendable {
    case username
    /// The current password of a login or change-password form.
    case password
    /// A new password (or its confirmation): offer the generator.
    case newPassword
}

/// A frame of a web view that holds a login form, as WebKit identified it to the handler.
public struct PasswordFrame {
    public let frameInfo: WKFrameInfo
    public private(set) weak var webView: WKWebView?
    /// The frame's own origin (`WKFrameInfo.securityOrigin`), which logins are matched against.
    public let origin: Origin
    /// Random per document. A fill for a document that has since been replaced does nothing.
    public let documentID: String
    public let isMainFrame: Bool
    /// The origin of the tab's page, when it's an http(s) page.
    public let topOrigin: Origin?

    /// The frame is an iframe from another site than the tab's page. The popover should say
    /// which site it fills ("Fill login for accounts.example.com in this frame?").
    public var isCrossSite: Bool {
        guard !isMainFrame else { return false }
        guard let topOrigin else { return true }
        return Origin.match(saved: topOrigin, page: origin) == nil
    }
}

/// A login field the user focused or clicked.
public struct LoginFieldFocus {
    public let frame: PasswordFrame
    /// Identifies the field inside the frame's capture script; only meaningful to `fill`.
    public let fieldID: String
    public let field: FieldKind
    public let form: FormKind
    /// The field's box in CSS pixels, relative to its frame's viewport.
    public let rect: CGRect
    /// The field's box in the web view's coordinates (flipped, origin top-left), for anchoring a
    /// popover. Nil for fields in iframes, whose offset in the page isn't known: anchor those at
    /// the mouse location or the web view's top instead.
    public let rectInWebView: CGRect?
    /// Logins that may be filled here, matched against the frame's origin: exact first.
    public let logins: [LoginSummary]
    /// The login to preselect: the one the user filled or typed on the first step of a two-step
    /// sign-in in this tab.
    public let suggestedLoginID: UUID?
    public let requirements: PasswordRequirements
    /// The user clicked the field or tabbed into it. A page calling `focus()` on a field also
    /// reports a focus, with this false: don't open the popover by itself for those, and ⌘\
    /// (`bestAutomaticLogin`) won't fill them.
    public let isUserInitiated: Bool
    /// When the focus was reported. `fill` refuses until `minimumFocusAge` has passed, so a page
    /// focusing a field just as the user clicks can't turn that click into a fill.
    public let receivedAt: Date

    /// Whether to offer "Use strong password" (signup and change-password forms).
    public var offersGeneratedPassword: Bool { field == .newPassword }
}

/// A submitted sign-in worth asking about: a new login or a changed password.
public struct PasswordCapture: Identifiable, CustomStringConvertible, CustomReflectable {
    public let id = UUID()
    /// The origin of the frame the form was in.
    public let origin: Origin
    public let username: String
    public let password: String
    /// `.save` or `.update`; unchanged and never-save submissions aren't reported.
    public let action: SaveAction
    public let form: FormKind
    public private(set) weak var webView: WKWebView?

    public var description: String { "PasswordCapture(\(origin), \(action), username: <redacted>, password: <redacted>)" }
    public var customMirror: Mirror {
        Mirror(self, children: ["origin": origin, "action": action, "username": "<redacted>", "password": "<redacted>"])
    }
}

/// What a fill wrote.
public enum FillResult: Equatable, Sendable {
    /// The username (if the form has one) and the password, or the username of a first step.
    case filled
    /// Only the username: the form's password field couldn't be seen (covered by a banner, say).
    /// The user can click the password field and fill again.
    case usernameOnly
}

public enum AutofillError: Error, Equatable {
    /// The web view or frame is gone.
    case frameGone
    case loginNotFound
    /// The login's origin doesn't match the frame's under the matching rules.
    case originMismatch
    /// The frame navigated since the field was focused.
    case stale
    /// The frame's document is no longer at the origin it was focused at.
    case frameOriginChanged
    /// The login is a same-site match (another host) and the fill didn't allow that.
    case sameSiteNotAllowed
    /// The fill came sooner than `minimumFocusAge` after the focus.
    case tooSoon
    /// Autofill is turned off for this web view (`setDisabled(_:for:)`).
    case disabled
    /// The field, or the form's password field, is gone or hidden.
    case noField
    case scriptFailed(String)
}

/// Events from the capture script. All are delivered on the main actor.
@MainActor
public protocol PasswordAutofillDelegate: AnyObject {
    /// A username or password field was focused or clicked: show the autofill popover for
    /// `focus.logins` (and "Use strong password" when `focus.offersGeneratedPassword`).
    func passwordAutofill(_ autofill: PasswordAutofill, loginFieldFocused focus: LoginFieldFocus)
    /// A form was submitted with a new login or a changed password: show the save bar.
    func passwordAutofill(_ autofill: PasswordAutofill, captured capture: PasswordCapture)
    /// A frame has login forms (sent when the set of kinds changes).
    func passwordAutofill(_ autofill: PasswordAutofill, foundForms kinds: Set<FormKind>, in frame: PasswordFrame)
}

public extension PasswordAutofillDelegate {
    func passwordAutofill(_ autofill: PasswordAutofill, loginFieldFocused focus: LoginFieldFocus) {}
    func passwordAutofill(_ autofill: PasswordAutofill, captured capture: PasswordCapture) {}
    func passwordAutofill(_ autofill: PasswordAutofill, foundForms kinds: Set<FormKind>, in frame: PasswordFrame) {}
}

/// Password capture and autofill for web views: attach it to each `WKWebViewConfiguration`
/// before the web view is made, set a delegate, and call `fill` when the user picks a login.
///
/// The script and its message handler live in a named content world (`contentWorld`), never the
/// page's: page scripts can't see the handler, post to it, or call the fill function. Logins are
/// matched against the origin WebKit reports for the sending frame (`WKFrameInfo.securityOrigin`),
/// never the tab's URL or anything the page says. Nothing is filled except by `fill` and
/// `fillGeneratedPassword`, which the app calls in response to the user.
@MainActor
public final class PasswordAutofill {
    public nonisolated static let defaultWorldName = "iSmith.passwords"
    nonisolated static let handlerName = "ismithPasswords"
    nonisolated static let fillFunctionName = "__ismithPasswordsFill"

    public let store: PasswordStore
    public let contentWorld: WKContentWorld
    public weak var delegate: PasswordAutofillDelegate?
    /// How long a username submitted on the first step of a two-step sign-in is kept for the
    /// password step.
    public var usernameStepLifetime: TimeInterval = 600
    /// How long after a focus event a fill is refused.
    public var minimumFocusAge: TimeInterval = 0.3

    private let userScript: WKUserScript
    private lazy var messageProxy = MessageProxy(owner: self)
    private let attached = NSHashTable<WKUserContentController>.weakObjects()
    private let tabs = NSMapTable<WKWebView, TabState>.weakToStrongObjects()
    private let disabledWebViews = NSHashTable<WKWebView>.weakObjects()
    private static let log = Logger(subsystem: "com.scottsmith.ismith", category: "autofill")

    final class TabState {
        var lastFocus: LoginFieldFocus?
        /// Usernames from the first step of a two-step sign-in, per site, with where and when.
        /// Keyed by site so a frame from another site can't replace or clear one.
        var pendingUsernames: [String: (origin: Origin, username: String, date: Date)] = [:]
        /// The login the user last filled in this tab.
        var chosen: (id: UUID, origin: Origin, date: Date)?
        /// A digest of the last capture (origin, username, password), never the values.
        var lastCapture: (digest: Data, date: Date)?
    }

    public init(store: PasswordStore, worldName: String = PasswordAutofill.defaultWorldName) {
        self.store = store
        contentWorld = .world(name: worldName)
        userScript = WKUserScript(source: Self.scriptSource(), injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false, in: contentWorld)
    }

    static func scriptSource() -> String {
        guard let url = Bundle.module.url(forResource: "autofill", withExtension: "js"),
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("autofill.js is missing from the Passwords bundle")
        }
        return template
            .replacingOccurrences(of: "__HANDLER__", with: jsonString(handlerName))
            .replacingOccurrences(of: "__FILL__", with: jsonString(fillFunctionName))
    }

    private static func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    /// Adds the script and its handler to a configuration's content controller. Call before the
    /// web view is created; attaching the same controller twice does nothing.
    public func attach(to configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !attached.contains(controller) else { return }
        attached.add(controller)
        controller.addUserScript(userScript)
        controller.add(messageProxy, contentWorld: contentWorld, name: Self.handlerName)
    }

    /// Stops listening on a configuration. The script stays (WebKit can't remove one script) but
    /// does nothing in documents loaded afterwards, because it finds no handler.
    public func detach(from configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard attached.contains(controller) else { return }
        attached.remove(controller)
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: contentWorld)
    }

    /// The field last focused in a web view, for ⌘\ ("fill the best login here").
    public func lastFocus(in webView: WKWebView) -> LoginFieldFocus? {
        tabs.object(forKey: webView)?.lastFocus
    }

    /// Drops what's remembered for a tab (the two-step username, the last focus).
    public func forget(_ webView: WKWebView) {
        tabs.removeObject(forKey: webView)
    }

    /// Turns autofill and capture off for one web view, for tabs an agent drives: their messages
    /// are ignored and nothing is filled into them.
    public func setDisabled(_ disabled: Bool, for webView: WKWebView) {
        if disabled {
            disabledWebViews.add(webView)
            forget(webView)
        } else {
            disabledWebViews.remove(webView)
        }
    }

    public func isDisabled(for webView: WKWebView) -> Bool { disabledWebViews.contains(webView) }

    /// The login ⌘\ may fill without showing the popover: only for a field the user clicked or
    /// tabbed into, in the main frame or a same-site frame, and only an exact-origin match (the
    /// suggested one from a two-step sign-in first). Otherwise nil: show the popover instead.
    public func bestAutomaticLogin(for focus: LoginFieldFocus) -> LoginSummary? {
        guard focus.isUserInitiated, !focus.frame.isCrossSite else { return nil }
        let exact = focus.logins.filter { $0.matchKind == .exact }
        if let suggested = focus.suggestedLoginID, let login = exact.first(where: { $0.id == suggested }) { return login }
        return exact.first
    }

    // MARK: Actions (call only in response to the user)

    /// Fills a saved login into the form of the focused field: the username (if the form has a
    /// visible one) and the password, or just the username on a first sign-in step. The login is
    /// loaded from the store here, and must match the frame's origin; the frame must still show
    /// the same document, and the fields must still be visible to the user.
    ///
    /// A same-site login (from another host of the site) is only filled with `allowSameSite`,
    /// which the popover passes when the user picked that row with its host shown.
    @discardableResult
    public func fill(_ loginID: UUID, into focus: LoginFieldFocus, allowSameSite: Bool = false) async throws -> FillResult {
        guard let webView = focus.frame.webView else { throw AutofillError.frameGone }
        guard !isDisabled(for: webView) else { throw AutofillError.disabled }
        guard Date().timeIntervalSince(focus.receivedAt) >= minimumFocusAge else { throw AutofillError.tooSoon }
        guard let login = try store.login(id: loginID) else { throw AutofillError.loginNotFound }
        switch Origin.match(saved: login.origin, page: focus.frame.origin) {
        case .exact: break
        case .sameSite: guard allowSameSite else { throw AutofillError.sameSiteNotAllowed }
        case nil:
            Self.log.error("refused to fill a login into a frame of another origin")
            throw AutofillError.originMismatch
        }
        let result = try await runFill(in: webView, focus: focus, request: [
            "mode": "login", "username": login.username, "password": login.password,
        ])
        try? store.markUsed(id: login.id)
        state(for: webView).chosen = (login.id, focus.frame.origin, Date())
        return result
    }

    /// Fills a generated password into the new-password field (and its confirmation) of the
    /// focused field's form. Generate it with `PasswordGenerator.generate(focus.requirements)`.
    public func fillGeneratedPassword(_ password: String, into focus: LoginFieldFocus) async throws {
        guard let webView = focus.frame.webView else { throw AutofillError.frameGone }
        guard !isDisabled(for: webView) else { throw AutofillError.disabled }
        guard Date().timeIntervalSince(focus.receivedAt) >= minimumFocusAge else { throw AutofillError.tooSoon }
        _ = try await runFill(in: webView, focus: focus, request: ["mode": "generated", "username": "", "password": password])
    }

    private func runFill(in webView: WKWebView, focus: LoginFieldFocus, request: [String: String]) async throws -> FillResult {
        var args: [String: Any] = request
        args["docID"] = focus.frame.documentID
        args["fieldID"] = focus.fieldID
        args["origin"] = focus.frame.origin.serialized
        let body = "const fill = window[\(Self.jsonString(Self.fillFunctionName))]; return fill ? fill(request) : \"noScript\";"
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(body, arguments: ["request": args],
                                                           in: focus.frame.frameInfo, contentWorld: contentWorld)
        } catch {
            // The frame went away, usually. The error text has no secrets but isn't logged anyway.
            throw AutofillError.frameGone
        }
        switch result as? String {
        case "filled": return .filled
        case "usernameOnly": return .usernameOnly
        case "stale": throw AutofillError.stale
        case "originMismatch": throw AutofillError.frameOriginChanged
        case "noField": throw AutofillError.noField
        case let other: throw AutofillError.scriptFailed(other ?? "no result")
        }
    }

    /// Saves a captured sign-in (the save bar's "Save" or "Update"), with the username the user
    /// may have corrected in the bar.
    @discardableResult
    public func save(_ capture: PasswordCapture, username: String? = nil) throws -> Login {
        try store.save(origin: capture.origin, username: username ?? capture.username, password: capture.password)
    }

    /// Never offers to save for the capture's origin again (the save bar's "Never for this site").
    public func neverSave(_ capture: PasswordCapture) throws {
        try store.setNeverSave(capture.origin)
    }

    // MARK: Messages from the script

    private func state(for webView: WKWebView) -> TabState {
        if let state = tabs.object(forKey: webView) { return state }
        let state = TabState()
        tabs.setObject(state, forKey: webView)
        return state
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.world.name == contentWorld.name, let webView = message.webView, !isDisabled(for: webView),
              let body = message.body as? [String: Any], let type = body["type"] as? String,
              let docID = body["docID"] as? String, docID.count == 32,
              docID.allSatisfy(\.isHexDigit) else { return }
        let info = message.frameInfo
        // The frame's real origin from WebKit; opaque origins (sandboxed frames, data: URLs)
        // come out nil and get nothing.
        guard let origin = Origin(securityOrigin: info.securityOrigin) else { return }
        let frame = PasswordFrame(frameInfo: info, webView: webView, origin: origin, documentID: docID,
                                  isMainFrame: info.isMainFrame, topOrigin: webView.url.flatMap { Origin(url: $0) })
        switch type {
        case "focus": receiveFocus(body, frame: frame, webView: webView)
        case "submit": receiveSubmit(body, frame: frame, webView: webView)
        case "forms":
            let kinds = Set((body["kinds"] as? [String] ?? []).compactMap(FormKind.init(rawValue:)))
            if !kinds.isEmpty { delegate?.passwordAutofill(self, foundForms: kinds, in: frame) }
        default: break
        }
    }

    private func receiveFocus(_ body: [String: Any], frame: PasswordFrame, webView: WKWebView) {
        guard let fieldID = body["fieldID"] as? String, fieldID.count <= 16,
              let field = (body["field"] as? String).flatMap(FieldKind.init(rawValue:)),
              let form = (body["form"] as? String).flatMap(FormKind.init(rawValue:)) else { return }
        let r = body["rect"] as? [String: Any] ?? [:]
        func number(_ v: Any?) -> CGFloat {
            guard let d = (v as? NSNumber)?.doubleValue, d.isFinite else { return 0 }
            return CGFloat(min(max(d, -1e6), 1e6))
        }
        let rect = CGRect(x: number(r["x"]), y: number(r["y"]), width: number(r["width"]), height: number(r["height"]))
        var rectInWebView: CGRect?
        if frame.isMainFrame {
            let scale = webView.pageZoom * webView.magnification
            rectInWebView = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                   width: rect.width * scale, height: rect.height * scale)
        }
        let matches = (try? store.logins(for: frame.origin)) ?? []
        let tab = state(for: webView)
        var suggested: UUID?
        if let chosen = tab.chosen, Date().timeIntervalSince(chosen.date) < usernameStepLifetime,
           matches.contains(where: { $0.login.id == chosen.id && $0.kind == .exact }) {
            suggested = chosen.id
        } else if let pending = pendingUsername(in: tab, for: frame.origin) {
            suggested = matches.first { $0.kind == .exact && $0.login.username == pending }?.login.id
        }
        func intValue(_ key: String) -> Int? {
            guard let v = (body[key] as? NSNumber)?.intValue, (1...4096).contains(v) else { return nil }
            return v
        }
        let rules = (body["passwordRules"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(512)) }
        let focus = LoginFieldFocus(
            frame: frame, fieldID: fieldID, field: field, form: form, rect: rect, rectInWebView: rectInWebView,
            logins: matches.map(\.summary), suggestedLoginID: suggested,
            requirements: PasswordRequirements(minLength: intValue("minLength"), maxLength: intValue("maxLength"), rules: rules),
            isUserInitiated: body["userInitiated"] as? Bool == true, receivedAt: Date())
        tab.lastFocus = focus
        delegate?.passwordAutofill(self, loginFieldFocused: focus)
    }

    private func receiveSubmit(_ body: [String: Any], frame: PasswordFrame, webView: WKWebView) {
        guard let form = (body["form"] as? String).flatMap(FormKind.init(rawValue:)) else { return }
        func text(_ key: String, limit: Int) -> String {
            guard let s = body[key] as? String, s.count <= limit else { return "" }
            return s
        }
        let tab = state(for: webView)
        let typed = text("username", limit: 1024).trimmingCharacters(in: .whitespacesAndNewlines)
        if form == .usernameOnly {
            if !typed.isEmpty { tab.pendingUsernames[Self.twoStepKey(frame.origin)] = (frame.origin, typed, Date()) }
            return
        }
        let current = text("password", limit: 4096), new = text("newPassword", limit: 4096)
        let password: String
        switch form {
        case .login: password = current
        case .signup: password = new
        case .change, .usernameOnly: password = new.isEmpty ? current : new
        }
        guard !password.isEmpty else { return }

        var username = typed
        if username.isEmpty, let pending = pendingUsername(in: tab, for: frame.origin) {
            username = pending
        }
        if username.isEmpty {
            username = text("usernameHint", limit: 1024).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        tab.pendingUsernames[Self.twoStepKey(frame.origin)] = nil

        // The script may report one sign-in more than once (a click and then the submit).
        let digest = Data(SHA256.hash(data: Data([frame.origin.serialized, username, password].joined(separator: "\u{0}").utf8)))
        if let last = tab.lastCapture, last.digest == digest, Date().timeIntervalSince(last.date) < 10 { return }
        tab.lastCapture = (digest, Date())

        let action: SaveAction
        do {
            action = try store.proposal(for: frame.origin, username: username, password: password)
        } catch {
            Self.log.error("could not check a submitted sign-in against the store")
            return
        }
        switch action {
        case .neverSave:
            return
        case .unchanged(let id):
            try? store.markUsed(id: id)
        case .save, .update:
            delegate?.passwordAutofill(self, captured: PasswordCapture(
                origin: frame.origin, username: username, password: password, action: action, form: form, webView: webView))
        }
    }
}

extension PasswordAutofill {
    /// Two-step usernames are kept per site (or per host where only exact matching applies).
    nonisolated static func twoStepKey(_ origin: Origin) -> String {
        "\(origin.scheme)|\(origin.port)|\(origin.sameSiteKey(using: .shared) ?? origin.host)"
    }

    fileprivate func pendingUsername(in tab: TabState, for origin: Origin) -> String? {
        guard let pending = tab.pendingUsernames[Self.twoStepKey(origin)],
              Date().timeIntervalSince(pending.date) < usernameStepLifetime,
              Origin.match(saved: pending.origin, page: origin) != nil else { return nil }
        return pending.username
    }
}

/// Holds the autofill controller weakly, so a content controller's strong reference to its
/// handler doesn't keep the controller alive.
@MainActor
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: PasswordAutofill?

    init(owner: PasswordAutofill) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

public extension Origin {
    /// The origin WebKit reports for a frame. Nil for opaque origins and anything not http(s).
    init?(securityOrigin: WKSecurityOrigin) {
        self.init(scheme: securityOrigin.protocol, host: securityOrigin.host, port: securityOrigin.port)
    }
}
