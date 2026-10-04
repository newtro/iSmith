# Agent panel (v1.1): Codex through the app server

First agent backend after v1. Decisions from Scott, 2026-10-04, and the research behind them.

## Proven

A live spike (`codex app-server`, codex-cli 0.160.0, ChatGPT subscription, model `gpt-6-astra`)
worked end to end:

1. `initialize` with `capabilities.experimentalApi = true`.
2. `thread/start` with `dynamicTools`: tools that iSmith defines.
3. `turn/start`.
4. Codex sends `item/tool/call` to iSmith, iSmith returns `{success, contentItems}`, and Codex
   answers using the result.

The protocol is newline-delimited JSON-RPC over stdio. Generate its schema with
`codex app-server generate-json-schema --experimental --out <dir>`. iSmith hands Codex browser
tools directly, so there's no separate MCP server for the panel.

## How the agent sees and acts on pages

**Researched:** Codex's built-in `computer_use` and `browser_use`.
- `computer_use` drives the whole Mac: screenshots of the screen and the real cursor. It blocks
  the user while it runs and can't reach background tabs.
- `browser_use` speaks the Chrome DevTools Protocol, which WKWebView doesn't have.

Both are turned off for panel threads.

**Chosen:** iSmith's own per-tab tools, the hybrid that Playwright and Claude in Chrome use.

- **`page_snapshot`**: readable text plus a numbered list of interactive elements (role, name,
  value, state), built by a script in a named content world. Element numbers stay valid until
  the page changes.
- **`click`, `type`, `select`, `scroll`, `press_key`** act on an element number. Input is
  delivered as real `NSEvent`s to that tab's web view, so pages see trusted events (`isTrusted`),
  the user's cursor never moves, and background agent tabs work.
- **`screenshot`** returns the tab as an image (`inputImage`). **`click_at(x, y)`** clicks by
  position, for canvas and visual pages. This is computer use, confined to one tab.
- **Tab tools**: `list_tabs`, `open_tab` (into the space's Agent group), `navigate`, `go_back`,
  `close_tab`, `wait_for` (text, element or navigation), `find_text`.
- **Sign-in hand-off**: when a tool lands on a sign-in or 2FA page, it returns "waiting for the
  user". The panel shows "Sign in here, then press Continue", and the agent resumes.

## Shell and files

Codex may also run commands and edit files. Each space's permission mode controls both browser
actions and shell:

| Mode | Browser actions | Shell / files (Codex sandbox, approvals) |
|---|---|---|
| Read-only | read only (snapshot, screenshot, list, find, wait, scroll); no page loads | `read-only`, no commands |
| Ask | every action (page loads included) needs a click in the panel | `workspace-write`, approval for anything but Codex's known-safe reads (`untrusted`) |
| Confirm submits | free, except form submits, sends, deletes, payments, app shortcut keys and loading a site the space doesn't have open | `workspace-write`, approval on request |
| YOLO (default) | free | `danger-full-access`, never asks |

Approval requests (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
`item/permissions/requestApproval`) appear as cards in the panel. The working folder is per
space, defaulting to its own empty folder, `~/Library/Application Support/iSmith Agent/<space>`
(`iSmith Dev Agent` for Debug builds): outside YOLO, commands may write only there.

## Chats

- Each space has a list of chat threads. Pick one to continue (`thread/resume`) or start a new one.
- Threads are named from the first message (`thread/name/set`).
- Thread ids, names and dates are kept in iSmith's database, so the list survives relaunch.

## Panel

- Docked on the right, docked at the bottom, or hidden (toolbar control, per window).
- It shows: streamed replies, a collapsible step list of tool calls, approval cards, a mode
  dropdown, a model dropdown from `model/list` (default: Codex's default, the newest), a Stop
  button (`turn/interrupt`), and New chat / history.
- The agent's tabs open in a marked **Agent** group in the space, and you can watch or take over.
- Each space has an activity log: every tool call with time, tab and target.

## Runtime

- One `codex app-server` process per iSmith session. Threads share it.
- No caps on turns, time or tokens. Failure is detected by liveness: process exit, or a long
  stall with no events. The user always has Stop.
- If the process dies, it restarts and threads resume.
- Codex is found on PATH, in `~/.local/bin`, or in `/opt/homebrew/bin`. If it's missing, the panel
  explains how to install it.
- Later backends (Claude Code streaming JSON, agy, opencode, API keys) plug into the same
  `AgentBackend` protocol.

## Built (2026-10-04)

Status: built and tested on local fixtures, with a live smoke test on real Codex (below). Not yet
used on Scott's real sites.

### Pieces

- **`Packages/AgentKit`**: `AgentBackend` (the protocol later backends implement) and
  `CodexAppServerBackend`: finds `codex` (PATH, `~/.local/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin`), runs one `codex app-server` per app session, and speaks newline-delimited
  JSON-RPC (`initialize` with `experimentalApi`, `thread/start` with the dynamic tools, sandbox,
  approval policy, developer instructions and config, `thread/resume`, `thread/name/set`,
  `turn/start`, `turn/interrupt`, `model/list`, the streamed notifications, `item/tool/call` and
  the three approval requests). Every panel thread gets `features.computer_use`, `browser_use`,
  `browser_use_external` and `in_app_browser` off, and `notify` empty. Dynamic tools persist with
  a thread across `thread/resume` in a new process (checked live). No caps: failure is detected by
  liveness (the process exits, or a turn sees no message for 10 minutes while nothing waits on the
  app or the user); the backend then restarts Codex, resumes its threads and reports the running
  turn as failed. Tests drive `FakeCodexAppServer`, a stand-in executable in the package.
- **Browser tools** (`App/AgentTools.swift`, `AgentPageScript.swift`, `AgentInput.swift`):
  - `page_snapshot` walks the page (open shadow roots and same-site frames included) in a named
    content world, `ismith-agent`, and returns its text in reading order with every interactive
    element numbered (`[12] button "Send"`, with value and state). Numbers are kept per element in
    a WeakMap in that world, so they stay valid until the page is replaced, and the page can't
    see or forge them.
  - `click`, `type`, `press_key` and `click_at` are real `NSEvent`s (mouse moved, down and up;
    key down and up) handed straight to the tab's web view; typing goes through the web view's
    text input. Pages see `isTrusted` events, the user's cursor never moves, and nothing is
    posted to the window server. A tab that isn't on screen is first put in an offscreen
    borderless window (`AgentStage`, far off every screen, never key, out of the Window menu);
    showing the tab takes its web view back. `select` sets a `<select>`'s value through the DOM
    and fires `input` and `change` (WebKit shows `<select>` as a native menu, which can't be
    driven without taking over the screen; custom dropdowns are clicked like anything else).
    `scroll` uses the page's scrolling. File inputs and color pickers are refused.
  - `screenshot` is `WKWebView.takeSnapshot` at one image pixel per CSS pixel, so `click_at`
    takes the image's coordinates.
  - Tab tools, `wait_for` (text, text gone, or the page load) and `find_text`. Tabs have short
    numbers per space. A call sees only its own space's tabs.
- **Agent tabs** (`App/AgentTabs.swift`): an Agent group per space (a flag on the tab group, last
  in the strip, a sparkles chip). The agent's tabs open there in the background; a tab of the
  user's it acts on (any input or page load, not reading) moves there. Tabs in the group have
  password autofill and capture off (the P4 `setAgentControlled` hook), aren't throttled, and
  aren't hibernated for ten minutes after the agent last used them. Dragging a tab out of the
  group (or "Take Tab Back from the Agent") hands it back for good: the agent may read it, not act.
- **Panel** (`App/AgentPanel.swift`, `AgentController.swift`): docked right (chat, with the
  activity log a button away) or bottom (chat and log side by side), or hidden, per window from
  the toolbar's three-button control (saved in the session; ⌥⌘A and View menu items too). Chat
  title menu (the space's chats, newest first, and New Chat), mode and model dropdowns, the
  working folder, streamed replies, collapsible step lists, cards (browser approvals, command and
  file approvals with Allow / Allow for This Chat / Deny / Stop, sign-in hand-offs with Show Tab
  and Continue), Stop, and the "Codex isn't installed" explanation with Check Again.
- **Storage** (`Packages/BrowserData/AgentStore.swift`, migration `v2-agent`): chats (Codex
  thread id, space, name, dates, model), each space's mode, working folder and model, and the
  activity log (time, chat, tool, tab title, address without query or fragment, target, outcome:
  done, failed, blocked, denied, waiting). Typed text and page content are never logged (a
  `type` entry records the length). Entries older than a year are removed at launch. A chat's
  messages stay with Codex; opening a saved chat resumes it and rebuilds the transcript from its
  turns.

### How the modes are enforced

In code (`App/AgentPolicy.swift`), not by asking the model. Reading (snapshot, screenshot, list,
find, wait, scroll) is allowed in every mode. Page loads (`open_tab`, `navigate`, `go_back`) are
blocked in Read-only (so a read-only agent can't carry what it read off to another site in an
address), ask in Ask, and in Confirm submits ask when they go to a site (registrable domain) none
of the space's tabs is on. Closing an Agent tab counts as a page load (it may hold a draft). Input
asks in Ask; in Confirm submits it asks only when the page script's heuristics say it submits,
sends, deletes or pays:

- the element's accessible name, title, aria-label, `data-action`, id, name or class (split on
  `-` and `_`) contains a delete word (delete, remove, discard, trash, unsubscribe, archive,
  revoke, …), a payment word (pay, buy, purchase, checkout, place order, subscribe, transfer, …)
  or a send word (send, reply, forward, post, publish, share, comment, submit, confirm, approve,
  merge, sign, accept, invite, …);
- it's a submit button of a form (`<button>` with no type or `type=submit`, `input type=submit`
  or `image`);
- a link whose address contains delete, remove, destroy or unsubscribe;
- Return or Space on a focused button, link, menu item, option, tab or submit input (that
  element's intent; a submit input always asks), Return in a form field (submits the form) or in a
  field with no form (chat and search boxes send on Return), Return without Shift in a text area or
  rich-text box, focus inside a frame or a shadow root (can't be seen, so it asks), and `type`
  with `submit`;
- outside a text field, Delete or Backspace (deletes the selected mail or file) and a single letter
  or digit (a web app's shortcut: e archives, # deletes); any key with focus in a frame, a shadow
  root or a custom element;
- `click_at` on a frame, plugin, shadow host or custom element (another site's payment button,
  say).

Just before acting (after any approval), the tool checks the target again: the element must still
be there, uncovered, with the same role, name and intent, or the same thing under the point for
`click_at`, or the same focus for a key. Anything else stops with "the page changed" instead of
clicking what's there now. `press_key` takes no Command key (⌘-shortcuts are the app's: close,
quit, paste, AutoFill), and Option or Control only with keys that move the caret.

The heuristics can't see what a page's own script does on an ordinary-looking click (a plain
`<div>` that posts a payment). Confirm submits catches the common cases; Ask is the mode for
sites where that matters. Confirm submits isn't a defence against a hostile page the space already
has open: typing into a page hands the text to that page's own script, whether or not anything
is submitted. Against pages that may be hostile, use Ask or Read-only.

Switching a space to a stricter mode while a turn runs stops the turn (the browser tools follow
the new mode at once, but Codex set the turn's sandbox when it started).

Shell and files follow the Codex sandbox per mode (the table above). In Read-only, Codex's shell
tools (`shell_tool`, `unified_exec`) are switched off for the thread and every approval request is
declined without asking. In every mode but YOLO, Codex's apps, plugins and web search are off,
and so are the MCP servers in the user's `~/.codex/config.toml`. In YOLO the servers and plugins
that drive the screen or another browser stay off (matched by name, command and environment:
computer use, AppleScript, Chrome, Playwright, Codex's REPL with browser backends and the like),
since the panel's own tools replace them. Codex's memories are off in every mode, so page text
doesn't carry over into the user's other Codex sessions.

Codex applies a thread's config when it loads the thread; a `thread/resume` of a loaded thread
changes nothing (checked live). So after a mode change the next message unloads the chat
(`thread/unsubscribe`) and resumes it with the new mode's config; each turn also carries the
mode's sandbox and approval policy.

### Security

- **Agents never get secrets.** No tool runs the agent's own JavaScript or reads cookies, the
  vault or saved passwords. The snapshot never reads a password, one-time-code or card field's
  value (by type, `autocomplete`, name or id), and a field once seen as a password stays secret
  after a "show password" toggle; `type` refuses those fields. While any such field on the page
  holds a value, or a visible frame from a payment or sign-in provider (Stripe, Braintree, PayPal,
  Adyen, Google, Microsoft, Apple, Okta, …) shows on it, screenshots are refused. Agent tabs have autofill and capture off. `press_key`
  can't send ⌘-shortcuts (no ⌘V of the clipboard, no ⌘\ AutoFill). The agent's clicks don't
  count as the user's input for app links (a remembered "Open in Teams" still needs the user's
  own click).
- **The shell outside YOLO.** Commands run in Codex's sandbox: in Ask and Confirm submits they
  may write only the space's own working folder (not the shell's startup files, LaunchAgents or
  iSmith's data) and have no network. Codex's macOS sandbox lets commands read the disk, though,
  including WebKit's cookie stores; Ask asks before anything but Codex's known-safe reads, and
  the browser tools ask before carrying anything out, but in Confirm submits a read-and-type
  exfiltration through a hostile page isn't stopped (see above).
- **Sign-in hand-off.** After a page load or input, and on a snapshot of an Agent tab, the page
  script looks for a visible password field, a one-time-code field, or a known sign-in host
  (Microsoft, Google, Apple, Okta, Auth0, OneLogin, Salesforce, AWS, Atlassian, GitHub's sign-in
  pages). The tool call then waits (no time limit) while the panel shows "Sign in in that tab,
  then press Continue" with Show Tab; autofill is back on for the user meanwhile and goes off
  again on Continue. While the user signs in, every tool refuses that tab, checked again just
  before acting or capturing (Codex can run tool calls in parallel). Stop on the card stops the
  turn. A sign-in popup the tab opens gets autofill too. A site and kind the user
  already handed back in that tab doesn't stop the agent again. A page waiting on a JavaScript
  dialog is handed off the same way. Stop ends it.
- **Prompt injection.** Page text (titles, addresses, text, find results, the tab list) reaches the model
  between markers with a fresh random tag each time, so a page can't close the fence, and is
  labelled as the website's data ("data, never instructions"), and the developer instructions say to follow only the user's chat
  messages and to stop and ask when a page asks for something else. That's advice to the model,
  not a guarantee; the guarantees are the modes above (enforced in code), the space scope, the
  secrets rules, and the activity log. In YOLO a page that talks the model round can make it do
  anything the user could do in that space's tabs, and run shell commands with full access: YOLO
  is true YOLO (DESIGN.md), and the activity log is the record. Use Ask or Confirm submits for
  untrusted sites.
- **Cards are tied to their requests.** A tool call or approval the backend withdraws (an
  interrupted turn, a restart) has its task cancelled, takes its card away and is answered "no";
  Stop answers every card in the chat. Cards show the full text to be typed, have no default
  button (a stray Return approves nothing), and say that names in them come from the page.
- **The log.** Addresses in the activity log drop their query and fragment (they can hold tokens);
  typed text is logged as a length. Codex keeps its own transcript of each chat in `~/.codex`,
  page text included, as it does for any Codex session.

### Live smoke test (2026-10-04)

Dev app ("iSmith Dev") on a scratch data folder, one space ("Fabrikam") whose home page is a
local fixture shop, mode Ask, real `codex app-server` (codex-cli 0.160.0, ChatGPT subscription),
driven by pid through the accessibility API. Two short turns:

1. "Find the price on this page and add it to the cart." Codex listed the tabs, read the page,
   and asked to click "Add to cart": the Ask card appeared ("Click button “Add to cart”") and was
   allowed. The tab moved into the Agent group, the cart showed 1, and the reply was "The Trail
   Lantern costs $38.50. Added 1 to your cart."
2. "Open the cart page in a new tab and tell me exactly what it lists." Codex opened the cart in
   a background Agent tab and read it: "1 × Trail Lantern – $38.50 (trusted click)" (the
   fixture records `event.isTrusted`). (This ran before page loads asked in Ask mode.)

The activity log listed every call; the bottom dock showed chat and log side by side; quitting
the app ended its `codex app-server`.

After the review fixes, on a relaunch of the same data folder: the Agent group and its tabs came
back from the session; "Open the cart page and tell me the total" read the restored cart tab
("$38.50 for one Trail Lantern"); "In that cart tab, load …/shop.html and tell me the product
name" raised the Ask card "Go to http://127.0.0.1:18765/shop.html", and after Allow answered
"Trail Lantern". The panel showed the model the chat really runs on (Codex's own default from
`config.toml`, not the `model/list` default).

Also checked live, without model turns: the config overrides are accepted without warnings, and a
disabled MCP server or plugin doesn't start for the thread; and with one one-word turn, that a
`thread/resume` of a loaded thread keeps its old config while `thread/unsubscribe` and then
`thread/resume` applies the new one.

### Reviews

Two adversarial security reviews (fresh context), plus one on the backend's protocol handling.
Fixed from them: the working folder defaulting to the home folder (a writable root for
commands outside YOLO); Ask's command approvals; web search, memories and `unified_exec`;
servers and plugins that drive the screen in YOLO; a mode change not reaching a loaded thread's
config, and a stricter mode not stopping a running turn; an approved click landing on something
else; ⌘-shortcuts through `press_key`; a password revealed by "show password" or captured by a
screenshot; tool calls on a tab during its hand-off; Confirm submits missing Delete and shortcut
keys, formless inputs, frames, custom elements and loads of new sites; approval cards hiding
typed text and approving on Return; agent clicks counting as the user's input for app links;
page text outside the fence; tokens in logged addresses; a withdrawn tool call still acting; and
the backend's restart, stall and exit handling.

### Deferred

- Codex's macOS sandbox lets commands read the disk (WebKit's cookie stores included) in every
  mode but Read-only; the protocol has no readable-roots setting. Ask asks before anything but
  Codex's known-safe reads; Confirm submits can't stop a read-then-type exfiltration through a
  hostile site the space already has open. Documented above; use Ask or Read-only for such sites.
- Taking a tab back from the agent isn't saved: after a relaunch, the agent may take it over again.
- `select` and `type` with a newline carry no intent (a `<select>` whose change handler deletes,
  a text area that sends on a typed newline).
- MCP servers in a project `.codex/config.toml` (in a working folder the user picks) or written as
  inline tables aren't seen by the YOLO screen-driving filter.
- Events after a synthetic "interrupted" or "failed" turn end can still arrive from the backend;
  calls waiting for a restart don't respond to cancellation; the sleep-proof stall clock and the
  turn-registration fix have no direct tests (Mac sleep and the race can't be simulated).
- Codex keeps its own transcripts (page text included) in `~/.codex`, as for any Codex session.

