import Foundation
@testable import SignInSync
import WebKit
import XCTest

/// Randomized sign-ins, rotations and sign-outs across the fixture's five spaces, on shared,
/// separate and "Not shared" accounts, interleaved in time. Seeded, so a failure replays:
/// `SIGNINSYNC_FUZZ_SEED=<seed> SIGNINSYNC_FUZZ_ROUNDS=<n> swift test --filter FuzzTests`.
///
/// Every cookie value names the account it belongs to (`<account>.<n>`), so isolation can be
/// checked at any moment, not only once things settle:
/// - after every step, no space holds a tracked cookie of an account it isn't bound to, and a
///   cookie no provider tracks never leaves the space that set it;
/// - after every round, every space bound to an account holds exactly the vault's cookies for it;
/// - after a quiet round (all its steps within the 0.4 s sync debounce, so no sync write races a
///   page's write), the result is the newest change to each cookie.
@MainActor
final class FuzzTests: XCTestCase {
    private var fx: Fixture!

    override func setUp() async throws {
        fx = try Fixture()
    }

    override func tearDown() async throws {
        // WebKit removes a store only once nothing holds it.
        stores = [:]
        await fx.tearDown()
        fx = nil
    }

    /// The cookies each provider's sign-in is made of here (names the providers track).
    private static let cookies: [String: [(name: String, domain: String, secure: Bool, session: Bool)]] = [
        "google": [("SID", ".google.com", false, false), ("HSID", ".google.com", false, false),
                   ("__Secure-1PSID", ".google.com", true, false), ("LSID", "accounts.google.com", true, true)],
        "microsoft": [("ESTSAUTH", "login.microsoftonline.com", true, true),
                      ("ESTSAUTHPERSISTENT", "login.microsoftonline.com", true, false),
                      ("buid", "login.microsoftonline.com", true, false)],
        "github": [("user_session", "github.com", true, false), ("logged_in", ".github.com", true, false)],
    ]
    /// Cookies no provider tracks; they must stay in the space that set them.
    private static let untracked: [(name: String, domain: String)] = [("NID", ".google.com"), ("site", "example.com")]

    private let spaceIDs = ["contoso", "fabrikam", "contoso-b", "personal", "newtro"]
    private var stores: [String: WKWebsiteDataStore] = [:]
    private var counter = 0

    func testRandomSignInsConvergeAndStayIsolated() async throws {
        let env = ProcessInfo.processInfo.environment
        let seed = env["SIGNINSYNC_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0x15_A1_7F
        let rounds = env["SIGNINSYNC_FUZZ_ROUNDS"].flatMap { Int($0) } ?? 24
        var rng = SplitMix64(seed: seed)
        print("FUZZ seed \(seed), \(rounds) rounds")

        for id in spaceIDs { stores[id] = await fx.attach(id) }
        await quiet()

        var steps = 0, quietRounds = 0
        for round in 0..<rounds {
            var isQuiet = rng.next() % 3 != 0
            // The model: each account's cookies as the newest change leaves them.
            var model = vaultState()
            let count = isQuiet ? 2 + Int(rng.next() % 2) : 2 + Int(rng.next() % 5)
            let started = Date()
            for index in 0..<count {
                let what = await step(&rng, model: &model)
                steps += 1
                try await assertIsolated("round \(round), after \(what)")
                guard index < count - 1 else { break }
                let gap = isQuiet ? 40 + rng.next() % 40 : rng.next() % 700
                try await Task.sleep(nanoseconds: gap * 1_000_000)
            }
            // A quiet round that took long enough for a sync to start partway isn't quiet: a sync
            // write can then race a page's write, which WebKit gives no way to prevent.
            if isQuiet, Date().timeIntervalSince(started) > 0.33 { isQuiet = false }
            await quiet()
            try await assertConverged("round \(round)")
            if isQuiet {
                quietRounds += 1
                let got = vaultState()
                for account in Set(model.keys).union(got.keys) where got[account] ?? [:] != model[account] ?? [:] {
                    XCTFail("round \(round): \(account) should end as the newest changes \((model[account] ?? [:]).sorted { $0.key < $1.key }), got \((got[account] ?? [:]).sorted { $0.key < $1.key })")
                }
            }
            try await assertIsolated("round \(round), settled")
        }

        // A relaunch seeds every space from the saved vault: still converged and isolated.
        let before = vaultState()
        await fx.relaunch()
        for id in spaceIDs { stores[id] = await fx.attach(id) }
        await quiet()
        XCTAssertEqual(vaultState(), before, "the vault on disk is what the last run had")
        try await assertConverged("after relaunch")
        try await assertIsolated("after relaunch")
        print("FUZZ done: \(rounds) rounds (\(quietRounds) quiet), \(steps) steps")
    }

    // MARK: Steps

    /// One random page action in a random space. Updates `model` for accounts the space shares.
    private func step(_ rng: inout SplitMix64, model: inout [String: [String: String]]) async -> String {
        let space = spaceIDs[Int(rng.next() % UInt64(spaceIDs.count))]
        let store = stores[space]!
        let providers = Self.cookies.keys.sorted()
        let provider = providers[Int(rng.next() % UInt64(providers.count))]
        let account = owner(space, provider)
        let specs = Self.cookies[provider]!
        counter += 1
        let shared = !account.hasPrefix("local-")
        func set(_ spec: (name: String, domain: String, secure: Bool, session: Bool)) async {
            let value = "\(account).\(counter)"
            let made = cookie(spec.name, value, spec.domain, expires: spec.session ? nil : Date().addingTimeInterval(3600),
                              secure: spec.secure, httpOnly: true)
            await store.httpCookieStore.setCookie(made)
            if shared { model[account, default: [:]][CookieRecord(made).key] = value }
        }
        switch rng.next() % 10 {
        case 0..<3:
            for spec in specs { await set(spec) }
            return "sign-in to \(provider) in \(space)"
        case 3..<7:
            await set(specs[Int(rng.next() % UInt64(specs.count))])
            return "rotation of a \(provider) cookie in \(space)"
        case 7..<9:
            for c in await store.httpCookieStore.allCookies() where specs.contains(where: { $0.name == c.name }) && ownedBy(provider, c) {
                await store.httpCookieStore.deleteCookie(c)
                if shared { model[account]?[CookieRecord(c).key] = nil }
            }
            return "sign-out of \(provider) in \(space)"
        default:
            let spec = Self.untracked[Int(rng.next() % UInt64(Self.untracked.count))]
            await store.httpCookieStore.setCookie(cookie(spec.name, "noise-\(space).\(counter)", spec.domain,
                                                         expires: Date().addingTimeInterval(3600)))
            return "a site cookie in \(space)"
        }
    }

    // MARK: Invariants

    /// The account a space uses for a provider, or `local-<space>` when it isn't shared.
    private func owner(_ space: String, _ provider: String) -> String {
        fx.config.accountID(in: fx.space(space), for: provider) ?? "local-\(space)"
    }

    private func ownedBy(_ provider: String, _ cookie: HTTPCookie) -> Bool {
        fx.config.provider(provider)?.tracks(cookie) == true
    }

    /// No space holds another account's sign-in cookie, and site cookies stay where they were set.
    private func assertIsolated(_ when: String) async throws {
        for space in spaceIDs {
            for c in await stores[space]!.httpCookieStore.allCookies() {
                if let provider = fx.config.providers.first(where: { $0.tracks(c) }) {
                    let account = owner(space, provider.id)
                    XCTAssertTrue(c.value.hasPrefix(account + "."),
                                  "\(when): \(space) (\(account)) holds \(c.name)=\(c.value)")
                } else if Self.untracked.contains(where: { $0.name == c.name }) {
                    XCTAssertTrue(c.value.hasPrefix("noise-\(space)."), "\(when): \(space) holds \(c.name)=\(c.value)")
                }
            }
        }
    }

    /// Every space bound to an account holds exactly the vault's cookies for it.
    private func assertConverged(_ when: String) async throws {
        let vault = vaultState()
        for space in spaceIDs {
            for provider in fx.config.providers where Self.cookies[provider.id] != nil {
                let account = owner(space, provider.id)
                guard !account.hasPrefix("local-") else { continue }
                var held: [String: String] = [:]
                for c in await stores[space]!.httpCookieStore.allCookies() where provider.tracks(c) {
                    held[CookieRecord(c).key] = c.value
                }
                XCTAssertEqual(held, vault[account] ?? [:], "\(when): \(space) matches the vault for \(account)")
            }
        }
    }

    /// Account id → cookie key → value, from the vault.
    private func vaultState() -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for account in fx.config.accounts {
            guard let provider = fx.config.provider(account.providerID) else { continue }
            let records = (fx.vault.records(for: account.id) ?? []).filter { provider.tracks(record: $0) && !$0.isExpired }
            if !records.isEmpty { out[account.id] = Dictionary(records.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a }) }
        }
        return out
    }

    /// Waits until the sync has nothing left to do and stays that way (WebKit's notifications for
    /// the sync's own writes arrive a moment after them).
    private func quiet() async {
        var calm = 0
        for _ in 0..<200 where calm < 3 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            calm = fx.sync.isIdle ? calm + 1 : 0
        }
        XCTAssertEqual(calm, 3, "the sync went quiet")
    }
}

/// A small seeded generator, so a failing run can be replayed.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
