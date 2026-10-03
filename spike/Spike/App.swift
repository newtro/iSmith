import SwiftUI

@main
struct ISmithSpikeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var browser = BrowserState()

    var body: some Scene {
        Window("iSmith Spike", id: "main") {
            ContentView()
                .environmentObject(browser)
                .environmentObject(browser.vault)
                .environmentObject(browser.sync)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { browser.newTabInActive() }
                    .keyboardShortcut("t")
                Button("Close Tab") { browser.closeSelectedTab() }
                    .keyboardShortcut("w")
            }
            CommandMenu("Spaces") {
                ForEach(Array(Seed.spaces.enumerated()), id: \.element.id) { index, space in
                    Button(space.name) { browser.select(index: index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by BrowserState: saves the latest cookie changes to the vault before quitting.
    @MainActor static var flush: (() async -> Void)?

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
