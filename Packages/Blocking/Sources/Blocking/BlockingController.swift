import ContentBlockerConverter
import Foundation
import WebKit

/// Ad and tracker blocking for the app's web views.
///
/// - `ruleLists()` gives the compiled EasyList and EasyPrivacy lists. The first call of a launch
///   looks them up in the compiled store (well under a millisecond). If there's no store yet, or
///   WebKit can't read it after an OS update, they're converted and compiled again from the last
///   downloaded copy or the bundled snapshot (about 5 s for both lists on an M4 Max).
/// - `refresh()` downloads the lists when a week has passed since the last check, and swaps in the
///   new compiled lists only once all of them compile. Until then, web views keep the old ones.
/// - `apply(to:host:)` attaches the lists to a web view's content controller, or removes them when
///   the site is on the allowlist (`setAllowed(host:_:)`).
///
/// Everything lives under the injected `directory`: `state.json`, `allowlist.json`, `lists/`
/// (the downloaded copies in use) and `Store/` (WebKit's compiled lists).
@MainActor
public final class BlockingController {
    /// Posted after the lists in use change: when the first load of a launch finishes, and after
    /// a refresh swaps in new lists. Re-apply them to open web views.
    public static let listsDidChange = Notification.Name("BlockingController.listsDidChange")
    /// Posted after `setAllowed(host:_:)` changes the allowlist. `userInfo["site"]` is the site.
    public static let allowlistDidChange = Notification.Name("BlockingController.allowlistDidChange")

    public struct Configuration: Sendable {
        public var directory: URL
        public var sources: [FilterSource]
        /// How long downloaded lists are used before checking for new ones.
        public var refreshInterval: TimeInterval = 7 * 24 * 3600
        /// After a failed refresh, how long to wait before trying again.
        public var retryInterval: TimeInterval = 6 * 3600
        /// How often automatic refresh checks whether a refresh is due.
        public var checkInterval: TimeInterval = 3600
        /// After the lists fail to load or compile from local files, how long `ruleLists()`
        /// answers empty before trying again.
        public var loadRetryInterval: TimeInterval = 600
        public var maxRulesPerList = RuleListBuilder.webKitRuleLimit
        /// A downloaded list with fewer rule lines than this is rejected (an error page, or a
        /// truncated download), and the current lists stay.
        public var minimumRulesPerSource = 1_000
        public var fetch: @Sendable (URL) async throws -> Data = { try await BlockingController.download($0) }
        public var now: @Sendable () -> Date = { Date() }

        public init(directory: URL, sources: [FilterSource] = FilterSource.defaults) {
            self.directory = directory
            self.sources = sources
        }
    }

    public enum RefreshResult: Equatable, Sendable {
        /// The last check was recent enough.
        case notDue
        /// Downloaded, and the same as the lists in use.
        case unchanged
        /// New lists compiled and in use.
        case updated
        /// The download, a list's check, or the compile failed. The lists in use didn't change.
        case failed(String)
    }

    public enum Origin: String, Codable, Sendable {
        case bundled, downloaded
    }

    public struct Status: Sendable {
        public let origin: Origin?
        /// Each source's `! Version:` header.
        public let listVersions: [String: String]
        /// Rules in each compiled list, by list name (`easylist-1`, …).
        public let ruleCounts: [String: Int]
        public let lastChecked: Date?
        public let lastError: String?
    }

    public let configuration: Configuration
    private let store: RuleListStoring
    private var allowlist: Allowlist
    private var state: State?
    private var lists: [WKContentRuleList]?
    private var loadTask: Task<[WKContentRuleList], Never>?
    private var loadFailedAt: Date?
    private var refreshTask: (id: Int, forced: Bool, task: Task<RefreshResult, Never>)?
    private var refreshCount = 0
    private var automaticRefresh: Task<Void, Never>?
    /// The latest `apply` call per content controller, so an older call that finishes later
    /// doesn't undo a newer one.
    private let applyTickets = NSMapTable<WKUserContentController, NSNumber>.weakToStrongObjects()
    private var nextTicket = 0
    /// The lists attached to each content controller, so `apply` takes off exactly those (lists
    /// from before a refresh included) and applying the same lists again changes nothing. Held
    /// only as long as they're attached, so a replaced generation is released (and its removed
    /// file freed) once every web view has re-applied or closed.
    private let attached = NSMapTable<WKUserContentController, NSArray>.weakToStrongObjects()
    private var loadError: String?

    private static let identifierPrefix = "ismith-blocking-"

    public convenience init(directory: URL) throws {
        try self.init(configuration: Configuration(directory: directory))
    }

    public convenience init(configuration: Configuration) throws {
        let store = try WebKitRuleListStore(directory: configuration.directory.appendingPathComponent("Store", isDirectory: true))
        self.init(configuration: configuration, store: store)
    }

    init(configuration: Configuration, store: RuleListStoring) {
        self.configuration = configuration
        self.store = store
        allowlist = Allowlist(fileURL: configuration.directory.appendingPathComponent("allowlist.json"))
    }

    // MARK: Rule lists

    /// The compiled lists to attach. Loads (and if needed compiles) them on the first call; later
    /// calls return them at once. Empty only if neither the downloaded copy nor the bundled
    /// snapshot compiles (see `status.lastError`). Then calls answer empty at once for
    /// `loadRetryInterval` before the next try, and a successful `refresh()` also ends it.
    public func ruleLists() async -> [WKContentRuleList] {
        if let lists { return lists }
        if let loadTask { return await loadTask.value }
        if let failed = loadFailedAt, configuration.now().timeIntervalSince(failed) < configuration.loadRetryInterval {
            return []
        }
        let task = Task {
            let result = await self.load()
            // Settled here, on the main actor, before any caller waiting on the load resumes.
            self.loadTask = nil
            guard !result.isEmpty else {
                self.loadFailedAt = self.configuration.now()
                return result
            }
            self.loadFailedAt = nil
            self.lists = result
            NotificationCenter.default.post(name: Self.listsDidChange, object: self)
            return result
        }
        loadTask = task
        return await task.value
    }

    /// The lists if they've loaded, without waiting.
    public var loadedRuleLists: [WKContentRuleList]? { lists }

    public var status: Status {
        Status(origin: state?.origin, listVersions: state?.listVersions ?? [:],
               ruleCounts: Dictionary(uniqueKeysWithValues: zip(state?.listNames ?? [], state?.ruleCounts ?? [])),
               lastChecked: state?.lastChecked, lastError: state?.lastError ?? loadError)
    }

    private var stateURL: URL { configuration.directory.appendingPathComponent("state.json") }
    private var downloadsDir: URL { configuration.directory.appendingPathComponent("lists", isDirectory: true) }

    /// What the compiled lists depend on besides the list texts. A change means recompiling.
    private var fingerprint: String {
        let names = configuration.sources.map(\.name).joined(separator: ",")
        return "format 1; converter \(ContentBlockerConverterVersion.library); safari \(SafariVersion.autodetect().doubleValue); "
            + "limit \(configuration.maxRulesPerList); sources \(names)"
    }

    private func load() async -> [WKContentRuleList] {
        let saved = readState()
        if let saved, saved.fingerprint == fingerprint, let found = await lookUpAll(saved.identifiers) {
            state = saved
            await removeLists(except: Set(saved.identifiers))
            return found
        }
        // No usable compiled lists: build from the downloaded copies in use, else the snapshot.
        var candidates: [(texts: [(name: String, text: String)], origin: Origin)] = []
        if saved?.origin == .downloaded, let downloaded = readDownloaded() { candidates.append((downloaded, .downloaded)) }
        do {
            candidates.append((try configuration.sources.map { ($0.name, try String(contentsOf: $0.bundled, encoding: .utf8)) }, .bundled))
        } catch {
            loadError = "The bundled filter lists can't be read: \(error)"
        }
        for candidate in candidates {
            do {
                let built = try await buildAndCompile(candidate.texts)
                var next = State(fingerprint: fingerprint, identifiers: built.identifiers, listNames: built.names,
                                 ruleCounts: built.ruleCounts, origin: candidate.origin,
                                 sourceDigest: Self.digest(candidate.texts), listVersions: Self.versions(candidate.texts))
                if candidate.origin == .downloaded {
                    // The same lists as before, recompiled: keep the refresh schedule.
                    next.lastChecked = saved?.lastChecked
                    next.lastAttempt = saved?.lastAttempt
                }
                // If the state can't be saved, the lists still work this launch; the next launch
                // compiles them again.
                try? writeState(next)
                state = next
                loadError = nil
                await removeLists(except: Set(next.identifiers))
                return built.lists
            } catch {
                loadError = "Compiling the \(candidate.origin.rawValue) filter lists failed: \(error)"
            }
        }
        return []
    }

    private func lookUpAll(_ identifiers: [String]) async -> [WKContentRuleList]? {
        guard !identifiers.isEmpty else { return nil }
        var found: [WKContentRuleList] = []
        for id in identifiers {
            guard let list = try? await store.lookUp(identifier: id) else { return nil }
            found.append(list)
        }
        return found
    }

    private struct Built {
        var lists: [WKContentRuleList]
        var identifiers: [String]
        var names: [String]
        var ruleCounts: [Int]
    }

    /// Converts off the main thread, then compiles every list under new identifiers. If any list
    /// fails, the ones already compiled are removed and nothing else changes.
    private func buildAndCompile(_ texts: [(name: String, text: String)]) async throws -> Built {
        let limit = configuration.maxRulesPerList
        let converted = try await Task.detached(priority: .utility) {
            try RuleListBuilder.build(sources: texts, maxRulesPerList: limit)
        }.value
        let generation = "\(Int(configuration.now().timeIntervalSince1970))-\(UUID().uuidString.prefix(8).lowercased())"
        var built = Built(lists: [], identifiers: [], names: [], ruleCounts: [])
        do {
            for list in converted {
                let id = "\(Self.identifierPrefix)\(generation)-\(list.name)"
                built.identifiers.append(id)
                built.lists.append(try await store.compile(identifier: id, json: list.json))
                built.names.append(list.name)
                built.ruleCounts.append(list.ruleCount)
            }
        } catch {
            for id in built.identifiers { try? await store.remove(identifier: id) }
            throw error
        }
        return built
    }

    /// Removes this controller's compiled lists other than `keep`: earlier generations and lists
    /// left by a refresh that didn't finish. Called while loading, before any list of this launch
    /// is attached to a web view, and after a refresh, keeping the lists it replaced.
    private func removeLists(except keep: Set<String>) async {
        for id in await store.identifiers() where id.hasPrefix(Self.identifierPrefix) && !keep.contains(id) {
            try? await store.remove(identifier: id)
        }
    }

    // MARK: Refresh

    /// Downloads the lists if a refresh is due (or `force`), and swaps in the new compiled lists
    /// once they all compile. Concurrent calls share one refresh.
    @discardableResult
    public func refresh(force: Bool = false) async -> RefreshResult {
        if let running = refreshTask {
            let result = await running.task.value
            // "Update now" during an automatic check that found nothing due: run it after.
            if force && !running.forced && result == .notDue { return await refresh(force: true) }
            return result
        }
        refreshCount += 1
        let id = refreshCount
        let task = Task {
            let result = await self.performRefresh(force: force)
            // Cleared here, on the main actor, before any caller waiting on it resumes.
            if self.refreshTask?.id == id { self.refreshTask = nil }
            return result
        }
        refreshTask = (id, force, task)
        return await task.value
    }

    /// Checks hourly (`checkInterval`) whether a refresh is due, starting after `initialDelay`
    /// seconds so a launch isn't slowed.
    public func startAutomaticRefresh(initialDelay: TimeInterval = 60) {
        guard automaticRefresh == nil else { return }
        let interval = configuration.checkInterval
        automaticRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(initialDelay, 0) * 1e9))
            while !Task.isCancelled {
                // Holds the controller only during the refresh, not the sleep; ends once it's gone.
                guard await self?.refresh() != nil else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1e9))
            }
        }
    }

    public func stopAutomaticRefresh() {
        automaticRefresh?.cancel()
        automaticRefresh = nil
    }

    private func performRefresh(force: Bool) async -> RefreshResult {
        let current = await ruleLists()
        let now = configuration.now()
        if !force, !current.isEmpty, let state {
            if let checked = state.lastChecked, now.timeIntervalSince(checked) < configuration.refreshInterval {
                return .notDue
            }
            if state.lastError != nil, let attempt = state.lastAttempt,
               now.timeIntervalSince(attempt) < configuration.retryInterval {
                return .notDue
            }
        }
        do {
            let texts = try await fetchAll()
            let digest = Self.digest(texts)
            if !current.isEmpty, let state, state.sourceDigest == digest {
                recordAttempt(at: now, checked: true, error: nil)
                return .unchanged
            }
            let built = try await buildAndCompile(texts)
            let next = State(fingerprint: fingerprint, identifiers: built.identifiers, listNames: built.names,
                             ruleCounts: built.ruleCounts, origin: .downloaded, sourceDigest: digest,
                             listVersions: Self.versions(texts), lastChecked: now, lastAttempt: now, lastError: nil)
            do {
                // Save the texts before the state that points at their lists: if the app stops in
                // between, the old lists still load and the next refresh compiles these again.
                for source in texts {
                    try DiskFile.write(Data(source.text.utf8), to: downloadsDir.appendingPathComponent("\(source.name).txt"))
                }
                try writeState(next)
            } catch {
                for id in built.identifiers { try? await store.remove(identifier: id) }
                throw error
            }
            let replaced = state?.identifiers ?? []
            state = next
            loadError = nil
            loadFailedAt = nil
            lists = built.lists
            NotificationCenter.default.post(name: Self.listsDidChange, object: self)
            // Observers have re-applied the new lists. Keep the ones just replaced, in case a web
            // view still holds them, and remove older generations so a long session doesn't
            // gather a compiled copy per week.
            await removeLists(except: Set(built.identifiers + replaced))
            return .updated
        } catch {
            let message = "\(error)"
            recordAttempt(at: now, checked: false, error: message)
            return .failed(message)
        }
    }

    enum RefreshError: Error, CustomStringConvertible {
        case notAFilterList(String, Int)
        case http(URL, Int)

        var description: String {
            switch self {
            case let .notAFilterList(name, lines):
                return "The downloaded \(name) isn't a filter list (\(lines) rule lines)."
            case let .http(url, code):
                return "\(url.absoluteString) answered HTTP \(code)."
            }
        }
    }

    /// Downloads every source and checks each is a filter list (off the main thread).
    private func fetchAll() async throws -> [(name: String, text: String)] {
        let fetch = configuration.fetch
        let sources = configuration.sources
        let minimum = configuration.minimumRulesPerSource
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    let text = String(decoding: try await fetch(source.url), as: UTF8.self)
                    let lines = RuleListBuilder.rules(in: text).count
                    guard Self.looksLikeFilterList(text), lines >= minimum else {
                        throw RefreshError.notAFilterList(source.name, lines)
                    }
                    return (index, text)
                }
            }
            var texts = [String](repeating: "", count: sources.count)
            for try await (index, text) in group { texts[index] = text }
            return zip(sources, texts).map { ($0.name, $1) }
        }
    }

    /// The default fetch: a plain GET that ignores caches and rejects non-2xx answers.
    public nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RefreshError.http(url, http.statusCode)
        }
        return data
    }

    private func recordAttempt(at date: Date, checked: Bool, error: String?) {
        guard var next = state else { return }
        next.lastAttempt = date
        if checked { next.lastChecked = date }
        next.lastError = error
        try? writeState(next)
        state = next
    }

    nonisolated static func looksLikeFilterList(_ text: String) -> Bool {
        let firstLine = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }.prefix { $0 != "\n" && $0 != "\r" }
        return firstLine.hasPrefix("[Adblock")
    }

    static func digest(_ texts: [(name: String, text: String)]) -> String {
        DiskFile.sha256(texts.map { "\($0.name)\n\(DiskFile.sha256($0.text))" }.joined(separator: "\n"))
    }

    static func versions(_ texts: [(name: String, text: String)]) -> [String: String] {
        var out: [String: String] = [:]
        for source in texts {
            var found: String?
            source.text.enumerateLines { line, stop in
                if line.hasPrefix("! Version:") {
                    found = line.dropFirst("! Version:".count).trimmingCharacters(in: .whitespaces)
                    stop = true
                } else if !line.hasPrefix("!") && !line.hasPrefix("[") {
                    stop = true
                }
            }
            if let found { out[source.name] = found }
        }
        return out
    }

    private func readDownloaded() -> [(name: String, text: String)]? {
        var texts: [(name: String, text: String)] = []
        for source in configuration.sources {
            guard let text = try? String(contentsOf: downloadsDir.appendingPathComponent("\(source.name).txt"), encoding: .utf8)
            else { return nil }
            texts.append((source.name, text))
        }
        return texts
    }

    // MARK: State

    struct State: Codable {
        var version = 1
        var fingerprint: String
        /// The compiled lists in use, in attach order.
        var identifiers: [String]
        var listNames: [String]
        var ruleCounts: [Int]
        var origin: Origin
        /// Digest of the list texts the compiled lists came from.
        var sourceDigest: String
        var listVersions: [String: String]
        /// Last successful check for new lists (downloaded, whether or not they changed).
        var lastChecked: Date?
        /// Last refresh attempt, successful or not.
        var lastAttempt: Date?
        var lastError: String?
    }

    private func readState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    private func writeState(_ state: State) throws {
        try DiskFile.write(try JSONEncoder.sorted.encode(state), to: stateURL)
    }

    // MARK: Allowlist

    /// Whether blocking is on for the host's site. False only for sites on the allowlist.
    public func isBlocked(host: String) -> Bool {
        !allowlist.contains(host: host)
    }

    public func isBlocked(url: URL) -> Bool {
        guard let host = url.host else { return true }
        return isBlocked(host: host)
    }

    /// Turns blocking off (`allowed` true) or back on for the host's site, saves the allowlist,
    /// and posts `allowlistDidChange`. Re-apply and reload the site's web views afterwards. If
    /// saving fails, nothing changes and the error is thrown.
    public func setAllowed(host: String, _ allowed: Bool) throws {
        var next = allowlist
        guard try next.set(host: host, allowed: allowed) else { return }
        allowlist = next
        NotificationCenter.default.post(name: Self.allowlistDidChange, object: self,
                                        userInfo: ["site": Allowlist.site(for: host) ?? host])
    }

    /// Sites on the allowlist, sorted.
    public var allowedSites: [String] { allowlist.sites.sorted() }

    /// The site (registrable domain) a host's allowlist entry is kept under.
    public nonisolated static func site(for host: String) -> String? { Allowlist.site(for: host) }

    // MARK: Applying to web views

    /// Attaches the rule lists to `controller` for a page on `host`, or takes them off if the
    /// host's site is allowed. Waits for the lists on a launch's first call. A nil host (a blank
    /// page, a file) is blocked. Takes effect for loads that start afterwards, so call it before
    /// a navigation's request goes out (see INTEGRATION.md).
    public func apply(to controller: WKUserContentController, host: String?) async {
        nextTicket += 1
        let ticket = nextTicket
        applyTickets.setObject(NSNumber(value: ticket), forKey: controller)
        let current = await ruleLists()
        // A later call for this controller has already applied (or will); it wins.
        guard applyTickets.object(forKey: controller)?.intValue == ticket else { return }
        attach(current, to: controller, host: host)
    }

    /// `apply(to:host:)` without waiting: returns false, and changes nothing, if the lists
    /// haven't loaded yet. It doesn't cancel an `apply` still waiting for the lists, since that
    /// one is for a navigation in progress.
    @discardableResult
    public func applyIfLoaded(to controller: WKUserContentController, host: String?) -> Bool {
        guard let lists else { return false }
        attach(lists, to: controller, host: host)
        return true
    }

    private func attach(_ current: [WKContentRuleList], to controller: WKUserContentController, host: String?) {
        let blocked = host.map(isBlocked(host:)) ?? true
        let wanted = blocked ? current : []
        let previous = attached.object(forKey: controller) as? [WKContentRuleList] ?? []
        // Already attached: leave them, so the page is never briefly without its lists.
        if previous.map(\.identifier) == wanted.map(\.identifier) { return }
        for list in previous { controller.remove(list) }
        for list in wanted { controller.add(list) }
        attached.setObject(wanted as NSArray, forKey: controller)
    }
}
