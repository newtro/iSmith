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
| Read-only | read only (snapshot, screenshot, list) | `read-only`, no commands |
| Ask | every action needs a click in the panel | `workspace-write`, approval on request |
| Confirm submits | free, except form submits, sends and deletes | `workspace-write`, approval on request |
| YOLO (default) | free | `danger-full-access`, never asks |

Approval requests (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
`item/permissions/requestApproval`) appear as cards in the panel. The working folder is per
space, defaulting to the home folder.

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
