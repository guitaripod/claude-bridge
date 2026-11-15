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
    var startsAt: String?
    /// The limiter's verdict on this window from the last response a turn here got: `true` while
    /// it refuses requests, `false` while it answers them, nil when no turn has said
    /// (``RateLimitOverlay``). A refusal reads `fraction` 1 like a whole 100 % does; this tells the
    /// two apart for a client folding several machines' readings.
    var refused: Bool?

    init(
        key: String, label: String, fraction: Double, resetsAt: String?, trustedReset: Bool,
        usedUSD: Double? = nil, limitUSD: Double? = nil, startsAt: String? = nil
    ) {
        self.key = key
        self.label = label
        self.fraction = fraction
        self.resetsAt = resetsAt
        self.trustedReset = trustedReset
        self.usedUSD = usedUSD
        self.limitUSD = limitUSD
        self.startsAt = startsAt
    }
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
    var errorCode: String?
    var accountID: String?
    var schema: Int?

    init(
        providerName: String, subtitle: String, source: String, live: Bool,
        gauges: [UsageGauge], details: [UsageDetail], error: String? = nil,
        errorCode: String? = nil, accountID: String? = nil, schema: Int? = nil
    ) {
        self.providerName = providerName
        self.subtitle = subtitle
        self.source = source
        self.live = live
        self.gauges = gauges
        self.details = details
        self.error = error
        self.errorCode = errorCode
        self.accountID = accountID
        self.schema = schema
    }
}

extension UsageSnapshot {
    /// Whether a window in this reading, taken at `readAt`, has reset since then and by `now`,
    /// which makes it a picture of a window that has ended. A reading taken after its own stated
    /// reset (the endpoint lagging its clock) is the newest there is, and asking again at once
    /// would only ask again.
    func hasReset(after readAt: Date, by now: Date) -> Bool {
        gauges.contains { gauge in
            guard let reset = gauge.resetsAt.flatMap(BridgeTimestamps.date) else { return false }
            return reset > readAt && reset <= now
        }
    }
}

private struct ClaudeCredentials {
    var accessToken: String
    var refreshToken: String
    var expiresAtMs: Int64
    var subscriptionType: String
    var rateLimitTier: String
}

/// What the account itself says it is on, as opposed to what this machine's login file remembers.
private struct ClaudeProfile: Sendable {
    var planName: String?
    var rateLimitTier: String?
}

/// Live Claude Max/Pro quota from the same OAuth endpoint Claude Code's
/// `/usage` command uses, read from this machine's `~/.claude/.credentials.json`.
enum ClaudeUsage {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let oauthBeta = "oauth-2025-04-20"

    /// Every client surface (home card, usage screen, other apps on the same
    /// account) polls this; a short TTL keeps us from hammering Anthropic
    /// into 429s, and a failed fetch serves the last good snapshot instead of
    /// blanking every gauge.
    private static let cache = UsageSnapshotCache(name: "claude")
    private static let staleWindow: TimeInterval = 24 * 3600
    /// A plan changes on a billing cycle, so it is asked for far less often than the gauges — and
    /// the last answer is kept without an expiry as the fallback, because the account's own answer
    /// from ten minutes ago is still a better account of the plan than a login file from March.
    private static let planCache = PlanCache()
    private static let planTTL: TimeInterval = 600

    private actor PlanCache {
        private var held: ClaudeProfile?
        private var at: Date?

        func value(within ttl: TimeInterval) -> ClaudeProfile? {
            guard let held, let at, Date().timeIntervalSince(at) < ttl else { return nil }
            return held
        }

        func store(_ profile: ClaudeProfile) {
            held = profile
            at = Date()
        }
    }

    /// A reading a minute old is served as it is, unless one of its windows has reset since: a
    /// week that opened at 21:00 is not still used up at 21:00:30 because the last answer said so.
    /// A failed read backs off, except once after each reset its last reading was waiting for.
    static func snapshot() async -> UsageSnapshot {
        let now = Date()
        if let held = await cache.held(within: 60),
            !held.snapshot.hasReset(after: held.at, by: now)
        {
            return await sharpened(held.snapshot, readAt: held.at)
        }
        if await cache.inBackoff, !(await cache.owesReadAfterReset(now: now)) {
            if let stale = await cache.held(within: staleWindow) {
                return await sharpened(cached(stale.snapshot), readAt: stale.at)
            }
            return unavailable("rate limited — retrying later")
        }
        await cache.noteAttempt(at: now)
        do {
            let snapshot = try await loadAndFetch()
            await cache.store(snapshot)
            return await sharpened(snapshot, readAt: Date())
        } catch {
            await cache.noteFailure()
            if let stale = await cache.held(within: staleWindow) {
                return await sharpened(cached(stale.snapshot), readAt: stale.at)
            }
            return unavailable("\(error)")
        }
    }

    /// A reading served from the last good one is not live, and says so: a client folding several
    /// machines' readings of one account lets a live one speak over it. A window in it whose reset
    /// has passed is served as the reset window it now is — empty, opened at that reset, with no
    /// reset of its own until a read names one — because the account said when it would open.
    static func cached(_ snapshot: UsageSnapshot, now: Date = Date()) -> UsageSnapshot {
        var served = snapshot
        served.source = "api.anthropic.com · cached"
        served.live = false
        served.gauges = snapshot.gauges.map { gauge in
            guard let reset = gauge.resetsAt, let date = BridgeTimestamps.date(reset), date <= now,
                !(gauge.usedUSD != nil && gauge.limitUSD == nil)
            else { return gauge }
            var opened = gauge
            opened.fraction = 0
            opened.startsAt = reset
            opened.resetsAt = nil
            if opened.limitUSD != nil { opened.usedUSD = 0 }
            return opened
        }
        return served
    }

    /// The endpoint's reading with the last turn's limiter reading laid over it
    /// (``RateLimitOverlay``).
    private static func sharpened(_ snapshot: UsageSnapshot, readAt: Date) async -> UsageSnapshot {
        var served = snapshot
        served.gauges = RateLimitOverlay.apply(
            snapshot.gauges, readAt: readAt, reading: await RateLimitLedger.shared.latest,
            now: Date())
        return served
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
            return parse(retryBody, creds: fresh, profile: await profile(fresh.accessToken))
        }
        guard status == 200 else { throw UsageError.message("usage endpoint returned \(status)") }
        return parse(body, creds: creds, profile: await profile(creds.accessToken))
    }

    /// The account's own answer about which plan it is on, kept for longer than the gauges because
    /// a plan changes on a billing cycle rather than on a turn, and asked with the same token the
    /// gauges were just fetched with. A failure here is not a failure of the snapshot: the bars are
    /// still true, so the plan simply goes unnamed rather than taking the snapshot down with it.
    private static func profile(_ token: String) async -> ClaudeProfile? {
        if let held = await planCache.value(within: planTTL) { return held }
        var request = URLRequest(url: profileURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(
            "claude-bridge (+https://github.com/guitaripod/claude-bridge)",
            forHTTPHeaderField: "user-agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return await planCache.value(within: .infinity) }
        let organization = json["organization"] as? [String: Any]
        let account = json["account"] as? [String: Any]
        let named: String? = {
            if let type = organization?["organization_type"] as? String {
                switch type {
                case "claude_max": return "Max"
                case "claude_pro": return "Pro"
                default: break
                }
            }
            if (account?["has_claude_max"] as? NSNumber)?.boolValue == true { return "Max" }
            if (account?["has_claude_pro"] as? NSNumber)?.boolValue == true { return "Pro" }
            return nil
        }()
        let found = ClaudeProfile(
            planName: named, rateLimitTier: organization?["rate_limit_tier"] as? String)
        await planCache.store(found)
        return found
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

    private static func parse(
        _ json: [String: Any], creds: ClaudeCredentials, profile: ClaudeProfile?
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerName: "Claude",
            subtitle: subtitle(creds, profile: profile),
            source: "api.anthropic.com · live",
            live: true,
            gauges: gauges(from: json),
            details: details(json),
            error: nil)
    }

    /// Every window the usage endpoint's answer states, in its own order.
    static func gauges(from json: [String: Any]) -> [UsageGauge] {
        var gauges: [UsageGauge] = []
        if let limits = json["limits"] as? [[String: Any]] {
            gauges = limits.compactMap { gaugeFromLimit($0, in: json) }
        }
        if gauges.isEmpty { gauges = gaugesFromTopLevel(json) }
        if let extra = gaugeFromExtra(json) { gauges.append(extra) }
        return gauges
    }

    private static func gaugeFromLimit(_ item: [String: Any], in json: [String: Any]) -> UsageGauge? {
        guard let kind = item["kind"] as? String,
            let rounded = (item["percent"] as? NSNumber)?.doubleValue
        else { return nil }
        let percent = finer(rounded, kind: kind, in: json)
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
        let resetsAt = normalizeTS(item["resets_at"])
        return UsageGauge(
            key: kind, label: label,
            fraction: min(1, max(0, percent / 100)),
            resetsAt: resetsAt,
            trustedReset: resetsAt != nil,
            usedUSD: nil, limitUSD: nil)
    }

    /// A row's percent is rounded to a whole number, so a week at 99.5 % reads as used up while it
    /// is still being answered. The same window's top-level `utilization` is the endpoint's own
    /// figure before rounding; it is taken where it agrees with the row to within that rounding.
    private static func finer(_ rounded: Double, kind: String, in json: [String: Any]) -> Double {
        let key: String
        switch kind {
        case "session": key = "five_hour"
        case "weekly_all": key = "seven_day"
        default: return rounded
        }
        guard let utilization = ((json[key] as? [String: Any])?["utilization"] as? NSNumber)?.doubleValue,
            abs(utilization - rounded) <= 1
        else { return rounded }
        return utilization
    }

    private static func gaugesFromTopLevel(_ json: [String: Any]) -> [UsageGauge] {
        [("five_hour", "5-hour session", true), ("seven_day", "Weekly · all models", true)]
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

    /// What plan these bars are a percentage of.
    ///
    /// Never read from `~/.claude/.credentials.json`. That file is written at login and the CLI
    /// rewrites only the tokens in it, so its `rateLimitTier` is whatever the plan was the day the
    /// account signed in — an account that moved from Ultra to Max goes on being told it is
    /// on Ultra forever, with the gauges underneath it already measuring the smaller plan. The
    /// account is the authority on the account, so the multiplier comes from the profile endpoint
    /// or it does not come at all: a plan named without its multiplier is incomplete, and a plan
    /// named with the wrong one is false.
    private static func subtitle(_ creds: ClaudeCredentials, profile: ClaudeProfile?) -> String {
        let plan = profile?.planName ?? planName(creds.subscriptionType)
        guard let tier = profile?.rateLimitTier,
            let multiplier = tier.split(separator: "_").last, multiplier.hasSuffix("x"),
            let count = Int(multiplier.dropLast())
        else { return plan }
        if plan == "Max" { return maxPlanName(multiplier: count) }
        return "\(plan) · \(count)×"
    }

    /// What Anthropic calls a Max account of this multiplier. Since 2026-10-30 the 5× plan is
    /// "Max" and the 20× plan is "Ultra", while the API still reports `claude_max` with a
    /// `default_claude_max_20x` tier for both, and Ultra's weekly allowance is 10× Pro rather
    /// than 20×, so no multiplier is shown beside either name.
    private static func maxPlanName(multiplier: Int) -> String {
        multiplier >= 20 ? "Ultra" : "Max"
    }

    private static func planName(_ subscriptionType: String) -> String {
        switch subscriptionType {
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return subscriptionType.isEmpty ? "Claude" : subscriptionType.capitalized
        }
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
        return BridgeTimestamps.string(date)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        BridgeTimestamps.date(raw)
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

/// Last-good snapshots persist to disk so a bridge restart doesn't blank the
/// gauges while the account is being rate limited, and a failed fetch backs
/// off before retrying upstream — the account-wide limit is shared with
/// every other tool polling the same endpoint.
actor UsageSnapshotCache {
    private struct Stored: Codable {
        var snapshot: UsageSnapshot
        var at: Date
    }

    private let name: String
    private let directory: URL
    private var stored: Stored?
    private var backoffUntil: Date = .distantPast
    private var lastAttemptAt: Date = .distantPast
    private var loaded = false

    init(
        name: String,
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude-bridge")
    ) {
        self.name = name
        self.directory = directory
    }

    var inBackoff: Bool { Date() < backoffUntil }

    func noteFailure(backoff seconds: TimeInterval = 300) {
        backoffUntil = Date().addingTimeInterval(seconds)
    }

    func noteAttempt(at date: Date) {
        lastAttemptAt = date
    }

    func fresh(within seconds: TimeInterval) -> UsageSnapshot? {
        held(within: seconds)?.snapshot
    }

    /// The last good reading and when it was taken, while it is younger than `seconds`.
    func held(within seconds: TimeInterval) -> (snapshot: UsageSnapshot, at: Date)? {
        loadIfNeeded()
        guard let stored, Date().timeIntervalSince(stored.at) < seconds else { return nil }
        return (stored.snapshot, stored.at)
    }

    /// Whether a window in the last good reading has reset since the last attempt to read the
    /// account. That reading is about a window that has ended, so it is worth one read even while
    /// failures are being backed off.
    func owesReadAfterReset(now: Date) -> Bool {
        loadIfNeeded()
        guard let stored else { return false }
        return stored.snapshot.gauges.contains { gauge in
            guard let reset = gauge.resetsAt.flatMap(BridgeTimestamps.date) else { return false }
            return reset <= now && reset > lastAttemptAt
        }
    }

    func store(_ snapshot: UsageSnapshot) {
        stored = Stored(snapshot: snapshot, at: Date())
        backoffUntil = .distantPast
        if let data = try? JSONCoding.encoder.encode(stored) {
            try? data.write(to: fileURL(), options: [.atomic])
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard stored == nil,
            let data = try? Data(contentsOf: fileURL()),
            let disk = try? JSONCoding.decoder.decode(Stored.self, from: data)
        else { return }
        stored = disk
    }

    private func fileURL() -> URL {
        directory.appending(path: "usage-cache-\(name).json")
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
