import AppKit
import Carbon.HIToolbox
import Sparkle

/// The menu bar. Each browser command acts on the key browser window (or the last one used).
@MainActor
enum MainMenu {
    static func build(commands: Commands, updater: SPUStandardUpdaterController?) -> NSMenu {
        let main = NSMenu()

        let name = AppIdentity.displayName
        let app = submenu(main, name)
        app.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let updater {
            let check = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            check.target = updater
            app.addItem(check)
        }
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(Commands.showSettings), ",", commands))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        file.addItem(item("New Tab", #selector(Commands.newTab), "t", commands))
        file.addItem(item("New Window", #selector(Commands.newWindow), "n", commands))
        file.addItem(item("New Space…", #selector(Commands.newSpace), "N", commands))
        file.addItem(.separator())
        file.addItem(item("Open Location…", #selector(Commands.openLocation), "l", commands))
        file.addItem(item("Reopen Closed Tab", #selector(Commands.reopenClosedTab), "T", commands))
        file.addItem(item("Reopen Closed Window", #selector(Commands.reopenClosedWindow), "", commands))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(Commands.closeTab), "w", commands))
        file.addItem(item("Close Window", #selector(Commands.closeWindow), "W", commands))

        let edit = submenu(main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
            .keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu(main, "View")
        view.addItem(item("Reload Page", #selector(Commands.reload), "r", commands))
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let history = submenu(main, "History")
        history.addItem(item("Back", #selector(Commands.goBack), "[", commands))
        history.addItem(item("Forward", #selector(Commands.goForward), "]", commands))

        let spaces = submenu(main, "Spaces")
        spaces.delegate = commands
        for index in 0..<9 {
            let space = item("Space \(index + 1)", #selector(Commands.selectSpace(_:)), "\(index + 1)", commands)
            space.tag = index
            spaces.addItem(space)
        }
        spaces.addItem(.separator())
        spaces.addItem(item("Edit Current Space…", #selector(Commands.editSpace), ",", commands, [.command, .shift]))

        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        // ⌃Tab and ⌃⇧Tab also switch tabs; they're caught before the page sees them.
        window.addItem(item("Show Next Tab", #selector(Commands.nextTab), "}", commands))
        window.addItem(item("Show Previous Tab", #selector(Commands.previousTab), "{", commands))
        window.addItem(item("Move Tab to New Window", #selector(Commands.moveTabToNewWindow), "", commands))
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(main, "Help")
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject,
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}

/// The browser's menu commands and keyboard shortcuts.
@MainActor
final class Commands: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let browser: BrowserState
    private weak var app: AppDelegate?

    init(browser: BrowserState, app: AppDelegate) {
        self.browser = browser
        self.app = app
    }

    private var window: WindowState? { browser.currentWindow }
    private var tabs: SpaceTabs? { window?.active }
    private var tab: Tab? { tabs?.selected }
    /// The key window when it isn't a browser window (Settings), for ⌘W.
    private var otherKeyWindow: NSWindow? {
        guard let key = NSApp.keyWindow, !browser.windows.contains(where: { $0.window === key }) else { return nil }
        return key
    }

    @objc func newTab() {
        guard let window else { return browser.reopen() }
        window.window?.makeKeyAndOrderFront(nil)
        browser.newTab(in: window)
    }

    @objc func newWindow() { browser.newWindow() }

    @objc func newSpace() {
        guard let window else { return }
        window.window?.makeKeyAndOrderFront(nil)
        window.editing = EditorRequest(spaceID: nil)
    }

    @objc func editSpace() {
        guard let window, let id = window.activeSpaceID else { return }
        window.editing = EditorRequest(spaceID: id)
    }

    @objc func openLocation() {
        guard let window else { return }
        window.window?.makeKeyAndOrderFront(nil)
        if window.active?.selected == nil { browser.newTab(in: window) } else { window.focusAddress() }
    }

    @objc func reopenClosedTab() {
        guard let window else { return browser.reopen() }
        browser.reopenClosedTab(in: window)
    }

    @objc func reopenClosedWindow() { browser.reopenClosedWindow() }

    @objc func closeTab() {
        if let other = otherKeyWindow { return other.performClose(nil) }
        guard let window else { return }
        browser.closeSelectedTab(in: window)
    }

    @objc func closeWindow() {
        (otherKeyWindow ?? window?.window)?.performClose(nil)
    }

    @objc func reload() {
        guard let tab, let tabs else { return }
        browser.reload(tab, in: tabs)
    }

    @objc func goBack() { tab?.webView?.goBack() }
    @objc func goForward() { tab?.webView?.goForward() }

    @objc func nextTab() {
        guard let window else { return }
        browser.selectNeighbor(forward: true, in: window)
    }

    @objc func previousTab() {
        guard let window else { return }
        browser.selectNeighbor(forward: false, in: window)
    }

    @objc func moveTabToNewWindow() {
        guard let window, let tabs, let id = tabs.layout.selected else { return }
        browser.moveToNewWindow(id, from: tabs, in: window)
    }

    @objc func selectSpace(_ sender: NSMenuItem) {
        guard let window else { return }
        browser.select(index: sender.tag, in: window)
    }

    @objc func showSettings() { app?.showSettings() }

    /// ⌃Tab, ⌃⇧Tab, ⌘⇧] and ⌘⇧[ switch tabs even while a page or the address bar has focus.
    func handleTabSwitchKey(_ event: NSEvent) -> Bool {
        guard let key = event.window, key.attachedSheet == nil,
              let window = browser.windows.first(where: { $0.window === key }) else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let forward: Bool
        switch (Int(event.keyCode), flags) {
        case (kVK_Tab, [.control]), (kVK_ANSI_RightBracket, [.command, .shift]): forward = true
        case (kVK_Tab, [.control, .shift]), (kVK_ANSI_LeftBracket, [.command, .shift]): forward = false
        default: return false
        }
        browser.selectNeighbor(forward: forward, in: window)
        return true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack): return tab?.canGoBack == true
        case #selector(goForward): return tab?.canGoForward == true
        case #selector(reload), #selector(moveTabToNewWindow): return tab != nil
        case #selector(nextTab), #selector(previousTab): return (tabs?.layout.count ?? 0) > 1
        case #selector(selectSpace(_:)): return browser.spaces.indices.contains(item.tag)
        case #selector(editSpace): return window?.activeSpaceID != nil
        case #selector(reopenClosedWindow): return browser.canReopenClosedWindow
        default: return true
        }
    }

    /// The Spaces menu shows each space's name next to its ⌘ number.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(selectSpace(_:)) {
            let space = browser.spaces.indices.contains(item.tag) ? browser.spaces[item.tag] : nil
            item.title = space?.def.name ?? "Space \(item.tag + 1)"
            item.isHidden = space == nil
            item.state = space != nil && space?.id == window?.activeSpaceID ? .on : .off
        }
    }
}
