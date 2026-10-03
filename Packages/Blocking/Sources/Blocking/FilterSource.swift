import Foundation

/// A filter list in Adblock Plus syntax: where it's downloaded from, and the copy shipped in the
/// app so blocking works on first launch without the network.
public struct FilterSource: Sendable, Hashable {
    /// Short, stable name used in rule-list identifiers and file names (letters, digits, `-`).
    public var name: String
    public var url: URL
    /// The bundled copy of the list (a `.txt` file in Adblock Plus syntax).
    public var bundled: URL

    public init(name: String, url: URL, bundled: URL) {
        self.name = name
        self.url = url
        self.bundled = bundled
    }

    /// EasyPrivacy first, then EasyList. Order only affects rule-list order, not what's blocked.
    public static var defaults: [FilterSource] {
        [
            FilterSource(name: "easyprivacy",
                         url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
                         bundled: snapshotURL("easyprivacy")),
            FilterSource(name: "easylist",
                         url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
                         bundled: snapshotURL("easylist")),
        ]
    }

    private static func snapshotURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Snapshot")!
    }
}
