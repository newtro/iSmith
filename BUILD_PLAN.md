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

### P7. Distribution (M)

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
