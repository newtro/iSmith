# Passwords: integrating into the app

The `Passwords` package is the core of P4: the encrypted store, origin matching, the capture and
fill script, and the `PasswordAutofill` controller. It has no UI. This note lists the hook points
and the native UI the app adds on top.

## Setup at launch

```swift
import Passwords

let store: PasswordStore
do {
    store = try PasswordStore(fileURL: PasswordStore.defaultFileURL(dataDirectory: dataDir),
                              keyStore: PasswordStore.keychainKeyStore())
} catch PasswordStoreError.keychainUnavailable {
    // Same handling as the vault: "Try Again" / continue without passwords. Nothing was touched.
}
if let aside = store.movedAside { /* tell the user once: saved passwords couldn't be opened, kept at `aside` */ }

let autofill = PasswordAutofill(store: store)   // one for the whole app; passwords are global
autofill.delegate = passwordUI                  // see "Delegate events" below
```

- The file is `~/Library/Application Support/iSmith/passwords.sqlite` (0600, folder 0700). With
  `ISMITH_DATA_DIR`, pass that folder as `dataDirectory`.
- The key is a 256-bit AES key in the file-based login Keychain, service
  `com.scottsmith.ismith.passwords-key`, account `passwords`, separate from the vault key.
- Add `Packages/Passwords` to `project.yml` under `packages:` and as a dependency of the
  `iSmith` target. It depends on `SignInSync` (for `KeyStore`) and GRDB 7.11.1 (exact).

## Attaching to web views

Call `autofill.attach(to: configuration)` on every `WKWebViewConfiguration` **before** the
`WKWebView` is created, in every space (passwords are global). Attaching the same configuration
twice is a no-op. When a tab closes, `autofill.forget(webView)` drops its two-step state (it's
also dropped automatically when the web view is deallocated).

The script runs in the content world `PasswordAutofill.defaultWorldName` (`iSmith.passwords`).
Don't run other app scripts in that world, and never register a handler named `ismithPasswords`
in the page world.

## Delegate events

All on the main actor.

| Event | When | App does |
|---|---|---|
| `loginFieldFocused(focus)` | The user focuses or clicks a username or password field of a recognized form (trusted events only). | Show the **autofill popover** anchored to `focus.rectInWebView` (main frame) or to the mouse location (iframes; `rectInWebView` is nil). |
| `captured(capture)` | A form was submitted with a new login (`.save`) or a changed password (`.update`). Unchanged logins and never-save origins aren't reported. | Show the **save bar**. |
| `foundForms(kinds, frame)` | A frame gained login forms (sent when the set of kinds changes). | Optional: a key icon in the address bar; enables ⌘\\. |

## Actions

Only ever call these in direct response to a user action (a click in the popover, ⌘\\, a save bar
button). Never call `fill` on page load, on a timer, or from anything a page or an agent can
trigger.

- `try await autofill.fill(loginID, into: focus)`: fills the username (if visible) and password
  of the focused field's form, or just the username on a first sign-in step. It re-reads the login
  from the store, refuses (`.originMismatch`) a login that doesn't match the frame's origin,
  refuses (`.stale`) when the frame has navigated since the focus, and refuses (`.noField`) when
  the field or the password field is gone or hidden. It marks the login used.
- `try await autofill.fillGeneratedPassword(password, into: focus)`: for `focus.offersGeneratedPassword`.
  Generate with `PasswordGenerator.generate(focus.requirements)` (it honors `minlength`,
  `maxlength` and `passwordrules`).
- ⌘\\: `if let f = autofill.lastFocus(in: webView), let best = f.suggestedLoginID ?? f.logins.first?.id { try await autofill.fill(best, into: f) }`.
- Save bar: `autofill.save(capture)`, `autofill.neverSave(capture)` (per exact origin), or dismiss.

## Native UI expected

### Autofill popover (`NSPopover`, anchored to the field)

- Lists `focus.logins` (usernames only; the popover never needs a password). Exact matches first;
  a `.sameSite` match shows its host in secondary text ("from login.example.com").
- Preselect `focus.suggestedLoginID` (the second step of Microsoft or Google sign-in).
- When `focus.frame.isCrossSite`, say so: "Fill your login for **accounts.example.com** in a frame
  on this page?" The login is still matched to the frame's own origin; this is about clickjacking.
- `focus.offersGeneratedPassword`: a "Use strong password" row showing the generated password.
- Ignore clicks in the popover for about 0.5 s after it appears, so a page that focuses a field
  under the pointer can't turn the user's next click into a fill.
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
- Copy with `SecretPasteboard.copy(_:)`: it marks the item concealed and transient for clipboard
  managers and clears it after 60 seconds unless something else was copied.
- Report `store.unreadableCount()` if it's non-zero ("2 saved logins couldn't be decrypted").

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
hosts are equal (exact) or both hosts share a registrable domain under the Public Suffix List
(same site). IP addresses, single-label hosts and hosts that are public suffixes match exactly
only. Opaque origins match nothing.

The Public Suffix List ships in `Sources/Passwords/Resources/public_suffix_list.dat`. Refresh it
from https://publicsuffix.org/list/public_suffix_list.dat before releases.

## Not in this package yet

- Brave password import (P5) writes through `store.save(origin:username:password:)`.
- Passkeys (entitlement pending).
- Fields inside shadow roots are only recognized when their `<form>` is in the same shadow root.
