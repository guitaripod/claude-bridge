import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct UsageGauge: Codable, Sendable {
    var key: String
    var label: String
    var fraction: Double
    var resetsAt: String?
    var trustedReset: Bool
    var usedUSD: Double?
    var limitUSD: Double?
}

struct UsageDetail: Codable, Sendable {
    var key: String
    var value: String
}

struct UsageSnapshot: Codable, Sendable {
    var providerName: String
    var subtitle: String
    var source: String
    var live: Bool
    var gauges: [UsageGauge]
    var details: [UsageDetail]
    var error: String?
}

private struct ClaudeCredentials {
    var accessToken: String
    var refreshToken: String
    var expiresAtMs: Int64
    var subscriptionType: String
    var rateLimitTier: String
}

/// Live Claude Max/Pro quota from the same OAuth endpoint Claude Code's
/// `/usage` command uses, read from this machine's `~/.claude/.credentials.json`.
enum ClaudeUsage {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let oauthBeta = "oauth-2025-04-20"

    static func snapshot() async -> UsageSnapshot {
        do {
            return try await loadAndFetch()
        } catch {
            return unavailable("\(error)")
        }
    }

    private static func loadAndFetch() async throws -> UsageSnapshot {
        var creds = try loadClaude()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if creds.expiresAtMs > 0, nowMs >= creds.expiresAtMs - 120_000 {
            if let fresh = try? await refresh(creds.refreshToken) { creds = fresh }
        }

        let (status, body) = try await getUsage(creds.accessToken)
        if status == 401 || status == 403 {
            let fresh = try await refresh(creds.refreshToken)
            let (retryStatus, retryBody) = try await getUsage(fresh.accessToken)
            guard retryStatus == 200 else {
                throw UsageError.message("usage endpoint returned \(retryStatus) after refresh")
            }
            return parse(retryBody, creds: fresh)
        }
        guard status == 200 else { throw UsageError.message("usage endpoint returned \(status)") }
        return parse(body, creds: creds)
    }

    private static func getUsage(_ token: String) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(
            "claude-bridge (+https://github.com/guitaripod/claude-bridge)",
            forHTTPHeaderField: "user-agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    private static func parse(_ json: [String: Any], creds: ClaudeCredentials) -> UsageSnapshot {
        var gauges: [UsageGauge] = []
        if let limits = json["limits"] as? [[String: Any]] {
            gauges = limits.compactMap(gaugeFromLimit)
        }
        if gauges.isEmpty { gauges = gaugesFromTopLevel(json) }
        if let extra = gaugeFromExtra(json) { gauges.append(extra) }

        return UsageSnapshot(
            providerName: "Claude",
            subtitle: subtitle(creds),
            source: "api.anthropic.com · live",
            live: true,
            gauges: gauges,
            details: details(json),
            error: nil)
    }

    private static func gaugeFromLimit(_ item: [String: Any]) -> UsageGauge? {
        guard let kind = item["kind"] as? String,
            let percent = (item["percent"] as? NSNumber)?.doubleValue
        else { return nil }
        let model = ((item["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        let label: String
        switch (kind, model) {
        case ("session", _): label = "5-hour session"
        case ("weekly_all", _): label = "Weekly · all models"
        case ("weekly_scoped", .some(let name)): label = "Weekly · \(name)"
        case ("weekly_scoped", .none): label = "Weekly · scoped"
        case (let other, .some(let name)): label = "\(pretty(other)) · \(name)"
        case (let other, .none): label = pretty(other)
        }
        return UsageGauge(
            key: kind, label: label,
            fraction: min(1, max(0, percent / 100)),
            resetsAt: normalizeTS(item["resets_at"]),
            trustedReset: kind == "session",
            usedUSD: nil, limitUSD: nil)
    }

    private static func gaugesFromTopLevel(_ json: [String: Any]) -> [UsageGauge] {
        [("five_hour", "5-hour session", true), ("seven_day", "Weekly · all models", false)]
            .compactMap { key, label, trusted in
                guard let obj = json[key] as? [String: Any],
                    let utilization = (obj["utilization"] as? NSNumber)?.doubleValue
                else { return nil }
                return UsageGauge(
                    key: key, label: label,
                    fraction: min(1, max(0, utilization / 100)),
                    resetsAt: normalizeTS(obj["resets_at"]),
                    trustedReset: trusted,
                    usedUSD: nil, limitUSD: nil)
            }
    }

    private static func gaugeFromExtra(_ json: [String: Any]) -> UsageGauge? {
        guard let extra = json["extra_usage"] as? [String: Any],
            (extra["is_enabled"] as? NSNumber)?.boolValue == true,
            let utilization = (extra["utilization"] as? NSNumber)?.doubleValue
        else { return nil }
        return UsageGauge(
            key: "extra_usage", label: "Extra usage credits",
            fraction: min(1, max(0, utilization / 100)),
            resetsAt: nil, trustedReset: false,
            usedUSD: (extra["used_credits"] as? NSNumber)?.doubleValue,
            limitUSD: (extra["monthly_limit"] as? NSNumber)?.doubleValue)
    }

    private static func details(_ json: [String: Any]) -> [UsageDetail] {
        var details: [UsageDetail] = []
        if let value = (json["five_hour"] as? [String: Any])?["resets_at"] as? String {
            details.append(UsageDetail(key: "Session resets", value: humanize(value)))
        }
        if let value = (json["seven_day"] as? [String: Any])?["resets_at"] as? String {
            details.append(UsageDetail(key: "Weekly resets", value: humanize(value)))
        }
        let extraEnabled = ((json["extra_usage"] as? [String: Any])?["is_enabled"] as? NSNumber)?.boolValue ?? false
        details.append(UsageDetail(key: "Extra usage credits", value: extraEnabled ? "enabled" : "disabled"))
        return details
    }

    private static func subtitle(_ creds: ClaudeCredentials) -> String {
        let plan: String
        switch creds.subscriptionType {
        case "max": plan = "Max"
        case "pro": plan = "Pro"
        default: plan = creds.subscriptionType
        }
        if let multiplier = creds.rateLimitTier.split(separator: "_").last, multiplier.hasSuffix("x") {
            return "\(plan) · \(multiplier.dropLast())×"
        }
        return plan
    }

    private static func pretty(_ kind: String) -> String {
        kind.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func humanize(_ raw: String) -> String {
        guard let date = parseTimestamp(raw) else { return raw }
        let seconds = max(0, date.timeIntervalSinceNow)
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "in \(hours)h \(minutes % 60)m" }
        return "in \(hours / 24)d \(hours % 24)h"
    }

    /// Re-emits Anthropic's fractional-seconds timestamp as plain `.withInternetDateTime` ISO8601,
    /// which the client's `.iso8601` `JSONDecoder` can parse.
    private static func normalizeTS(_ value: Any?) -> String? {
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

    private static func loadClaude() throws -> ClaudeCredentials {
        let data = try Data(contentsOf: credentialsPath())
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String
        else {
            throw UsageError.message("no claudeAiOauth block — run `claude` to sign in")
        }
        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String ?? "",
            expiresAtMs: (oauth["expiresAt"] as? NSNumber)?.int64Value ?? 0,
            subscriptionType: oauth["subscriptionType"] as? String ?? "unknown",
            rateLimitTier: oauth["rateLimitTier"] as? String ?? "")
    }

    private static func writeBackClaude(accessToken: String, refreshToken: String, expiresAtMs: Int64) throws {
        let path = credentialsPath()
        let data = try Data(contentsOf: path)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var oauth = root["claudeAiOauth"] as? [String: Any]
        else {
            throw UsageError.message("credentials file missing claudeAiOauth")
        }
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = expiresAtMs
        root["claudeAiOauth"] = oauth
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try out.write(to: path, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private static func credentialsPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
    }

    private static func refresh(_ refreshToken: String) async throws -> ClaudeCredentials {
        guard !refreshToken.isEmpty else {
            throw UsageError.message("no refresh token — run `claude` to sign in")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UsageError.message("token refresh returned \(status)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String
        else { throw UsageError.message("no access_token in refresh response") }
        let newRefresh = json["refresh_token"] as? String ?? refreshToken
        let expiresIn = (json["expires_in"] as? NSNumber)?.int64Value ?? 28_800
        let expiresAtMs = Int64(Date().timeIntervalSince1970 * 1000) + expiresIn * 1000
        try writeBackClaude(accessToken: access, refreshToken: newRefresh, expiresAtMs: expiresAtMs)
        return try loadClaude()
    }

    private static func unavailable(_ error: String) -> UsageSnapshot {
        UsageSnapshot(
            providerName: "Claude",
            subtitle: "Claude",
            source: "api.anthropic.com · unreachable",
            live: false,
            gauges: [],
            details: [],
            error: error)
    }
}

private enum UsageError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let value): value
        }
    }
}
