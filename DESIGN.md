# iSmith Browser: Design

A macOS browser for people who work across several organizations at once (consultants,
contractors) and who use AI agents in the browser. Goal: never sign in again just to check an
email or open a work item, and let agents work safely in the right identity.

Status: design. No code yet.

## Decisions

| Area | Decision |
|---|---|
| Audience | Scott's daily driver first. Built so other multi-client consultants could use it. |
| Engine | Swift + WKWebView (macOS 14+). Fallback: Electron, if the sign-in cookie sync spike fails. |
| Identity model | Accounts + Spaces (below). |
| Ungrouped / outside links | URL rules route to a space; otherwise the Default space. |
| Agent modes | User-selectable per space, with a global default. Includes a YOLO / full mode. |
| Agent backend | Pluggable. Auto-detect installed CLIs and use the user's subscription; API keys as an alternative. |
| Page index | Index every page, partitioned per space, stored locally. |
| Window layout | Space rail on the left; the selected space's tabs across the top, with tab groups. |
| Agent panel | User setting: right panel, bottom panel, or hidden. |
| Identity cue | The browser frame reshades to the active space's color, plus an address-bar chip naming the account in use. |

## Identity: Accounts + Spaces

- **Account**: one sign-in at one provider (Microsoft/Contoso, Microsoft/Fabrikam,
  Google/personal, GitHub, AWS, ...). Sign in once; its session lives in the vault.
  Unlimited accounts.
- **Space**: a workspace that binds one account per provider, e.g.
  - Contoso = MS:Contoso + Google:personal + GitHub:personal
  - Fabrikam = MS:Fabrikam + Google:personal + GitHub:personal

  Unlimited spaces. Tab groups live inside a space and share its sign-ins.
- **Cookie split**: an account owns its identity-provider cookies (`login.microsoftonline.com`,
  `.google.com`, `github.com`, ...). App cookies (Outlook, Azure DevOps) live in the space's own
  jar and are recreated by silent sign-in through the shared session.
- **One account per provider per space.** This is what keeps tenants from colliding. Sites you
  sign in to *with* a provider ("Sign in with Google", e.g. two Etsy shops tied to two Google
  accounts) are not providers: their cookies stay in the space and use the space's account.
  Two shops = two spaces (Personal with Google: personal, Newtro Studios with Google: Newtro
  Studios), both signed in at once.
- **Discovery**: signing in as an account the browser doesn't know offers to save it as a new
  account.
- **Mechanism (WKWebView)**: one `WKWebsiteDataStore(forIdentifier:)` per space. Provider cookies
  are copied from the vault into the space store; `WKHTTPCookieStoreObserver` writes changes back.
  **Risk**: unproven. Spike: two MS tenants side by side + shared Google OAuth.
- **Limits**: company sign-in-frequency policies can still force re-auth; the browser can't
  override them.

## Routing

- A new tab opened from a tab joins that tab's group and space.
- Dragging a tab to another space reloads it under that space's accounts.
- Outside links: URL rules (`dev.azure.com/contoso-dev/*` → Contoso). No match → Default space,
  which uses your everyday accounts. Outlook's URL is the same for every tenant, so it needs a
  rule or the default.

## Agents

- **Local MCP server**: list spaces/tabs, open tab in space, read page (text / accessibility tree),
  click/type by ref, screenshot, search the page index. Any MCP client can connect
  (Claude Code, Codex, agy, ...).
- **Scope**: an agent works inside one space with that space's accounts; it never sees the vault
  or other spaces.
- **Agent tabs**: a marked group inside the space; the user can watch or take over.
- **Login handoff**: the agent pauses on a login or 2FA prompt, notifies the user, and resumes
  once it's done.
- **Activity log**: per space, every agent read, click and submit.
- **Permission modes** (per space, global default):
  - Read-only: read pages, no input.
  - Ask: read and navigate; confirm every click or type.
  - Confirm submits: act freely; confirm send/submit/delete.
  - YOLO: do anything without asking (Scott's default).
- **Backends** (`AgentBackend` protocol):
  - CLI backends (subscription): auto-detect `claude`, `codex`, `agy`, `opencode` on PATH;
    newest model from each CLI's own list.
  - API backends: Anthropic / OpenAI / Google keys, configured in settings.
  - Used by the built-in sidebar; external agents connect over MCP instead.
  - No turn/budget caps; detect failure by liveness and offer Cancel.

## Window layout

- **Space rail**: a narrow column on the far left, one icon per space, with unread badges
  from that space's pinned apps; a "+" adds a space, and a gear opens accounts and settings.
- **Top tab strip**: shows only the selected space's tabs. Order: space name, tabs, tab
  groups, then the Agent group. No pinned apps: Outlook, DevOps and Teams are ordinary tabs.
  Rail unread badges are read from the open tabs' titles (e.g. Outlook's "(7)"). Switching space swaps the whole
  strip and returns to that space's last active tab.
- **Tab groups**: Brave-style colored labels inside a space; click a label to collapse it.
  Groups are for organizing only; sign-ins come from the space.
- **Agent panel**: right, bottom (chat plus activity log) or hidden, set from a three-button
  dock control in the toolbar. Hidden still allows MCP clients and shows Agent tabs.
- **Space tint**: the tab strip, toolbar and agent panel reshade to the active space's color
  when you switch spaces. The rail stays neutral. The address bar shows a chip naming the
  account in use for the current site (e.g. `Contoso · Microsoft: Contoso`).
- Mockup: `mockups/layouts.html` (https://claude.ai/artifact/NMDgJUarqktwL6RE2XEEDG).

## Data layer

- Every page visited is indexed locally: text + embeddings, partitioned by space.
- Agents can only search the space they're working in.

## Vault & security

- **Vault**: account sign-in cookies live in an encrypted local database; the key is in the
  macOS Keychain, bound to the signed app. Unlocks with the Mac login, no extra prompts.
- **Space data**: each space's WebKit store sits on disk under FileVault.
- **Agents never see cookies or the vault.** They act through tabs. API calls (e.g. Azure
  DevOps REST) run inside a tab in the space, so the session is used without leaving the browser.
- **YOLO is true YOLO**: no exceptions for sending, deleting or payments. The activity log is
  the record.
- **Sign-out spreads**: when an account's session ends, every space using it shows one
  "Sign in again" prompt. Each account has "Sign out everywhere".
- **Passwords and passkeys**: macOS password autofill (iCloud Keychain, 1Password). No built-in
  password manager.
- **Company policy**: no attempt to bypass sign-in frequency or device checks; just stay signed
  in as long as policy allows.
- **Multiple Macs**: sync setup (spaces, accounts list, routing rules, groups, agent settings)
  through iCloud Drive. Sessions never sync; sign in once per Mac.
- **Backup**: setup only. A restore means signing in again; the page index is not backed up.

## Space setup

- **New space sheet** (from "+" in the rail): name, color, template, one account per provider,
  suggested routing rules, tabs to open, agent mode. Mocked in `mockups/layouts.html`.
- **Templates**: Client on Microsoft 365 (new Microsoft account + personal Google and GitHub;
  opens Outlook, Teams, SharePoint, Azure DevOps), Client on Google Workspace (new Google
  account + personal GitHub), Blank, and Copy of an existing space (its accounts, groups and
  rules).
- **Accounts**: each provider is a dropdown of existing accounts, "New account…" or None. The
  sheet shows which other spaces already use an account.
- **New accounts**: on create, a tab opens in the space at the provider's sign-in page. After
  sign-in, iSmith reads the email and tenant and saves the account as `<Provider>: <Space>`.
- **Routing rules**: suggested from the space name (`<slug>.sharepoint.com/*`,
  `dev.azure.com/<slug>/*`, `*.<slug>.com/*`), then checked against the real tenant and org names
  after sign-in. Over time iSmith learns and suggests: when you keep moving a kind of link into one
  space, it offers a rule you accept with one click. Rules never apply without your OK.
- **Ending an engagement**: Archive. Signs out accounts used only by that space, keeps its page
  index and activity log read-only and searchable, and removes it from the rail.

## Open topics

- Data layer details (extraction, notes)
