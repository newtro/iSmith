# iSmith sign-in spike

Proves the one unproven mechanism in DESIGN.md: copying an account's sign-in cookies between
per-space WebKit stores, so you sign in once per account and every space bound to it stays
signed in.

Nothing is hard-coded: spaces, accounts and providers are managed in the app and saved to
`~/Library/Application Support/iSmithSpike/config.json`. First launch starts with Contoso,
Fabrikam, a second Contoso space, Personal and Newtro Studios.

- **New space**: + in the rail (⇧⌘N). Pick an account per provider, or "New account…".
- **Edit or delete a space**: right-click it in the rail (⇧⌘, edits the current one).
- **Accounts panel** (button at the bottom of the rail): rename accounts, sign out everywhere,
  remove unused accounts, add your own provider (any site, by cookie domain), and see the sync
  log.
- **Signed in somewhere new?** If you sign in to a provider in a space that has no account for
  it, a banner offers to save that sign-in as a new or existing account, or keep it local.

## Build and run

```bash
cd spike && xcodegen generate && xcodebuild -project iSmithSpike.xcodeproj -scheme iSmithSpike -derivedDataPath build build
open build/Build/Products/Debug/iSmithSpike.app
```

## Automated tests (no real sign-ins; separate stores and vault)

```bash
build/Build/Products/Debug/iSmithSpike.app/Contents/MacOS/iSmithSpike --selftest
build/Build/Products/Debug/iSmithSpike.app/Contents/MacOS/iSmithSpike --selftest --phase=write
build/Build/Products/Debug/iSmithSpike.app/Contents/MacOS/iSmithSpike --selftest --phase=read
build/Build/Products/Debug/iSmithSpike.app/Contents/MacOS/iSmithSpike --selftest --phase=config
```

## Manual acceptance test

1. Contoso (⌘1): sign in to Outlook with the Contoso account. Tick "Stay signed in".
2. Fabrikam (⌘2): sign in to Outlook with the Fabrikam account.
3. Switch between ⌘1 and ⌘2: each shows its own mailbox, with no sign-in prompts.
4. Contoso: Go → Gmail, sign in with your personal Google account.
5. Fabrikam: Go → Gmail. Expected: already signed in.
6. Contoso (second space) (⌘3): Outlook. Expected: signed in as Contoso without a password.
7. Quit (⌘Q), reopen, and repeat steps 3, 5 and 6. Expected: still signed in everywhere.
8. Personal (⌘4): Go → Etsy shop, "Continue with Google" as you@gmail.com.
9. Newtro Studios (⌘5): Etsy opens; "Continue with Google" as you@yourstudio.com.
10. Switch between ⌘4 and ⌘5: each shows its own Etsy shop, both signed in.

The key button at the bottom of the rail shows the vault: cookie names per account (no values)
and a log of every copy between spaces.

What the automated tests cover: sharing between open spaces, isolation between Microsoft
tenants, Google tracking cookies staying local, simultaneous changes in two spaces, sign-out
spreading, and session-only cookies surviving a relaunch (the case only the vault can cover).

Known risks outside the code:
- A tenant with device-based Conditional Access needs Apple's Enterprise SSO plug-in, which
  serves Safari and allowlisted apps only. If a tenant blocks sign-in here, that is policy, not
  cookies.
- Passkeys and Keychain autofill need Apple's web-browser entitlement. Use a password or
  Authenticator for now.
- A space that was closed while an account signed out elsewhere keeps its old cookies until the
  site rejects them.

Spike limits: the vault is plain JSON with owner-only permissions (the real one encrypts with a
Keychain key), and password autofill isn't available.
