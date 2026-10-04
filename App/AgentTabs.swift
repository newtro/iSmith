import AppKit
import WebKit

/// Agent tabs (v1.1): the tabs in a space's Agent group. An agent opens its tabs there, in the
/// background, and a tab of yours that it acts on moves there. While a tab is in the group,
/// password autofill and capture are off in it (and in its popups); dragging it out takes it back
/// for good, and the agent may then only read it.
extension BrowserState {
    /// Opens `url` in a new tab in the space's Agent group. It's selected only when asked (the
    /// space had no other tab); otherwise it loads in the background.
    @discardableResult
    func openAgentTab(in window: WindowState, space spaceID: String, url: URL, select: Bool) -> Tab {
        openTab(in: window, space: spaceID, url: url, select: select) { layout, id in
            layout.addToAgentGroup(id)
        }
    }

    /// Moves one of the user's tabs into the Agent group (an agent acted on it).
    func moveToAgentGroup(_ tab: Tab, in tabs: SpaceTabs) {
        tabs.update { $0.addToAgentGroup(tab.id) }
        syncAgentControl(tabs)
    }

    /// Brings every tab's agent control in line with its group: in the Agent group means
    /// agent-controlled (autofill off), except while the user signs in for the agent. A tab that
    /// left the group was taken back by the user.
    func syncAgentControl(_ tabs: SpaceTabs) {
        for tab in tabs.ordered {
            let member = tabs.layout.group(of: tab.id)?.agent == true
            if tab.agentMember, !member { tab.agentReleased = true }
            if member { tab.agentReleased = false }
            tab.agentMember = member
            let wanted = member && !tab.agentHandOff
            if wanted != tab.agentControlled { setAgentControlled(wanted, for: tab) }
        }
    }

    func syncAgentControl(_ tab: Tab) {
        guard let (_, tabs) = owner(of: tab) else { return }
        syncAgentControl(tabs)
    }

    /// An agent acted in the tab recently: it stays loaded for a while, so the agent's next step
    /// finds the page as it left it.
    func agentRecentlyUsed(_ tab: Tab, now: Date = Date()) -> Bool {
        guard tab.agentControlled || tab.agentHandOff, let used = tab.agentUsedAt else { return tab.agentHandOff }
        return now.timeIntervalSince(used) < 10 * 60
    }
}
