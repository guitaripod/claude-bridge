import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Live OpenCode Go subscription usage from opencode's own usage API, read with this machine's
/// Go key. The same numbers sit behind the console at opencode.ai, but the endpoint answers to
/// the Go key directly — account-wide, every machine's spend folded server-side, with the exact
/// reset moment of each window (the monthly reset is the billing-cycle anchor). The endpoint is
/// undocumented, so a bridge that cannot reach it falls back to the opencode.db estimate: the
/// same windows summed from the turns this machine ran.
enum OpenCodeGoUsage {
    private static let cache = UsageSnapshotCache(name: "opencode-go")
    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

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
            do {
                let estimate = try estimate()
                await cache.store(estimate)
                return estimate
            } catch {
                if var stale = await cache.fresh(within: 24 * 3600) {
                    stale.source += " · cached"
                    return stale
                }
                return unavailable("\(error)")
            }
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
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(
            "claude-bridge (+https://github.com/guitaripod/claude-bridge)",
            forHTTPHeaderField: "user-agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.message("usage endpoint returned \(status)")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let usage = json["usage"] as? [String: Any]
        else { throw Failure.message("usage endpoint returned no usage block") }
        return try parseLive(usage)
    }

    /// One gauge per published window, dollars against the plan's caps, each reset exactly as
    /// opencode's server states it. A window whose status says the account is walled reads as
    /// exhausted whatever its percentage; anything else renders the server's number.
    static func parseLive(_ usage: [String: Any]) throws -> UsageSnapshot {
        let limits = configuredLimits()
        let windows: [(key: String, label: String, cap: Double)] = [
            ("rolling", "5-hour", limits.rolling),
            ("weekly", "Weekly", limits.weekly),
            ("monthly", "Monthly", limits.monthly),
        ]
        var gauges: [UsageGauge] = []
        for window in windows {
            guard let block = usage[window.key] as? [String: Any],
                let percent = (block["percent"] as? NSNumber)?.doubleValue
            else { continue }
            let status = block["status"] as? String
            let fraction = ["limit", "blocked"].contains(status ?? "")
                ? 1
                : min(1, max(0, percent / 100))
            gauges.append(
                UsageGauge(
                    key: window.key, label: window.label,
                    fraction: fraction,
                    resetsAt: normalizedReset(block["resetsAt"]),
                    trustedReset: true,
                    usedUSD: rounded(percent * window.cap / 100),
                    limitUSD: window.cap))
        }
        guard !gauges.isEmpty else {
            throw Failure.message("usage endpoint returned no windows")
        }
        return UsageSnapshot(
            providerName: "opencode",
            subtitle: "$10/mo",
            source: "opencode.ai Go usage API · live",
            live: true,
            gauges: gauges,
            details: [
                UsageDetail(key: "Counted by", value: "opencode.ai · account-wide")
            ],
            error: nil)
    }

    private static func estimate() throws -> UsageSnapshot {
        let database = databasePath()
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw Failure.message("opencode database not found")
        }
        let limits = configuredLimits()
        let spent = try spentUSD(database: database, windows: [
            ("rolling", 5 * 3600.0), ("weekly", 7 * 86400.0), ("monthly", 30 * 86400.0),
        ])
        let gauges = [
            gauge(key: "rolling", label: "5-hour", used: spent["rolling"] ?? 0, limit: limits.rolling),
            gauge(key: "weekly", label: "Weekly", used: spent["weekly"] ?? 0, limit: limits.weekly),
            gauge(key: "monthly", label: "Monthly", used: spent["monthly"] ?? 0, limit: limits.monthly),
        ]
        return UsageSnapshot(
            providerName: "opencode",
            subtitle: "$10/mo",
            source: "opencode.db · this machine · estimated",
            live: true,
            gauges: gauges,
            details: [
                UsageDetail(key: "Counted from", value: "turns this machine ran"),
                UsageDetail(key: "Exact numbers", value: "opencode.ai console"),
            ],
            error: nil)
    }

    private static func gauge(key: String, label: String, used: Double, limit: Double) -> UsageGauge {
        UsageGauge(
            key: key, label: label,
            fraction: limit > 0 ? used / limit : 0,
            resetsAt: nil, trustedReset: false,
            usedUSD: (used * 100).rounded() / 100, limitUSD: limit)
    }

    /// One `sqlite3` invocation for all windows: assistant messages from the Go provider, cost
    /// summed per window. The CLI dependency is deliberate — the bridge links no SQLite, and a
    /// machine running opencode has its database tooling within reach.
    private static func spentUSD(
        database: URL, windows: [(key: String, seconds: Double)]
    ) throws -> [String: Double] {
        let now = Date().timeIntervalSince1970
        let selects = windows.map { window in
            let cutoff = Int64((now - window.seconds) * 1000)
            return """
                SELECT '\(window.key)', COALESCE(SUM(json_extract(data,'$.cost')),0) FROM message \
                WHERE json_extract(data,'$.role')='assistant' \
                AND json_extract(data,'$.providerID')='opencode-go' \
                AND time_created > \(cutoff)
                """
        }
        let output = try run(
            "/usr/bin/env", ["sqlite3", "-readonly", database.path, selects.joined(separator: ";")])
        var spent: [String: Double] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|")
            guard parts.count == 2, let value = Double(parts[1]) else { continue }
            spent[String(parts[0])] = value
        }
        return spent
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.message("sqlite3 exited \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func databasePath() -> URL {
        if let override = ProcessInfo.processInfo.environment["BRIDGE_OPENCODE_DB"] {
            return URL(fileURLWithPath: override)
        }
        return dataHome().appendingPathComponent("opencode/opencode.db")
    }

    private static func dataHome() -> URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share")
    }

    /// The published Go windows; overridable if the plan changes before the bridge does.
    /// `BRIDGE_OPENCODE_GO_LIMITS="12,30,60"` — rolling, weekly, monthly, in dollars.
    private static func configuredLimits() -> (rolling: Double, weekly: Double, monthly: Double) {
        if let raw = ProcessInfo.processInfo.environment["BRIDGE_OPENCODE_GO_LIMITS"] {
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            if parts.count == 3 { return (parts[0], parts[1], parts[2]) }
        }
        return (12, 30, 60)
    }

    /// Re-emits opencode's fractional-seconds timestamp as plain `.withInternetDateTime` ISO8601,
    /// which the client's `.iso8601` `JSONDecoder` can parse.
    private static func normalizedReset(_ value: Any?) -> String? {
        guard let raw = value as? String, let date = parseTimestamp(raw) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.string(from: date)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func unavailable(_ reason: String) -> UsageSnapshot {
        UsageSnapshot(
            providerName: "opencode", subtitle: "$10/mo",
            source: "opencode.db", live: false, gauges: [], details: [], error: reason)
    }

    private enum Failure: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self { case .message(let text): return text }
        }
    }
}
