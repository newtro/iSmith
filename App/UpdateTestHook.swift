#if ISMITH_UPDATE_TEST
import Foundation
import Passwords
import Sparkle

/// Only in builds made with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=ISMITH_UPDATE_TEST` (never by
/// `make` or `Tools/release.sh`): seeds saved passwords and reports what the store shows, so an
/// update from one signed Release build to another, through Sparkle, can be checked end to end.
/// Settings come from the test bundle id's defaults, since Sparkle relaunches without our
/// environment:
///
/// - `UTDataDir`: the data folder (see `AppPaths.standard`).
/// - `UTSeed`: adds that many logins (`https://site<i>.example`) when the store is empty.
/// - `UTReportDir`: writes `report-<version>-<time>.json` there: what the store opened with.
/// - `UTCheckNow`: starts a background update check at launch.
@MainActor
enum UpdateTestHook {
    static func run(_ browser: BrowserState, updater: SPUStandardUpdaterController?) {
        let defaults = UserDefaults.standard
        let store = browser.passwords?.store
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var report: [String: Any] = [
            "version": version,
            "bundleID": AppIdentity.bundleID,
            "dataDir": browser.paths.dataDir.path,
            "keyService": AppIdentity.passwordsKeyService,
            "storeOpened": store != nil,
            "problem": browser.passwordsProblem ?? NSNull(),
            "movedAside": store?.movedAside?.path ?? NSNull(),
        ]
        let seed = defaults.integer(forKey: "UTSeed")
        if let store, seed > 0, (try? store.allLogins().isEmpty) == true {
            for i in 0..<seed {
                _ = try? store.add(origin: Origin(string: "https://site\(i).example")!, username: "user\(i)", password: "pw-\(i)-seeded")
            }
            report["seeded"] = seed
        }
        if let store {
            report["readable"] = (try? store.allLogins().count) ?? -1
            report["unreadable"] = (try? store.unreadableCount()) ?? -1
            report["matchesSite0"] = (try? store.logins(for: Origin(string: "https://site0.example")!).count) ?? -1
        }
        if let dir = defaults.string(forKey: "UTReportDir"),
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("report-\(version)-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: url)
        }
        if defaults.bool(forKey: "UTCheckNow") {
            updater?.updater.checkForUpdatesInBackground()
        }
    }
}
#endif
