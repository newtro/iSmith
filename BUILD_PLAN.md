# iSmith v1 Build Plan

v1 replaces Brave as Scott's daily browser. It builds on DESIGN.md and the proven sign-in engine in
`spike/`. Delivered as one release; the phases below are the internal order of work, each with its
own tests and review gate.

**Done means:** Scott sets iSmith as his default browser, uses it all day across Contoso, Fabrikam
Point, Personal and Newtro Studios, and no longer opens Brave. Concretely, every item in the
acceptance checklist at the end passes on his real accounts.

**Size:** large. Roughly 12k–16k lines of Swift across nine phases, built with parallel agents where
phases are independent. Password capture and autofill and the tab strip's drag-and-drop are the
biggest single pieces.

## Decisions (interview, 2026-10-02)

| Decision | Choice |
|---|---|
| Codebase | New Xcode app. The spike's sync engine, vault and config move into a Swift package with real unit tests. `spike/` stays as a reference. |
| v1 scope | Space rail, top tabs with groups, tinted chrome; browser basics; default browser with link routing; ad and tracker blocking; own password store; Brave import. |
| Not in v1 | Agent panel, MCP server, page index, setup sync across Macs, space templates, archiving. |
| Delivery | Whole v1 at once. |
| Apple Developer account | Yes. Developer ID signing, notarization, and the passkey entitlement if Apple grants it. |
| Install and updates | Signed and notarized app in /Applications, auto-updated with Sparkle from GitHub Releases. |
| Passwords | iSmith's own encrypted password store with autofill. Passwords are imported directly from Brave. |
| Extensions | No Chrome extensions (WKWebView can't run them). Built-in ad and tracker blocking replaces Brave Shields. |
| Import from Brave | Bookmarks and passwords. |
| After v1 | Built-in agent panel first, then the MCP server, then the page index. |

### Defaults I chose (change any of them by saying so)

- **Passwords are global, not per space.** A login for a site autofills in any space. Sign-in
  sessions are already shared, so per-space passwords would add friction for no gain.
- **Bookmarks belong to spaces.** Brave bookmarks import into a space you pick. A bookmark can be
  moved or copied to another space.
- **History is per space.** Address-bar suggestions come from the current space first, then the
  other spaces.
- **Multiple windows.** Each window shows one space at a time. A space's tabs belong to the window
  they're in.
- **Tab hibernation and Keep alive.** A background tab is unloaded after 30 minutes and reloads
  when selected, to keep memory down. A tab marked **Keep alive** (right-click, or automatic for
  Outlook, Teams and Gmail) is never unloaded or throttled (`inactiveSchedulingPolicy = .none`), so
  mail counts update and Teams calls ring.
- **Session restore always on.** Windows, spaces, tabs, groups and each tab's back/forward history
  come back after a quit or crash.
- **Minimum macOS 14**, as in DESIGN.md. It has every API used here (data stores per identifier,
  `interactionState`, find, `WKDownload`).

## Architecture

```
iSmith/
  project.yml                 XcodeGen project (app + test targets)
  App/                        SwiftUI + AppKit app: windows, rail, tab strip, panels
  Packages/
    SignInSync/               Providers, accounts, spaces config; vault; cookie sync; migration
    BrowserData/              SQLite (GRDB): history, bookmarks, sessions, downloads, passwords
    Passwords/                Crypto, capture and autofill scripts, Brave password import
    Blocking/                 EasyList/EasyPrivacy → WebKit content-rule lists, per-site toggle
    Routing/                  URL-rule engine, rule learning
    BraveImport/              Brave profile discovery, bookmarks and passwords readers
  Tools/                      release.sh (sign, notarize, appcast), list-update scripts
  spike/                      the proven prototype (reference only)
```

- **Storage**: `~/Library/Application Support/iSmith/`. Config is JSON, the same model as the spike.
  Everything else is SQLite through GRDB.
- **Secrets**: the vault (provider sessions) and the password store are encrypted with AES-GCM. The
  key is a 256-bit key in the file-based login Keychain (not synced), tied to the app's signature,
  and unlocks with the Mac login (see P0 findings). The data-protection Keychain would need a
  Developer ID provisioning profile in the app and the XCTest host; it can come later with the
  passkey entitlement.
- **WebKit**: one `WKWebsiteDataStore(forIdentifier:)` per space. A single shared
  `WKProcessPool` isn't needed (it's deprecated). Content-rule lists and user scripts are attached
  per web view.
- **Carried over from the spike**: the Safari user agent (Google's sign-in needs it), and
  `isInspectable` in debug builds.
- **Coming from the spike**: on first run, iSmith imports the spike's `config.json` and
  `vault.json`. Your sign-in sessions carry over. Each site's own cookies don't, but sites sign in
  silently through the shared session (the account picker may appear once per app).

## P0 findings (2026-10-02)

- **Apple Developer membership is Individual.** The passkey entitlement will be requested, but v1
  plans on passwords and Authenticator only.
- **Signing**: Apple Development (team 232A77467G) is used for daily builds. The Developer ID
  Application certificate is created in P7; it's only needed for releases.
- **Keychain**: the vault and password keys use the file-based login Keychain, tied to the app's
  signature, so no provisioning profile is needed. The data-protection Keychain can come later
  along with the passkey entitlement.
- **Teams/Meet feasibility** (`spike/Spike/FeasibilityProbe.swift`, run inside an app bundle that
  declares camera and microphone usage):
  - Camera and microphone: the API exists, and permission requests reach the app.
  - `getDisplayMedia`: present. It needs a real click; a live Teams share is checklist item 8.
  - Web notifications: present, but `requestPermission()` always returns "denied". The P2
    notification workaround is required.
  - `inactiveSchedulingPolicy = .none` is available for Keep-alive tabs.

### Foundations built (2026-10-02)

- **Project**: `project.yml` (XcodeGen) produces the `iSmith` app (`com.scottsmith.ismith`,
  macOS 14) and an `iSmithTests` bundle hosted by the app. Signing is automatic with team
  232A77467G and the Apple Development certificate. Hardened runtime is on, with the camera,
  audio-input and location entitlements and their Info.plist usage strings. No sandbox.
  `make build`, `make test` and `make run` wrap XcodeGen, `swift test` and `xcodebuild`.
- **Packages**: only `SignInSync` exists so far. The other five packages (BrowserData, Passwords,
  Blocking, Routing, BraveImport) are created in the phases that fill them; an empty package now
  would only be scaffolding. `SignInSync` holds `Config`, `Vault`, `CookieSync`, the definitions,
  `SpikeImport`, and a new `SpaceManager` for the space and account operations that used to sit in
  the spike's `BrowserState`. Storage paths and the first-run layout are injected, so the core
  has no self-test special cases.
- **Tests run under `swift test`, not in a test host.** `WKWebsiteDataStore(forIdentifier:)`
  works inside the plain `xctest` process: stores open, keep cookies, and can be removed. The one
  requirement is that every reference to a store is released before
  `WKWebsiteDataStore.remove(forIdentifier:)`, or WebKit answers "Data store is in use". The test
  fixture detaches the sync and retries removal briefly. The spike's 49 checks became 13 XCTest
  cases in three suites:
  - `SharingTests`: 3 tests, 18 checks.
  - `RelaunchTests`: 1 test, 3 checks, plus a fourth check: the space that lost a session
    cookie gets it back. The relaunch is new `Vault`, `Config` and `CookieSync` instances on the
    same files. WebKit keeps session cookies for the life of a process, so the test deletes the
    cookie from the target stores and asserts they lack it before reopening.
  - `ConfigTests`: 9 tests, 28 checks.

  Each test uses its own temp folder and new store UUIDs, and deletes its stores when it ends.
  The settle waits are the spike's: 3 s per sync, 2 s after the first opens. `VaultTests` adds 11
  tests: encryption round trip, a wrong key, a missing key, an unreadable Keychain, the Keychain
  key store, two first launches saving a key at once, and the spike import (including waiting for
  a vault that can save). `SpaceManagerTests` adds 2: deleting a space removes its WebKit store,
  and removing accounts and providers deletes their saved sign-ins. `iSmithTests` (app-hosted, 5 tests) checks the Keychain under
  the app's own signature, first-launch import through `BrowserState`, the address bar and the
  user agent.
- **Vault**: AES-GCM through CryptoKit. The file is `{"version": 1, "combined": "<base64 sealed
  box>"}`, mode 0600, in a 0700 folder, written atomically. The key is 256-bit, stored base64 as a
  generic password in the file-based login Keychain (service `com.scottsmith.ismith.vault-key`,
  account `vault`, `kSecUseDataProtectionKeychain` false). How failures are handled:
  - A file that won't decrypt, or a key that's missing, is first copied to
    `vault.unreadable-<time>.json`, and the vault starts empty. As with `config.json`, new saves
    go to `vault.json` only once that copy exists.
  - If the Keychain can't be read at all (locked, or access denied), nothing is written and no key
    is replaced, so the old vault opens again once the Keychain does. The app stops at launch with
    "Try Again" or "Quit" rather than syncing on a vault it can't save, because the next launch
    would roll back any sign-in or sign-out made in between.
  - An existing Keychain key is never replaced. If another launch saved one first, it's used.
- **Spike import**: on first launch (no `iSmith/config.json`, but `iSmithSpike/config.json`
  exists), the spike's plaintext `vault.json` goes into the encrypted vault, then its `config.json`
  is copied and loaded with the normal migration rules. The config is copied only once the
  sign-ins are saved, so a launch that can't save doesn't count as a finished import. The spike's
  files are only read.

  What doesn't come over: the spike's WebKit stores, which are kept per app under
  `~/Library/WebKit/<bundle id>`. That means each site's own sessions (Outlook, Etsy, Azure
  DevOps), and any provider sign-in a space kept "Not shared". Shared sign-ins come from the vault,
  so sites sign in again silently, with the account picker once per site. A space set to "Not
  shared" needs one sign-in.

  A dry run
  against the real spike data imported 5 spaces and 4 vault entries (27 cookies), with Microsoft
  (shared), Microsoft: Fabrikam and Google holding sessions. The spike's files were unchanged
  afterwards (checksums matched). `ISMITH_DATA_DIR` points a development run at another folder and
  skips the import.
- **Sparkle 2.10.0** (exact pin) through SPM. `SPUStandardUpdaterController` starts at launch, and
  "Check for Updates…" is in the app menu. `SUFeedURL` is
  `https://raw.githubusercontent.com/newtro/iSmith-releases/main/appcast.xml`, and
  `SUEnableAutomaticChecks` stays NO until P7. The EdDSA key came from
  `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`, run with no options. That
  saved the private key to the login Keychain (service `https://sparkle-project.org`, account
  `ed25519`), and the public key went into Info.plist: `SUPublicEDKey` =
  `Ezl8lB6Z6JnAQ08oLRWy8uOWsNpPxzlNEV4d5+xFyEU=`. Back up the private key with
  `generate_keys -x <file>`: losing it means shipped apps can't verify new updates.
- **Deleting a space** retries WebKit's store removal for up to 30 seconds while the closed
  tabs' web views go away. Before this, a store still in use was left on disk.
- **Differs from the plan**:
  - Debug builds use Apple Development signing with no provisioning profile. Developer ID and
    notarization wait for P7.
  - Keychain calls work in the signed app and in its test host. A smoke run of the app on a
    scratch data folder created the key and an encrypted vault, and quit cleanly through the
    vault flush.
  - The data-protection Keychain and the Developer ID provisioning profile aren't used (see
    Keychain above).

## P1 findings (2026-10-03)

- **AppKit runs the app.** `Launcher` starts an `NSApplication` with `AppDelegate`; there's no
  SwiftUI `App` scene. Browser windows are `NSWindow`s made by `BrowserWindowController` from
  `BrowserState`'s window list, so ⌘N, session restore and "move tab to new window" all go
  through one path and SwiftUI's own window restoration can't fight it. The menu bar is built in
  `MainMenu.swift`, with the standard Edit items so copy and paste work in pages and fields.
  SwiftUI draws each window's content (rail, toolbar, page) and the Accounts window (⌘, or the
  rail's gear; it replaced the in-window panel).
- **The tab strip is AppKit** (`TabStripView.swift`): an `NSScrollView` of tab and group-label
  views, laid out by hand. Tabs shrink from 200 to 110 points, then the strip scrolls (a vertical
  wheel scrolls it sideways). Drags use `NSDraggingSession` with an in-app pasteboard type
  (`com.scottsmith.ismith.tab`, declared in Info.plist); the drag carries only an id, and drop
  targets read `BrowserState.drag`, so nothing from outside the app can be dropped as a tab, and
  a tab dropped on a page doesn't navigate it. The rail (SwiftUI) accepts the same type. A tab
  dropped outside every iSmith window opens in a new window there. Drops in the strip: the left
  or right half of a tab places it before or after that tab in that tab's group; the left 30% of
  an expanded group label drops before the group, the rest into it; a collapsed group is one item.
- **Tab model**: `TabLayout` (pure, unit-tested) holds the order, group membership and selection
  for one space in one window. A group is always one contiguous run and is dropped when it has no
  tabs; every change re-normalizes. Group colors are a fixed palette of nine (Chrome's), picked
  from a dropdown in the group editor or the label's Color menu.
- **Session file**: groups and their tabs persist in a new `session.json` (windows → spaces →
  groups → tabs with URL, title and Keep alive setting), not in config. Config is what a space
  is; the session is what's open in it and changes on every navigation. P1 restores it at launch,
  loading only each window's visible tab and the Keep alive tabs. P2 adds each tab's back/forward
  history (`interactionState`) and crash safety to the same records. It's saved at most a second
  after a change (a page retitling itself every second can't postpone it) and at quit; AppKit
  closes every window while quitting, so from then on closing windows doesn't change it.
- **Closing windows**: a closed window (all its spaces' tabs) goes on a stack of five. "Reopen
  Closed Window" in the File menu, ⌘⇧T when the space has no closed tab, and ⌘N or the Dock with
  no window open bring it back. The last window's tabs are also kept for the next launch. ⌘W in an
  empty space closes the window only if none of its other spaces has tabs.
- **Rail order** is saved in config (`Config.moveSpace`, the only SignInSync change besides
  making `SecureFile` public for the session file).
- **Keep alive**: `inactiveSchedulingPolicy` is read when a web view is created, so every web
  view gets its own `WKPreferences` (WebKit shares a configuration's preferences with popups) and
  a policy change means a new web view, which keeps the tab's history through
  `interactionState`. When it happens:
  - creating a tab, restoring one, or typing an address: the policy for that URL is used from
    the start;
  - a link or redirect (GET) to Outlook, Teams or Gmail in an ordinary tab: the navigation is
    cancelled and the same request loads in a new keep-alive web view;
  - a form post that lands there (can't be replayed): the new web view is made once the tab is in
    the background;
  - the context menu: at once.
  Losing Keep alive (navigating away from Outlook) isn't applied to a live tab, so a page isn't
  reloaded just to be throttled; it applies the next time the tab loads. A popup and the tab that
  opened it are never rebuilt automatically while both are open (a sign-in popup posts back to its
  opener), and closing a popup that was showing goes back to its opener.
- **Account switches**: a web view made for a space while its accounts are switching waits for
  the switch, so it can't load the old account and write it back after the wipe; only pages still
  showing in that space reload afterwards.
- **Unread badges** come from leading "(N)" in titles (Outlook, Teams) and Gmail's
  "Inbox (N) - … - Gmail". A space's badge adds up its tabs in every window, counting identical
  titles once, and isn't shown for the space the window is on.
- **Shortcuts**: all are menu items. ⌃Tab, ⌃⇧Tab, ⌘⇧] and ⌘⇧[ are also caught by a local key
  monitor before the page sees them. ⌘W with no tab in the space closes the window; in the
  Accounts window it closes that window.
- **Smoke test** (scratch `ISMITH_DATA_DIR`, four spaces, a seeded session), driven through the
  accessibility API by process id: restore with groups and a collapsed group; only the selected
  and Keep alive tabs loaded; new tab and address bar; typing `outlook.office.com` rebuilt the tab
  with keep-alive on; a meta-refresh to `teams.microsoft.com` was cancelled and reloaded
  keep-alive; group from the context menu, named in its editor; collapse; move to another space
  (reloaded in that space's store); space switch with tint and badges; close and reopen in place;
  next tab; move to a new window; Accounts window; new-space sheet; quit saved the session.
  Real mouse drags weren't driven by the test (the drop logic is unit-tested), and keyboard
  shortcuts were checked as menu items, not as keystrokes.
- **Tests**: `make test` runs 27 SignInSync tests (one new: the rail order survives a relaunch)
  and 30 app-hosted tests: `TabLayoutTests` (13: order, groups as one run, drops into and out of
  groups, collapse moving the selection, repair of saved records, reopening into a group whose
  neighbor moved, a stale selection), `SessionTests` (6: round trip,
  owner-only file, unreadable file kept aside, older records, pruning deleted spaces, rail order
  through the browser), `PageRulesTests` (6: badge parsing and totals, keep-alive hosts, a tab's
  own setting, the scheduling policy on its own preferences) and the 5 P0 app tests.
- **Deferred from review** (low; not hit in daily use as built):
  - ⌘⇧T falls back to reopening a closed window when the current space has no closed tab, even if
    a tab was just closed in another space (Chrome-like; a single time-ordered list would fix it).
  - Keep alive isn't removed from a live tab that navigates away from Outlook; it applies the next
    time the tab loads (by design, see above). P2's hibernation should re-check it.
  - Real mouse drags and keystrokes weren't driven by the smoke test (see above); they're part of
    the P1 acceptance run.
- **Seen during the smoke test**: WebKit shows its own "Allow related Microsoft websites to share
  cookies?" prompt (Storage Access for related domains) during Microsoft sign-in. It's WebKit's
  UI, shown over the window; P2's prompts work should check it doesn't block real sign-ins.

## Phases

Each phase ends with its tests green, an adversarial review (fix critical and high; at most two
rounds), and a commit to `main`.

### P0. Foundations (M)

- XcodeGen project, the app target, and the six packages. `make test` runs every package and app
  test.
- Port `CookieSync`, `Vault` and `Config` into `SignInSync`. Turn the spike's 49 self-test checks
  into XCTest cases that run inside a test host app, because WebKit stores need an app process.
- Encrypted vault (AES-GCM with a Keychain key). Migrate the spike's plaintext vault.
- **Signing and entitlements**:
  - Developer ID signing with hardened runtime, and a Developer ID provisioning profile
    (needed for the data-protection Keychain and restricted entitlements).
  - Hardened-runtime entitlements: camera, audio input and location
    (`com.apple.security.device.camera`, `device.audio-input`, `personal-information.location`),
    plus their Info.plist usage strings.
  - Sparkle 2 wired up, with an EdDSA key generated and kept in the Keychain.
- **Passkeys, started on day one because Apple takes time**: on macOS the entitlement is
  `com.apple.developer.web-browser.public-key-credential` only. (`com.apple.developer.web-browser`
  is iOS-only.) First confirm whether your membership is Individual or Organization, because
  reports say individual memberships can't get it. Then request it, and call
  `ASAuthorizationWebBrowserPublicKeyCredentialManager.requestAuthorizationForPublicKeyCredentials`
  at runtime.
- **Teams and Meet feasibility spike**:
  - camera, microphone and screen sharing (`getDisplayMedia`) in WKWebView;
  - web notifications;
  - a call ringing in a background tab.

  Screen sharing in WKWebView is unproven. If it fails, the fallback is "Open this call in
  Safari", and that goes into the plan before P2 starts.

Acceptance: every ported sync test passes; the app launches signed with its provisioning profile;
Keychain calls work in the app and in the test host; the spike's sign-ins load; the feasibility
spike's results are written into this plan.

### P1. Windows, spaces and tabs (L)

- **Space rail**: icons, unread badges from tab titles, drag to reorder, right-click to edit or
  delete, "+" for a new space, ⌘1–9.
- **Top tab strip** for the current space:
  - create, rename, color and collapse tab groups;
  - drag tabs within the strip, into groups, and to another space (the tab reloads under that
    space's sign-ins);
  - close buttons, a "+" button and overflow scrolling.
- **Keep alive** per tab, as described in Decisions.
- **Tinted chrome** that fades to the space color. Account chips show only the space's exceptions.
- The space editor and Accounts panel from the spike, restyled.
- **Multiple windows** (⌘N), and moving a tab to a new window.
- **Shortcuts**: ⌘T, ⌘W, ⌘⇧T (reopen closed tab), ⌘L, ⌃Tab/⌃⇧Tab, ⌘⇧[ and ⌘⇧], ⌘R, ⌘[ and ⌘].

Acceptance: your current Brave tab setup is recreated across four spaces; every action in the
shortcut list above works from the keyboard; dragging a tab to another space reloads it signed in
as that space.

### P2. Browser basics (L)

- **Session restore**: windows, spaces, tabs, groups and back/forward history, using
  `interactionState`. Also after a crash.
- **History**: per space, with a search page (⌘Y).
- **Address bar**: suggestions from history, bookmarks and open tabs; search through a chosen
  engine; inline autocomplete.
- **Bookmarks**: a bar, a menu and a manager.
- **Downloads**: `WKDownload`, a downloads panel, and saving to ~/Downloads with a progress badge.
  Downloaded files are quarantined (`LSFileQuarantineEnabled`), so Gatekeeper still checks
  downloaded apps.
- **Viewing**: find in page (⌘F), zoom per site (⌘+ and ⌘−), print (⌘P), PDFs inline,
  fullscreen video (`isElementFullscreenEnabled`), picture-in-picture.
- **Notifications**: a user script stands in for the web `Notification` API and hands alerts to
  macOS notifications, which click through to the tab. Permission is per site.
- **App links**: `msteams:`, `ms-word:`, `mailto:`, `zoommtg:` and similar open the matching app
  after one "Open in Teams?" prompt. The answer is remembered per scheme. (The spike drops these
  links.)
- **Security pages**: HTTP authentication, client certificates, and certificate-error pages.
- **Prompts**: file uploads; camera, microphone and location permission prompts per site; JS
  alerts, confirms and prompts.
- **Context menu**: "Open link in new tab", "Open in space ▸", copy link, save image.
- **Crash recovery**: when a web content process dies, the tab shows a reload state.
- **Tab hibernation**, as described in Decisions. Restore loads tabs lazily: only the visible tab
  loads at launch.

Acceptance:
- Every item in this phase works on Outlook, Teams (including a call and a notification), Azure
  DevOps, the Azure portal, SharePoint and Loop embeds, Gmail, Etsy and GitHub.
- Embeds that rely on third-party cookies work under WebKit's tracking prevention, or a per-site
  exception is added.

#### P2 notes (2026-10-03)

Built and tested on local fixtures. The acceptance run on Scott's real sites (Outlook, Teams with
a call and a notification, Azure DevOps, the Azure portal, SharePoint and Loop, Gmail, Etsy,
GitHub) is still to do; it needs his accounts.

- **Dev isolation (done first)**: Debug builds are "iSmith Dev", bundle id
  `com.scottsmith.ismith.debug`, with their own data folder (`~/Library/Application Support/iSmith
  Dev`; `ISMITH_DATA_DIR` still overrides), WebKit stores, notification settings, drag types and
  Keychain items (`<bundle id>.vault-key`, `.passwords-key`, from `AppIdentity`). Debug never
  imports the spike or starts Sparkle. Release stays `com.scottsmith.ismith`. `make install`
  builds Release and installs `/Applications/iSmith.app` (it refuses while iSmith runs). A side
  effect: `xcodebuild test` now terminates only "iSmith Dev"; before, it would quit the installed
  app, which shared the bundle id. When P4 wires in the Passwords package, it must be given
  `AppIdentity.passwordsKeyService` and the app's data folder (its defaults are the Release ones).
- **Session restore**: each tab's back/forward history is WebKit's `interactionState` (`Data`).
  It can hold form posts (a sign-in's code or password), so session.json (version 2) stores it
  sealed with AES-GCM under a key derived (HKDF-SHA256) from the vault key
  (`Vault.derivedKey(purpose:)`); a history that won't open is dropped and the tab reopens on its
  URL. Histories over 512 KB aren't kept. A tab's history is re-read only after it navigates.
  The file is written off the main thread, a second after a navigation or a change to the tabs,
  not for title-only changes (a flashing Teams title would rewrite it every second), and not
  when nothing changed. A crash loses at most the last second of navigation (checked by killing
  the app and relaunching: the restored tab went back and forward through its history). Restore
  stays lazy: only each window's visible tab and Keep alive tabs load; the rest load from their
  saved history when selected. Restoring a tab isn't recorded as a new visit.
- **BrowserData** (`Packages/BrowserData`, GRDB 7.11.1 exact, one owner-only `browser.sqlite`):
  history (one row per space and address without the fragment, visits, typed counts, frecency
  suggestions, inline completion, search, delete, clear, prune at a year), bookmarks (a tree per
  space with a bar and an "Other Bookmarks" root, dense positions, move and copy across spaces,
  import of a neutral tree that's idempotent by external id), site settings (permissions per
  origin, zoom per host, app-link answers per scheme; global, not per space) and the downloads
  list. Stores post a `didChange` notification on the main queue. A damaged file is moved aside
  and a new one starts; environment errors (locked, disk full) are thrown instead. 34 tests;
  suggestions take about 11 ms with 50,000 pages.
- **Brave import mapping (P5)**: `BookmarkImportNode` is the neutral input. Map Brave's bar root's
  children into the space's `.bar` root, "Other bookmarks" into `.other`, and "Mobile bookmarks"
  into a "Mobile Bookmarks" folder under `.other`. Brave GUIDs go in `externalID`, so a second
  import adds only what's new.
- **History** is recorded on each main-frame commit and on same-document address changes
  (single-page apps), per space, for http and https only, without `user:password@`, and with
  titles stripped of unread counts. Back/forward and reloads aren't new visits. ⌘Y opens a
  History window (a space dropdown, defaulting to the current space, or All Spaces; search;
  grouped by day; delete, clear last hour, today or all).
- **Address bar**: an AppKit text field. Typing shows suggestions in a borderless child window
  under the field (it has to draw over the web view): what Return does first (the inline
  completion, an address or a search), then open tabs in the space ("Switch to Tab"), bookmarks,
  history (this space first, other spaces labelled), then a search. Inline completion selects
  the rest of a host or path from history. ↑/↓ move the highlight; the mouse only highlights,
  and Return never opens the row under the pointer. Search engine: Google, DuckDuckGo, Bing,
  Brave Search, Kagi or Ecosia (Settings ▸ General). `localhost`, `*.test`, `*.local` and
  127.0.0.1 open over http.
- **Bookmarks**: a bar under the toolbar (⌘⇧B toggles it; folders are menus), a Bookmarks menu
  rebuilt when it opens, ⌘D (bookmarks the page on the bar and opens a small editor: name,
  folder, remove; the star shows when the page is bookmarked), and ⌥⌘B a manager window
  (space dropdown, search, folders, rename/edit, move to folder or space, copy to space, delete).
  `javascript:` bookmarklets run on the page on screen.
- **Downloads**: `WKDownload` for attachments, types WebKit can't show, `<a download>`, and the
  context menu. Files go to ~/Downloads under a free name ("name (2).ext"; names are cleaned and
  limited to 230 bytes). The panel opens when a download starts; the toolbar button shows a
  progress ring and the Dock icon the number running. **Quarantine**: WebKit's networking
  process writes the file, so neither the app nor `LSFileQuarantineEnabled` would quarantine it
  (and that key would also quarantine every file the app writes, its own databases included).
  Each finished (or partial) download gets `com.apple.quarantine` through
  `URLResourceValues.quarantineProperties`: agent "iSmith", the app's bundle id, type web
  download, and the source and page URLs. Checked on a real download: `0081;…` with the agent
  and type in the quarantine database. Downloads started from the context menu send the page's
  origin as Referer, never its path.
- **Viewing**: find (⌘F, ⌘G, ⇧⌘G, a bar above the page), zoom per site (⌘+, ⌘−, ⌘0, shown in
  the address bar, saved per host and applied to the site's other tabs), print (⌘P, the page
  through the print panel), PDFs inline (WebKit's viewer), element fullscreen on, and picture in
  picture: `document.pictureInPictureEnabled` and `document.fullscreenEnabled` are both true in
  iSmith's web views, so video players offer both.
- **Notifications**: WKWebView's own API always answers "denied" (P0). iSmith's shim: a page-world
  script defines `Notification` (and `showNotification` on service-worker registrations, and
  `navigator.permissions.query` for notifications). It talks over DOM events with a random name
  per run to a bridge script in iSmith's own content world (`iSmith.app`), the only place the
  native handler exists; the page world can't reach it. Permission is per origin, taken from the
  sending frame's security origin, never from the page's message; only a top-level page can ask
  (cross-origin iframes and sandboxed or `data:` frames get "denied"). Asking shows a bar on the
  tab; allowing asks macOS once for notification permission for the app. Notifications go to
  Notification Center with the site and space as subtitle; a tag replaces that site's earlier
  notification in that space. Clicking one brings its window, space and tab forward and fires the
  page's `click` event (after a relaunch the tab still comes forward).
- **App links** (`msteams:`, `ms-word:`, `mailto:`, `zoommtg:`, …): a bar asks "<site> wants to
  open Microsoft Teams" with "Open Microsoft Teams" or "Don't Open", remembered per scheme in site
  settings (Settings ▸ Websites can change or forget it). A remembered "Open" applies only right
  after a real click or key press in the page (or in the page that opened it moments ago, such as
  Outlook's "Join" launcher). A page reaching for an app on its own (a restored launcher tab, a
  scripted click, an ad) is asked "Open" or "Not Now", and that answer isn't remembered, so a
  restored launcher can neither open Teams at startup nor get Teams blocked. No installed app:
  a notice after a click. One question per scheme at a time; iSmith never hands a link to
  itself.
- **Prompts**: camera and microphone (`requestMediaCapturePermission`) and location (the macOS 27
  delegate; older macOS keeps WebKit's default) ask with a bar on the tab and remember the answer
  per origin; a saved camera-and-microphone answer covers each alone. In the smoke test
  `getUserMedia` was refused before the delegate was asked, because a process started from a
  shell takes the shell's camera permission; launched normally, macOS asks for "iSmith" once.
  JavaScript alerts, confirms and prompts, file uploads, HTTP sign-in (Basic, Digest, NTLM; for
  the session only) and client-certificate choice are sheets, queued per tab until the tab is on
  screen; every WebKit completion handler is called exactly once, including when the tab closes,
  hibernates or gets a new web view. Escape doesn't answer a site's bar.
- **Certificate errors and failed loads**: a certificate problem replaces the page with a warning
  (Go Back; Details ▸ Show Certificate, "Visit This Website Anyway" for that certificate and host
  until the app quits). A page that can't be reached shows "can't open" with Try Again, and
  retries itself when the network comes back. A tab in the background or kept alive keeps what it
  shows and retries each minute and when the network returns (a newer navigation cancels that).
- **Context menu**: WebKit's menu, with "Open Link in New Tab", "Open Link in Space ▸", WebKit's
  "Copy Link", "Download Linked File", "Open Image in New Tab" and "Save Image As…" (a save panel)
  in place of its new-window and download items. WebKit doesn't say which link a menu is for, so
  a script in iSmith's world reports the element under a trusted `contextmenu` event; WebKit
  delivers that before it asks for the menu. ⌘-click and middle-click open background tabs.
- **Crashes and hibernation**: when a page's web content process dies, the tab shows "This page
  stopped working" with Reload, and reloads by itself when next shown; a Keep alive tab in the
  background reloads after 2 s, at most three times in five minutes. Every minute, a tab that has
  been off screen for 30 minutes is unloaded (history kept) unless it's kept alive, a popup or
  its opener while both are open, waiting on a dialog or question, using the camera or
  microphone, playing media, or edited since it loaded (a trusted `input` event: typing, paste,
  drop, dictation). This also applies the P1 deferred item: a tab that lost Keep alive gets its
  new policy when it reloads.
- **Storage access and third-party cookies** (checked on a local fixture, 127.0.0.1 framing
  localhost): WebKit blocks third-party cookies in iframes outright, `hasStorageAccess()` is
  false, and `requestStorageAccess()` is rejected without a prompt for a site not yet visited as
  a first party. There's no public API to answer the Storage Access prompt, pre-grant access or
  add a per-site cookie exception. WebKit's built-in quirks for Microsoft sign-in show its own
  "Allow related websites to share cookies?" prompt (seen in P1); iSmith doesn't intercept it,
  so it never blocks a sign-in, and clicking Allow is remembered per space's store. Whether
  Teams, SharePoint and Loop embeds work under this is part of the acceptance run. If they
  don't, the options are WebKit SPI per space (`_setResourceLoadStatisticsEnabled:` or the
  third-party-cookie blocking mode on the space's store) or "Open in Safari" for that site.
- **Settings window**: Accounts (as before), General (search engine, bookmarks bar, downloads
  folder) and Websites (permissions, app links and zoom levels, each changeable or removable).
- **Smoke test** (scratch `ISMITH_DATA_DIR`, a local fixture site, driven only through the Debug
  app's own pid: accessibility actions and key events posted to that pid; screenshots of its own
  windows with `screencapture -l`): restore of two tabs and their history, the notification bar
  (denied, and the page saw "denied"), a JavaScript alert sheet, the app-link bar for `msteams:`
  and the no-app notice, a download with the panel and quarantine, an inline PDF, find, zoom kept
  per site across a relaunch, address-bar suggestions with inline completion and arrow keys,
  ⌘D and the bar, the History and Bookmarks windows, Settings ▸ Websites, the link context menu,
  a kill and relaunch (history intact), and the third-party cookie check above.
- **Tests**: `make test` is green: SignInSync 28 (one new: derived keys), BraveImport 37, Blocking
  36 (one live test skipped), Passwords 42, BrowserData 34, and 49 app-hosted tests. New app
  tests (`BrowserBasicsTests`, 18): a back/forward history through a real web view, the sealed
  session file and a new web view; unloading keeps history; the key is needed; oversized or
  damaged history dropped; a fixture page's `Notification` reaching the app with site, space and
  tag, and its click event; `requestPermission` asking once and the handler absent from the page
  world; a denied site; app-link decisions and plans and their storage; quarantine on a file and
  on a real `WKDownload` from a local server (saved under a free name, tracked, listed);
  download names; permission decisions per site and combined; prompts asked once per tab and
  dismissed on unload; history titles; address input and search engines; the context-menu
  rewrite.
- **Review**: two adversarial rounds. Round 1: one high (a remembered app-link "Open" let any
  page or iframe launch apps without a click, and a restored launcher reopen Teams at every
  launch) and seven real-use mediums (hibernation losing unsaved text; Escape answering site
  bars; the session rewritten every second on the main thread; sign-in form posts in
  session.json in the clear; Return opening the hovered suggestion; failed loads covering the
  page and never retrying; the full page URL sent as Referer), plus lows. Round 2: two highs in
  the round-1 fix (a scripted `a.click()` still counted as a click; `window.open()` with no URL
  was treated as an app link) and three real-use mediums (a "Don't Open" given to a restored
  launcher blocking Teams links for good; hibernation counting key presses instead of edits;
  an old retry overriding a newer navigation). All are fixed, and round 2's cheap lows too
  (title flashes writing the file, a failed write not retried, one Keychain read for the history
  key, Save As on volumes without a Trash, long fake extensions).
- **Deferred** (hypothetical or low today):
  - Downloads from a subframe or without a click aren't asked about (Safari asks per site).
  - The HTTP sign-in sheet also appears for a cross-origin subresource's challenge.
  - Files left by a download that a quit interrupted aren't quarantined (finished and failed ones
    are).
  - `hadRecentInput` trusts any real click in the page in the last 3 s, so a page could launch a
    remembered app right after an unrelated click on it.
  - Notification icons aren't shown (Notification Center gets the title, body, site and space).
  - Geolocation on macOS before 27 uses WebKit's default (no per-site prompt).

### P3. Ad and tracker blocking (M)

- Convert EasyList and EasyPrivacy to WebKit content-blocking JSON, using AdGuard's
  SafariConverterLib. Split into lists under WebKit's rule limit.
- Compile the lists in the background and cache them. Refresh them weekly.
- A shield button in the toolbar toggles blocking per site, by removing the rule lists from that
  site's web view and reloading. WebKit has no public API for counting blocked items, so there's no
  blocked count.
- Lists are under WebKit's 150k-rule limit each. They're recompiled when WebKit invalidates the
  compiled store after an OS update.

Acceptance:
- Ads are gone on cnn.com, youtube.com, weather.com and reddit.com.
- Outlook, Teams, Azure, Gmail, Etsy and GitHub work unchanged.

#### P3 notes (2026-10-03): the `Blocking` package

The core is built in `Packages/Blocking` and isn't wired into the app yet; that waits for P1's
tabs and P2's navigation delegate. `Packages/Blocking/INTEGRATION.md` gives the exact hook points.

- **Converter**: AdGuard SafariConverterLib 4.3.0, pinned exactly, with swift-psl 1.1.182 (also
  pinned) for site names. It builds with Xcode 27.0 and Swift 6.4 in Swift 5 mode. The WebKit
  feature level is the library's `SafariVersion.autodetect()` for the running macOS. Advanced
  AdGuard syntax (scriptlets, CSS injection) is left out; WebKit can't run it.
- **Live lists (2026-10-03)**:

  | | Source | Rule lines | WebKit rules | Lines skipped | JSON | Compile |
  |---|---|---|---|---|---|---|
  | EasyPrivacy 202610030402 | 1.51 MB | 56,256 | 57,002 | 44 | 6.3 MB | 1.31 s |
  | EasyList 202610030410 | 2.08 MB | 78,743 | 61,267 | 38 | 7.3 MB | 1.63 s |

  Both convert in 1.9 s together (debug build, M4 Max). Each fits in one list, well under the
  150,000-rule limit, so today there are two lists. The compiled store is 52 MB. A first launch
  converts and compiles the bundled snapshot in about 5 s in the test process. A normal launch
  looks the compiled lists up in under a millisecond.
- **Splitting**: WebKit applies an exception (`ignore-previous-rules`) only to earlier rules in
  the same list. So every exception, cosmetic exception and `$badfilter` line from both lists
  goes into every list, and only the blocking lines are divided. A list over the limit is cut
  into pieces sized from the overflow, recursively. An EasyList exception for an EasyPrivacy
  rule works as it would in a normal ad blocker.
- **Snapshot**: the raw lists ship in the package (3.6 MB), rather than converted JSON (13.5 MB,
  and specific to one WebKit feature level). `Tools/update-blocking-snapshot.sh` refreshes them.
- **Refresh**: checked hourly once started, downloaded when a week has passed since the last
  successful check, retried 6 hours after a failure. A download must start with `[Adblock` and
  have at least 1,000 rule lines, or it's rejected (captive portals, truncated files). New lists
  compile under new identifiers. Only when all of them compile do the saved copies, the state
  and the lists in use change. Any failure removes the half-compiled lists and keeps the old
  ones. The lists a refresh replaces stay in the store, since open web views may still hold them,
  until the next refresh or launch, so the store holds at most two generations (about 104 MB).
  The controller holds a list only while it's attached, so a removed generation's disk space is
  freed once every web view has re-applied or closed.
- **If nothing compiles** (neither the downloaded copies nor the snapshot), blocking is off and
  `status.lastError` says why. The load is tried again after 10 minutes, and a successful
  refresh also ends it.
- **Recompiling**: the state records a fingerprint (converter version, WebKit feature level,
  limit, sources). If it changes, or WebKit can't read a compiled list (as after an OS update),
  the lists are rebuilt from the downloaded copies in use, or from the snapshot if there are none.
- **Allowlist**: per site, meaning the registrable domain (eTLD+1, using the public suffix
  list), as Brave's Shields work. Allowing `www.cnn.com` also covers `edition.cnn.com`.
  `azurewebsites.net` and `github.io` apps are each their own site. The allowlist is saved in
  `allowlist.json`. Blocking is toggled by attaching or removing the lists on that web view's
  content controller, which takes effect from the next load. The app applies a destination's
  setting only once its navigation is allowed, and restores the current page's setting if the
  navigation fails before committing (unless a newer navigation replaced it); INTEGRATION.md
  has the delegate code.
- **Tests**: 35 tests in 5 suites (`swift test`, about 6 s), plus an opt-in live test
  (`BLOCKING_LIVE_TESTS=1`) that downloads, converts and compiles today's lists:
  - `RuleListBuilderTests`: conversion of a fixture list, comment handling, line classification,
    the split (200 rules at a limit of 50, with every exception in each list), a cosmetic
    exception and a `$badfilter` acting on the other source's rules, split lists compiling in
    WebKit, and the error when exceptions alone exceed the limit.
  - `StoreTests`: the real bundled snapshot compiled in the xctest process, then loaded from the
    store with no compile; recompiling after the store is corrupted, the fingerprint changes or
    the state file is damaged; recompiling the downloaded copies (not the snapshot); a failed
    load tried again after the retry interval.
  - `RefreshTests`: the weekly schedule, a successful swap (and a relaunch that loads it and
    removes the old lists), a failed download with its retry delay, a non-list download, a
    truncated download, a compile failure partway through, concurrent refreshes, "Update now"
    during an automatic check, older generations removed by later refreshes, and automatic
    refresh.
  - `AllowlistTests`: site names, persistence across launches, an unreadable file, a failed save.
  - `WebViewTests`: real loads from a local server under two host names. A fixture ad script is
    blocked (the server never sees the request) and `.ad-banner` is hidden on a blocked host; both
    load on an allowlisted host. Lists applied in `decidePolicyFor` take effect for that
    navigation, a cancelled or failed navigation leaves the page on screen with its own setting,
    a navigation replaced while loading doesn't undo the new one's setting, the shield toggle
    plus reload works in one web view, and refreshed lists replace the old ones in an open web
    view.
- **License**: SafariConverterLib is GPL-3.0, and it's compiled into the app. EasyList and
  EasyPrivacy are GPL-3.0 or CC BY-SA 3.0. For a personal build this doesn't matter. Publishing
  binaries (P7's public releases repo) brings GPL obligations, such as offering the app's source.
  Decide before P7: accept that, or move conversion out of the app (convert on a server and
  download converted JSON).
- **Review**: two adversarial rounds. Round 1 found one high (a cancelled or failed navigation
  left the page on screen with the destination's setting) and three mediums (compiled lists
  piling up during a long session, a failed load turning blocking off for the session, "Update
  now" answering "not due"); round 2 found one high its fix introduced (a replaced navigation's
  failure undoing the new one's setting) and one medium (replaced lists held until relaunch).
  All are fixed and tested. Deferred, all hypothetical today: if the lists keep failing to
  compile, each 10-minute retry holds one navigation for the compile; a retried load could
  overlap a refresh; allowlist entries typed as Unicode domains don't match the punycode hosts
  WebKit reports (only matters if a settings field accepts typed domains).
- **Still to do for P3**: the shield button and wiring (after P1 and P2), then the acceptance
  sites.

### P4. Password store and autofill (L)

- **Store**: SQLite rows whose username and password fields are encrypted with the Keychain key.
  Each row is scoped to an origin, with matching for subdomains and port.
- **Capture**: an injected user script watches login and signup forms, and on submit offers to
  save or update the password in a native bar.
- **Autofill**: focusing a login field shows a native popover of matching logins. One click fills
  them, ⌘\\ fills too, and there's a strong-password generator for signup forms.
- **Passwords manager window**: search, view (Touch ID or the Mac password before revealing),
  edit, delete, copy, and spotting reused or weak passwords.
- **Passkeys**: once Apple grants the entitlement, WebAuthn works and passkeys are stored in Apple
  Passwords or your passkey provider. iSmith doesn't store passkeys itself.
- **Script security**: autofill scripts and their message handlers run in a named
  `WKContentWorld`, never the page's own world. A login is matched against the sending frame's
  `securityOrigin`, not the top-level URL, so a cross-origin iframe gets nothing. Autofill only
  fills on your action, never on page load, so hidden forms can't harvest passwords. Capture
  handles two-step sign-ins (Microsoft and Google ask for the username and password on separate
  pages).
- **Threat model**: secrets are never written to logs, never placed on the pasteboard without
  being cleared, and never exposed to agents. A separate review focuses on this phase.

Acceptance: you sign in to 10 everyday sites using autofill only; new passwords are captured; a
revealed password needs your fingerprint or Mac password.

**Core built (2026-10-03)**: `Packages/Passwords` holds the store, matching, script and
`PasswordAutofill` controller, with 42 tests (WebKit ones on local fixtures). The app UI (save
bar, popover, manager window) is still to do; `Packages/Passwords/INTEGRATION.md` lists the hook
points. Two security reviews changed the design:
- Same-site matching is https-only and skips multi-tenant hosts the Public Suffix List lacks
  (Okta, SharePoint, Atlassian, …). Same-site logins fill only from an explicit popover pick;
  ⌘\\ fills exact matches in fields the user clicked.
- Only fields the user can see get a popover or a password (hit test, opacity, clipping, masks).
- Captures need a trusted click or Return and a password the user typed or iSmith filled.

### P5. Import from Brave (S)

- Find Brave profiles under `~/Library/Application Support/BraveSoftware/Brave-Browser/`.
- **Bookmarks**: read the `Bookmarks` JSON and import it into the space you pick, keeping folders.
- **Passwords**: read copies of `Login Data` and `Login Data For Account` (Brave locks the
  originals while it runs). Decrypt the `v10` values: AES-128-CBC, with a key derived by
  PBKDF2-SHA1 from the "Brave Safe Storage" Keychain item (account "Brave"), salt `saltysalt`,
  1003 rounds, and an IV of 16 spaces. (App-bound encryption only applies on Windows.) Skip
  "never save" rows. macOS asks for your Mac password once. Imported passwords go into the P4
  store.
- A first-run import screen, also available from the File menu later.

Acceptance: every Brave bookmark and saved password appears in iSmith; the counts match Brave's
(excluding "never save" entries).

**Core built (2026-10-03)**: `Packages/BraveImport`, with no UI. The app still has to map
bookmarks into a space, move passwords into the P4 store, and build the import screen.

- `BraveProfiles.discover()` lists `Default` and `Profile N` folders that hold bookmarks or
  passwords, named and ordered from `Local State`.
- `BookmarksReader` turns `Bookmarks` into a neutral tree (folders, titles, URLs as stored,
  dates, GUIDs), one folder per root.
- `BravePasswordReader` byte-copies both login databases, with any `-journal` or `-wal`, into an
  owner-only temp folder. If Brave writes during the copy (inode, size or modification time
  changes), it copies again, up to five times. It reads the copies with the system SQLite and
  deletes them before decrypting anything.
- It decrypts `v10` passwords and notes from `password_notes`, skips "never save" rows, and
  merges the same login (site, username and password) into one, as Brave shows it.
- The Safe Storage password comes from an injected source. It is asked for once per reader, and
  only when something is encrypted. The reader throws `wrongKey` when two or more encrypted
  values all fail to decrypt. To check acceptance, compare against the row count of Brave's
  "Export passwords" CSV, not its grouped list.
- **macOS 27 protects Brave's folder.** Another app's process sees the folder but can't read it.
  This shell got "Operation not permitted", while Scott's terminal could read it. The package
  reports that as `BraveAccessError.permissionDenied`, so the import screen has to explain the
  macOS permission and offer a retry.
- Checked read-only against Scott's Brave: 1 profile, 507 bookmarks in 79 folders, and only the
  three standard roots. Passwords were not read; the fixtures cover them.

### P6. Default browser and link routing (M)

- Register as an http/https handler, and declare the HTML document types so iSmith appears in
  macOS's default-browser list. Offer "Make iSmith your default browser"; macOS shows its own
  confirmation.
- **Incoming links** (from Teams, Outlook, Slack and others):
  1. a URL rule picks the space;
  2. if no rule matches, the link opens in the Default space;
  3. for hosts whose URL is the same in every tenant (outlook.office.com), the space you last used
     for that host wins.
- **Rule editor**: an ordered list of URL patterns and their spaces.
- **Learned rules**: if you move links from the same host or path into one space twice, iSmith
  offers a rule you accept with one click.
- "Open in space ▸" from the link context menu and from the Dock.

Acceptance: links from Teams and Outlook to dev.azure.com/contoso-dev, Fabrikam SharePoint
and Etsy each land in the right space.

#### P6 notes (2026-10-03)

Built and tested with injected links and a scratch data folder. The acceptance run (clicking real
Teams and Outlook links with iSmith as the default browser) is still to do. It needs Scott to confirm
macOS's "change your default web browser?" question.

- **Registration**: Info.plist declares `CFBundleURLTypes` for http and https, and
  `CFBundleDocumentTypes` for `public.html`, `public.xhtml` and `com.apple.webarchive`. The document
  types rank Alternate, so installing iSmith never takes over .html files on its own. Checked
  read-only on this Mac: `LSCopyAllHandlersForURLScheme("https")` lists
  `com.scottsmith.ismith.debug`, and `NSWorkspace.urlsForApplications(toOpen:)` lists the Debug
  app for https links and for `public.html`. The real default browser was never changed (it's still
  Brave).
- **Packages/Routing** (no UI, no dependencies) is saved in `routing.json` (owner-only, written
  through a temporary file and a rename).
  - **Patterns**: a host (`github.com`), a host and path prefix on segment boundaries
    (`dev.azure.com/contoso-dev`, which matches `/contoso-dev/Storefront/…` but not
    `/contoso-dev2`), or `*.fabrikam.com` (the domain and every subdomain). Matching ignores
    case and `www.`. A port, if given, must match. A pasted scheme or trailing `/*` is dropped.
    Only http and https links match. The editor rejects a misplaced `*`, a bad host or a bad port,
    with a message.
  - **Rules** are an ordered list; the first match wins. A rule for a deleted space is skipped,
    and deleting a space removes its rules.
  - **Shared-address sites**: Outlook, Teams, Microsoft 365, Gmail, and Etsy (both shops use the
    same addresses). Each is a family of hosts, so Outlook at `outlook.cloud.microsoft` counts for
    `outlook.office.com` links. With no rule, they open in the space the site was last used in.
    "Used" means on screen in the key window of the active app, or moved into a space. A
    background tab refreshing itself doesn't count, and neither does a window restored at launch.
  - **Default space**: a Settings dropdown. Unset, or set to a deleted space, means the first
    space in the rail.
  - **Wrapped links**: Defender Safe Links (`*.safelinks.protection.outlook.com/?url=` and Teams'
    Safe Links page) and Google's `google.<tld>/url?q=` are routed and learned by the link inside.
    The wrapper is what opens, so the click-time check still runs.
- **Incoming links** (`application(_:open:)`):
  - Links that arrive before the browser starts are queued. A first launch from a link opens only
    that link, with no home page tab (checked with a cold `open -a` on a fresh data folder).
  - The link opens in a new tab of the routed space. It goes in the current window if that window
    shows the space, else in the frontmost window that does, else the current window switches to
    the space. With no window open it goes into the last closed window, else a new one. The window
    comes forward.
  - HTML files open in the Default space through `loadFileURL`, with read access to their folder.
    They load afresh after a relaunch rather than from saved history.
  - In a space that already keeps Outlook or Gmail alive, a further Outlook or Gmail link opens
    without Keep alive, so links don't pile up copies that are never unloaded. That setting isn't
    saved, and it's undone when the tab moves or the kept-alive tab closes. Teams links (meetings)
    always stay kept alive.
- **Learned rules**: a tab that came from another app and is moved to another space (dragged to the
  rail, "Move to Space", the Dock) records its link's host and first path segment.
  - When to offer: two moves of the same host and segment to one space offer `host/segment`.
    Two moves of one host with different segments, all to one space, offer the host.
  - What's never learned: shared-address sites, redirectors (aka.ms, t.co, bit.ly, …), wrappers,
    and anything an existing rule already does.
  - What counts once: a link moved again counts once. A link stops counting once you type an
    address or follow a link in its tab.
  - The bar: "Always open github.com/contoso-dev in Contoso?" with Always Open in Contoso / Not
    Now / Never, in the window where the move happened.
    - Accept puts the rule ahead of the first rule that would otherwise catch those links.
    - Not Now needs two more moves before the rule is offered again.
    - Never is listed in Settings, where it can be undone.
  - A moved incoming tab loads its link again in the new space instead of replaying a sign-in
    redirect or rewritten page that belongs to the old space.
- **Dock menu**: "Open in Space ▸" lists the other spaces under the front tab's title. It moves that
  tab, reloading it as the new space's accounts, and switches its window there. The link context
  menu's "Open Link in Space ▸" came with P2.
- **Default browser**: a first-run bar ("Make iSmith your default browser?", Make Default / Not
  Now), shown once until answered (`defaultBrowserOffered` in routing.json), and a button in
  Settings ▸ Links. Both call `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` for
  http first, then https only if it still isn't iSmith's, and macOS asks the user to confirm. A
  refusal (3072 or -128) isn't shown as an error. The LaunchServices calls sit behind the
  `DefaultBrowser` seam, so tests use a fake.
- **Settings ▸ Links**: default-browser status and button, the Default space dropdown, the rule list
  (up/down, edit, delete, a space dropdown per rule, and Add Rule… in a sheet that checks the
  pattern as you type), last-used sites, and suggestions turned off with "Never".
- **Fixed on the way**: `openTab` and `ensureLoaded` now mark a tab as building as soon as its web
  view is scheduled. Before, opening a tab in another space and then showing that space built and
  loaded two web views (this also affected P2's "Open Link in Space").
- **App hooks** (kept small for merging): `BrowserState` gained a `routing` property, the
  last-used and learning calls in `shown`, `recordVisit` and `moveTab`, `routing.forget` on a
  typed address or a followed link, `removeSpace`, `closeTab` (Keep alive back) and
  `start(links:)`. `AppDelegate` gained `application(_:open:)`, `applicationDockMenu` and
  `applicationDidBecomeActive`. `SpaceView` gained the bar, `SettingsView` the tab, and `Tab` the
  `keepAliveLowered` flag. Everything else is in `LinkRouting.swift` and `LinkSettings.swift`.
- **Smoke test** (scratch `ISMITH_DATA_DIR` with Personal, Contoso and Fabrikam; links sent with
  `open -a <Debug app path>`; driven only through the Debug app's own pid with accessibility
  actions; screenshots with `screencapture -l`):
  - the first-run bar;
  - `dev.azure.com/contoso-dev/…` opening in Contoso as a single tab, with no extra home tab;
  - an unmatched GitHub link opening in Personal;
  - two GitHub links moved to Contoso through the tab menu, which showed the suggestion bar.
    Accepting saved the rule, and the third link went straight to Contoso;
  - Settings ▸ Links, and the rule sheet's error and explanation;
  - a cold launch from a `*.fabrikam.com` link opening in Fabrikam;
  - a cold first launch from a link opening only that link.
  The Dock menu wasn't clicked, because that would mean sending input to the Dock; the app tests
  cover it.
- **Tests**: `make test` is green.
  - Routing: 26 tests. The pattern table and parsing, rules, Default space, deleted spaces,
    families and last used, Safe Links and Google unwrapping (including a spoofed host),
    learning, Not now and Never, rule placement, the moves cap, persistence across a relaunch, the
    owner-only file, an unreadable file kept aside, a bad rule dropped rather than the file, and
    unknown keys.
  - App: 64 tests, 15 of them new in `LinkRoutingTests`. Dispatch to a space and window,
    last-used from Outlook use and moves, window choice, no window, Safe Links, keep-alive copies,
    reloading a moved link, background commits, learning end to end, Not now and Never, deleting
    a space, the Dock menu, the default-browser seam and first-run offer with a fake
    LaunchServices, and Info.plist plus LaunchServices registration.
  - The app tests are synchronous, so their tabs close before any web view loads a real site.
    tearDown deletes the WebKit stores they made.
- **Review**: two adversarial rounds.
  - Round 1 found two highs and six real-use mediums, all fixed:
    - the highs: last used was keyed per host, so Outlook at `outlook.cloud.microsoft` didn't count
      for `outlook.office.com` links; and Safe Links wrappers defeated rules and trained a rule
      for the Safe Links host;
    - the mediums: the Dock move built two web views; a moved link replayed a stale sign-in
      redirect; background windows changed last used; Outlook links piled up kept-alive copies;
      Etsy couldn't be routed; a link with no window also opened a home tab.
  - Round 2 found no critical or high issues. Its four real-use mediums are fixed:
    - a moved link now always reloads the link until you follow a link or type in the tab;
    - restoring windows at launch no longer sets last used;
    - Teams links keep Keep alive;
    - a lowered Keep alive isn't saved and comes back on a move or when the kept-alive tab closes.
  - Round 2's cheap lows are fixed too: a spoofable Google check, a link with only Settings open
    losing the last window's tabs, blank file tabs after a relaunch, and stale last-used keys.
- **Deferred** (low or hypothetical today):
  - `buildWebView`'s `defer` can clear `isBuilding` for an older build that gave up while a newer
    one is still running. This predates P6. A build generation would fix it.
  - Learned rules are placed using host plus prefix, not the real links. A more specific rule
    already in the list can still shadow one you accept.
  - Learned patterns keep their path decoded, so a `%3F` in a path reloads as a broader rule.
  - Very broad patterns (`*.com`) are accepted.
  - "Not Now" on the first-run bar is final; Settings ▸ Links keeps the button.
  - A group of incoming tabs moved together counts as several moves.
  - The frontmost-window order isn't covered by tests, since test windows have no `NSWindow`.
  - The refusal error codes and whether macOS changes https along with http are unverified until
    Scott answers the real prompt. If https stays unchanged, iSmith asks for it separately.

### P7. Distribution (M)

- **License (decided 2026-10-03)**: the ad-block converter (SafariConverterLib) is GPL-3.0 and is
  compiled into the app. Scott accepted the GPL: releases publish iSmith's source alongside the
  binaries (for example, by making the repo public at the first release).

- `Tools/release.sh`:
  1. build Release;
  2. sign with Developer ID and hardened runtime;
  3. notarize with `notarytool`, using an App Store Connect API key;
  4. staple;
  5. create a zip and DMG;
  6. sign the Sparkle appcast and publish the appcast and download files.
- `newtro/iSmith` is private, so Sparkle can't read from it. The appcast and downloads go to a
  public `newtro/iSmith-releases` repo instead. I'll confirm with you before creating it.
- The app checks for updates daily, and from the menu.
- Entitlements: the web-browser entitlements once granted; no app sandbox.

Acceptance: installing from the DMG passes Gatekeeper; a test 1.0.1 release auto-updates 1.0.0.

### P8. Hardening and acceptance (M)

- **Performance**: 40 tabs across four spaces under 3 GB RAM, counting WebKit's web content
  processes, with hibernation working. Switching space takes under 100 ms.
- **Fuzz the cookie sync** with randomized multi-space sign-ins. This also fixes the deferred
  per-cookie conflict timing from the spike review.
- Run the acceptance checklist on your real accounts. Fix whatever it finds, then dogfood for one
  week.

## Acceptance checklist (v1)

1. iSmith is the default browser. Clicking links in Teams and Outlook opens them in the right space.
2. Contoso and Fabrikam Outlook are open side by side in their spaces, with no sign-in
   prompts, after a reboot.
3. A new space opens Gmail, Outlook and GitHub already signed in.
4. Etsy shop 1 is in Personal and shop 2 is in Newtro Studios. Both stay signed in.
5. Brave bookmarks and passwords are imported, and autofill signs in to 10 everyday sites.
6. Ads are blocked, and work sites still work.
7. Quitting with 40 tabs and reopening restores every window, space, group and tab.
8. Downloads, printing, find, zoom, PDFs and uploads all work. A Teams call works with camera,
   microphone and screen sharing, or opens in Safari if the P0 spike showed screen sharing can't
   work.
9. Teams and Outlook notifications appear while iSmith is in the background, and an incoming
   Teams call rings in a background tab.
10. Links to Teams, Office apps and mail open the right app after the first prompt.
11. An update installs through Sparkle.
12. A full week of daily use without opening Brave.

## Steps only you can do

| When | Step |
|---|---|
| P0, day one | Confirm whether your Apple Developer membership is Individual or Organization. Then submit the passkey entitlement request: I fill in the form in your browser; you sign in and send it. |
| P0 | Approve creating the Developer ID provisioning profile (I prepare it; you sign in). |
| P7 | OK creating the public `newtro/iSmith-releases` repo for update downloads. |
| P0 | Create an App Store Connect API key for notarization. I prepare it; you sign in. |
| P5 | Click "Allow" when macOS asks iSmith to read "Brave Safe Storage". |
| P6 | Confirm "Use iSmith as default browser" in the macOS prompt. |
| P8 | Run the acceptance checklist on your accounts and dogfood for a week. |

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Apple is slow to grant, or denies, the passkey entitlement (possibly not available to individual memberships) | No passkeys or WebAuthn; sites that require a passkey fail | Request on day one. Use passwords and Authenticator until it's granted. iSmith's own password autofill doesn't need the entitlement. |
| Screen sharing doesn't work in WKWebView | Can't present in a Teams or Meet call | Test in the P0 spike. Fall back to "Open this call in Safari". |
| WebKit throttles background tabs | Calls don't ring, mail counts go stale | Keep alive tabs with `inactiveSchedulingPolicy = .none`; checklist item 9. |
| A tenant turns on device-based Conditional Access | Microsoft sign-in is blocked in iSmith | Detect the error page and offer to open that site in Safari. Not fixable inside WebKit. |
| A site only works in Chrome | Broken page | "Open in Brave or Chrome" in the menu. Keep Brave installed. |
| Memory with many spaces and tabs | Slow Mac | Tab hibernation, a performance budget in P8, one data store per space (not per tab). |
| Holding passwords | A security bug exposes secrets | Encryption tied to the Keychain, secrets kept out of logs and agents, a dedicated review in P4, reveal only after authentication. |
| WebKit's content-blocker rule limit | Lists don't fit | Split across several rule lists, and prioritize EasyPrivacy and core EasyList. |
| Concurrent sign-ins to different accounts within about 2 seconds | The older session can win | Per-cookie conflict timing and a fuzz test in P8. |

## After v1

1. **Built-in agent panel**: a right, bottom or hidden dock. It has the permission modes Read-only,
   Ask, Confirm submits and YOLO (YOLO is the default), an activity log per space, a group for
   agent tabs, and a hand-off to you for logins.

   Backends to investigate first, all using your subscriptions rather than API keys:
   - **Codex app server** (`codex app-server`): the JSON-RPC-over-stdio interface Codex's IDE
     extensions use. It has threads, streamed turns and events, tool-approval requests the panel
     can answer, and ChatGPT sign-in.
   - **Claude Code**, through its two-way streaming JSON mode or the Agent SDK.
   - **agy** and **opencode**, through whatever interfaces they offer.

   A thin `AgentBackend` protocol keeps the panel independent of which backend runs. An API key
   is only the fallback.
2. **MCP server**: Claude Code, Codex and agy drive tabs in a space, under the same modes.
3. **Page index**: local text and embeddings per space, searched by you and by agents.
4. Then setup sync across Macs (iCloud Drive), space templates, archiving, and per-cookie conflict
   timing (if not already done in P8).
