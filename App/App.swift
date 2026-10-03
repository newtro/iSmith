import Sparkle
import SwiftUI

@main
enum Launcher {
    static func main() {
        // Unit tests run inside the app. They get an app with no windows, so a test run never
        // opens real spaces, imports the spike or starts the updater.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            TestHostApp.main()
        } else {
            ISmithApp.main()
        }
    }
}

struct ISmithApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var browser = BrowserState()

    var body: some Scene {
        Window("iSmith", id: "main") {
            ContentView()
                .environmentObject(browser)
                .environmentObject(browser.vault)
                .environmentObject(browser.sync)
                .environmentObject(browser.config)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appDelegate.updater.updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { browser.newTabInActive() }
                    .keyboardShortcut("t")
                Button("New Space…") { browser.editing = EditorRequest(spaceID: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Close Tab") { browser.closeSelectedTab() }
                    .keyboardShortcut("w")
            }
            CommandMenu("Spaces") {
                ForEach(0..<9, id: \.self) { index in
                    Button("Space \(index + 1)") { browser.select(index: index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
                Button("Edit Current Space…") {
                    if let id = browser.active?.id { browser.editing = EditorRequest(spaceID: id) }
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            }
        }
    }
}

/// The app as a unit-test host: no windows and no data.
struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by BrowserState: saves the latest cookie changes to the vault before quitting.
    @MainActor static var flush: (() async -> Void)?

    /// Sparkle. Automatic checks are off until releases exist (SUEnableAutomaticChecks in
    /// Info.plist); "Check for Updates…" works now.
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
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
