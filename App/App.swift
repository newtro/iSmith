import AppKit
import Sparkle
import SwiftUI

@main
enum Launcher {
    /// The app delegate; NSApplication holds its delegate weakly.
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        // Unit tests run inside the app. They get an app with no windows, so a test run never
        // opens real spaces, imports the spike or starts the updater.
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let app = NSApplication.shared
        let delegate = AppDelegate(testing: testing)
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

/// An AppKit app: browser windows are made and restored by `BrowserState`, so the window list,
/// the menus and the keyboard shortcuts are all under the app's control. SwiftUI draws each
/// window's content.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by BrowserState: saves the session and the latest cookie changes before quitting.
    static var flush: (() async -> Void)?

    private let testing: Bool
    private(set) var browser: BrowserState?
    /// Sparkle. Automatic checks are off until releases exist (SUEnableAutomaticChecks in
    /// Info.plist); "Check for Updates…" works now.
    private(set) var updater: SPUStandardUpdaterController?
    private var controllers: [UUID: BrowserWindowController] = [:]
    private var settings: NSWindowController?
    private var commands: Commands?
    private var keyMonitor: Any?

    init(testing: Bool) {
        self.testing = testing
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !testing else { return }
        #if !DEBUG
        // "iSmith Dev" never updates itself from the release feed.
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
        let browser = BrowserState()
        self.browser = browser
        browser.presentWindow = { [weak self] state in self?.present(state) }
        browser.openSettings = { [weak self] in self?.showSettings() }
        let commands = Commands(browser: browser, app: self)
        self.commands = commands
        NSApp.mainMenu = MainMenu.build(commands: commands, updater: updater)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak commands] event in
            commands?.handleTabSwitchKey(event) == true ? nil : event
        }
        browser.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present(_ state: WindowState) {
        guard let browser else { return }
        let previous = NSApp.keyWindow ?? controllers.values.compactMap(\.window).last
        let controller = BrowserWindowController(state: state, browser: browser, cascadeFrom: previous) { [weak self] id in
            self?.controllers[id] = nil
        }
        controllers[state.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        guard let browser else { return }
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Accounts and Sign-ins"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: AccountsPanel()
                .environmentObject(browser)
                .environmentObject(browser.vault)
                .environmentObject(browser.sync)
                .environmentObject(browser.config)
                .frame(minWidth: 380, minHeight: 420))
            window.center()
            settings = NSWindowController(window: window)
        }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !testing }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        browser?.reopen()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let flush = Self.flush else { return .terminateNow }
        // Quit goes ahead after 3 seconds even if WebKit never answers, so the app can't hang.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await flush()
            reply()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reply() }
        return .terminateLater
    }
}

/// One browser window. Closing it closes its tabs; the last window's tabs are kept for the next
/// launch.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let state: WindowState
    private let browser: BrowserState
    private let closed: (UUID) -> Void

    init(state: WindowState, browser: BrowserState, cascadeFrom previous: NSWindow?, closed: @escaping (UUID) -> Void) {
        self.state = state
        self.browser = browser
        self.closed = closed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "iSmith"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 900, height: 560)
        let host = NSHostingView(rootView: BrowserWindowView(window: state)
            .environmentObject(browser)
            .environmentObject(browser.vault)
            .environmentObject(browser.sync)
            .environmentObject(browser.config))
        // The window's size is the user's, not SwiftUI's idea of the content's size.
        host.sizingOptions = []
        window.contentView = host
        if let frame = state.savedFrame {
            window.setFrame(from: frame)
        } else if let frame = state.initialFrame {
            window.setFrame(frame, display: false)
        } else if let previous {
            window.setFrame(NSRect(origin: NSPoint(x: previous.frame.minX + 28, y: previous.frame.minY - 28),
                                   size: previous.frame.size), display: false)
        } else {
            window.center()
        }
        state.window = window
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        browser.windowWillClose(state)
        closed(state.id)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        browser.windowBecameMain(state)
    }

    func windowDidMove(_ notification: Notification) { browser.scheduleRefresh() }
    func windowDidEndLiveResize(_ notification: Notification) { browser.scheduleRefresh() }
}
