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

    init(id: UUID = UUID(), name: String, color: GroupColor, collapsed: Bool = false) {
        (self.id, self.name, self.color, self.collapsed) = (id, name, color, collapsed)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(GroupColor.self, forKey: .color) ?? .grey
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}

/// The order of one space's tabs in one window, which tabs are in which group, and which tab is
/// selected. Tabs are known only by id here, so the rules can be tested without web views.
///
/// Invariants, restored after every change by `normalize()`:
/// - a group's tabs are next to each other (a group is one run in the strip);
/// - every group has at least one tab;
/// - the selection, if any, is one of the tabs.
struct TabLayout: Equatable {
    struct Slot: Equatable {
        var id: UUID
        var group: UUID?
    }

    /// One thing in the strip, left to right.
    enum Item: Equatable {
        case group(TabGroup, count: Int)
        case tab(UUID, group: TabGroup?)
    }

    private(set) var slots: [Slot] = []
    private(set) var groups: [TabGroup] = []
    private(set) var selected: UUID?

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

    /// What the strip shows: each group's label followed by its tabs, unless it's collapsed.
    var items: [Item] {
        var out: [Item] = []
        var current: UUID?
        for slot in slots {
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
    mutating func insert(_ id: UUID, before: UUID? = nil, group: UUID? = nil) {
        guard !contains(id) else { return }
        let group = group.flatMap { self.group($0) == nil ? nil : $0 }
        slots.insert(Slot(id: id, group: group), at: insertionIndex(before: before, group: group))
        normalize()
    }

    /// Adds a tab right after `anchor`, in its group (a link opened from a tab joins its group).
    mutating func insert(_ id: UUID, after anchor: UUID) {
        guard let i = index(of: anchor) else { return insert(id) }
        guard !contains(id) else { return }
        slots.insert(Slot(id: id, group: slots[i].group), at: i + 1)
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
        guard let id, let i = index(of: id) else { selected = nil; return }
        selected = id
        if let g = slots[i].group, let gi = groups.firstIndex(where: { $0.id == g }) { groups[gi].collapsed = false }
    }

    /// Moves a tab before `before` (nil: to the end of `group`, or of the strip) and into `group`
    /// (nil: out of any group). This is what a drop in the strip does.
    mutating func move(_ id: UUID, before: UUID?, group: UUID?) {
        guard contains(id), before != id else {
            if before == id { setGroup([id], group) }
            return
        }
        slots.removeAll { $0.id == id }
        let group = group.flatMap { self.group($0) == nil ? nil : $0 }
        slots.insert(Slot(id: id, group: group), at: insertionIndex(before: before, group: group))
        normalize()
    }

    private mutating func setGroup(_ ids: [UUID], _ group: UUID?) {
        for i in slots.indices where ids.contains(slots[i].id) { slots[i].group = group }
        normalize()
    }

    private func insertionIndex(before: UUID?, group: UUID?) -> Int {
        if let before, let i = index(of: before) { return i }
        if let group, let last = slots.lastIndex(where: { $0.group == group }) { return last + 1 }
        return slots.count
    }

    // MARK: - Groups

    /// Puts tabs into a new group at the position of the leftmost one, keeping their order.
    @discardableResult
    mutating func createGroup(with ids: [UUID], name: String = "", color: GroupColor? = nil) -> UUID? {
        let members = slots.map(\.id).filter(ids.contains)
        guard let first = members.first, let at = index(of: first) else { return nil }
        let group = TabGroup(name: name, color: color ?? nextColor)
        groups.append(group)
        let moving = slots.filter { members.contains($0.id) }.map { Slot(id: $0.id, group: group.id) }
        var rest = slots.filter { !members.contains($0.id) }
        let insertAt = slots[..<at].filter { !members.contains($0.id) }.count
        rest.insert(contentsOf: moving, at: insertAt)
        slots = rest
        normalize()
        return group.id
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
            move(id, before: anchor, group: nil)
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

    /// Gathers each group's tabs into one run at the position of its first tab, drops groups with
    /// no tabs and memberships of unknown groups, and checks the selection.
    private mutating func normalize() {
        let known = Set(groups.map(\.id))
        for i in slots.indices where slots[i].group.map({ !known.contains($0) }) == true { slots[i].group = nil }
        var out: [Slot] = []
        var placed = Set<UUID>()
        for slot in slots {
            guard let g = slot.group else { out.append(slot); continue }
            guard !placed.contains(g) else { continue }
            placed.insert(g)
            out.append(contentsOf: slots.filter { $0.group == g })
        }
        slots = out
        groups.removeAll { !placed.contains($0.id) }
        if let selected, !contains(selected) { self.selected = slots.first?.id }
    }
}
