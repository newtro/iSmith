import Foundation

/// The fixed colors a tab group can have, as in Brave and Chrome.
enum GroupColor: String, Codable, CaseIterable, Identifiable {
    case grey, blue, red, yellow, green, pink, purple, cyan, orange

    var id: String { rawValue }
    var title: String { rawValue == "grey" ? "Grey" : rawValue.capitalized }

    var rgb: (Double, Double, Double) {
        switch self {
        case .grey: return (0.39, 0.45, 0.55)
        case .blue: return (0.15, 0.39, 0.92)
        case .red: return (0.86, 0.15, 0.15)
        case .yellow: return (0.79, 0.54, 0.02)
        case .green: return (0.08, 0.54, 0.35)
        case .pink: return (0.86, 0.15, 0.55)
        case .purple: return (0.49, 0.23, 0.93)
        case .cyan: return (0.05, 0.45, 0.56)
        case .orange: return (0.92, 0.35, 0.05)
        }
    }

    /// Unknown names (from a newer version) read as grey rather than failing the whole file.
    init(from decoder: Decoder) throws {
        self = GroupColor(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .grey
    }
}

/// A named, colored run of tabs inside a space. Groups only organize; sign-ins come from the space.
struct TabGroup: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var color: GroupColor
    var collapsed: Bool
    /// The space's Agent group (v1.1): the tabs an agent opened or took over. A space has at most
    /// one, and it's always last in the strip. A tab in it is driven by the agent (no autofill);
    /// dragging a tab out of it takes the tab back.
    var agent: Bool

    init(id: UUID = UUID(), name: String, color: GroupColor, collapsed: Bool = false, agent: Bool = false) {
        (self.id, self.name, self.color, self.collapsed, self.agent) = (id, name, color, collapsed, agent)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(GroupColor.self, forKey: .color) ?? .grey
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        agent = try c.decodeIfPresent(Bool.self, forKey: .agent) ?? false
    }
}

/// The order of one space's tabs in one window, which tabs are in which group, and which tab is
/// selected. Tabs are known only by id here, so the rules can be tested without web views.
///
/// Invariants, restored after every change by `normalize()`:
/// - pinned tabs come first and are never in a group;
/// - a group's tabs are next to each other (a group is one run in the strip);
/// - every group has at least one tab;
/// - the selection, if any, is one of the tabs.
struct TabLayout: Equatable {
    struct Slot: Equatable {
        var id: UUID
        var group: UUID?
        /// Pinned: shown as an icon at the start of the strip (per space, saved).
        var pinned = false
    }

    /// One thing in the strip, left to right.
    enum Item: Equatable {
        case pinned(UUID)
        case group(TabGroup, count: Int)
        case tab(UUID, group: TabGroup?)
    }

    private(set) var slots: [Slot] = []
    private(set) var groups: [TabGroup] = []
    private(set) var selected: UUID?
    /// Pinned tabs an agent took over (moving them into the Agent group unpins them): taking one
    /// back pins it again. Not saved.
    private(set) var unpinnedForAgent: Set<UUID> = []

    init() {}

    /// Rebuilds a layout from saved slots and groups, repairing anything that breaks the
    /// invariants (unknown groups, split runs, a missing selection).
    init(slots: [Slot], groups: [TabGroup], selected: UUID?) {
        var seen = Set<UUID>()
        self.slots = slots.filter { seen.insert($0.id).inserted }
        var seenGroups = Set<UUID>()
        self.groups = groups.filter { seenGroups.insert($0.id).inserted }
        self.selected = selected
        normalize()
    }

    // MARK: - Reading

    var ids: [UUID] { slots.map(\.id) }
    var isEmpty: Bool { slots.isEmpty }
    var count: Int { slots.count }

    func contains(_ id: UUID) -> Bool { slots.contains { $0.id == id } }
    func index(of id: UUID) -> Int? { slots.firstIndex { $0.id == id } }
    func groupID(of id: UUID) -> UUID? { slots.first { $0.id == id }?.group }
    func group(_ id: UUID) -> TabGroup? { groups.first { $0.id == id } }
    func group(of tab: UUID) -> TabGroup? { groupID(of: tab).flatMap { group($0) } }
    func tabs(in group: UUID) -> [UUID] { slots.filter { $0.group == group }.map(\.id) }
    func isPinned(_ id: UUID) -> Bool { slots.first { $0.id == id }?.pinned == true }
    var pinnedIDs: [UUID] { slots.filter(\.pinned).map(\.id) }
    var pinnedCount: Int { slots.prefix { $0.pinned }.count }
    /// The tabs on screen, in order (not those in collapsed groups).
    var visibleIDs: [UUID] {
        items.compactMap { item in
            switch item {
            case let .pinned(id), let .tab(id, _): return id
            case .group: return nil
            }
        }
    }
    /// The space's Agent group, if it has one.
    var agentGroup: TabGroup? { groups.first { $0.agent } }

    /// What the strip shows: each group's label followed by its tabs, unless it's collapsed.
    var items: [Item] {
        var out: [Item] = []
        var current: UUID?
        for slot in slots {
            if slot.pinned {
                out.append(.pinned(slot.id))
                continue
            }
            let g = slot.group.flatMap { group($0) }
            if let g, g.id != current {
                out.append(.group(g, count: tabs(in: g.id).count))
            }
            current = g?.id
            if g?.collapsed != true { out.append(.tab(slot.id, group: g)) }
        }
        return out
    }

    /// The tab after (or before) `id`, wrapping around. Tabs in collapsed groups count: selecting
    /// one expands its group.
    func neighbor(of id: UUID, forward: Bool) -> UUID? {
        guard let i = index(of: id), slots.count > 1 else { return nil }
        let j = (i + (forward ? 1 : -1) + slots.count) % slots.count
        return slots[j].id
    }

    /// The first color no group in this layout uses yet, or blue.
    var nextColor: GroupColor {
        let used = Set(groups.map(\.color))
        return GroupColor.allCases.first { $0 != .grey && !used.contains($0) } ?? .blue
    }

    // MARK: - Tabs

    /// Adds a tab before `before` (or at the end of `group`'s run, or at the end of the strip).
    /// A pinned tab goes among the pinned ones (at their end without a pinned `before`).
    mutating func insert(_ id: UUID, before: UUID? = nil, group: UUID? = nil, pinned: Bool = false) {
        guard !contains(id) else { return }
        if pinned {
            slots.insert(Slot(id: id, group: nil, pinned: true), at: pinnedIndex(before: before))
        } else {
            let group = group.flatMap { self.group($0) == nil ? nil : $0 }
            slots.insert(Slot(id: id, group: group), at: insertionIndex(before: before, group: group))
        }
        normalize()
    }

    /// Adds a tab right after `anchor`, in its group (a link opened from a tab joins its group).
    /// A tab opened from a pinned tab goes first among the unpinned ones.
    mutating func insert(_ id: UUID, after anchor: UUID) {
        guard let i = index(of: anchor) else { return insert(id) }
        guard !contains(id) else { return }
        if slots[i].pinned {
            slots.insert(Slot(id: id, group: nil), at: pinnedCount)
        } else {
            slots.insert(Slot(id: id, group: slots[i].group), at: i + 1)
        }
        normalize()
    }

    /// Removes a tab. If it was selected, the tab to its right is selected (or the one to its
    /// left), as in other browsers.
    mutating func remove(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let wasSelected = selected == id
        slots.remove(at: i)
        let next = slots.isEmpty ? nil : slots[min(i, slots.count - 1)].id
        normalize()
        if wasSelected { select(next) }
    }

    /// Selects a tab; a collapsed group holding it expands.
    mutating func select(_ id: UUID?) {
        guard let id else { selected = nil; return }
        // A tab that's gone (a click on a view the strip hasn't removed yet) changes nothing.
        guard let i = index(of: id) else { return }
        selected = id
        if let g = slots[i].group, let gi = groups.firstIndex(where: { $0.id == g }) { groups[gi].collapsed = false }
    }

    /// Moves a tab before `before` (nil: to the end of `group`, or of the strip) and into `group`
    /// (nil: out of any group), pinned or not. This is what a drop in the strip does.
    mutating func move(_ id: UUID, before: UUID?, group: UUID?, pinned: Bool = false) {
        guard contains(id), before != id else {
            if before == id { setPlace([id], group: group, pinned: pinned) }
            return
        }
        slots.removeAll { $0.id == id }
        if pinned {
            slots.insert(Slot(id: id, group: nil, pinned: true), at: pinnedIndex(before: before))
        } else {
            let group = group.flatMap { self.group($0) == nil ? nil : $0 }
            slots.insert(Slot(id: id, group: group), at: insertionIndex(before: before, group: group))
        }
        normalize()
    }

    /// Moves a whole group, its tabs in order, before `before` (nil: the end of the strip). A
    /// `before` in another group means before that whole group, and a pinned one means first
    /// among the unpinned tabs. This is what dropping a dragged group label does.
    mutating func moveGroup(_ id: UUID, before: UUID?) {
        guard group(id) != nil, before.map({ groupID(of: $0) != id }) ?? true else { return }
        let members = slots.filter { $0.group == id }
        slots.removeAll { $0.group == id }
        var index = slots.count
        if let before, let i = slots.firstIndex(where: { $0.id == before }) {
            index = slots[i].group.flatMap { g in slots.firstIndex { $0.group == g } } ?? i
        }
        index = max(index, slots.firstIndex { !$0.pinned } ?? slots.count)
        slots.insert(contentsOf: members, at: index)
        normalize()
    }

    private mutating func setPlace(_ ids: [UUID], group: UUID?, pinned: Bool) {
        let group = pinned ? nil : group.flatMap { self.group($0) == nil ? nil : $0 }
        for i in slots.indices where ids.contains(slots[i].id) {
            slots[i].group = group
            slots[i].pinned = pinned
        }
        normalize()
    }

    /// Where a pinned tab goes: before `before` if that's pinned, else at the end of the pinned run.
    private func pinnedIndex(before: UUID?) -> Int {
        if let before, let i = index(of: before), slots[i].pinned { return i }
        return pinnedCount
    }

    private func insertionIndex(before: UUID?, group: UUID?) -> Int {
        // Into a group, the anchor must be inside the group's run or just after it; otherwise
        // (the anchor has moved since, as for a reopened tab) the tab goes to the group's end
        // rather than pulling the whole group to the anchor.
        if let group, let first = slots.firstIndex(where: { $0.group == group }),
           let last = slots.lastIndex(where: { $0.group == group }) {
            if let before, let i = index(of: before), (first...(last + 1)).contains(i) { return i }
            return last + 1
        }
        if let before, let i = index(of: before) { return max(i, pinnedCount) }
        if let group, let last = slots.lastIndex(where: { $0.group == group }) { return last + 1 }
        return slots.count
    }

    // MARK: - Pinned tabs

    /// Pins tabs: they leave their groups and go to the end of the pinned tabs, in strip order.
    mutating func pin(_ ids: [UUID]) {
        let moving = slots.filter { ids.contains($0.id) && !$0.pinned }
        guard !moving.isEmpty else { return }
        slots.removeAll { s in moving.contains { $0.id == s.id } }
        slots.insert(contentsOf: moving.map { Slot(id: $0.id, group: nil, pinned: true) }, at: pinnedCount)
        normalize()
    }

    /// Unpins tabs: they go first among the unpinned tabs, in strip order.
    mutating func unpin(_ ids: [UUID]) {
        let moving = slots.filter { ids.contains($0.id) && $0.pinned }
        guard !moving.isEmpty else { return }
        slots.removeAll { s in moving.contains { $0.id == s.id } }
        let at = pinnedCount
        slots.insert(contentsOf: moving.map { Slot(id: $0.id, group: nil) }, at: at)
        normalize()
    }

    // MARK: - Acting on several tabs

    /// The tabs right of the rightmost of `ids`, not counting pinned tabs ("Close Tabs to the Right").
    func tabsRight(of ids: [UUID]) -> [UUID] {
        guard let last = ids.compactMap(index(of:)).max() else { return [] }
        return slots[(last + 1)...].filter { !$0.pinned && !ids.contains($0.id) }.map(\.id)
    }

    /// Every unpinned tab except `ids` ("Close Other Tabs" keeps pinned tabs, as other browsers do).
    func others(than ids: [UUID]) -> [UUID] {
        slots.filter { !$0.pinned && !ids.contains($0.id) }.map(\.id)
    }

    /// The run a tab sorts within: the pinned tabs, its group, or the ungrouped tabs.
    func run(of id: UUID) -> [UUID] {
        guard let i = index(of: id) else { return [] }
        let slot = slots[i]
        return slots.filter { $0.pinned == slot.pinned && $0.group == slot.group }.map(\.id)
    }

    /// Sorts tabs by site (`key`, such as the host), each within its run: the tabs trade places
    /// among the slots they hold in the pinned tabs, a group, or the ungrouped tabs. Ties keep
    /// their order.
    mutating func sort(_ ids: [UUID], by key: (UUID) -> String) {
        var runs: [String: [Int]] = [:]
        for (i, slot) in slots.enumerated() where ids.contains(slot.id) {
            let run = slot.pinned ? "pinned" : slot.group?.uuidString ?? "loose"
            runs[run, default: []].append(i)
        }
        for positions in runs.values {
            let keys = positions.map { key(slots[$0].id) }
            let order = positions.indices.sorted { a, b in
                keys[a] == keys[b] ? a < b : keys[a].localizedStandardCompare(keys[b]) == .orderedAscending
            }
            let sorted = order.map { slots[positions[$0]] }
            for (position, slot) in zip(positions, sorted) { slots[position] = slot }
        }
        normalize()
    }

    // MARK: - Groups

    /// Puts tabs into a new group at the position of the leftmost one, keeping their order.
    @discardableResult
    mutating func createGroup(with ids: [UUID], name: String = "", color: GroupColor? = nil, agent: Bool = false) -> UUID? {
        let members = slots.map(\.id).filter(ids.contains)
        guard let first = members.first, let at = index(of: first) else { return nil }
        // One Agent group per space: more agent tabs join it.
        if agent, let existing = agentGroup {
            add(members, to: existing.id)
            return existing.id
        }
        let group = TabGroup(name: name, color: color ?? nextColor, agent: agent)
        groups.append(group)
        let moving = slots.filter { members.contains($0.id) }.map { Slot(id: $0.id, group: group.id) }
        var rest = slots.filter { !members.contains($0.id) }
        let insertAt = slots[..<at].filter { !members.contains($0.id) }.count
        rest.insert(contentsOf: moving, at: insertAt)
        slots = rest
        normalize()
        return group.id
    }

    /// Puts a tab in the space's Agent group, making the group (last in the strip) if there's none.
    @discardableResult
    mutating func addToAgentGroup(_ id: UUID) -> UUID? {
        if !contains(id) { insert(id) }
        if isPinned(id) { unpinnedForAgent.insert(id) }
        if let group = agentGroup {
            add([id], to: group.id)
            return group.id
        }
        return createGroup(with: [id], name: "Agent", color: .blue, agent: true)
    }

    /// Adds tabs to the end of an existing group.
    mutating func add(_ ids: [UUID], to group: UUID) {
        guard self.group(group) != nil else { return }
        for id in slots.map(\.id) where ids.contains(id) {
            move(id, before: nil, group: group)
        }
    }

    /// Takes tabs out of their groups, placing them just after the group they left.
    mutating func removeFromGroup(_ ids: [UUID]) {
        for id in slots.map(\.id).reversed() where ids.contains(id) {
            guard let g = groupID(of: id) else { continue }
            let after = slots.lastIndex { $0.group == g }.map { $0 + 1 } ?? slots.count
            let anchor = after < slots.count ? slots[after].id : nil
            // A pinned tab the agent had goes back among the pinned tabs.
            let repin = unpinnedForAgent.contains(id)
            move(id, before: anchor, group: nil)
            if repin { pin([id]) }
        }
    }

    /// Removes the group; its tabs stay where they are.
    mutating func ungroup(_ group: UUID) {
        for i in slots.indices where slots[i].group == group { slots[i].group = nil }
        normalize()
    }

    mutating func rename(_ group: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[i].name = name
    }

    mutating func setColor(_ group: UUID, _ color: GroupColor) {
        guard let i = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[i].color = color
    }

    /// Collapses or expands a group. Collapsing the group that holds the selected tab selects the
    /// nearest tab outside it. Returns false when there's no such tab: the caller opens a new one
    /// first, as Chrome does, so something stays selected.
    @discardableResult
    mutating func setCollapsed(_ group: UUID, _ collapsed: Bool) -> Bool {
        guard let gi = groups.firstIndex(where: { $0.id == group }) else { return true }
        if collapsed, let selected, groupID(of: selected) == group {
            guard let i = index(of: selected) else { return false }
            let right = slots[(i + 1)...].first { $0.group != group }
            let left = slots[..<i].last { $0.group != group }
            guard let next = right ?? left else { return false }
            self.selected = next.id
        }
        groups[gi].collapsed = collapsed
        return true
    }

    // MARK: - Invariants

    /// Puts pinned tabs first, gathers each group's tabs into one run at the position of its first
    /// tab, drops groups with no tabs and memberships of unknown groups, and checks the selection.
    private mutating func normalize() {
        let known = Set(groups.map(\.id))
        for i in slots.indices where slots[i].group.map({ !known.contains($0) }) == true { slots[i].group = nil }
        for i in slots.indices where slots[i].pinned { slots[i].group = nil }
        var out: [Slot] = slots.filter(\.pinned)
        var placed = Set<UUID>()
        for slot in slots where !slot.pinned {
            guard let g = slot.group else { out.append(slot); continue }
            guard !placed.contains(g) else { continue }
            placed.insert(g)
            out.append(contentsOf: slots.filter { $0.group == g && !$0.pinned })
        }
        // The Agent group stays at the end of the strip.
        if let agent = groups.first(where: { $0.agent })?.id, out.contains(where: { $0.group == agent }) {
            out = out.filter { $0.group != agent } + out.filter { $0.group == agent }
        }
        slots = out
        groups.removeAll { !placed.contains($0.id) }
        if let selected, !contains(selected) { self.selected = slots.first?.id }
        if !unpinnedForAgent.isEmpty {
            let agentTabs = Set(slots.filter { s in s.group.map { g in groups.contains { $0.id == g && $0.agent } } == true }.map(\.id))
            unpinnedForAgent.formIntersection(agentTabs)
        }
    }
}

/// Several tabs picked at once, for acting on them together (close, group, move, bookmark, sort).
/// The selected tab is always part of it; `marked` holds the others.
///
/// - A click selects a tab. It keeps the marks when the tab is already marked (so a right-click
///   or a drag can still act on all of them), and clears them otherwise.
/// - ⌘-click adds a tab to the selection or takes it out. Taking out the selected tab selects the
///   marked tab nearest to it.
/// - ⇧-click picks every tab from the anchor (the tab last clicked, or the selected tab) to the
///   clicked one; ⌘⇧-click adds that range to the marks.
struct TabSelection: Equatable {
    var marked: Set<UUID> = []
    /// Where a ⇧-click range starts.
    var anchor: UUID?

    enum Click { case plain, command, shift, commandShift }

    /// Applies a click on `id`. Returns the tab to select, if the selection changes.
    mutating func click(_ id: UUID, _ kind: Click, in layout: TabLayout) -> UUID? {
        guard layout.contains(id) else { return nil }
        let selected = layout.selected
        switch kind {
        case .plain:
            let wasPicked = marked.contains(id)
            if !wasPicked { marked = [] }
            marked.remove(id)
            if wasPicked, let selected, selected != id { marked.insert(selected) }
            anchor = id
            return id == selected ? nil : id
        case .command:
            anchor = id
            if id == selected {
                // The selected tab leaves the selection: the nearest marked tab takes over.
                guard let index = layout.index(of: id), let next = marked.min(by: { a, b in
                    abs((layout.index(of: a) ?? 0) - index) < abs((layout.index(of: b) ?? 0) - index)
                }) else { return nil }
                marked.remove(next)
                return next
            }
            if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
            return nil
        case .shift, .commandShift:
            // Over the tabs on screen only: tabs in a collapsed group are never picked. The range
            // starts at the anchor, or the selected tab, or the clicked tab, whichever is visible.
            let visible = layout.visibleIDs
            let start = [anchor, selected, id].compactMap { $0 }.first(where: visible.contains) ?? id
            guard let a = visible.firstIndex(of: start), let b = visible.firstIndex(of: id) else { return nil }
            let order = visible
            let range = Set(order[min(a, b)...max(a, b)])
            marked = kind == .commandShift ? marked.union(range) : range
            if let selected { marked.remove(selected) }
            return nil
        }
    }

    /// The tabs an action on `id` applies to, in strip order: the whole selection when `id` is in
    /// it and it has more than one tab, otherwise `id` alone.
    func targets(for id: UUID, in layout: TabLayout) -> [UUID] {
        let all = marked.union(layout.selected.map { [$0] } ?? [])
        guard all.count > 1, all.contains(id) else { return [id] }
        return layout.ids.filter(all.contains)
    }

    /// Drops marks for tabs that are gone.
    /// Drops marks for tabs that are gone or hidden in a collapsed group, and such an anchor.
    mutating func prune(_ layout: TabLayout) {
        let visible = Set(layout.visibleIDs)
        marked = marked.filter { visible.contains($0) && $0 != layout.selected }
        if let anchor, !visible.contains(anchor) { self.anchor = nil }
    }
}
