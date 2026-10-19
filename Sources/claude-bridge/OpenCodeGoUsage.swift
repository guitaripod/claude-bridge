import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Live OpenCode Go subscription usage from the console's own account status, read with this
/// machine's Go key. The status route is the one the console page renders: every window carries
/// the account's used and allowed micro-cents and the exact reset the provider will honour, and
/// the plan says whether the account is Go or Go Plus. The route is undocumented, so a bridge
/// that cannot read it serves the last reading it did read, marked cached, and otherwise says
/// plainly why there is no reading. Nothing here estimates.
enum OpenCodeGoUsage {
    private static let cache = UsageSnapshotCache(name: "opencode-go")
    private static let statusURL = URL(string: "https://opencode.ai/console/api/go/status")!
    private static let fallbackURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private static let microCentsPerDollar = 100_000_000.0
    private static let staleWindow: TimeInterval = 24 * 3600

    static func snapshot() async -> UsageSnapshot {
        guard let key = goKey() else {
            return unavailable("no opencode Go account on this machine")
        }
        if let fresh = await cache.fresh(within: 60) { return fresh }
        do {
            let snapshot = try await fetchLive(key: key)
            await cache.store(snapshot)
            return snapshot
        } catch {
            if var stale = await cache.fresh(within: staleWindow), !stale.gauges.isEmpty {
                stale.live = false
                stale.source = stale.source.replacingOccurrences(of: " · live", with: " · cached")
                stale.error = "\(error)"
                return stale
            }
            return unavailable("\(error)")
        }
    }

    /// The Go key opencode itself uses, from the same auth file the CLI keeps its logins in.
    static func goKey() -> String? {
        let path = dataHome().appendingPathComponent("opencode/auth.json")
        guard let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let block = json["opencode-go"] as? [String: Any],
            let key = block["key"] as? String, !key.isEmpty
        else { return nil }
        return key
    }

    private static func fetchLive(key: String) async throws -> UsageSnapshot {
        let (data, status) = try await send(statusURL, key: key)
        if status == 200 { return try parseStatus(data) }
        if status != 401 {
            let (fallbackData, fallbackStatus) = try await send(fallbackURL, key: key)
            if fallbackStatus == 200 { return try parseZen(fallbackData) }
        }
        throw failure(status: status, body: data)
    }

    private static func send(_ url: URL, key: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(
            "claude-bridge (+https://github.com/guitaripod/claude-bridge)",
            forHTTPHeaderField: "user-agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The console's status: one meter per published window, dollars against the plan's own
    /// ceilings, each reset exactly as opencode states it. A window the server leaves out is left
    /// out rather than invented, and a plan that is not Go Plus is still named Go.
    static func parseStatus(_ data: Data) throws -> UsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.message("opencode.ai returned an unreadable status")
        }
        guard let access = json["access"] as? [String: Any],
            let meters = access["meters"] as? [String: Any]
        else { throw Failure.message("opencode.ai reports no Go subscription") }

        let plan = planName(json["product"] as? String)
        let windows: [(key: String, label: String, meter: String)] = [
            ("five_hour", "5-hour session", "fiveHour"),
            ("weekly", "Weekly", "week"),
            ("monthly", "Monthly", "month"),
        ]
        var gauges: [UsageGauge] = []
        for window in windows {
            guard let block = meters[window.meter] as? [String: Any],
                let limit = microCents(block["limitMicroCents"]), limit > 0,
                let used = microCents(block["usedMicroCents"])
            else { continue }
            let reset = normalizedReset(block["resetsAt"])
            gauges.append(
                UsageGauge(
                    key: window.key,
                    label: window.label,
                    fraction: min(1, max(0, used / limit)),
                    resetsAt: reset,
                    trustedReset: reset != nil,
                    usedUSD: rounded(used / microCentsPerDollar),
                    limitUSD: rounded(limit / microCentsPerDollar)))
        }
        guard !gauges.isEmpty else {
            throw Failure.message("opencode.ai reports no Go usage windows")
        }

        var details = [
            UsageDetail(key: "Plan", value: plan),
            UsageDetail(key: "Counted by", value: "opencode.ai · account-wide"),
        ]
        if access["cancelAtPeriodEnd"] as? Bool == true,
            let ends = normalizedReset(access["endsAt"])
        {
            details.append(UsageDetail(key: "Ends", value: ends))
        }
        return UsageSnapshot(
            providerName: "opencode go",
            subtitle: plan,
            source: "opencode.ai console · live",
            live: true,
            gauges: gauges,
            details: details,
            error: nil)
    }

    /// The older Go usage route, which answers in percentages and does not name the plan. It is
    /// only reached when the console route has moved, and it never turns a percentage into a
    /// dollar figure the server did not state.
    static func parseZen(_ data: Data) throws -> UsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let usage = json["usage"] as? [String: Any]
        else { throw Failure.message("opencode.ai returned no usage block") }

        let windows: [(key: String, label: String, source: String)] = [
            ("five_hour", "5-hour session", "rolling"),
            ("weekly", "Weekly", "weekly"),
            ("monthly", "Monthly", "monthly"),
        ]
        var gauges: [UsageGauge] = []
        for window in windows {
            guard let block = usage[window.source] as? [String: Any],
                let percent = number(block["percent"])
            else { continue }
            let status = (block["status"] as? String)?.lowercased()
            let reset = normalizedReset(block["resetsAt"])
            let money = microCents(block["usedMicroCents"]).flatMap { used in
                microCents(block["limitMicroCents"]).map { (used, $0) }
            }
            gauges.append(
                UsageGauge(
                    key: window.key,
                    label: window.label,
                    fraction: ["limit", "blocked", "exceeded"].contains(status ?? "")
                        ? 1 : min(1, max(0, percent / 100)),
                    resetsAt: reset,
                    trustedReset: reset != nil,
                    usedUSD: money.map { rounded($0.0 / microCentsPerDollar) },
                    limitUSD: money.map { rounded($0.1 / microCentsPerDollar) }))
        }
        guard !gauges.isEmpty else {
            throw Failure.message("opencode.ai returned no windows")
        }
        return UsageSnapshot(
            providerName: "opencode go",
            subtitle: "",
            source: "opencode.ai Go usage API · live",
            live: true,
            gauges: gauges,
            details: [
                UsageDetail(key: "Counted by", value: "opencode.ai · account-wide")
            ],
            error: nil)
    }

    /// The sentence a failed request carries, without the key and without a body a log or a card
    /// would have to truncate later.
    static func failure(status: Int, body: Data) -> Failure {
        let message =
            serverMessage(body)
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return .message("opencode.ai returned \(status): \(message)")
    }

    static func serverMessage(_ body: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any] {
                if let message = error["message"] as? String { return message }
                if let type = error["type"] as? String { return type }
            }
            for key in ["message", "code", "_tag"] {
                if let value = json[key] as? String, !value.isEmpty { return value }
            }
        }
        let text = String(decoding: body.prefix(240), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return text
    }

    private static func planName(_ product: String?) -> String {
        switch product?.lowercased() {
        case "go-plus": return "Go Plus"
        default: return "Go"
        }
    }

    private static func microCents(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let number = Double(string) { return number }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// Re-emits opencode's timestamp as plain ISO8601 to the second, which the client's
    /// `.iso8601` `JSONDecoder` can parse. Opencode writes fractional seconds; the console route
    /// may also write epoch milliseconds.
    static func normalizedReset(_ value: Any?) -> String? {
        guard let date = timestamp(value) else { return nil }
        return BridgeTimestamps.string(date)
    }

    private static func timestamp(_ value: Any?) -> Date? {
        if let raw = value as? String {
            if let date = BridgeTimestamps.date(raw) { return date }
            if let number = Double(raw) { return date(fromEpoch: number) }
            return nil
        }
        if let number = value as? NSNumber { return date(fromEpoch: number.doubleValue) }
        return nil
    }

    private static func date(fromEpoch value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
    }

    private static func dataHome() -> URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share")
    }

    private static func unavailable(_ reason: String) -> UsageSnapshot {
        UsageSnapshot(
            providerName: "opencode go",
            subtitle: "Go",
            source: "opencode.ai console",
            live: false,
            gauges: [],
            details: [],
            error: reason)
    }

    enum Failure: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self { case .message(let text): return text }
        }
    }
}
