# iSmith

A macOS browser for working across several organizations at once. Each **space** (Contoso,
Fabrikam, Personal, …) has its own WebKit data store and tinted chrome. Sign-ins to providers
such as Microsoft, Google and GitHub are shared by every space through an encrypted vault, so you
sign in once. Each site's own session stays in its space, so Outlook or Etsy can show a different
account in each space.

See [DESIGN.md](DESIGN.md) for the model and [BUILD_PLAN.md](BUILD_PLAN.md) for the v1 phases.
`spike/` is the prototype that proved the sign-in sync. It's kept for reference.

## Layout

- `App/`: the app. AppKit runs the app, its windows, menus and the tab strip (for drag and
  drop); SwiftUI draws the rail, toolbar, space editor and the Accounts window.
  - `TabLayout.swift`: the tab and group rules (order, groups as one run, selection, collapse).
  - `Session.swift`: `session.json`, the open windows, spaces, groups and tabs.
  - `Model.swift`, `BrowserState.swift`: tabs, windows and spaces at run time, and web views.
  - `TabStripView.swift`, `WindowView.swift`, `MainMenu.swift`, `Panels.swift`: the UI.
  - `PageRules.swift`: unread badges from page titles, and which pages are kept alive.
- `Packages/SignInSync/`: the sign-in engine, with no UI. It holds providers, accounts and spaces
  (`Config`), the encrypted `Vault`, `CookieSync`, `SpaceManager`, and the one-time import from
  the spike.
- `Packages/BraveImport/`: reads a Brave install, with no UI and no writes to Brave's files. It
  finds profiles, parses bookmarks into a neutral tree, and decrypts saved passwords from private
  copies of `Login Data` and `Login Data For Account`. The "Brave Safe Storage" Keychain read is
  injected, so its tests never touch the Keychain.
- `Packages/Blocking/`: ad and tracker blocking, not yet wired into the app. EasyList and
  EasyPrivacy become WebKit content-rule lists, refreshed weekly, with a per-site allowlist.
  `Packages/Blocking/INTEGRATION.md` lists the app's hook points.
- `Tools/update-blocking-snapshot.sh`: refreshes the filter lists bundled for first launch.
- `Packages/Passwords/`: the password store and autofill core, with no UI: encrypted logins in
  SQLite, origin matching, the capture and fill script, and the `PasswordAutofill` controller.
  [INTEGRATION.md](Packages/Passwords/INTEGRATION.md) lists the app's hook points.
- `AppTests/`: tests that run inside the signed app.
- `project.yml`: the XcodeGen spec. `iSmith.xcodeproj` is generated from it and not committed.

## Build, test, run

Needs Xcode and XcodeGen (`brew install xcodegen`).

```bash
make build   # generate the project and build Debug into build/
make test    # package tests (SignInSync, BraveImport, Blocking, Passwords; swift test), then the app-hosted tests
make run     # build and open the app
```

The package's sync tests use real WebKit stores. Each test makes its own stores and deletes them
afterwards. A full run takes about two minutes because the tests wait for the sync to settle.

## Data

- `~/Library/Application Support/iSmith/` holds `config.json`, `vault.json` and `session.json`,
  all owner-only. The vault is encrypted with AES-GCM. Its key is in the login Keychain under
  `com.scottsmith.ismith.vault-key`.
- `config.json` is what each space is: name, color, accounts, and the rail's order.
- `session.json` is what's open: windows → spaces → tab groups → tabs, with each tab's URL,
  title and Keep alive setting. It's saved a second after any change and on quit, and restored
  at launch. Restored tabs load when you select them; Keep alive tabs load at once.
- On first launch, iSmith imports the spike's config and saved sign-ins from
  `~/Library/Application Support/iSmithSpike/`. It only reads the spike's files. The spike's
  WebKit stores don't come over, so sites ask for an account once, and a space set to "Not
  shared" signs in once.
- For development, `ISMITH_DATA_DIR=/some/folder` starts the app on another folder with no spike
  import:
  `ISMITH_DATA_DIR=/tmp/ismith-dev build/Build/Products/Debug/iSmith.app/Contents/MacOS/iSmith`.

## Using it

- **Spaces**: the rail on the left. ⌘1–⌘9 switch space; drag icons to reorder; right-click to
  edit or delete; "+" adds one. A badge shows the unread counts in a space's tab titles, such as
  Outlook's "(7)". The window's chrome takes the space's color.
- **Tabs**: ⌘T, ⌘W, ⌘⇧T (reopen the space's last closed tab), ⌘L, ⌘R, ⌘[ and ⌘], and ⌃Tab,
  ⌃⇧Tab, ⌘⇧] and ⌘⇧[ to move between tabs. Drag a tab to reorder it, into or out of a group, onto
  a space in the rail (it reloads signed in as that space), into another window, or out of the
  window for a new one.
- **Groups**: right-click a tab ("Add Tab to New Group"), or ⌘-click or ⇧-click several first.
  Click a group's label to collapse it; right-click it to rename, recolor, ungroup or close it.
- **Keep alive**: Outlook, Teams and Gmail tabs are never throttled in the background, so
  counts update and calls ring. Right-click any tab to turn it on or off (a bolt marks it).
- **Windows**: ⌘N opens a window; each window shows one space at a time and has its own tabs.
  "Move Tab to New Window" is in the Window menu and a tab's context menu.

## Updates

Sparkle 2 is built in. "Check for Updates…" is in the app menu and reads the appcast from the
public `newtro/iSmith-releases` repo. Automatic checks stay off until releases exist (P7).
