#if DEBUG
import AppKit
import QuartzCore

/// P8's performance run, in Debug builds only, started by `ISMITH_PERF_STAGE_FILE=<path>` on a
/// scratch `ISMITH_DATA_DIR` whose session holds the tabs to measure (`Tools/perf-run.sh` sets
/// it up). It drives the browser the way a day of use does, writing each stage's name to the
/// stage file and holding there while the script sums the memory of the app and its WebKit
/// processes:
/// 1. `restored`: the session restored (only visible and Keep alive tabs load);
/// 2. `allLoaded`: every tab in every space selected once, so every tab has a web view;
/// 3. `capped`: a minute later, the regular hibernation pass, which keeps only the most recently
///    shown `maxLoadedBackgroundTabs` background tabs loaded;
/// 4. `hibernated`: every background tab idle past `hibernateAfter` (their last-shown times are
///    moved back rather than waiting 30 minutes), then the real hibernation pass.
/// Space switches are timed after stages 2 to 4, from `select` until the window has laid out and
/// drawn the space, including one more turn of the main run loop. Results go to
/// `<stage file>.json`, then the app quits.
@MainActor
enum PerfHarness {
    static func runIfRequested(_ browser: BrowserState) {
        guard let path = ProcessInfo.processInfo.environment["ISMITH_PERF_STAGE_FILE"], !path.isEmpty else { return }
        let hold = Double(ProcessInfo.processInfo.environment["ISMITH_PERF_HOLD"] ?? "") ?? 12
        Task { await run(browser, stageFile: URL(fileURLWithPath: path), hold: hold) }
    }

    private static func run(_ browser: BrowserState, stageFile: URL, hold: TimeInterval) async {
        var results: [String: Any] = [:]
        func stage(_ name: String) async {
            try? Data("\(name) \(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: stageFile)
            NSLog("iSmith perf: stage \(name)")
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        }
        // Launch settles: a first launch compiles the filter lists.
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        guard let window = browser.windows.first else { return }
        results["tabs"] = browser.windows.flatMap(\.allTabs).count
        results["loadedAtRestore"] = browser.windows.flatMap(\.allTabs).filter { $0.webView != nil }.count
        await stage("restored")

        // Every tab once, space by space, waiting for each page.
        let loadStart = CACurrentMediaTime()
        for space in browser.spaces {
            browser.select(space, in: window)
            guard let tabs = window.spaces[space.id] else { continue }
            for tab in tabs.ordered {
                browser.selectTab(tab.id, in: tabs)
                for _ in 0..<200 {
                    if let webView = tab.webView, !webView.isLoading, webView.url != nil { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        results["loadAllSeconds"] = CACurrentMediaTime() - loadStart
        results["loadedAfterVisit"] = browser.windows.flatMap(\.allTabs).filter { $0.webView != nil }.count
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await stage("allLoaded")
        results["switchAllLoaded"] = await timeSwitches(browser, window: window)

        // A little later, the regular pass (every minute in the app) keeps only the most
        // recently shown background tabs loaded.
        try? await Task.sleep(nanoseconds: UInt64((BrowserState.loadedTabGrace + 5) * 1_000_000_000))
        browser.hibernateIdleTabs()
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        results["loadedAfterCap"] = browser.windows.flatMap(\.allTabs).filter { $0.webView != nil }.count
        await stage("capped")
        results["switchCapped"] = await timeSwitches(browser, window: window)

        // Hibernation: background tabs idle for longer than the limit, then the real pass.
        let longAgo = Date().addingTimeInterval(-BrowserState.hibernateAfter - 60)
        for tab in browser.windows.flatMap(\.allTabs) { tab.lastShown = longAgo }
        browser.hibernateIdleTabs()
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        results["loadedAfterHibernation"] = browser.windows.flatMap(\.allTabs).filter { $0.webView != nil }.count
        results["keptAlive"] = browser.windows.flatMap(\.allTabs).filter(\.keepAlive).count
        await stage("hibernated")
        results["switchHibernated"] = await timeSwitches(browser, window: window)
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: stageFile.appendingPathExtension("json"))
        }
        await stage("done")
        // From the run loop, not from inside this task: quitting waits for a flush that needs
        // the main actor.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// Switches between the spaces 40 times; milliseconds per switch (median, 95th, max).
    private static func timeSwitches(_ browser: BrowserState, window: WindowState) async -> [String: Double] {
        var times: [Double] = []
        let spaces = browser.spaces
        guard spaces.count > 1 else { return [:] }
        for i in 0..<40 {
            let space = spaces[(i + 1) % spaces.count]
            let start = CACurrentMediaTime()
            browser.select(space, in: window)
            window.window?.contentView?.layoutSubtreeIfNeeded()
            window.window?.displayIfNeeded()
            // SwiftUI and the tab strip finish some updates on the next turn of the run loop.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
            window.window?.contentView?.layoutSubtreeIfNeeded()
            window.window?.displayIfNeeded()
            times.append((CACurrentMediaTime() - start) * 1000)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let sorted = times.sorted()
        return ["medianMs": sorted[sorted.count / 2], "p95Ms": sorted[Int(Double(sorted.count - 1) * 0.95)], "maxMs": sorted.last!]
    }
}
#endif
