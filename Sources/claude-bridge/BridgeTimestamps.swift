import Foundation

/// ISO8601 written and read as values rather than formatter objects. Foundation's
/// `ISO8601DateFormatter` is not safe to use from several threads at once on Linux, and every
/// quota route here can be asked concurrently; the value styles carry no shared mutable state.
enum BridgeTimestamps {
    private static let output = Date.ISO8601FormatStyle(timeZone: .gmt)
    private static let fractional = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true, timeZone: .gmt)

    static func string(_ date: Date) -> String {
        date.formatted(output)
    }

    static func date(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: fractional) { return date }
        return try? Date(raw, strategy: output)
    }
}
