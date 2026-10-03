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
                result.append(ConvertedRuleList(name: "\(source.name)-\(index + 1)", json: part.safariRulesJSON,
                                                ruleCount: part.safariRulesCount, skippedLines: part.errorsCount))
            }
        }
        return result
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

    /// Converts `globals` plus `blocking`; if that's over `limit` rules, splits `blocking` into
    /// pieces sized from the overflow and converts each (recursively, in case a piece is still
    /// too big). Returns the pieces in order.
    private static func convert(blocking: ArraySlice<String>, globals: [String], globalRules: Int,
                                version: SafariVersion, limit: Int) throws -> [ConversionResult] {
        let result = ContentBlockerConverter().convertArray(rules: globals + blocking, safariVersion: version,
                                                            advancedBlocking: false)
        let total = result.safariRulesCount + result.discardedSafariRules
        if total <= limit { return [result] }
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
        var out: [ConversionResult] = []
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
