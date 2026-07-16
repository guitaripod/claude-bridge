import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private struct GrokCredentials {
    var accessToken: String
    var refreshToken: String
    var expiresAtMs: Int64
    var oidcIssuer: String
    var oidcClientId: String
    var email: String
    var tier: Int64
    var entryKey: String
}

/// Live Grok Build quota from the same billing endpoint the Grok CLI's
/// `/usage` command uses, read from this machine's `~/.grok/auth.json`.
enum GrokUsage {
    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    private static let clientVersion = "0.2.101"
    private static let userAgent = "claude-bridge (+https://github.com/guitaripod/claude-bridge)"

    static func snapshot() async -> UsageSnapshot {
        do {
            return try await loadAndFetch()
        } catch {
            return unavailable("\(error)")
        }
    }

    private static func loadAndFetch() async throws -> UsageSnapshot {
        var creds = try loadGrok()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if creds.expiresAtMs > 0, nowMs >= creds.expiresAtMs - 120_000 {
            if let fresh = try? await refresh(creds) { creds = fresh }
        }

        let (status, credits) = try await getJSON(creditsURL, token: creds.accessToken)
        if status == 401 || status == 403 {
            let fresh = try await refresh(creds)
            let (retryStatus, retryBody) = try await getJSON(creditsURL, token: fresh.accessToken)
            guard retryStatus == 200 else {
                throw GrokUsageError.message("billing endpoint returned \(retryStatus) after refresh")
            }
            let dollars = try? await getJSON(billingURL, token: fresh.accessToken)
            return parse(retryBody, dollars: dollars?.1, creds: fresh)
        }
        guard status == 200 else { throw GrokUsageError.message("billing endpoint returned \(status)") }
        let dollars = try? await getJSON(billingURL, token: creds.accessToken)
        return parse(credits, dollars: dollars?.1, creds: creds)
    }

    private static func getJSON(_ url: URL, token: String) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(clientVersion, forHTTPHeaderField: "x-grok-client-version")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    private static func parse(
        _ credits: [String: Any], dollars: [String: Any]?, creds: GrokCredentials
    ) -> UsageSnapshot {
        let config = credits["config"] as? [String: Any] ?? [:]
        var gauges: [UsageGauge] = []

        let weeklyPct = (config["creditUsagePercent"] as? NSNumber)?.doubleValue ?? 0
        let weeklyResetRaw = (config["currentPeriod"] as? [String: Any])?["end"] as? String
            ?? config["billingPeriodEnd"] as? String
        let weeklyReset = normalizeTS(weeklyResetRaw)
        gauges.append(UsageGauge(
            key: "weekly", label: "Weekly credits",
            fraction: min(1, max(0, weeklyPct / 100)),
            resetsAt: weeklyReset, trustedReset: true,
            usedUSD: nil, limitUSD: nil))

        if let products = config["productUsage"] as? [[String: Any]] {
            for product in products {
                guard let name = product["product"] as? String,
                    let pct = (product["usagePercent"] as? NSNumber)?.doubleValue
                else { continue }
                gauges.append(UsageGauge(
                    key: "product_\(name.lowercased())",
                    label: prettyProduct(name),
                    fraction: min(1, max(0, pct / 100)),
                    resetsAt: weeklyReset, trustedReset: true,
                    usedUSD: nil, limitUSD: nil))
            }
        }

        let onCap = moneyCents(config["onDemandCap"])
        let onUsed = moneyCents(config["onDemandUsed"]) ?? 0
        if let cap = onCap, cap > 0 {
            gauges.append(UsageGauge(
                key: "on_demand", label: "Pay-as-you-go",
                fraction: min(1, max(0, onUsed / cap)),
                resetsAt: nil, trustedReset: false,
                usedUSD: onUsed, limitUSD: cap))
        }

        if let dollars,
            let dcfg = dollars["config"] as? [String: Any],
            let used = moneyCents(dcfg["used"]),
            let limit = moneyCents(dcfg["monthlyLimit"]), limit > 0
        {
            gauges.append(UsageGauge(
                key: "monthly", label: "Monthly spend",
                fraction: min(1, max(0, used / limit)),
                resetsAt: normalizeTS(dcfg["billingPeriodEnd"] as? String),
                trustedReset: false,
                usedUSD: used, limitUSD: limit))
        }

        return UsageSnapshot(
            providerName: "Grok",
            subtitle: subtitle(creds),
            source: "cli-chat-proxy.grok.com · live",
            live: true,
            gauges: gauges,
            details: details(config, creds: creds),
            error: nil)
    }

    private static func moneyCents(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue / 100 }
        if let obj = value as? [String: Any], let n = obj["val"] as? NSNumber {
            return n.doubleValue / 100
        }
        return nil
    }

    private static func prettyProduct(_ name: String) -> String {
        switch name {
        case "GrokBuild": "Grok Build"
        case "Api", "API": "API"
        default: name
        }
    }

    private static func subtitle(_ creds: GrokCredentials) -> String {
        switch creds.tier {
        case 0: "Free"
        case 1: "Basic"
        case 2: "SuperGrok"
        case 3: "X Premium"
        case let n where n > 3: "Tier \(n)"
        default: "Grok"
        }
    }

    private static func details(_ config: [String: Any], creds: GrokCredentials) -> [UsageDetail] {
        var rows: [UsageDetail] = []
        if !creds.email.isEmpty {
            rows.append(UsageDetail(key: "Account", value: creds.email))
        }
        if let end = (config["currentPeriod"] as? [String: Any])?["end"] as? String
            ?? config["billingPeriodEnd"] as? String,
            let date = parseTimestamp(end)
        {
            rows.append(UsageDetail(key: "Weekly resets", value: humanize(date)))
        }
        if let prepaid = moneyCents(config["prepaidBalance"]), prepaid > 0 {
            rows.append(UsageDetail(key: "Prepaid balance", value: String(format: "$%.2f", prepaid)))
        }
        let period = ((config["currentPeriod"] as? [String: Any])?["type"] as? String
            ?? "weekly").replacingOccurrences(of: "USAGE_PERIOD_TYPE_", with: "").lowercased()
        rows.append(UsageDetail(key: "Period", value: period))
        return rows
    }

    private static func humanize(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "in \(hours)h \(minutes % 60)m" }
        return "in \(hours / 24)d \(hours % 24)h"
    }

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

    private static func authPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".grok/auth.json")
    }

    private static func loadGrok() throws -> GrokCredentials {
        let data = try Data(contentsOf: authPath())
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokUsageError.message("grok auth.json is not an object — run `grok login`")
        }
        let preferred = root.first { key, value in
            key.contains("auth.x.ai")
                && ((value as? [String: Any])?["key"] as? String).map { !$0.isEmpty } == true
        } ?? root.first { _, value in
            ((value as? [String: Any])?["key"] as? String).map { !$0.isEmpty } == true
        }
        guard let (entryKey, rawEntry) = preferred,
            let entry = rawEntry as? [String: Any],
            let accessToken = entry["key"] as? String
        else {
            throw GrokUsageError.message("no grok session — run `grok login`")
        }
        return GrokCredentials(
            accessToken: accessToken,
            refreshToken: entry["refresh_token"] as? String ?? "",
            expiresAtMs: parseExpiresMs(entry["expires_at"] as? String ?? ""),
            oidcIssuer: entry["oidc_issuer"] as? String ?? "https://auth.x.ai",
            oidcClientId: entry["oidc_client_id"] as? String ?? "",
            email: entry["email"] as? String ?? "",
            tier: jwtClaimInt64(accessToken, claim: "tier") ?? 0,
            entryKey: entryKey)
    }

    private static func writeBackGrok(
        entryKey: String, accessToken: String, refreshToken: String, expiresAt: String
    ) throws {
        let path = authPath()
        let data = try Data(contentsOf: path)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var entry = root[entryKey] as? [String: Any]
        else {
            throw GrokUsageError.message("auth entry missing after refresh")
        }
        entry["key"] = accessToken
        entry["refresh_token"] = refreshToken
        entry["expires_at"] = expiresAt
        root[entryKey] = entry
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try out.write(to: path, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private static func refresh(_ creds: GrokCredentials) async throws -> GrokCredentials {
        guard !creds.refreshToken.isEmpty else {
            throw GrokUsageError.message("no refresh token — run `grok login`")
        }
        guard !creds.oidcClientId.isEmpty else {
            throw GrokUsageError.message("no OIDC client id in grok auth")
        }
        let issuer = creds.oidcIssuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(issuer)/oauth2/token") else {
            throw GrokUsageError.message("bad OIDC issuer")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(formEncode(creds.refreshToken))",
            "client_id=\(formEncode(creds.oidcClientId))",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GrokUsageError.message("token refresh returned \(status)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String else {
            throw GrokUsageError.message("no access_token in refresh response")
        }
        let newRefresh = json["refresh_token"] as? String ?? creds.refreshToken
        let expiresIn = (json["expires_in"] as? NSNumber)?.intValue ?? 21_600
        let expiresAt = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(TimeInterval(expiresIn)))
        try writeBackGrok(
            entryKey: creds.entryKey,
            accessToken: access,
            refreshToken: newRefresh,
            expiresAt: expiresAt)
        return try loadGrok()
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: " ", with: "+") ?? value
    }

    private static func parseExpiresMs(_ raw: String) -> Int64 {
        guard !raw.isEmpty else { return 0 }
        guard let date = parseTimestamp(raw) else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func jwtClaimInt64(_ token: String, claim: String) -> Int64? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        let pad = (4 - payload.count % 4) % 4
        if pad > 0 { payload += String(repeating: "=", count: pad) }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (json[claim] as? NSNumber)?.int64Value
    }

    private static func unavailable(_ error: String) -> UsageSnapshot {
        UsageSnapshot(
            providerName: "Grok",
            subtitle: "Grok",
            source: "cli-chat-proxy.grok.com · unreachable",
            live: false,
            gauges: [],
            details: [],
            error: error)
    }
}

private enum GrokUsageError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let value): value
        }
    }
}
