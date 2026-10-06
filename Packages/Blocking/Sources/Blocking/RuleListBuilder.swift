import ContentBlockerConverter
import Foundation

/// The JSON for one WebKit content-rule list.
public struct ConvertedRuleList: Sendable, Equatable {
    /// `<source>-<n>`, for example `easylist-1`.
    public let name: String
    public let json: String
    /// Rules in `json`. WebKit needs at least one, so a list with nothing to block holds one
    /// rule that does nothing and counts 0.
    public let ruleCount: Int
    /// Source lines the converter couldn't turn into WebKit rules (advanced AdGuard syntax,
    /// unsupported regexes). They're skipped.
    public let skippedLines: Int
}

/// Converts Adblock Plus filter lists to WebKit content-blocking JSON with AdGuard's
/// SafariConverterLib, split into lists that each fit under WebKit's rule limit.
///
/// How the split keeps exceptions working: WebKit applies an `ignore-previous-rules` exception
/// only to rules earlier in the *same* list. So every exception line (`@@…`, `#@#…`) and every
/// `$badfilter` line from *all* sources goes into every list, and only the blocking lines are
/// divided between lists. An exception written in EasyList for an EasyPrivacy rule still works,
/// as it does in an ad blocker that loads both lists together.
public enum RuleListBuilder {
    /// WebKit's limit on rules in one compiled content-rule list (Safari 15 and later).
    public static let webKitRuleLimit = 150_000

    public enum BuildError: Error, CustomStringConvertible {
        /// The exception lines alone are more rules than one list can hold.
        case exceptionsExceedLimit(rules: Int, limit: Int)
        /// One blocking line plus the exceptions is still over the limit.
        case cannotSplit(rules: Int, limit: Int)

        public var description: String {
            switch self {
            case let .exceptionsExceedLimit(rules, limit):
                return "The filter lists' exceptions alone make \(rules) rules, over the limit of \(limit) per list."
            case let .cannotSplit(rules, limit):
                return "A filter line and the exceptions make \(rules) rules, over the limit of \(limit) per list."
            }
        }
    }

    /// Converts `sources` (name and Adblock Plus text, in order) into rule lists of at most
    /// `maxRulesPerList` rules each. Runs on the calling thread and takes seconds for the full
    /// EasyList and EasyPrivacy, so call it off the main thread.
    public static func build(sources: [(name: String, text: String)],
                             maxRulesPerList: Int = webKitRuleLimit) throws -> [ConvertedRuleList] {
        try build(sources: sources, safariVersion: .autodetect(), maxRulesPerList: maxRulesPerList)
    }

    static func build(sources: [(name: String, text: String)], safariVersion: SafariVersion,
                      maxRulesPerList: Int) throws -> [ConvertedRuleList] {
        // The converter itself discards rules past Safari's limit; a lower limit here is how the
        // split is tested on a small list.
        let limit = min(maxRulesPerList, safariVersion.rulesLimit)
        var globals: [String] = []
        var blocking: [(name: String, lines: [String])] = []
        for source in sources {
            var lines: [String] = []
            for line in rules(in: source.text) {
                if isGlobal(line) { globals.append(line) } else { lines.append(line) }
            }
            blocking.append((source.name, lines))
        }
        // The exceptions go into every list, so they have to leave room for blocking rules.
        let globalRules = convertedCount(globals, version: safariVersion)
        // Leave at least a tenth of each list for blocking rules, or the split would make a list
        // for every few lines, each converting all the exceptions again.
        guard globalRules <= limit - limit / 10 else {
            throw BuildError.exceptionsExceedLimit(rules: globalRules, limit: limit)
        }
        var result: [ConvertedRuleList] = []
        for source in blocking {
            let parts = try convert(blocking: source.lines[...], globals: globals, globalRules: globalRules,
                                    version: safariVersion, limit: limit)
            for (index, part) in parts.enumerated() {
                result.append(ConvertedRuleList(name: "\(source.name)-\(index + 1)", json: part.json,
                                                ruleCount: part.ruleCount, skippedLines: part.skippedLines))
            }
        }
        return result
    }

    /// What a blocking rule blocks unless it names `$document` or `$popup`, as Adblock Plus and
    /// Brave read it: every load but a page in a tab. WebKit reads a rule with no resource type
    /// as every type, a tab's page and a `window.open` popup included, and the converter writes
    /// "every type but X" (`$~image`) with "document" in it. So `||urldefense.com^$third-party`
    /// stopped Outlook from opening Proofpoint-wrapped links at all. Such a rule keeps its other
    /// types and gets a twin for documents in frames (ad iframes). A rule that is only
    /// "document" (`$popup`, `$document`) still blocks pages.
    static let subresourceTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media"]

    /// A converted list with every blocking rule that would block a page in a tab without saying
    /// so split as `subresourceTypes` describes, and how many rules the split added.
    static func withoutPageBlocking(_ json: String) throws -> (json: String, added: Int) {
        guard let rules = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var out: [[String: Any]] = []
        out.reserveCapacity(rules.count * 2)
        for rule in rules {
            guard (rule["action"] as? [String: Any])?["type"] as? String == "block",
                  let trigger = rule["trigger"] as? [String: Any] else {
                out.append(rule)
                continue
            }
            let context = trigger["load-context"] as? [String]
            let types = trigger["resource-type"] as? [String] ?? subresourceTypes + ["document"]
            // Only in frames, or only pages and named as such: nothing to change.
            guard context != ["child-frame"], types.contains("document"), types != ["document"] else {
                out.append(rule)
                continue
            }
            var subresources = rule
            var t = trigger
            t["resource-type"] = types.filter { $0 != "document" }
            subresources["trigger"] = t
            out.append(subresources)
            // A rule only for top frames blocked nothing in frames to keep.
            if context != ["top-frame"] {
                var frames = rule
                t["resource-type"] = ["document"]
                t["load-context"] = ["child-frame"]
                frames["trigger"] = t
                out.append(frames)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.withoutEscapingSlashes])
        return (String(decoding: data, as: UTF8.self), out.count - rules.count)
    }

    /// Whitespace and the byte-order mark some downloads start with.
    private static let trimmed = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}"))

    /// The rule lines of an Adblock Plus list: no blank lines, `!` comments or `[Adblock …]`
    /// headers.
    static func rules(in text: String) -> [String] {
        var out: [String] = []
        text.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: trimmed)
            if line.isEmpty || line.hasPrefix("!") || (line.hasPrefix("[") && line.hasSuffix("]")) { return }
            var copy = line
            copy.makeContiguousUTF8()
            out.append(copy)
        }
        return out
    }

    /// Lines that change what *other* lines do, so every list needs its own copy: exceptions
    /// (`@@`), cosmetic exceptions (`#@#`, `#@$#`, `#@?#`, `#@%#`) and `$badfilter`.
    static func isGlobal(_ line: String) -> Bool {
        line.hasPrefix("@@") || line.contains("#@") || line.contains("$badfilter") || line.contains(",badfilter")
    }

    private static func convertedCount(_ lines: [String], version: SafariVersion) -> Int {
        let result = ContentBlockerConverter().convertArray(rules: lines, safariVersion: version, advancedBlocking: false)
        return result.safariRulesCount + result.discardedSafariRules
    }

    private struct Part {
        var json: String
        var ruleCount: Int
        var skippedLines: Int
    }

    /// Converts `globals` plus `blocking`; if that's over `limit` rules, splits `blocking` into
    /// pieces sized from the overflow and converts each (recursively, in case a piece is still
    /// too big). Returns the pieces in order.
    private static func convert(blocking: ArraySlice<String>, globals: [String], globalRules: Int,
                                version: SafariVersion, limit: Int) throws -> [Part] {
        let result = ContentBlockerConverter().convertArray(rules: globals + blocking, safariVersion: version,
                                                            advancedBlocking: false)
        let split = try withoutPageBlocking(result.safariRulesJSON)
        let count = result.safariRulesCount + split.added
        let total = count + result.discardedSafariRules
        if total <= limit { return [Part(json: split.json, ruleCount: count, skippedLines: result.errorsCount)] }
        // One line can make several rules, but a single line never makes more than a list holds
        // beyond the exceptions; if it somehow does, stop rather than split forever.
        guard blocking.count >= 2 else {
            throw BuildError.cannotSplit(rules: total, limit: limit)
        }
        // Size the pieces from the blocking rules and the room left beside the exceptions, aiming
        // at 90% of it, since rules don't divide evenly between lines.
        let room = Double(limit - globalRules) * 0.9
        let needed = Double(max(total - globalRules, 1))
        let pieces = min(blocking.count, max(2, Int((needed / max(room, 1)).rounded(.up))))
        let size = (blocking.count + pieces - 1) / pieces
        var out: [Part] = []
        var start = blocking.startIndex
        while start < blocking.endIndex {
            let end = min(start + size, blocking.endIndex)
            out += try convert(blocking: blocking[start..<end], globals: globals, globalRules: globalRules,
                               version: version, limit: limit)
            start = end
        }
        return out
    }
}
