# Passwords: integrating into the app

The `Passwords` package is the core of P4: the encrypted store, origin matching, the capture and
fill script, and the `PasswordAutofill` controller. It has no UI. This note lists the hook points
and the native UI the app adds on top.

## Setup at launch

```swift
import Passwords

func openPasswords(dataDir: URL?) -> PasswordAutofill? {
    let store: PasswordStore
    do {
        store = try PasswordStore(fileURL: PasswordStore.defaultFileURL(dataDirectory: dataDir),
                                  keyStore: KeychainKeyStore(service: AppIdentity.passwordsKeyService,
                                                            account: "passwords", label: "iSmith passwords key"))
    } catch {
        // `.keychainUnavailable` or `.databaseUnavailable` (the file is locked or can't be read
        // just now): same handling as the vault ("Try Again", or run without passwords). Nothing
        // on disk was touched. Say every error out loud: a store that silently fails to open
        // looks exactly like "no saved passwords".
        return nil
    }
    if let aside = store.movedAside {
        // Tell the user once: saved passwords couldn't be opened and were kept at `aside`.
        _ = aside
    }
    // Earlier copies set aside: add back what opens with the current key (backs the store up
    // first; never removes anything), then report what doesn't decrypt.
    for copy in PasswordStore.setAsideCopies(of: store.fileURL) where copy != store.movedAside {
        _ = try? store.recover(from: copy)   // nil: sealed with another key
    }
    let health = try store.health()          // rows and unreadable rows: report unreadable > 0
    let autofill = PasswordAutofill(store: store)   // one for the whole app; passwords are global
    autofill.delegate = passwordUI                  // see "Delegate events" below
    return autofill
}
```

- The file is `~/Library/Application Support/iSmith/passwords.sqlite` (0600, folder 0700). With
  `ISMITH_DATA_DIR`, pass that folder as `dataDirectory`.
- The key is a 256-bit AES key in the file-based login Keychain, service
  `com.scottsmith.ismith.passwords-key`, account `passwords`, separate from the vault key. The
  app passes `AppIdentity.passwordsKeyService` rather than the package default, so the Debug
  build ("iSmith Dev") uses `com.scottsmith.ismith.debug.passwords-key` and never reads the
  installed app's key.
- Add `Packages/Passwords` to `project.yml` under `packages:` and as a dependency of the
  `iSmith` target. It depends on `SignInSync` (for `KeyStore`) and GRDB 7.11.1 (exact).

## Attaching to web views

Call `autofill.attach(to: configuration)` on every `WKWebViewConfiguration` **before** the
`WKWebView` is created, in every space (passwords are global). Attaching the same configuration
twice is a no-op. When a tab closes, `autofill.forget(webView)` drops its two-step state (it's
also dropped automatically when the web view is deallocated).

Tabs driven by an agent (after v1) call `autofill.setDisabled(true, for: webView)` when the agent
takes them over: their focus and submit messages are ignored and `fill` refuses them.

The script runs in the content world `PasswordAutofill.defaultWorldName` (`iSmith.passwords`).
Don't run other app scripts in that world, and never register a handler named `ismithPasswords`
in the page world.

## Delegate events

All on the main actor.

| Event | When | App does |
|---|---|---|
| `loginFieldFocused(focus)` | A visible username or password field of a recognized form is focused or clicked. `focus.isUserInitiated` is true when the user clicked it or tabbed into it; a page calling `focus()` reports it false. | If `isUserInitiated`, show the **autofill popover** anchored to `focus.rectInWebView` (main frame) or the mouse location (iframes; `rectInWebView` is nil). If not, show at most a small key button in the field's corner that opens the popover on click. |
| `captured(capture)` | A form was submitted with a new login (`.save`) or a changed password (`.update`). Unchanged logins and never-save origins aren't reported. | Show the **save bar**. |
| `foundForms(kinds, frame)` | A frame gained login forms (sent when the set of kinds changes). | Optional: a key icon in the address bar; enables ⌘\\. |

## Actions

Only ever call these in direct response to a user action (a click in the popover, ⌘\\, a save bar
button). Never call `fill` on page load, on a timer, or from anything a page or an agent can
trigger.

- `try await autofill.fill(loginID, into: focus, allowSameSite: row.matchKind == .sameSite)`:
  fills the username (if visible) and password of the focused field's form, or just the username
  on a first sign-in step. Pass `allowSameSite: true` only from a popover click on a same-site row
  whose host was shown. It re-reads the login from the store and refuses:
  - `.originMismatch`: the login doesn't match the frame's origin;
  - `.sameSiteNotAllowed`: a same-site login without `allowSameSite`;
  - `.tooSoon`: within `minimumFocusAge` (0.3 s) of the focus;
  - `.stale` / `.frameOriginChanged`: the frame has navigated since the focus;
  - `.noField`: the field or the password field is gone, hidden, covered, or moved to another
    form;
  - `.disabled`: autofill is off for the web view.

  It returns `.filled`, or `.usernameOnly` when the password field couldn't be seen even after
  scrolling it into view (a cookie banner over it, say): tell the user to click the password
  field to finish. It marks the login used.
- `try await autofill.fillGeneratedPassword(password, into: focus)`: for `focus.offersGeneratedPassword`.
  Generate with `PasswordGenerator.generate(focus.requirements)` (it honors `minlength`,
  `maxlength` and `passwordrules`).
- ⌘\\: `if let f = autofill.lastFocus(in: webView), let best = autofill.bestAutomaticLogin(for: f) { try await autofill.fill(best.id, into: f) } else { /* open the popover */ }`.
  `bestAutomaticLogin` only answers for a field the user clicked or tabbed into, outside
  cross-site frames, with an exact-origin login; everything else goes through the popover.
- Save bar: `autofill.save(capture, username: editedUsername)`, `autofill.neverSave(capture)` (per
  exact origin), or dismiss.

## Native UI expected

### Autofill popover (`NSPopover`, anchored to the field)

- Lists `focus.logins` (usernames only; the popover never needs a password). Exact matches first;
  a `.sameSite` match shows its host in secondary text ("from login.example.com").
- Preselect `focus.suggestedLoginID` (the second step of Microsoft or Google sign-in).
- When `focus.frame.isCrossSite`, say so: "Fill your login for **accounts.example.com** in a frame
  on this page?" The login is still matched to the frame's own origin; this is about clickjacking
  (the frame itself may be invisible: its page can't hide it from the script inside).
- `focus.offersGeneratedPassword`: a "Use strong password" row showing the generated password.
- Ignore clicks and Return in the popover for about 0.5 s after it appears, so a page that
  focuses a field under the pointer can't turn the user's next click or keypress into a fill
  (`fill` itself refuses within 0.3 s of the focus).
- Keyboard: ↑/↓, Return fills, Esc closes. Close it on navigation, scroll or tab switch.
- Show nothing when `logins` is empty and there's no generator row.

### Save bar (below the toolbar of the tab that submitted)

- "Save password for **user** on **example.com**?" or "Update password for **user**?" with Save
  (Update), Never for this site, and Not now. Show `capture.origin`, not the tab's URL: in an
  iframe they differ.
- Editable username before saving (a two-step sign-in's guess can be wrong). The password is
  never shown in the bar.
- Hold the `PasswordCapture` only while the bar is up; drop it when dismissed or the tab closes.

### Passwords manager window (Settings or ⌘⌥P)

- Search (`store.search`), list (`store.allLogins()`), edit (`store.update`), delete
  (`store.delete`), add (`store.add`), never-save list (`neverSaveOrigins`, `removeNeverSave`).
- Health: `store.securityReport()` gives weak logins and groups of logins reusing a password
  across sites. Show a badge per row and a summary.
- **Reveal and copy are behind LocalAuthentication**. Before showing or copying a password, call
  `LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your saved password")`
  (Touch ID, falling back to the Mac password). Keep the unlock for about 60 seconds while the
  window stays key, and re-lock when it resigns key, the screen locks, or the Mac sleeps.
- Copy with `SecretPasteboard.copy(_:)`: it keeps the item on this Mac (no Universal Clipboard),
  marks it concealed and transient for clipboard managers, and clears it after 60 seconds or at
  quit unless something else was copied.
- Report `store.unreadableCount()` if it's non-zero ("2 saved logins couldn't be decrypted").

## What the script reports

- **Focus**: only for fields the user can see (hit-tested at the field's middle, not
  transparent, clipped, masked, blurred or off-screen) in forms it recognizes.
- **Submissions**: only right after a trusted click or Return, and only passwords the user typed
  or iSmith filled that still hold that value. Pages can't forge a "Save" or "Update" by setting
  values and calling `requestSubmit()`.
- **Limits**: an opaque overlay with `pointer-events: none` over the field isn't detected (hit
  testing looks through it), and a page script on the site itself can always read what's filled
  into its own visible form. Same-origin script is trusted with that origin's logins, as in every
  browser.

## Rules the app must keep (threat model)

- Never log a `Login`'s username or password, a `PasswordCapture`, or fill arguments. The types
  redact themselves in `print`, `dump` and string interpolation; don't work around that.
- Never put passwords in URLs, notifications, crash reports, analytics, or agent context. When
  the agent panel and MCP server arrive, they get no access to `PasswordStore` or
  `PasswordAutofill`, and agent-driven tabs don't call `fill`.
- Never copy a password without `SecretPasteboard`.
- Never decide matches from `webView.url`; the controller matches on the frame's
  `securityOrigin`.

## Matching rules (summary)

See `Origin.swift` for the full rules and `OriginTests` for the table. A login saved for origin S
is offered on a frame of origin P when the scheme and effective port are equal and either the
hosts are equal (exact) or both are `https` hosts sharing a registrable domain under the Public
Suffix List (same site). `http` origins, IP addresses, single-label hosts, hosts that are public
suffixes, and hosts under multi-tenant services that aren't on the list (`Origin.exactOnlySites`:
Okta, SharePoint, Atlassian, Salesforce, Zendesk, …) match exactly only. Opaque origins match
nothing. Same-site matches are only filled from an explicit popover pick.

The Public Suffix List ships in `Sources/Passwords/Resources/public_suffix_list.dat`. Refresh it
from https://publicsuffix.org/list/public_suffix_list.dat before releases.

## Not in this package yet

- Brave password import (P5) writes through `store.save(origin:username:password:)`.
- Passkeys (entitlement pending).
- Password history: "Update" replaces the old password; there's no undo yet.
- Fields inside shadow roots are only recognized when their `<form>` is in the same shadow root.
