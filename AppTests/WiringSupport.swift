import AppKit
import Blocking
import SignInSync
import WebKit
import XCTest
@testable import iSmith

/// A `BrowserState` on a scratch data folder with one space (no home page, so nothing loads from
/// the network), throwaway Keychain keys, and an optional blocking controller. Its WebKit store
/// is deleted by `tearDown`.
@MainActor
final class WiredBrowser {
    let dir: URL
    let spaceID = "fixture"
    let browser: BrowserState
    /// The browser window, made on first use (tests that need no web view never open one).
    private(set) lazy var window: WindowState = browser.newWindow(space: spaceID)
    /// An offscreen window web views are put in, so pages lay out and hit-test as on screen.
    let host: NSWindow
    let defaults: UserDefaults
    private let defaultsSuite = "iSmithTests.\(UUID().uuidString)"

    init(blocking: ((URL) throws -> BlockingController?)? = nil) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("iSmithWiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = """
            {"version":2,"providers":[],"accounts":[],"shared":{},
             "spaces":[{"id":"fixture","name":"Fixture","color":0,"storeID":"\(UUID().uuidString)","bindings":{},"home":""}]}
            """
        try Data(config.utf8).write(to: dir.appendingPathComponent("config.json"))
        let blockingDir = dir.appendingPathComponent("Blocking", isDirectory: true)
        let made = try blocking?(blockingDir)
        browser = BrowserState(paths: AppPaths(dataDir: dir, spikeDir: nil), keyStore: InMemoryKeyStore(),
                               passwordsKeyStore: InMemoryKeyStore(), blocking: { _ in made })
        defaults = UserDefaults(suiteName: defaultsSuite)!
        // The Dev app's own defaults may have blocking switched off; tests start with it on.
        browser.shields.setEnabled(true, defaults: defaults)
        host = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 700),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.orderBack(nil)
    }

    var tabs: SpaceTabs { window.tabs(for: spaceID) }

    /// Opens a tab on `url` and waits for it to finish loading.
    @discardableResult
    func open(_ url: URL) async throws -> Tab {
        let tab = browser.openTab(in: window, space: spaceID, url: url)
        try await waitForLoad(tab, path: url.path)
        return tab
    }

    func waitForLoad(_ tab: Tab, path: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let loaded = await eventually(timeout: 15) {
            guard let webView = tab.webView, webView.url?.path == path, !webView.isLoading else { return false }
            let state = try? await webView.evaluateJavaScript("document.readyState") as? String
            return state == "complete"
        }
        XCTAssertTrue(loaded, "\(path) loaded", file: file, line: line)
    }

    /// Marks the page, runs `action` (a reload or navigation) and waits for the next page.
    func waitForNewPage(_ tab: Tab, path: String, _ action: () -> Void) async throws {
        _ = try await tab.webView?.evaluateJavaScript("window.__iSmithOldPage = true; 1")
        action()
        let replaced = await eventually(timeout: 15) {
            guard let webView = tab.webView, webView.url?.path == path, !webView.isLoading else { return false }
            let old = try? await webView.evaluateJavaScript("window.__iSmithOldPage === true && document.readyState === 'complete'") as? Bool
            let ready = try? await webView.evaluateJavaScript("document.readyState") as? String
            return old == false && ready == "complete"
        }
        XCTAssertTrue(replaced, "a new page loaded at \(path)")
    }

    /// Shows a tab's web view in the offscreen window.
    func show(_ tab: Tab) throws {
        let webView = try XCTUnwrap(tab.webView)
        webView.frame = host.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        host.contentView = webView
    }

    func tearDown() async {
        host.contentView = nil
        host.orderOut(nil)
        browser.passwordUI.close()
        for tab in browser.windows.flatMap(\.allTabs) { tab.unload() }
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        // Deletes the space's WebKit store (retried while WebKit lets go of it).
        let removal = browser.manager.deleteSpace(spaceID)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once<Void> { continuation.resume() }
            Task { await removal.value; once.run() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { once.run() }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Real input (trusted events), as a user would

    func click(_ id: String, in tab: Tab) async throws {
        let webView = try XCTUnwrap(tab.webView)
        let rect = try await webView.callAsyncJavaScript("""
            const r = document.getElementById(id).getBoundingClientRect();
            return [r.left + r.width / 2, r.top + r.height / 2];
            """, arguments: ["id": id], contentWorld: .page) as? [NSNumber]
        let point = try XCTUnwrap(rect)
        let location = NSPoint(x: point[0].doubleValue, y: webView.bounds.height - point[1].doubleValue)
        let now = ProcessInfo.processInfo.systemUptime
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, Float(0))] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: now,
                                                         windowNumber: host.windowNumber, context: nil, eventNumber: 1,
                                                         clickCount: 1, pressure: pressure))
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    func type(_ text: String, in tab: Tab) async throws {
        try XCTUnwrap(tab.webView).insertText(text)
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func pressReturn(in tab: Tab) async throws {
        let webView = try XCTUnwrap(tab.webView)
        let now = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: now,
                                                       windowNumber: host.windowNumber, context: nil, characters: "\r",
                                                       charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func value(_ id: String, in tab: Tab) async throws -> String {
        try await XCTUnwrap(tab.webView).callAsyncJavaScript("return document.getElementById(id).value",
                                                             arguments: ["id": id], contentWorld: .page) as? String ?? "<none>"
    }
}
