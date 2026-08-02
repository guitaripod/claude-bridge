import Foundation

/// Estimated opencode Go subscription usage. opencode's console shows the real numbers behind a
/// browser session and offers no key-authed API, but every Go turn this machine ran is in
/// opencode's local database with its list-price cost — the same quantity the subscription
/// windows meter. Summing it over the published windows ($12 per rolling 5 h, $30 per week,
/// $60 per month) reproduces the console's picture for a single-machine account, so the
/// snapshot says "estimated" and counts only this machine.
enum OpenCodeGoUsage {
    private static let cache = UsageSnapshotCache(name: "opencode-go")

    static func snapshot() async -> UsageSnapshot {
        guard hasGoAccount() else {
            return unavailable("no opencode Go account on this machine")
        }
        if let fresh = await cache.fresh(within: 60) { return fresh }
        do {
            let snapshot = try measure()
            await cache.store(snapshot)
            return snapshot
        } catch {
            if var stale = await cache.fresh(within: 24 * 3600) {
                stale.source += " · cached"
                return stale
            }
            return unavailable("\(error)")
        }
    }

    private static func hasGoAccount() -> Bool {
        let path = dataHome().appendingPathComponent("opencode/auth.json")
        guard let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["opencode-go"] != nil
    }

    private static func measure() throws -> UsageSnapshot {
        let database = databasePath()
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw Failure.message("opencode database not found")
        }
        let limits = configuredLimits()
        let spent = try spentUSD(database: database, windows: [
            ("rolling", 5 * 3600.0), ("weekly", 7 * 86400.0), ("monthly", 30 * 86400.0),
        ])
        let gauges = [
            gauge(key: "rolling", label: "5-hour window", used: spent["rolling"] ?? 0, limit: limits.rolling),
            gauge(key: "weekly", label: "Weekly", used: spent["weekly"] ?? 0, limit: limits.weekly),
            gauge(key: "monthly", label: "Monthly", used: spent["monthly"] ?? 0, limit: limits.monthly),
        ]
        return UsageSnapshot(
            providerName: "opencode",
            subtitle: "Go",
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

    private static func unavailable(_ reason: String) -> UsageSnapshot {
        UsageSnapshot(
            providerName: "opencode", subtitle: "Go",
            source: "opencode.db", live: false, gauges: [], details: [], error: reason)
    }

    private enum Failure: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self { case .message(let text): return text }
        }
    }
}
