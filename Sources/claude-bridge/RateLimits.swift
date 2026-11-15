import Foundation

/// What Anthropic's limiter said on the last response a turn on this machine got, as the CLI
/// streams it (`rate_limit_event`).
///
/// The usage endpoint answers in whole percents and says nothing about whether requests are being
/// refused, so a week at 99.5 % reads as 100 % and as a wall for the half hour it goes on
/// answering. Every response a turn gets carries the limiter's own figures and its verdict (the
/// `anthropic-ratelimit-unified-*` headers), and the CLI hands both over whenever they move.
struct RateLimitReading: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        var utilization: Double?
        var resetsAt: Date?
        var status: String?
    }

    var observedAt: Date
    /// `allowed`, `allowed_warning` or `rejected`: whether requests are being answered at all. A
    /// window past its cap on its own does not mean they are not.
    var status: String?
    /// The window the verdict is about (`five_hour`, `seven_day`, …).
    var limitingWindow: String?
    var limitingResetsAt: Date?
    var windows: [String: Window]

    init(
        observedAt: Date, status: String?, limitingWindow: String?, limitingResetsAt: Date?,
        windows: [String: Window]
    ) {
        self.observedAt = observedAt
        self.status = status
        self.limitingWindow = limitingWindow
        self.limitingResetsAt = limitingResetsAt
        self.windows = windows
    }

    /// The event as the CLI writes it on its stream, or nil for any other line.
    init?(event object: [String: Any], now: Date) {
        guard object["type"] as? String == "rate_limit_event",
            let info = object["rate_limit_info"] as? [String: Any]
        else { return nil }
        var windows: [String: Window] = [:]
        for (name, value) in info["unifiedWindows"] as? [String: Any] ?? [:] {
            guard let window = value as? [String: Any] else { continue }
            windows[name] = Window(
                utilization: (window["utilization"] as? NSNumber)?.doubleValue,
                resetsAt: Self.epoch(window["resetsAt"]),
                status: window["status"] as? String)
        }
        self.init(
            observedAt: now, status: info["status"] as? String,
            limitingWindow: info["rateLimitType"] as? String,
            limitingResetsAt: Self.epoch(info["resetsAt"]), windows: windows)
    }

    /// Whether this reading says requests through `window` are being refused right now.
    func refuses(_ window: String) -> Bool {
        guard status == "rejected" else { return false }
        if let limitingWindow { return limitingWindow == window }
        return windows[window]?.status == "rejected"
    }

    /// Whether this reading says requests are being answered.
    var answers: Bool { status == "allowed" || status == "allowed_warning" }

    /// What the reading knows about one window, with the verdict's own reset standing in for a
    /// window the event named only as the one it was about.
    func window(_ name: String) -> Window? {
        if let known = windows[name] { return known }
        guard limitingWindow == name else { return nil }
        return Window(utilization: nil, resetsAt: limitingResetsAt, status: status)
    }

    private static func epoch(_ value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// The newest limiter reading any turn on this machine was handed. Held in memory only: after a
/// restart the usage endpoint is the whole account until the next turn speaks.
actor RateLimitLedger {
    static let shared = RateLimitLedger()

    private(set) var latest: RateLimitReading?

    /// Keeps the newer reading. A CLI too old to send per-window figures still sends the verdict,
    /// and the figures the ledger already holds are the newest there are, for the windows that
    /// have not ended since.
    func note(_ reading: RateLimitReading) {
        if let latest, latest.observedAt > reading.observedAt { return }
        var kept = reading
        if kept.windows.isEmpty, let previous = latest?.windows {
            kept.windows = previous.filter { ($0.value.resetsAt ?? .distantFuture) > reading.observedAt }
        }
        latest = kept
    }

    func reset() {
        latest = nil
    }
}

/// The usage endpoint's gauges, sharpened by what the last turn on this machine was told.
///
/// The endpoint is the account's own word on every window, read on a minute's cache; a turn's
/// reading is finer and is the limiter's own verdict, but it is only as fresh as the last response
/// a turn here got. So the turn's reading speaks only where it is newer than the endpoint's, or
/// where it agrees with it to within the endpoint's rounding, and never once it is an hour old.
enum RateLimitOverlay {
    /// A turn's reading older than this says nothing about the account now.
    static let maxAge: TimeInterval = 3600
    /// Two resets closer than this are the same window seen twice; the nearest two windows of one
    /// kind are five hours apart.
    static let sameWindow: TimeInterval = 1800
    /// One step of the endpoint's whole-percent rounding.
    static let roundingStep = 0.01
    /// Where a window that is past its cap and still being answered is drawn: full, and short of
    /// the wall every client reads as refused.
    static let answeringPastCap = 0.999

    /// The limiter's name for the window a gauge measures, for the windows a turn's reading carries.
    static func window(for gaugeKey: String) -> String? {
        switch gaugeKey {
        case "session", "five_hour": return "five_hour"
        case "weekly_all", "seven_day": return "seven_day"
        default: return nil
        }
    }

    static func apply(
        _ gauges: [UsageGauge], readAt: Date, reading: RateLimitReading?, now: Date
    ) -> [UsageGauge] {
        guard let reading, now.timeIntervalSince(reading.observedAt) < maxAge else { return gauges }
        return gauges.map { sharpened($0, readAt: readAt, reading: reading, now: now) }
    }

    private static func sharpened(
        _ gauge: UsageGauge, readAt: Date, reading: RateLimitReading, now: Date
    ) -> UsageGauge {
        guard let name = window(for: gauge.key), let seen = reading.window(name) else { return gauge }
        if let reset = seen.resetsAt, reset <= now { return gauge }
        let newer = reading.observedAt >= readAt
        let stated = gauge.resetsAt.flatMap(BridgeTimestamps.date)
        var result = gauge
        if let reset = seen.resetsAt, let stated, abs(reset.timeIntervalSince(stated)) >= sameWindow {
            guard newer, reset > stated else { return gauge }
            result.fraction = clamped(seen.utilization ?? 0)
            result.resetsAt = BridgeTimestamps.string(reset)
            result.trustedReset = true
        } else if let utilization = seen.utilization {
            guard newer || abs(utilization - gauge.fraction) <= roundingStep else { return gauge }
            result.fraction = clamped(utilization)
        } else if !newer {
            return gauge
        }
        if reading.refuses(name) {
            result.fraction = 1
            result.refused = true
        } else if reading.answers {
            if result.fraction >= 1 { result.fraction = answeringPastCap }
            result.refused = false
        }
        return result
    }

    private static func clamped(_ value: Double) -> Double { min(1, max(0, value)) }
}
