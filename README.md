# iSmith

A macOS browser for working across several organizations at once. Each **space** (Contoso,
Fabrikam, Personal, …) has its own WebKit data store and tinted chrome. Sign-ins to providers
such as Microsoft, Google and GitHub are shared by every space through an encrypted vault, so you
sign in once. Each site's own session stays in its space, so Outlook or Etsy can show a different
account in each space.

See [DESIGN.md](DESIGN.md) for the model and [BUILD_PLAN.md](BUILD_PLAN.md) for the v1 phases.
[AGENT_PANEL.md](AGENT_PANEL.md) is the agent panel (v1.1): Codex through its app server, with
iSmith's own per-tab browser tools.
[ACCEPTANCE.md](ACCEPTANCE.md) is the runbook for the v1 checks on real accounts.
`spike/` is the prototype that proved the sign-in sync. It's kept for reference.

## Layout

- `App/`: the app. AppKit runs the app, its windows, menus and the tab strip (for drag and
  drop); SwiftUI draws the rail, toolbar, space editor and the Settings, History and Bookmarks
  windows.
  - `TabLayout.swift`: the tab and group rules (order, groups as one run, selection, collapse).
  - `Session.swift`: `session.json`, the open windows, spaces, groups and tabs, with each tab's
    sealed back/forward history.
  - `Model.swift`, `BrowserState.swift`: tabs, windows and spaces at run time, and web views.
  - `WebDelegates.swift`: what pages ask for (popups, dialogs, permissions, downloads, sign-in
    challenges, app links, failed loads, crashes). `BrowserFeatures.swift`: scripts, the link
    context menu, hibernation, retries, zoom, find, print. `BrowserWebView.swift`: the web view
    and its context menu.
  - `WebNotifications.swift`: the web Notification shim and Notification Center delivery.
  - `Downloads.swift`: downloads, quarantine and the panel. `AppLinks.swift`: links that open
    other apps. `Prompts.swift`: site questions, dialogs, certificate exceptions.
  - `AddressBar.swift`: the address field, suggestions and inline completion. `Library.swift`:
    history and bookmarks windows and the Bookmarks menu. `PageViews.swift`: the bars and pages
    shown over a tab (questions, find, crash, failed load, bookmarks bar). `Settings.swift`.
  - `TabStripView.swift`, `WindowView.swift`, `MainMenu.swift`, `Panels.swift`: the UI. The tab
    strip and the vertical-tabs sidebar share one AppKit view and the tab context menu
    (`TabMenu`). `TabActions.swift`: pinned tabs and the actions on several tabs.
    `TabOverview.swift`: the tab overview (⌘⇧A). `Favicons.swift`: site icons.
  - `TabLayout.swift` also holds `TabSelection`, the ⌘-click and ⇧-click rules.
  - `PageRules.swift`: unread badges from page titles, and which pages are kept alive.
  - `LinkRouting.swift`: links from other apps (which space and window), the default-browser
    seam, learned-rule offers, the Dock's "Open in Space". `LinkSettings.swift`: Settings ▸ Links.
  - `Shields.swift`: ad and tracker blocking in web views, the toolbar shield and Settings ▸
    Privacy. `PasswordUI.swift`: the save bar, the autofill popover and ⌘\\.
    `PasswordsWindow.swift`: the Passwords window. `ImportFromBrave.swift`: the Brave import
    (first-run screen and File ▸ Import from Brave…).
  - `Support.swift`: `AppIdentity` (Debug vs Release), `AppPaths`, search engines, address input.
  - The agent panel (v1.1): `AgentController.swift` (the backend, a session per space, chats,
    cards), `AgentPanel.swift` (the panel, the activity log, the toolbar's dock control),
    `AgentTools.swift` (the browser tools and the sign-in hand-off), `AgentPolicy.swift` (what
    each mode allows), `AgentPageScript.swift` (the page script in the agent's content world),
    `AgentInput.swift` (real mouse and key events for one tab, screenshots, the offscreen stage)
    and `AgentTabs.swift` (the Agent group and agent control).
  - `PerfHarness.swift` (Debug only): drives the performance run started by `Tools/perf-run.py`.
- `Packages/SignInSync/`: the sign-in engine, with no UI. It holds providers, accounts and spaces
  (`Config`), the encrypted `Vault`, `CookieSync`, `SpaceManager`, and the one-time import from
  the spike.
- `Packages/BraveImport/`: reads a Brave install, with no UI and no writes to Brave's files. It
  finds profiles, parses bookmarks into a neutral tree, and decrypts saved passwords from private
  copies of `Login Data` and `Login Data For Account`. The "Brave Safe Storage" Keychain read is
  injected, so its tests never touch the Keychain.
- `Packages/Blocking/`: ad and tracker blocking (wired in by `App/Shields.swift`). EasyList and
  EasyPrivacy become WebKit content-rule lists, refreshed weekly, with a per-site allowlist.
  `Packages/Blocking/INTEGRATION.md` lists the app's hook points.
- `Tools/update-blocking-snapshot.sh`: refreshes the filter lists bundled for first launch.
- `Tools/perf-run.py`: the P8 performance run (after `make build`): 40 fixture tabs across four
  spaces in "iSmith Dev" on a scratch data folder, with the memory of the app and its WebKit
  processes at each stage and the space-switch times. `Tools/memory.py [pid]`: the memory of a
  running iSmith (default: the installed one) and only its own WebKit processes; read-only.
- `Packages/Passwords/`: the password store and autofill core (the app's UI is in `App/`): encrypted logins in
  SQLite, origin matching, the capture and fill script, and the `PasswordAutofill` controller.
  [INTEGRATION.md](Packages/Passwords/INTEGRATION.md) lists the app's hook points.
- `Packages/Routing/`: link routing, with no UI: URL patterns, ordered rules, the space last used
  for shared-address sites (Outlook, Teams, Gmail, Etsy), the Default space, Safe Links
  unwrapping and learned rules, saved in `routing.json`.
- `Packages/AgentKit/`: agent backends for the agent panel, with no UI and no browser code: the
  `AgentBackend` protocol and `CodexAppServerBackend` (`codex app-server`, newline-delimited
  JSON-RPC over stdio: threads, turns, streamed events, iSmith's dynamic tools, approvals,
  restart and resume). Its tests drive `FakeCodexAppServer`, a stand-in executable in the
  package, so they never use Codex or a subscription.
- `Packages/BrowserData/`: `browser.sqlite` through GRDB: history per space, bookmarks (shared by
  every space), site settings (permissions, zoom, app-link answers) and the downloads list. No UI.
- `AppTests/`: tests that run inside the signed app.
- `project.yml`: the XcodeGen spec. `iSmith.xcodeproj` is generated from it and not committed.

## Build, test, run

Needs Xcode and XcodeGen (`brew install xcodegen`).

```bash
make build   # generate the project and build Debug ("iSmith Dev") into build/
make test    # package tests (SignInSync, BraveImport, Blocking, Passwords, BrowserData, Routing, AgentKit; swift test), then the app-hosted tests
make run     # build and open the Debug app, "iSmith Dev"
make install # build Release and install it as /Applications/iSmith.app (quit iSmith first)
```

**Debug and Release are separate apps.** Debug builds are "iSmith Dev", bundle id
`com.scottsmith.ismith.debug`: their own data folder (`~/Library/Application Support/iSmith Dev`),
WebKit stores, notification settings and Keychain items (`com.scottsmith.ismith.debug.vault-key`,
`.passwords-key`), no spike import and no Sparkle updates. Release is `com.scottsmith.ismith`, the
installed app. A development run never reads or prompts for the installed app's keys or data.
Drive a test copy only through its own process (by pid, or through code); never send input to
the installed iSmith by app name or bundle id.

The package's sync tests use real WebKit stores. Each test makes its own stores and deletes them
afterwards. A full run takes about two and a half minutes because the tests wait for the sync to
settle. `FuzzTests` runs seeded random sign-ins, rotations and sign-outs across five spaces;
`SIGNINSYNC_FUZZ_SEED=<n> SIGNINSYNC_FUZZ_ROUNDS=<n> swift test --filter FuzzTests` replays a
seed or runs longer.

## Data

- `~/Library/Application Support/iSmith/` (`iSmith Dev/` for Debug builds) holds `config.json`,
  `vault.json`, `session.json`, `browser.sqlite` and `passwords.sqlite`, all owner-only, and
  `Blocking/` (the compiled filter lists, the downloaded copies and the allowlist). The vault is
  encrypted with AES-GCM. Its key is in the login Keychain under `<bundle id>.vault-key`
  (`com.scottsmith.ismith.vault-key` for the installed app).
- `passwords.sqlite` holds saved logins, each username and password sealed with AES-GCM under
  its own Keychain key, `<bundle id>.passwords-key`. Passwords are global, not per space.
- `config.json` is what each space is: name, color, accounts, and the rail's order.
- `session.json` is what's open: windows → spaces → tab groups → tabs, with each tab's URL,
  title, Keep alive setting, pin and back/forward history, and each window's tab layout
  (strip or vertical) and agent dock. The history can hold form posts, so it's
  sealed (AES-GCM, a key derived from the vault key). The file is saved a second after a
  navigation or a change to the tabs, and on quit, and restored at launch (after a crash too).
  Restored tabs load when you select them; Keep alive tabs load at once.
- `routing.json` holds the link rules, the Default space, the space each shared-address site was
  last used in, learned moves and suggestions turned off. It's owner-only; a file that can't be
  read is kept aside.
- `browser.sqlite` also holds the agent panel's chats (Codex thread ids, names and dates; the
  messages stay with Codex in `~/.codex`), each space's agent mode, working folder and model, and
  the activity log (what each tool acted on, never typed text or page content; kept a year).
- `browser.sqlite` holds history (per space), bookmarks (shared by every space), site settings (camera, microphone,
  location and notification answers per site, zoom per site, app-link answers per scheme) and
  the downloads list. History older than a year is removed at launch.
- On first launch, the Release app imports the spike's config and saved sign-ins from
  `~/Library/Application Support/iSmithSpike/`. It only reads the spike's files. The spike's
  WebKit stores don't come over, so sites ask for an account once, and a space set to "Not
  shared" signs in once.
- For development, `ISMITH_DATA_DIR=/some/folder` starts the app on another folder (a scratch
  folder for smoke tests):
  `ISMITH_DATA_DIR=/tmp/ismith-dev build/Build/Products/Debug/iSmith.app/Contents/MacOS/iSmith`.
  In a Debug build, `ISMITH_BRAVE_ROOT=/fixture/Brave-Browser` points the Brave import at a
  fixture profile; it then never reads the real "Brave Safe Storage" Keychain item
  (`ISMITH_BRAVE_SAFE_STORAGE` gives the fixture's key).

## Using it

- **Spaces**: the rail on the left. ⌘1–⌘9 switch space; drag icons to reorder; right-click to
  edit or delete; "+" adds one. A badge shows the unread counts in a space's tab titles, such as
  Outlook's "(7)". The window's chrome takes the space's color.
- **Tabs**: ⌘T, ⌘W, ⌘⇧T (reopen the space's last closed tab), ⌘L, ⌘R, ⌘[ and ⌘], and ⌃Tab,
  ⌃⇧Tab, ⌘⇧] and ⌘⇧[ to move between tabs. Drag a tab to reorder it, into or out of a group, onto
  a space in the rail (it reloads signed in as that space), into another window, or out of the
  window for a new one.
- **Pinned tabs**: right-click a tab ▸ Pin Tab (or Window ▸ Pin Tab). Pinned tabs are icons at
  the start of the strip, per space, and come back after a relaunch. ⌘W on a pinned tab doesn't
  close it; it moves to the first unpinned tab (right-click ▸ Close Tab closes it).
- **Several tabs at once**: ⌘-click adds or removes a tab, ⇧-click picks a range. Right-click
  one of them to close them, close the others or those to the right, move them to a group, a
  new group, another space or a new window, bookmark them into a folder, sort them by site,
  duplicate, pin or reload them.
- **Tab overview**: ⌘⇧A lists the space's tabs; type to filter by title, site or group, ↑↓ and
  Return to go to one, ⇧↑↓ or ⌘-click to pick several, ⌘⌫ (with the search field empty) to
  close them, "Move To" to move them.
- **Vertical tabs**: View ▸ Use Vertical Tabs (per window) or Settings ▸ General ▸ Tabs shows
  the space's tabs in a sidebar beside the rail: pinned tabs on top, groups as sections that
  collapse, the same drag and drop and menus. The top strip hides.
- **Groups**: right-click a tab ("Add Tab to New Group"), or ⌘-click or ⇧-click several first.
  Click a group's label to collapse it; right-click it to rename, recolor, ungroup or close it.
- **Keep alive**: Outlook, Teams and Gmail tabs are never throttled in the background, so
  counts update and calls ring. Right-click any tab to turn it on or off (a bolt marks it).
- **Windows**: ⌘N opens a window; each window shows one space at a time and has its own tabs.
  "Move Tab to New Window" is in the Window menu and a tab's context menu.
- **Address bar**: suggestions from the space's open tabs, bookmarks and history (other spaces'
  history labelled), with the rest of an address completed inline; ↑/↓ and Return, ⌘Return for a new
  tab. The search engine is in Settings ▸ General.
- **History and bookmarks**: ⌘Y history (per space, searchable). ⌘D bookmarks the page (the star
  shows it); ⌘⇧B shows or hides the bookmarks bar; ⌥⌘B opens the bookmarks manager; the
  Bookmarks menu lists the bookmarks. Bookmarks are shared by every space: one bar, menu and
  manager everywhere (bookmarks kept per space by versions before 2026-10-06 are merged into one
  set the first time a newer version opens, after a backup copy of `browser.sqlite`).
- **Page**: ⌘F find (⌘G, ⇧⌘G), ⌘+ ⌘− ⌘0 zoom (kept per site), ⌘P print. PDFs open in the tab;
  videos go full screen and picture in picture. Right-click a link to open it in a new tab or
  another space, copy it or download it; right-click an image to save it.
- **Downloads** go to ~/Downloads and are quarantined, so Gatekeeper checks downloaded apps. The
  arrow button (⌥⌘L) shows them, with progress; the Dock icon shows how many are running.
- **Questions from sites** (notifications, camera, microphone, location, opening an app such as
  Teams) appear as a bar above the page. Answers are kept per site (per scheme for apps) and can
  be changed in Settings ▸ Websites. Site notifications appear in Notification Center; clicking
  one brings its tab forward.
- **Links from other apps**: make iSmith the default browser from the first-run bar or Settings ▸
  Links (macOS asks you to confirm). A link opens in a new tab in the space of the first matching
  rule. With no match, Outlook, Teams, Gmail and Etsy links open in the space you last used them
  in, and anything else opens in the Default space. Rules are edited in Settings ▸ Links:
  `dev.azure.com/contoso-dev`, `*.fabrikam.com` or `github.com`, first match wins. Move two
  links of the same kind to one space and iSmith offers a rule ("Always open … in Contoso?").
  The Dock menu's "Open in Space ▸" moves the front tab to another space.
- **Ads and trackers** are blocked with EasyList and EasyPrivacy (refreshed weekly). The shield
  in the address bar turns blocking off or on for the whole site and reloads it; Settings ▸
  Privacy has the global switch, the list versions, "Update Now" and the allowed sites.
- **Passwords**: after you sign in, a bar offers to save (or update) the password; you can fix
  the username first, or say "Never for This Site". Click a username or password field to pick
  a saved login, or press ⌘\\ to fill the site's login; sign-up fields offer a strong password.
  ⌥⌘P opens the Passwords window: search, weak and reused passwords, edit, add and delete.
  Showing or copying a password asks for Touch ID or your Mac password; copies are cleared from
  the clipboard after a minute and don't go to other devices.
- **Import from Brave** (offered at first launch, and in the File menu): pick the profile; the
  bookmarks go into the bookmarks every space shares (a later import adds only what isn't there
  yet), passwords into the password store. macOS asks once for
  permission to read Brave's data (Privacy & Security ▸ Files & Folders if you said no) and for
  your Mac password to use the "Brave Safe Storage" key.
- **Agent panel** (needs Codex: `npm install -g @openai/codex`, then `codex login`): the toolbar's
  three buttons dock it on the right, at the bottom or hide it (per window; ⌥⌘A shows or hides
  it). Ask about the space's tabs; the agent reads pages and clicks and types in them with real
  input, opens its own tabs in the space's **Agent** group (in the background), and moves a tab
  of yours there when it acts on it. Drag a tab out of the group (or "Take Tab Back from the
  Agent") and it stops acting there. The mode dropdown is per space: Read-only, Ask, Confirm
  submits or YOLO (the default, set in Settings ▸ Agents). Approvals and sign-ins appear as cards
  in the panel; on a sign-in page the agent waits while you sign in (autofill works for you), then
  Continue. Chats are kept per space (the title menu lists them); the activity log button shows
  every tool call with its time, tab and target. Stop interrupts the turn.
- **Background tabs** are unloaded after 30 minutes off screen (not Keep alive tabs, and not
  pages you've edited), keeping their history; they reload when selected. Only the 15 most
  recently shown background tabs stay loaded for longer than a minute (sites allowed to notify
  keep their 30 minutes). When macOS is short of memory, tabs not shown for 5 minutes are
  unloaded, and at critical pressure every background tab that can be. A page whose process
  crashed shows Reload. `Tools/memory.py` prints how much memory iSmith and its WebKit processes
  use.

## Updates

Sparkle 2 is built in. "Check for Updates…" is in the app menu and reads the appcast from the
public `newtro/iSmith-releases` repo. Automatic checks stay off until releases exist (P7).

## Releasing

`Tools/release.sh <version>` archives, notarizes (with the Apple ID signed in to Xcode), packages
a zip and DMG, signs the update for Sparkle, updates `appcast.xml`, and publishes a GitHub
Release. Installed copies check `appcast.xml` daily.

## License

GPL-3.0, because iSmith includes AdGuard's SafariConverterLib. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
