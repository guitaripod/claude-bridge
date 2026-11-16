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

/// Where a device's alerts go: APNs in production, a recorder in tests.
protocol DevicePushTransport: Sendable {
    var bundleTopic: String { get }
    func send(
        body: Data, token: String, environment: String,
        topic: String, pushType: String, priority: String, collapseID: String?
    ) async -> (status: Int, reason: String?)
}

extension APNSClient: DevicePushTransport {}

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
    /// What the device asked to hear about; nil from a device that registered before it could
    /// say, which is read as ``DeviceRules/standard``.
    var rules: DeviceRules?
}

struct DeviceRegisterRequest: Codable, Sendable {
    var token: String
    var environment: String
    var rules: DeviceRules?
    /// The installation, as its Live Activity registrations name it; absent from older apps.
    var deviceID: String?
    /// How this bridge may start the device's Live Activities itself; absent from a device that
    /// cannot, or that predates it.
    var liveActivity: LiveActivityStarter?
}

/// A notice held back because its device's person was at a desk, kept until they leave it.
struct HeldPush: Codable, Sendable, Equatable {
    var token: String
    var sessionID: String
    var kind: String
    var body: Data
    var collapseID: String?
    var heldAt: Date
    /// A notice the device raised itself about a conversation this bridge does not hold: only a
    /// desk having it on screen says it is no longer news.
    var foreign: Bool?
}

/// A notice a device raised itself while its person was at a desk, handed here to go out through
/// APNs once they leave: the shape CodingAgentKit's `DeskHeldNotice` writes.
struct HeldNoticeRequest: Codable, Sendable {
    var token: String
    var identifier: String
    var title: String
    var body: String
    var sessionID: String?
    var threadID: String?
    var category: String?
    var userInfo: String?
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
    private let client: (any DevicePushTransport)?
    private let devicesURL: URL?
    private var devices: [String: DeviceRegistration]
    private var lastSilentPushAt: Date = .distantPast
    private let desks: DeskRegistry?
    /// Held notices by device token, then by conversation: a later notice for the same
    /// conversation replaces an earlier one, as the collapse id would on the phone.
    private var held: [String: [String: HeldPush]]
    private var newsCheck: (@Sendable (String, NoticePush.Kind, Date) async -> Bool)?
    /// Notices taken out to be sent and not yet answered, kept on disk with the held ones so a
    /// restart mid-release loses nothing.
    private var sending: [String: HeldPush] = [:]
    /// The chats each device has an alert standing for, and when it was sent, so a chat read
    /// anywhere takes its alert down on every device that still shows it. Not kept across a
    /// restart: the phone's own check against the read mark is the backstop.
    private var alerted: [String: [String: Date]] = [:]
    private static let alertedPerDevice = 200
    private static let heldMaxAge: TimeInterval = 7 * 86400
    private static let heldPerDevice = 50

    private static let silentInterval: TimeInterval = 300
    private static let registrationMaxAge: TimeInterval = 30 * 86400
    private static let pruneReasons: Set<String> = [
        "BadDeviceToken", "DeviceTokenNotForTopic", "TopicDisallowed",
    ]

    init(client: (any DevicePushTransport)?, devicesURL: URL?, desks: DeskRegistry? = nil) {
        self.client = client
        self.devicesURL = devicesURL
        self.desks = desks
        devices = Self.load(from: devicesURL)
        held = Self.loadHeld(from: devicesURL.map(Self.heldURL))
    }

    static func heldURL(_ devicesURL: URL) -> URL {
        devicesURL.deletingLastPathComponent().appendingPathComponent("held-pushes.json")
    }

    /// How a held notice is judged still worth sending once its person has left a desk: given the
    /// conversation, the kind of notice and when it was held. Without one, every held notice that
    /// no desk had on screen since goes out.
    func setNewsCheck(_ check: @escaping @Sendable (String, NoticePush.Kind, Date) async -> Bool) {
        newsCheck = check
    }

    /// The notices held for a device right now, oldest first — for a test, and for the log.
    func heldPushes(for token: String) -> [HeldPush] {
        (held[token] ?? [:]).values.sorted { $0.heldAt < $1.heldAt }
    }

    /// Whether this device's person is at a desk by its own patience, so a notice for it waits.
    static func isQuiet(
        _ device: DeviceRegistration, desks: DeskRegistry?, now: Date
    ) -> Bool {
        guard let patience = (device.rules ?? .standard).deskPatience, let desks else { return false }
        return desks.mayBeOccupied(awayAfter: patience, now: now)
    }

    /// Whether this bridge holds an APNs client at all, so a registering client can tell a real
    /// push from one that only ever answers `{"ok":true}` because there is nothing behind it.
    var delivers: Bool { client != nil }

    func register(token: String, environment: String, rules: DeviceRules? = nil) {
        devices[token] = DeviceRegistration(
            token: token, environment: environment, lastSeenAt: Date(), rules: rules)
        persist()
        let finish = (rules ?? .standard).finish.rawValue
        log("device registered (\(environment), finished work: \(finish)) — \(devices.count) known")
    }

    /// When a push about a turn is sent: as the turn closes, or once the stretch of work it
    /// belongs to is over.
    enum Occasion: Sendable, Equatable {
        case turnClosed
        case workSettled
    }

    /// The devices a push is for, each by its own rules. A question goes to every device that
    /// hears asks, as the turn closes. Finished work goes to the devices that hear every turn when
    /// the turn closes, and to everyone else once the work settles — never both.
    static func recipients(
        _ devices: [DeviceRegistration], kind: NoticePush.Kind, occasion: Occasion,
        failed: Bool, length: TimeInterval, sessionID: String
    ) -> [DeviceRegistration] {
        devices.filter { device in
            let rules = device.rules ?? .standard
            if kind == .question { return occasion == .turnClosed && rules.hearsAsks }
            guard rules.hearsEveryTurn == (occasion == .turnClosed) else { return false }
            return rules.admits(failed: failed, length: length, sessionID: sessionID)
        }
    }

    func unregister(token: String) {
        alerted[token] = nil
        if held.removeValue(forKey: token) != nil { persistHeld() }
        guard devices.removeValue(forKey: token) != nil else {
            log("unregister ignored for unknown device …\(token.suffix(8))")
            return
        }
        persist()
        log("device unregistered …\(token.suffix(8)) — \(devices.count) known")
    }

    func pushTurnEnd(
        sessionID: String, title: String, toolCount: Int, failed: Bool, duration: TimeInterval,
        goal: GoalStatus? = nil, notice: NoticePush.Additions? = nil, occasion: Occasion
    ) async {
        guard let client, !devices.isEmpty else { return }
        let kind = notice?.kind ?? (failed ? .failed : .done)
        let targets = Self.recipients(
            Array(devices.values), kind: kind, occasion: occasion,
            failed: failed || kind == .failed, length: duration, sessionID: sessionID)
        guard !targets.isEmpty else { return }
        var payload: [String: Any] = [
            "aps": [
                "alert": [
                    "title": title.isEmpty ? "Agent" : title,
                    "body": Self.turnEndSummary(
                        toolCount: toolCount, failed: failed, duration: duration, goal: goal),
                ],
                "sound": "default",
                "mutable-content": 1,
                "thread-id": sessionID,
                "interruption-level": "active",
            ],
            "sessionID": sessionID,
        ]
        if let data = await Self.usageJSON(), let usage = Self.usageObject(data) {
            payload["usage"] = usage
        }
        if let notice { payload = NoticePush.fitted(NoticePush.merged(payload, with: notice)) }
        let collapseID = Self.truncated("done:\(sessionID)", toBytes: 64)
        let now = Date()
        let judged = targets.map { ($0, Self.isQuiet($0, desks: desks, now: now)) }
        let quiet = judged.filter(\.1).map(\.0)
        let loud = judged.filter { !$0.1 }.map(\.0)
        if !quiet.isEmpty, let body = try? JSONSerialization.data(withJSONObject: payload) {
            hold(
                body: body, kind: kind, sessionID: sessionID, collapseID: collapseID, for: quiet,
                now: now)
        }
        guard !loud.isEmpty else { return }
        await fanOut(
            payload: payload, topic: client.bundleTopic, pushType: "alert", priority: "10",
            collapseID: collapseID, label: "alert", to: loud, about: sessionID)
    }

    /// The chats were read, or looked at on a desk: every device still showing an alert about
    /// one of them is told, with one silent push naming them all, so it takes the alert down.
    /// An alert sent after `now` is about news the look did not see, and stays.
    func withdraw(_ sessionIDs: Set<String>, now: Date = Date()) async {
        guard let client, !sessionIDs.isEmpty, !alerted.isEmpty else { return }
        var due: [(DeviceRegistration, [String])] = []
        for (token, sessions) in alerted {
            let read = sessions.filter { sessionIDs.contains($0.key) && $0.value <= now }.map(\.key)
            guard !read.isEmpty else { continue }
            for id in read { alerted[token]?[id] = nil }
            if alerted[token]?.isEmpty == true { alerted[token] = nil }
            guard let device = devices[token] else { continue }
            due.append((device, read.sorted()))
        }
        for (device, read) in due {
            let payload: [String: Any] = ["aps": ["content-available": 1], "withdraw": read]
            await fanOut(
                payload: payload, topic: client.bundleTopic, pushType: "background", priority: "5",
                collapseID: nil, label: "withdraw", to: [device])
        }
    }

    /// The chats each device is still being shown an alert about — for a test.
    func standingAlerts(for token: String) -> Set<String> { Set((alerted[token] ?? [:]).keys) }

    private func hold(
        body: Data, kind: NoticePush.Kind, sessionID: String, collapseID: String,
        for targets: [DeviceRegistration], now: Date
    ) {
        for device in targets {
            keep(
                HeldPush(
                    token: device.token, sessionID: sessionID, kind: kind.rawValue, body: body,
                    collapseID: collapseID, heldAt: now))
        }
        persistHeld()
        let desk = desks?.occupied(awayAfter: .infinity, now: now)?.name ?? "a desk"
        log("\(kind.rawValue) for \(sessionID) held for \(targets.count) device(s) while at \(desk)")
    }

    /// Holds a notice the device raised itself, to go out once its person leaves the desk. Taken
    /// only from a device this bridge pushes to; one that is not at a desk any more hears it at the
    /// next sweep.
    func holdForeign(_ request: HeldNoticeRequest, now: Date = Date()) -> Bool {
        guard client != nil, devices[request.token] != nil,
            let body = Self.foreignBody(request)
        else { return false }
        let key = request.sessionID ?? request.identifier
        keep(
            HeldPush(
                token: request.token, sessionID: key, kind: NoticePush.Kind.done.rawValue,
                body: body, collapseID: Self.truncated(request.identifier, toBytes: 64),
                heldAt: now, foreign: true))
        persistHeld()
        log("a device's own notice \(request.identifier) held until its person leaves the desk")
        return true
    }

    /// Holds one notice, a later one for the same conversation in its place, and no more than
    /// `heldPerDevice` for a device: the oldest goes first.
    private func keep(_ push: HeldPush) {
        var pushes = held[push.token] ?? [:]
        pushes[push.sessionID] = push
        while pushes.count > Self.heldPerDevice,
            let oldest = pushes.values.min(by: { $0.heldAt < $1.heldAt })
        {
            pushes[oldest.sessionID] = nil
            log("held \(oldest.kind) for \(oldest.sessionID) dropped: too many held for one device")
        }
        held[push.token] = pushes
    }

    /// The alert a device's own notice becomes: its words, its thread and category, and the fields
    /// a tap reads, cut back to the ones that route a tap when the whole would not fit in a push.
    static func foreignBody(_ request: HeldNoticeRequest) -> Data? {
        var aps: [String: Any] = [
            "alert": [
                "title": String(request.title.prefix(200)), "body": String(request.body.prefix(1000)),
            ],
            "sound": "default",
            "mutable-content": 1,
            "interruption-level": "active",
        ]
        if let thread = request.threadID ?? request.sessionID { aps["thread-id"] = thread }
        if let category = request.category, !category.isEmpty { aps["category"] = category }
        var payload: [String: Any] = [:]
        if let raw = request.userInfo?.data(using: .utf8),
            let fields = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        {
            payload = fields.filter { $0.key != "aps" }
        }
        if let sessionID = request.sessionID { payload["sessionID"] = sessionID }
        payload["aps"] = aps
        if let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= 4000 {
            return data
        }
        let kept = payload.filter { ["aps", "sessionID", "profileID", "route"].contains($0.key) }
        return try? JSONSerialization.data(withJSONObject: kept)
    }

    /// Sends what was held for every device whose person has left the desk, by that device's own
    /// patience, keeping only what is still news: a conversation no desk had on screen since,
    /// nobody read since, and that is not working again. What is still held for a device that
    /// unregistered, or that stopped asking to be quiet, goes too. Taken out of the store before
    /// anything is awaited, so two sweeps at once can never send one notice twice.
    func releaseHeld(now: Date = Date()) async {
        guard !held.isEmpty || !sending.isEmpty else { return }
        var due: [(DeviceRegistration, HeldPush)] = []
        var changed = false
        for (token, pushes) in held {
            guard let device = devices[token] else {
                held[token] = nil
                changed = true
                continue
            }
            guard !Self.isQuiet(device, desks: desks, now: now) else { continue }
            held[token] = nil
            changed = true
            for push in pushes.values.sorted(by: { $0.heldAt < $1.heldAt }) {
                sending[Self.sendingKey(push)] = push
                due.append((device, push))
            }
        }
        if changed { persistHeld() }
        guard let client else {
            sending = [:]
            persistHeld()
            return
        }
        for (device, push) in due {
            if await isStillNews(push, now: now) {
                await fanOut(
                    body: push.body, topic: client.bundleTopic, pushType: "alert", priority: "10",
                    collapseID: push.collapseID, label: "held alert", to: [device],
                    about: push.sessionID)
            } else {
                log("held \(push.kind) for \(push.sessionID) dropped: already seen or moved on")
            }
            sending[Self.sendingKey(push)] = nil
            persistHeld()
        }
    }

    private static func sendingKey(_ push: HeldPush) -> String { "\(push.token)|\(push.sessionID)" }

    private func isStillNews(_ push: HeldPush, now: Date) async -> Bool {
        if let desks, desks.looked(push.sessionID, since: push.heldAt) { return false }
        guard now.timeIntervalSince(push.heldAt) < Self.heldMaxAge else { return false }
        guard push.foreign != true, let newsCheck else { return true }
        let kind = NoticePush.Kind(rawValue: push.kind) ?? .done
        return await newsCheck(push.sessionID, kind, push.heldAt)
    }

    func noteExternalIdle() async {
        guard let client, !devices.isEmpty else { return }
        guard Date().timeIntervalSince(lastSilentPushAt) >= Self.silentInterval else { return }
        let previous = lastSilentPushAt
        lastSilentPushAt = Date()
        guard let data = await Self.usageJSON(), let usage = Self.usageObject(data) else {
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
        collapseID: String?, label: String, to chosen: [DeviceRegistration]? = nil,
        about sessionID: String? = nil
    ) async {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        await fanOut(
            body: body, topic: topic, pushType: pushType, priority: priority,
            collapseID: collapseID, label: label, to: chosen, about: sessionID)
    }

    private func fanOut(
        body: Data, topic: String, pushType: String, priority: String,
        collapseID: String?, label: String, to chosen: [DeviceRegistration]? = nil,
        about sessionID: String? = nil
    ) async {
        guard let client else { return }
        let targets = chosen ?? Array(devices.values)
        var sent = 0
        for device in targets {
            let (status, reason) = await client.send(
                body: body, token: device.token, environment: device.environment,
                topic: topic, pushType: pushType, priority: priority, collapseID: collapseID)
            if status == 200 {
                sent += 1
                if let sessionID { noteAlerted(device.token, sessionID) }
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

    private func noteAlerted(_ token: String, _ sessionID: String, now: Date = Date()) {
        var sessions = alerted[token] ?? [:]
        sessions[sessionID] = now
        while sessions.count > Self.alertedPerDevice,
            let oldest = sessions.min(by: { $0.value < $1.value })
        {
            sessions[oldest.key] = nil
        }
        alerted[token] = sessions
    }

    /// {"claude": snapshot?, "grok": snapshot?} with each key present only if
    /// that snapshot is live with gauges, sourced from the cached snapshot
    /// machinery — nil when neither qualifies.
    /// The usage payload as JSON rather than as the dictionary APNs takes. `Data` is `Sendable`, so
    /// an actor can carry it out of this nonisolated call; the dictionary is not, and a compiler
    /// before Swift 6.4 refuses to send it across.
    private static func usageJSON() async -> Data? {
        async let claudeSnapshot = ClaudeUsage.snapshot()
        async let grokSnapshot = GrokUsage.snapshot()
        let usage = PushUsage(
            claude: qualifying(await claudeSnapshot), grok: qualifying(await grokSnapshot))
        guard usage.claude != nil || usage.grok != nil else { return nil }
        return try? JSONCoding.encoder.encode(usage)
    }

    private static func usageObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func qualifying(_ snapshot: UsageSnapshot) -> UsageSnapshot? {
        snapshot.live && !snapshot.gauges.isEmpty ? snapshot : nil
    }

    /// A goal is the reason the user walked away from the phone, so it outranks the tool count:
    /// reaching it is the news, and still pursuing it means this turn was not the end.
    private static func turnEndSummary(
        toolCount: Int, failed: Bool, duration: TimeInterval, goal: GoalStatus?
    ) -> String {
        if failed { return "Something went wrong" }
        if let goal {
            if goal.isActive { return "Still working toward: \(goal.condition)" }
            if goal.met { return "Goal reached: \(goal.condition)" }
        }
        var parts = ["Done in \(PushFormatting.compactDuration(duration))"]
        if toolCount > 0 { parts.append("\(toolCount) tool\(toolCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private static func shouldPrune(status: Int, reason: String?) -> Bool {
        if status == 410 { return true }
        guard status == 400, let reason else { return false }
        return pruneReasons.contains(reason)
    }

    static func truncated(_ value: String, toBytes limit: Int) -> String {
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

    private static func loadHeld(from url: URL?) -> [String: [String: HeldPush]] {
        guard let url, let data = try? Data(contentsOf: url),
            let stored = try? JSONCoding.decoder.decode([HeldPush].self, from: data)
        else { return [:] }
        let threshold = Date().addingTimeInterval(-heldMaxAge)
        var held: [String: [String: HeldPush]] = [:]
        for push in stored where push.heldAt > threshold {
            held[push.token, default: [:]][push.sessionID] = push
        }
        return held
    }

    private func persistHeld() {
        guard let devicesURL else { return }
        let url = Self.heldURL(devicesURL)
        let all = (held.values.flatMap(\.values) + sending.values)
            .sorted { ($0.token, $0.sessionID) < ($1.token, $1.sessionID) }
        guard !all.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONCoding.encoder.encode(all) else { return }
        try? data.write(to: url, options: .atomic)
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
