# Wiring Blocking into the app

The package has no UI. Wire it in after P1 (tabs) and P2 (navigation delegate) land. Everything
below runs on the main actor.

## 1. Project and build

- `project.yml`: add the package next to `SignInSync`, and add it to the `iSmith` target's
  dependencies:

  ```yaml
  packages:
    Blocking:
      path: Packages/Blocking
  targets:
    iSmith:
      dependencies:
        - package: Blocking
  ```

  The package's resource bundle (`Blocking_Blocking.bundle`, holding the 3.6 MB list snapshot)
  is copied into the app by Xcode automatically.
- The `Makefile`'s `test-package` already runs `swift test` in `Packages/Blocking`.

## 2. One controller per app, at launch

Create it where `BrowserState` is created (so the windowless XCTest host app, which never makes a
`BrowserState`, never loads or downloads lists):

```swift
let blocking = try BlockingController(directory: paths.dataDir.appendingPathComponent("Blocking", isDirectory: true))
Task { await blocking.ruleLists() }     // start loading before the first tab needs the lists
blocking.startAutomaticRefresh()        // first check after 60 s, then hourly; downloads weekly
```

- `paths.dataDir` is `AppPaths.standard.dataDir`: `~/Library/Application Support/iSmith`, or
  `ISMITH_DATA_DIR` when that's set. `make run` and the Xcode scheme don't set it, so a plain
  development run uses (and refreshes) the real lists, as it uses the real config and vault.
- `init` throws only if WebKit can't open a store in that folder.
- Normal launch: the lists come from the compiled store in under a millisecond. First launch,
  or the first launch after an OS update changes WebKit's compiled format: about 5 s in a debug
  build (on an M4 Max) to convert and compile the bundled snapshot or the last downloaded lists.

## 3. Each web view gets its own `WKUserContentController`

The lists are attached to a web view's content controller, so two web views must never share
one, or the shield for one site would change the other. Don't add or remove content-rule lists on
these controllers outside `BlockingController`: it remembers what it attached.

- New tab: give its `WKWebViewConfiguration` a new `WKUserContentController()`.
- Popup (`webView(_:createWebViewWith:for:windowFeatures:)`): the configuration WebKit passes is
  a copy whose `userContentController` is the **opener's** (checked: it's the same object).
  Before `makeWebView(configuration)`, set `configuration.userContentController =
  WKUserContentController()` and re-add the app's user scripts and script message handlers. Then
  apply blocking with `blocking.applyIfLoaded(to: configuration.userContentController, host:)`
  (that delegate method is synchronous; the lists are loaded long before a page can open a
  popup). For `host`, use `navigationAction.request.url?.host`, or the opener's
  `webView.url?.host` when that's nil (`window.open('')` or `about:blank`, which the opener then
  writes into).
- A hibernated tab that's recreated is a new web view: same as a new tab.

## 4. Navigation delegate: apply when a main-frame navigation is allowed

The rule lists change what the web view loads from then on, including for the page still on
screen. So apply the destination's setting only once the navigation is allowed, and put the
current page's setting back if the navigation ends before committing. In `BrowserState`'s
`WKNavigationDelegate`:

```swift
// Replaces the decisionHandler version: WebKit calls only one of the two, so the app's own
// policy (app links today) moves in here.
func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
             preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
    let policy: WKNavigationActionPolicy = /* the app's decision: app links, downloads … */
    if policy == .allow, action.targetFrame?.isMainFrame == true {
        await blocking.apply(to: webView.configuration.userContentController, host: action.request.url?.host)
    }
    return (policy, preferences)
}

func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    tab(for: webView).committedHost = webView.url?.host     // whatever per-tab state P1 has
}

func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    blocking.applyIfLoaded(to: webView.configuration.userContentController, host: tab(for: webView).committedHost)
}
```

- Do the same `applyIfLoaded(…committedHost)` where a main-frame navigation turns into a
  download (`navigationAction:didBecome:` and `navigationResponse:didBecome:`) and where
  `decidePolicyFor navigationResponse` cancels it.
- `decidePolicyFor` runs for typed URLs, link clicks, back/forward, reloads and server
  redirects, so the lists match the site being loaded. `WebViewTests` checks that a change made
  there applies to the navigation being decided, and that a cancelled or failed navigation leaves
  the page on screen with its own setting (the test's `Navigator` is this recipe).
- Only main-frame navigations: an iframe from another site follows the top-level site's shield.
- A host-less URL (`msteams:`, `about:blank`) counts as blocked. App links are cancelled before
  `apply`, so they never change the page's setting.
- `apply` waits for the lists. On a normal launch that's instant. On a first launch it holds the
  first navigation for the few seconds the compile takes, so the first page is blocked too. To
  load without waiting instead, use `blocking.applyIfLoaded(to:host:)` here and rely on
  `listsDidChange` (below) to attach the lists once ready; pages loaded before then aren't blocked.
- Applying the same lists again changes nothing, so calling this on every navigation is cheap.

## 5. The shield button

- State: `blocking.isBlocked(host: webView.url?.host ?? "")` (or `isBlocked(url:)`). The
  allowlist is per site (registrable domain): allowing `www.cnn.com` covers `edition.cnn.com`.
  `BlockingController.site(for: host)` gives the name to show ("Blocking off for cnn.com").
- Toggle: `try blocking.setAllowed(host: host, !blocked)`. It saves `allowlist.json` and posts
  `BlockingController.allowlistDidChange` with `userInfo["site"]`. If saving fails it throws and
  nothing changes; show the error.
- On `allowlistDidChange`, for every open web view (all windows and spaces) whose
  `BlockingController.site(for: webView.url?.host ?? "")` equals that site: call
  `blocking.applyIfLoaded(to: webView.configuration.userContentController, host: webView.url?.host)`
  and then `webView.reload()`. A rule-list change only affects loads that start afterwards.
- There's no blocked-item count: WebKit has no public API for it.

## 6. New lists after a refresh

Observe `BlockingController.listsDidChange` (posted when the launch's first load finishes and
after a refresh swaps in new lists). For every open web view, call
`blocking.applyIfLoaded(to: webView.configuration.userContentController, host: webView.url?.host)`.
No reload: the new lists apply from the next load, and pages already open keep working.
`apply` takes off the previous lists, including ones from before a refresh.

## 7. Settings (optional, later)

- `blocking.allowedSites` lists the allowlisted sites; `setAllowed(host: site, false)` removes one.
- `blocking.status` has the lists' origin (bundled or downloaded), each list's version, rule
  counts, the last check and the last error, for an "Ad blocking: EasyList 202610030410, checked
  2 days ago" line.
- `await blocking.refresh(force: true)` is "Update now".

## Files

Under the injected directory: `state.json` (lists in use, versions, refresh schedule),
`allowlist.json`, `lists/` (the downloaded copies in use, about 3.6 MB) and `Store/` (WebKit's
compiled lists, about 52 MB for both). After a refresh, the lists it replaced stay in `Store/`
(an open web view may still hold them) until the next refresh or launch removes them, so `Store/`
holds at most two generations.

## Updating the bundled snapshot

`Tools/update-blocking-snapshot.sh` downloads the current lists into
`Packages/Blocking/Sources/Blocking/Snapshot/`. Run it before a release.
