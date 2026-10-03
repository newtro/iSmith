# iSmith

A macOS browser for working across several organizations at once. Each **space** (Contoso,
Fabrikam, Personal, …) has its own WebKit data store and tinted chrome. Sign-ins to providers
such as Microsoft, Google and GitHub are shared by every space through an encrypted vault, so you
sign in once. Each site's own session stays in its space, so Outlook or Etsy can show a different
account in each space.

See [DESIGN.md](DESIGN.md) for the model and [BUILD_PLAN.md](BUILD_PLAN.md) for the v1 phases.
`spike/` is the prototype that proved the sign-in sync. It's kept for reference.

## Layout

- `App/`: the SwiftUI and AppKit app (rail, tab strip, toolbar, space editor, Accounts panel).
- `Packages/SignInSync/`: the sign-in engine, with no UI. It holds providers, accounts and spaces
  (`Config`), the encrypted `Vault`, `CookieSync`, `SpaceManager`, and the one-time import from
  the spike.
- `Packages/Blocking/`: ad and tracker blocking, not yet wired into the app. EasyList and
  EasyPrivacy become WebKit content-rule lists, refreshed weekly, with a per-site allowlist.
  `Packages/Blocking/INTEGRATION.md` lists the app's hook points.
- `Tools/update-blocking-snapshot.sh`: refreshes the filter lists bundled for first launch.
- `AppTests/`: tests that run inside the signed app.
- `project.yml`: the XcodeGen spec. `iSmith.xcodeproj` is generated from it and not committed.

## Build, test, run

Needs Xcode and XcodeGen (`brew install xcodegen`).

```bash
make build   # generate the project and build Debug into build/
make test    # package tests (SignInSync, Blocking; swift test), then the app-hosted tests
make run     # build and open the app
```

The package's sync tests use real WebKit stores. Each test makes its own stores and deletes them
afterwards. A full run takes about two minutes because the tests wait for the sync to settle.

## Data

- `~/Library/Application Support/iSmith/` holds `config.json` and `vault.json`, both owner-only.
  The vault is encrypted with AES-GCM. Its key is in the login Keychain under
  `com.scottsmith.ismith.vault-key`.
- On first launch, iSmith imports the spike's config and saved sign-ins from
  `~/Library/Application Support/iSmithSpike/`. It only reads the spike's files. The spike's
  WebKit stores don't come over, so sites ask for an account once, and a space set to "Not
  shared" signs in once.
- For development, `ISMITH_DATA_DIR=/some/folder` starts the app on another folder with no spike
  import:
  `ISMITH_DATA_DIR=/tmp/ismith-dev build/Build/Products/Debug/iSmith.app/Contents/MacOS/iSmith`.

## Updates

Sparkle 2 is built in. "Check for Updates…" is in the app menu and reads the appcast from the
public `newtro/iSmith-releases` repo. Automatic checks stay off until releases exist (P7).
