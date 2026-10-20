# Passwords: integrating into the app

The `Passwords` package is the core of P4: the encrypted store, origin matching, the capture and
fill script, and the `PasswordAutofill` controller. It has no UI. This note lists the hook points
and the native UI the app adds on top.

## Setup at launch

Every `PasswordStore` is opened with an explicit `OpenMode`, which decides what `init` may change
on disk:

| Mode | Who | Missing key | Missing file | Key doesn't open the file |
|---|---|---|---|---|
| `.app` | the iSmith app | first run only (no file, or a file holding nothing): creates the key; a file with logins or a key check throws `.keyMissing`, nothing changed | creates it | moves it aside as `passwords.unreadable-<time>.sqlite` (with its `-wal`/`-shm`) and starts a new one |
| `.appStartOver` | the app, after the user confirmed "Start a New Passwords File…" | creates a new key, moves the old file aside (never deletes it) | creates it | as `.app` |
| `.existingOnly` | any other process (the iSmith Agent) | throws `.keyMissing` | throws `.fileMissing` | throws `.wrongKey` (`.unrecognizedFile` for a damaged file) |

`.existingOnly` never creates a key or a file, never moves, deletes, migrates or converts one, and
throws `.notSetUp` for a file the app hasn't set up yet (an older rollback-journal file, pending
migrations, no key check): open the app once. `recover(from:)` (and its backup) throws `.appOnly`
on such a store, and `BrowserState.checkPasswordStore` does nothing with it.

```swift
import Passwords

func openPasswords(dataDir: URL?) -> PasswordAutofill? {
    let store: PasswordStore
    do {
        store = try PasswordStore(fileURL: PasswordStore.defaultFileURL(dataDirectory: dataDir),
                                  keyStore: KeychainKeyStore(service: AppIdentity.passwordsKeyService,
                                                            account: "passwords", label: "iSmith passwords key"),
                                  mode: .app)
    } catch PasswordStoreError.keyMissing {
        // The key is gone but the file holds logins: never start over on our own. Offer
        // "Try Again", "Continue Without Passwords" and, after a confirmation that the old file
        // is kept, "Start a New Passwords File…" (open again with `mode: .appStartOver`).
        return nil
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
    // Each copy once (newest first): a login deleted after it was restored must stay deleted.
    for copy in PasswordStore.setAsideCopies(of: store.fileURL)
    where copy != store.movedAside && (try? store.wasRecovered(copy)) == false {
        _ = try? store.recover(from: copy)   // nil: sealed with another key; throws if locked
    }
    let health = try store.health()          // rows and unreadable rows: report unreadable > 0
    let autofill = PasswordAutofill(store: store)   // one for the whole app; passwords are global
    autofill.delegate = passwordUI                  // see "Delegate events" below
    return autofill
}
```

Another process opens the same file with `mode: .existingOnly` and reports any error; it never
offers to start over.

- The file is `~/Library/Application Support/iSmith/passwords.sqlite` (0600, folder 0700). With
  `ISMITH_DATA_DIR`, pass that folder as `dataDirectory`.
- The file is in WAL mode (the app converts an older rollback-journal file on its first open,
  which needs a moment with no other connection), with a 5-second busy timeout: the app and
  another process can have it open at once, readers never wait, and a write waits for another
  one rather than failing with `SQLITE_BUSY`. Its `-wal` and `-shm` side files are 0600 like the
  file, and anything that moves or copies the store must take the `-wal` with it (or use
  `backUp`, which writes one self-contained file). `secure_delete` and `trusted_schema = OFF`
  apply on every connection. The app opens a `DatabasePool`; `.existingOnly` opens a single
  `DatabaseQueue`, which (unlike a pool) doesn't write to the file when it opens.
- Every open store holds `passwords.sqlite.lock` (0600, made by the app, never moved or
  deleted) with a shared `flock` for as long as it's open, in every process. Moving the file
  aside (wrong key, damaged file, start over) needs that lock exclusively and doesn't wait: if
  any other store has the file open, `init` throws `.databaseUnavailable("another process has
  the passwords file open")` and changes nothing. Under the exclusive lock the file is judged
  again before anything moves, so a launch never moves aside a file another launch just started.
  `.existingOnly` needs the lock file to exist (else `.notSetUp`), keeps the very connection
  whose key check it verified, and refuses a file whose inode changed while it opened. A move
  aside that fails part way is put back; if that fails too, `init` throws
  `.moveAsideIncomplete` naming where each file is.
- `.existingOnly` judges the file through a read-only connection, which never checkpoints or
  removes the `-wal`/`-shm` (it therefore needs both side files to exist: the app leaves them,
  as SQLite on macOS does by default; without them it's `.notSetUp`). Only the `-shm` index's
  read marks change. The app's inspection may checkpoint committed WAL pages into the file when
  it closes, which loses nothing.
- Not yet crash-atomic: a move aside renames the main file, then its `-wal`, `-journal` and
  `-shm`, one at a time. A crash between renames leaves the main file at the new name and its
  `-wal` at the old one; nothing is deleted, but nothing reconciles it at the next launch yet.
- `close()` closes the store's connections and lets go of the lock (so does deallocating it).
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
| `codeFieldFocused(focus)` | A visible one-time-code field was focused, by the user (`isUserInitiated`) or by the page (verification pages usually focus their own field). | Look up codes for `focus.pageHost` (always the tab's top-level host), keep those `OneTimeCodeBinding.mayOffer(domain:in:)` allows and `focus.accepts(_:)` fits, and show the **code popover** when there are any. Keep looking (every second, up to 2 minutes) while the field stays focused. |
| `codeFieldBlurred(fieldID, frame)` | Focus left that code field, or its page was hidden or unloaded. A click in the app's popover isn't reported (the field stays the page's active element). | Stop looking; leave an open popover until it's answered. |

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
- `try await autofill.fillCode(code, into: codeFocus)`: types a one-time code into the focused code
  field, or into each box of a split field, only for a code the user picked. Refuses `.disabled`,
  `.tooSoon`, `.stale` / `.frameOriginChanged`, `.noField` (gone, hidden, no longer a code
  field), `.codeDoesNotFit` (not 3–12 ASCII letters and digits, longer than the field's
  `maxlength`, or not exactly one character per box) and `.codeNotAccepted` (a box or the field
  doesn't hold the code right after: don't mark it used). `autofill.lastCodeFocus(in:)` is the
  code field focused now (cleared when focus leaves it, or a login field is focused; the page
  re-focusing a field the user clicked keeps it user-initiated). ⌘\\ goes to it when it was
  focused after the last login field, and when the user focused it or didn't focus that login
  field: a page moving focus to a code field after the user clicked a password field doesn't get
  the ⌘\\ meant for the password.

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

### Code popover (`NSPopover`, anchored to the code field; the app's `CodeFill.swift`)

- One row per code, newest first: "Fill **123456** from Chase" (the SMS sender) and, for a code
  bound to a domain, "· for chase.com"; an unbound code names the page it goes into ("· into
  example.com"). A field in a cross-site frame says so first ("Fill a code into
  **auth.example.com**, a frame on this page?").
- A field only the page focused gets only codes bound to the site; unbound codes wait for the
  user's click or Tab into the field (a page can't focus a field by itself and put another
  site's unbound code under the pointer).
- Opened right after the user's click: first row preselected, 0.5 s input delay. Opened by itself
  (a code arrived while the field was focused): nothing preselected, so the Return that submits
  a code typed by hand goes to the page, and a 1 s input delay. Never anchored at the pointer
  (an iframe's field, whose position isn't known, gets the top of the web view).
- Keys, Esc and closing as the login popover; ⌘\\ over it fills the highlighted row. A code
  already shown for the field isn't shown again unasked; a new code is. A click on the field
  asks again. The page focusing the field again doesn't extend the 2-minute watch; a click does.
- ⌘\\ with no popover fills the newest code directly only into a field the user focused outside
  a cross-site frame; otherwise it opens the popover.
- Before filling, look the code up again (it may have been used or expired), then call
  `markUsed(id)` on the agent.
- Nothing when codes are off, the agent isn't registered (`SMAppService` status), it doesn't
  answer, "Offer codes in iSmith" is off (the agent then returns nothing), the tab is driven by
  an agent, or the page isn't https (http only on loopback hosts).

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

## One-time-code fields

The script reports a focused field as a code field when it is a visible `text`, `tel`, `number`
or untyped input (never `password`, `search`, `hidden` or read-only, never inside `role=search`)
and one of these holds:

- `autocomplete` includes `one-time-code` (and no `cc-*` token);
- its name, id, placeholder, aria-label, title, `<label>` or `aria-labelledby` text (camelCase
  and snake_case split into words) names a code: otp, totp, 2fa, mfa, passcode, one-time
  (code/password/pin), two-factor, two-step, multi-factor, verification / verify / confirmation /
  security / SMS / text / login / sign-in / authentication / access code, "enter the code",
  "code we sent"; Spanish and Portuguese "código de verificación/segurança/…", French "code de
  vérification/sécurité/confirmation", German "Bestätigungscode", "Sicherheitscode",
  "Einmalcode", Italian, Dutch, Polish and Swedish equivalents, and 認証コード, 验证码, 驗證碼,
  인증번호, "код подтверждения";
- `inputmode="numeric"` with `maxlength` 4 to 10, unless its text names an identifier (phone,
  mobile, tel, customer, member, account, user, login, email, id, card) or it is the username of
  a login form;
- it is one of a row of 4 to 8 inputs with `maxlength="1"` side by side in one form (a split
  field: reported once, by its first box, with `boxes`).

Except, for the last three (heuristics): a `maxlength` under 4 or over 12; an `autocomplete`
token for something else (`cc-*`, `postal-code`, `bday*`, `tel*`, `email`, `username`, passwords,
names, addresses); text naming zip/postal code, area or country code, promo, coupon, voucher,
discount, gift, referral, invite, quantity, amount, price, search, captcha, card, CVV/CVC/CSC,
expiry, month, year, birth date, age, SSN, IBAN or routing; and any form with card fields
(`cc-*` autocomplete, or card-number/CVC names), where "security code" is the card's CVC. A code
field is never also offered as a username field. Code fields may have invisible text (a
transparent input over drawn boxes, as the `input-otp` widget does); login fields may not.

Wrongly detected fields cost little: the popover only appears when a code has just arrived for
the page, and nothing is filled without the user.

**The binding** (`OneTimeCodeBinding`): codes are always looked up with the tab's **top-level**
host (`CodeFieldFocus.pageHost`: the main frame's own origin, or the tab's page for an iframe),
never an iframe's, and only for https pages (http on loopback). iSmith Agent returns codes bound
to that host or a parent domain and unbound codes under 2 minutes old. The app then keeps a
bound code only when its domain matches the top-level host **and**, for a field in an iframe,
the frame's own host: a page can't get chase.com's code by framing chase.com, and chase.com
can't hand its code to a third-party frame. Unbound codes follow the top-level page alone.

**Filling** runs in the content world, like a login fill: the frame must still show the same
document at the same origin, and the field must still be a visible code field the code fits. A
code is typed as a key down, the value through the element's own setter, an `insertText` input
event carrying the text, a key up and change, box by box for split fields with a 16 ms turn of
the event loop between boxes (so a React widget that keeps the digits in state re-renders before
the next box), so React and Vue controlled inputs and split-box widgets accept it. Right after
the last box, every box must hold its character (ignoring spaces and case; a box the page
already replaced counts), else `.codeNotAccepted`. The code is passed only to that call: it is
never in any of the page's worlds before the user picks it, and the page can't list codes.

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
