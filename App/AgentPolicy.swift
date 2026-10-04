import AgentKit
import Foundation

/// What each permission mode lets the agent's browser tools do (AGENT_PANEL.md):
///
/// | Mode | Reading (snapshot, screenshot, list, find, wait, scroll) | Loading pages (open, navigate, back) | Input (click, type, select, keys) |
/// |---|---|---|---|
/// | Read-only | yes | no | no |
/// | Ask | yes | each one asks in the panel | each one asks |
/// | Confirm submits | yes | yes, except a site the space doesn't have open, which asks | free, except submits, sends, deletes and purchases, which ask |
/// | YOLO | yes | yes | free |
///
/// Loading a page is an action, not a read: a page planted with instructions could otherwise
/// get a read-only agent to carry what it read off to another site in an address. Closing one of
/// the agent's tabs counts as moving around too (it may hold a draft). The rules live
/// here, in code; the agent's instructions only describe them.
enum AgentPolicy {
    enum Kind: Equatable {
        case read
        case navigate
        case input
    }

    enum Decision: Equatable {
        case allow
        case ask(reason: String)
        case block(reason: String)
    }

    static func kind(of tool: String) -> Kind {
        switch tool {
        case "page_snapshot", "screenshot", "list_tabs", "find_text", "wait_for", "scroll": return .read
        case "open_tab", "navigate", "go_back", "close_tab": return .navigate
        default: return .input
        }
    }

    /// `intent` is what the input would do, from the page script's heuristics ("submit", "send",
    /// "delete", "purchase"), or nil for an ordinary click or keystroke.
    static func decide(tool: String, mode: AgentMode, intent: String?) -> Decision {
        switch (kind(of: tool), mode) {
        case (.read, _), (_, .yolo):
            return .allow
        case (.navigate, .confirmSubmits):
            // A page load is free, except one that takes data (a query) to a site the space
            // doesn't have open: the way a planted instruction would carry off what was read.
            guard let intent else { return .allow }
            return .ask(reason: describe(intent: intent))
        case (.navigate, .readOnly):
            return .block(reason: "This space's agent mode is Read-only: the agent may read the tabs that are open, but not load pages, click, type or press keys. The user can change the mode in the agent panel.")
        case (.input, .readOnly):
            return .block(reason: "This space's agent mode is Read-only: the agent may read pages, but not click, type or press keys. The user can change the mode in the agent panel.")
        case (_, .ask):
            return .ask(reason: "Ask mode")
        case (.input, .confirmSubmits):
            guard let intent else { return .allow }
            return .ask(reason: describe(intent: intent))
        }
    }

    static func describe(intent: String) -> String {
        switch intent {
        case "delete": return "This looks like it deletes or removes something."
        case "purchase": return "This looks like a payment or an order."
        case "send": return "This looks like it sends, posts or submits something."
        case "unknown": return "What this does can't be seen from the page (it's inside a frame, often another site's)."
        case "navigate": return "This loads a site that isn't open in this space, with data in its address."
        default: return "This submits a form."
        }
    }
}
