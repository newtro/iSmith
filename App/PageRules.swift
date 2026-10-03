import Foundation

/// Unread counts read from page titles, for the rail's badges. Mail and chat apps put the count in
/// the title: Outlook and Teams lead with it ("(7) Mail - Scott Smith - Outlook"), Gmail puts it
/// after the label ("Inbox (12) - scott@gmail.com - Gmail").
enum UnreadBadge {
    /// The count in a title, or nil if it has none. "(99+)" reads as 99.
    static func count(in title: String) -> Int? {
        let text = title.trimmingCharacters(in: .whitespaces)
        if let n = leading(text) { return n }
        // Gmail-style: "<label> (N) - … - Gmail". Only for Gmail, so a document called
        // "Report (2) - Google Docs" doesn't show a badge.
        let parts = text.components(separatedBy: " - ")
        if parts.count >= 2, parts.last?.trimmingCharacters(in: .whitespaces) == "Gmail",
           let open = parts[0].lastIndex(of: "("), parts[0].hasSuffix(")") {
            return number(parts[0][parts[0].index(after: open)..<parts[0].index(before: parts[0].endIndex)])
        }
        return nil
    }

    /// "(7) Inbox", "(99+) Chat".
    private static func leading(_ text: String) -> Int? {
        guard text.hasPrefix("("), let close = text.firstIndex(of: ")") else { return nil }
        let rest = text[text.index(after: close)...]
        // "(2024)" on its own, or glued to the next word, isn't a count.
        guard rest.isEmpty || rest.first == " " else { return nil }
        return number(text[text.index(after: text.startIndex)..<close])
    }

    private static func number(_ s: Substring) -> Int? {
        var digits = s
        if digits.hasSuffix("+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy(\.isASCII), let n = Int(digits), n > 0 else { return nil }
        return n
    }

    /// A space's badge: the counts of its tabs added up, counting a page open in two tabs (the
    /// same title) once.
    static func total(_ titles: [String]) -> Int {
        var seen = Set<String>()
        return titles.reduce(0) { sum, title in
            guard let n = count(in: title), seen.insert(title).inserted else { return sum }
            return sum + n
        }
    }
}

/// Tabs that must never be throttled or unloaded in the background, so mail counts update and
/// Teams calls ring. Outlook, Teams and Gmail are kept alive automatically; any tab can be set
/// either way from its context menu.
enum KeepAlive {
    static let automaticHosts = [
        "outlook.office.com", "outlook.office365.com", "outlook.live.com", "outlook.cloud.microsoft",
        "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft",
        "mail.google.com",
    ]

    /// Whether a page at this URL is kept alive when the tab has no setting of its own.
    static func isAutomatic(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        return automaticHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// A tab's own setting wins; otherwise the automatic rule for its page.
    static func isOn(setting: Bool?, url: URL?) -> Bool {
        setting ?? isAutomatic(url)
    }
}
