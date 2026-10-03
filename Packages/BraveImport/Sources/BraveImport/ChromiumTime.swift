import Foundation

/// Chromium stores times as microseconds since 1601-01-01 00:00 UTC (the Windows epoch), as an
/// integer in SQLite and as a decimal string in JSON. Zero means "not set".
enum ChromiumTime {
    /// Seconds from 1601-01-01 to 1970-01-01.
    static let epochOffset: Int64 = 11_644_473_600

    static func date(microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        let unixMicros = microseconds - epochOffset * 1_000_000
        return Date(timeIntervalSince1970: Double(unixMicros) / 1_000_000)
    }

    static func date(string: String?) -> Date? {
        guard let string, let value = Int64(string) else { return nil }
        return date(microseconds: value)
    }

    /// The reverse, for tests that build fixtures.
    static func microseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded()) + epochOffset * 1_000_000
    }
}
