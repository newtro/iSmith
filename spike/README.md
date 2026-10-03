# iSmith sign-in spike

Proves the one unproven mechanism in DESIGN.md: copying an account's sign-in cookies between
per-space WebKit stores, so you sign in once per account and every space bound to it stays
signed in.

Spaces: Contoso (Microsoft: Contoso, Google, GitHub), Fabrikam (Microsoft: Fabrikam,
Google, GitHub), Contoso (second space) (Microsoft: Contoso only), Personal (Google, GitHub).

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
```

## Manual acceptance test

1. Contoso (⌘1): sign in to Outlook with the Contoso account. Tick "Stay signed in".
2. Fabrikam (⌘2): sign in to Outlook with the Fabrikam account.
3. Switch between ⌘1 and ⌘2: each shows its own mailbox, with no sign-in prompts.
4. Contoso: Go → Gmail, sign in with your personal Google account.
5. Fabrikam: Go → Gmail. Expected: already signed in.
6. Contoso (second space) (⌘3): Outlook. Expected: signed in as Contoso without a password.
7. Quit (⌘Q), reopen, and repeat steps 3, 5 and 6. Expected: still signed in everywhere.

The key button at the bottom of the rail shows the vault: cookie names per account (no values)
and a log of every copy between spaces.

Spike limits: the vault is plain JSON with owner-only permissions (the real one encrypts with a
Keychain key), password autofill isn't available, and spaces are hard-coded.
