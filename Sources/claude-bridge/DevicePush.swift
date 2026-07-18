import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Shared APNs transport: mints and caches the ES256 provider JWT and posts
/// one payload to one device token, so Live Activity and device pushes never
/// duplicate signing logic.
actor APNSClient {
    struct Config: Sendable {
        var keyPEM: String
        var keyID: String
        var teamID: String
        var topic: String
    }

    let config: Config
    private var jwt: (token: String, at: Date)?

    init(config: Config) {
        self.config = config
    }

    /// The app's bundle topic — the configured Live Activity topic with the
    /// ".push-type.liveactivity" suffix stripped.
    nonisolated var bundleTopic: String {
        let suffix = ".push-type.liveactivity"
        guard config.topic.hasSuffix(suffix) else { return config.topic }
        return String(config.topic.dropLast(suffix.count))
    }

    func send(
        body: Data, token: String, environment: String,
        topic: String, pushType: String, priority: String, collapseID: String? = nil
    ) async -> (status: Int, reason: String?) {
        guard let jwt = signedJWT() else { return (0, "cannot sign APNs JWT") }
        let host = environment == "production"
            ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)") else {
            return (0, "bad device token")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue(pushType, forHTTPHeaderField: "apns-push-type")
        request.setValue(priority, forHTTPHeaderField: "apns-priority")
        if let collapseID {
            request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let reason = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["reason"] as? String
            return (status, reason)
        } catch {
            return (0, "\(error)")
        }
    }

    private func signedJWT() -> String? {
        if let jwt, Date().timeIntervalSince(jwt.at) < 2400 { return jwt.token }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: config.keyPEM) else {
            return nil
        }
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(try! JSONSerialization.data(withJSONObject: [
            "alg": "ES256", "kid": config.keyID,
        ]))
        let claims = b64url(try! JSONSerialization.data(withJSONObject: [
            "iss": config.teamID, "iat": Int(Date().timeIntervalSince1970),
        ]))
        let message = Data("\(header).\(claims)".utf8)
        guard let signature = try? key.signature(for: message) else { return nil }
        let token = "\(header).\(claims).\(b64url(signature.rawRepresentation))"
        jwt = (token, Date())
        return token
    }
}

enum PushFormatting {
    static func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(max(seconds, 1))s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

struct DeviceRegistration: Codable, Sendable {
    var token: String
    var environment: String
    var lastSeenAt: Date
}

struct DeviceRegisterRequest: Codable, Sendable {
    var token: String
    var environment: String
}

struct PushUsage: Codable, Sendable {
    var claude: UsageSnapshot?
    var grok: UsageSnapshot?
}

/// Pushes to every registered device (not per-activity): a turn-end alert for
/// app-driven sessions and a coalesced silent usage refresh when external CLI
/// sessions go idle. Tokens persist to devices.json beside sessions.json and
/// are pruned when APNs reports them dead.
actor DevicePusher {
    private let client: APNSClient?
    private let devicesURL: URL?
    private var devices: [String: DeviceRegistration]
    private var lastSilentPushAt: Date = .distantPast

    private static let silentInterval: TimeInterval = 300
    private static let registrationMaxAge: TimeInterval = 30 * 86400
    private static let pruneReasons: Set<String> = [
        "BadDeviceToken", "DeviceTokenNotForTopic", "TopicDisallowed",
    ]

    init(client: APNSClient?, devicesURL: URL?) {
        self.client = client
        self.devicesURL = devicesURL
        devices = Self.load(from: devicesURL)
    }

    func register(token: String, environment: String) {
        devices[token] = DeviceRegistration(
            token: token, environment: environment, lastSeenAt: Date())
        persist()
        log("device registered (\(environment)) — \(devices.count) known")
    }

    func unregister(token: String) {
        guard devices.removeValue(forKey: token) != nil else {
            log("unregister ignored for unknown device …\(token.suffix(8))")
            return
        }
        persist()
        log("device unregistered …\(token.suffix(8)) — \(devices.count) known")
    }

    func pushTurnEnd(
        sessionID: String, title: String, toolCount: Int, failed: Bool, duration: TimeInterval
    ) async {
        guard let client, !devices.isEmpty else { return }
        var payload: [String: Any] = [
            "aps": [
                "alert": [
                    "title": title.isEmpty ? "Agent" : title,
                    "body": Self.turnEndSummary(toolCount: toolCount, failed: failed, duration: duration),
                ],
                "sound": "default",
                "mutable-content": 1,
                "thread-id": sessionID,
                "interruption-level": "active",
            ],
            "sessionID": sessionID,
        ]
        if let usage = await Self.usageObject() { payload["usage"] = usage }
        await fanOut(
            payload: payload, topic: client.bundleTopic, pushType: "alert", priority: "10",
            collapseID: Self.truncated("done:\(sessionID)", toBytes: 64), label: "alert")
    }

    func noteExternalIdle() async {
        guard let client, !devices.isEmpty else { return }
        guard Date().timeIntervalSince(lastSilentPushAt) >= Self.silentInterval else { return }
        let previous = lastSilentPushAt
        lastSilentPushAt = Date()
        guard let usage = await Self.usageObject() else {
            lastSilentPushAt = previous
            return
        }
        let payload: [String: Any] = [
            "aps": ["content-available": 1],
            "usage": usage,
        ]
        await fanOut(
            payload: payload, topic: client.bundleTopic, pushType: "background", priority: "5",
            collapseID: nil, label: "background")
    }

    private func fanOut(
        payload: [String: Any], topic: String, pushType: String, priority: String,
        collapseID: String?, label: String
    ) async {
        guard let client, let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return }
        let targets = Array(devices.values)
        var sent = 0
        for device in targets {
            let (status, reason) = await client.send(
                body: body, token: device.token, environment: device.environment,
                topic: topic, pushType: pushType, priority: priority, collapseID: collapseID)
            if status == 200 {
                sent += 1
                continue
            }
            log("\(label) push failed \(status) for …\(device.token.suffix(8)): \(reason ?? "no reason")")
            if Self.shouldPrune(status: status, reason: reason) {
                devices[device.token] = nil
                persist()
                log("pruned device …\(device.token.suffix(8)) (\(reason ?? "\(status)"))")
            }
        }
        log("\(label) push sent to \(sent)/\(targets.count) device(s)")
    }

    /// {"claude": snapshot?, "grok": snapshot?} with each key present only if
    /// that snapshot is live with gauges, sourced from the cached snapshot
    /// machinery — nil when neither qualifies.
    private static func usageObject() async -> [String: Any]? {
        async let claudeSnapshot = ClaudeUsage.snapshot()
        async let grokSnapshot = GrokUsage.snapshot()
        let usage = PushUsage(
            claude: qualifying(await claudeSnapshot), grok: qualifying(await grokSnapshot))
        guard usage.claude != nil || usage.grok != nil else { return nil }
        guard let data = try? JSONCoding.encoder.encode(usage),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object
    }

    private static func qualifying(_ snapshot: UsageSnapshot) -> UsageSnapshot? {
        snapshot.live && !snapshot.gauges.isEmpty ? snapshot : nil
    }

    private static func turnEndSummary(
        toolCount: Int, failed: Bool, duration: TimeInterval
    ) -> String {
        if failed { return "Something went wrong" }
        var parts = ["Done in \(PushFormatting.compactDuration(duration))"]
        if toolCount > 0 { parts.append("\(toolCount) tool\(toolCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private static func shouldPrune(status: Int, reason: String?) -> Bool {
        if status == 410 { return true }
        guard status == 400, let reason else { return false }
        return pruneReasons.contains(reason)
    }

    private static func truncated(_ value: String, toBytes limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        return String(decoding: Array(value.utf8.prefix(limit)), as: UTF8.self)
    }

    private static func load(from url: URL?) -> [String: DeviceRegistration] {
        guard let url, let data = try? Data(contentsOf: url),
            let stored = try? JSONCoding.decoder.decode([DeviceRegistration].self, from: data)
        else { return [:] }
        let threshold = Date().addingTimeInterval(-registrationMaxAge)
        let fresh = stored.filter { $0.lastSeenAt > threshold }
        return Dictionary(fresh.map { ($0.token, $0) }, uniquingKeysWith: { _, new in new })
    }

    private func persist() {
        guard let devicesURL else { return }
        let snapshot = devices.values.sorted { $0.token < $1.token }
        guard let data = try? JSONCoding.encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: devicesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: devicesURL, options: .atomic)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[device-push] \(message)\n".utf8))
    }
}
