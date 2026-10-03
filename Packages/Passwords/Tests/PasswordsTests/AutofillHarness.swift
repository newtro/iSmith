import AppKit
@testable import Passwords
import SignInSync
import WebKit
import XCTest

enum HarnessError: Error {
    case timeout(String)
}

/// One web view with the autofill controller attached, on a throwaway store and a non-persistent
/// WebKit data store, in an offscreen window so pages lay out as they would on screen.
@MainActor
final class AutofillHarness: NSObject, PasswordAutofillDelegate, WKNavigationDelegate {
    let dir: URL
    let store: PasswordStore
    let autofill: PasswordAutofill
    let webView: WKWebView
    let window: NSWindow
    private(set) var focuses: [LoginFieldFocus] = []
    private(set) var captures: [PasswordCapture] = []
    private(set) var forms: [(kinds: Set<FormKind>, frame: PasswordFrame)] = []
    private var navigationWaiters: [CheckedContinuation<Void, Error>] = []

    override init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AutofillTests-\(UUID().uuidString)")
        store = try! PasswordStore(fileURL: dir.appendingPathComponent("passwords.sqlite"), keyStore: InMemoryKeyStore())
        autofill = PasswordAutofill(store: store)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        autofill.attach(to: configuration)
        autofill.attach(to: configuration) // a second attach does nothing (and doesn't throw)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 900, height: 700),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        super.init()
        autofill.delegate = self
        webView.navigationDelegate = self
    }

    func tearDown() {
        webView.navigationDelegate = nil
        window.orderOut(nil)
        window.contentView = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func clearEvents() {
        focuses.removeAll()
        captures.removeAll()
        forms.removeAll()
    }

    // MARK: Delegate

    func passwordAutofill(_ autofill: PasswordAutofill, loginFieldFocused focus: LoginFieldFocus) {
        focuses.append(focus)
    }

    func passwordAutofill(_ autofill: PasswordAutofill, captured capture: PasswordCapture) {
        captures.append(capture)
    }

    func passwordAutofill(_ autofill: PasswordAutofill, foundForms kinds: Set<FormKind>, in frame: PasswordFrame) {
        forms.append((kinds, frame))
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let waiters = navigationWaiters
        navigationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let waiters = navigationWaiters
        navigationWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    /// Loads a URL and waits for it to finish.
    func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationWaiters.append(continuation)
            webView.load(URLRequest(url: url))
        }
    }

    /// Runs `action` (which starts a navigation, like a form submit) and waits for the next load.
    func waitForNavigation(_ action: () async throws -> Void) async throws {
        let wait = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                navigationWaiters.append(continuation)
            }
        }
        await Task.yield()
        try await action()
        try await wait.value
    }

    // MARK: Scripts

    /// Runs script in the page's own world, as the page's scripts would.
    @discardableResult
    func page(_ script: String, in frame: WKFrameInfo? = nil) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: [:], in: frame, contentWorld: .page)
    }

    func pageString(_ script: String, in frame: WKFrameInfo? = nil) async throws -> String {
        (try await page(script, in: frame) as? String) ?? "<not a string>"
    }

    /// Polls until `condition` holds, failing the test after `timeout` seconds.
    func waitUntil(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                throw HarnessError.timeout(what)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Lets events settle, for asserting that something did not happen.
    func settle(_ seconds: Double = 0.8) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
