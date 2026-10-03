# iSmith sign-in spike

Proves the one unproven mechanism in DESIGN.md: copying an account's sign-in cookies between
per-space WebKit stores, so you sign in once per account and every space bound to it stays
signed in.

How it works: **sign in once, every space is signed in.** Each provider's sign-in session
(Microsoft, Google, GitHub, plus any you add) is shared by all spaces, including new ones. Each
space keeps its own cookies for the sites themselves, so Outlook, Azure DevOps or Etsy can be a
different account in each space. Add more accounts with the provider's own picker: Google's
"Add another account", Microsoft's "Use another account".

- **New space**: + in the rail (⇧⌘N). No account setup needed.
- **Overrides** (rarely needed): right-click a space → Edit Space. Per provider, pick a separate
  account or "Not shared (this space only)". Changing one clears that space's browsing data.
- **Accounts panel** (button at the bottom of the rail): add a provider by cookie domain, sign
  out everywhere, rename or remove separate accounts, and see the sync log.
- Settings live in `~/Library/Application Support/iSmithSpike/config.json`.

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

1. Any space: sign in to Gmail as you@gmail.com, then Google's "Add another account" →
   you@yourstudio.com. Every space's Google picker now shows both.
2. Personal: Etsy → "Continue with Google" → your personal account. Newtro Studios: Etsy → "Continue with
   Google" → your studio account. Both shops stay signed in, one per space.
3. Contoso: Outlook (Contoso). Fabrikam: Outlook → "Use another account" once → Fabrikam
   Point. Switch between the spaces: each keeps its own mailbox.
4. Create a new space: Gmail and Outlook open signed in, with the account picker.
5. Quit and reopen: still signed in everywhere.

The Accounts panel shows cookie names per account (no values) and a log of every copy between
spaces.

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
