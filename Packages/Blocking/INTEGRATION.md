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

```swift
let blocking = try BlockingController(directory: dataDir.appendingPathComponent("Blocking", isDirectory: true))
Task { await blocking.ruleLists() }     // start loading before the first tab needs the lists
blocking.startAutomaticRefresh()        // first check after 60 s, then hourly; downloads weekly
```

- `dataDir` is the app's data folder (`~/Library/Application Support/iSmith`, or
  `ISMITH_DATA_DIR` in development), so a development run never touches the real lists.
- `init` throws only if WebKit can't open a store in that folder.
- Normal launch: the lists come from the compiled store in under a millisecond. First launch,
  or the first launch after an OS update changes WebKit's compiled format: about 5 s in a debug
  build (on an M4 Max) to convert and compile the bundled snapshot or the last downloaded lists.

## 3. Each web view gets its own `WKUserContentController`

The lists are attached to a web view's content controller, so two web views must never share
one, or the shield for one site would change the other.

- New tab: give its `WKWebViewConfiguration` a new `WKUserContentController()`.
- Popup (`webView(_:createWebViewWith:for:windowFeatures:)`): the configuration WebKit passes is
  a copy whose `userContentController` is the **opener's**. Before creating the popup's web view,
  set `configuration.userContentController = WKUserContentController()`, re-add the app's user
  scripts, then apply blocking for the popup's URL:
  `await blocking.apply(to: configuration.userContentController, host: navigationAction.request.url?.host)`.
  (That delegate method is synchronous; use `blocking.applyIfLoaded(to:host:)` there. The lists
  are loaded long before a page can open a popup.)
- A hibernated tab that's recreated is a new web view: same as a new tab.

## 4. Navigation delegate: apply before each main-frame load

In the tab's `WKNavigationDelegate`:

```swift
func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
             preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
    if action.targetFrame?.isMainFrame == true {
        await blocking.apply(to: webView.configuration.userContentController, host: action.request.url?.host)
    }
    // … the rest of the app's policy (app links, downloads) …
    return (.allow, preferences)
}
```

- This runs for typed URLs, link clicks, back/forward, reloads and server redirects, so the
  lists always match the site being loaded. `WebViewTests` checks that a change made here applies
  to the navigation being decided.
- Only main-frame navigations: an iframe from another site follows the top-level site's shield.
- `apply` waits for the lists. On a normal launch that's instant. On a first launch it holds the
  first navigation for the few seconds the compile takes, so the first page is blocked too. To
  load without waiting instead, use `blocking.applyIfLoaded(to:host:)` here and rely on
  `listsDidChange` (below) to attach the lists once ready; pages loaded before then aren't blocked.

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
compiled lists, about 52 MB for both). After a refresh the previous compiled lists stay in
`Store/` until the next launch removes them, because open web views may still hold them.

## Updating the bundled snapshot

`Tools/update-blocking-snapshot.sh` downloads the current lists into
`Packages/Blocking/Sources/Blocking/Snapshot/`. Run it before a release.
