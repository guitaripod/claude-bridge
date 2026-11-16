import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// What a desktop Tailscode says about the person in front of it, the shape CodingAgentKit's
/// `DeskReport` writes. Every field but the desk's own id may be missing from a newer or older
/// client and reads as the quiet default.
struct DeskReportBody: Codable, Sendable, Equatable {
    static let interval: TimeInterval = 30

    var desk: String
    var name: String
    var idle: Int?
    var locked: Bool
    var leaving: Bool
    var looked: [String]
    /// Seconds before the report each look happened; absent from a desk that predates it.
    var lookedAgo: [String: Int]?

    init(
        desk: String, name: String, idle: Int?, locked: Bool = false, leaving: Bool = false,
        looked: [String] = [], lookedAgo: [String: Int]? = nil
    ) {
        self.desk = desk
        self.name = name
        self.idle = idle
        self.locked = locked
        self.leaving = leaving
        self.looked = looked
        self.lookedAgo = lookedAgo
    }

    private enum CodingKeys: String, CodingKey {
        case desk, name, idle, locked, leaving, looked, lookedAgo
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        desk = try values.decode(String.self, forKey: .desk)
        name = (try? values.decodeIfPresent(String.self, forKey: .name)) ?? ""
        idle = try? values.decodeIfPresent(Int.self, forKey: .idle)
        locked = (try? values.decodeIfPresent(Bool.self, forKey: .locked)) ?? false
        leaving = (try? values.decodeIfPresent(Bool.self, forKey: .leaving)) ?? false
        looked = (try? values.decodeIfPresent([String].self, forKey: .looked)) ?? []
        lookedAgo = try? values.decodeIfPresent([String: Int].self, forKey: .lookedAgo)
    }
}

/// One desk as a device reads it: idle as of the answer, and how long ago it was heard.
struct DeskBody: Codable, Sendable, Equatable {
    var desk: String
    var name: String
    var idle: Int?
    var locked: Bool
    var heard: Int
}

/// The answer to `GET /presence` and `GET /presence/wait`, the shape CodingAgentKit's
/// `DeskPresence` reads.
struct DeskPresenceBody: Codable, Sendable, Equatable {
    var desks: [DeskBody]
    var looked: [String: Date]
    var away: Bool?
}

/// The desks reporting to this bridge, and the conversations they had on screen.
///
/// Nothing here is persisted: a desk reports every 30 s, so within `staleAfter` of starting this
/// process has heard from every desk that is there. Until then it cannot tell a desk nobody is at
/// from one that has not spoken yet, and says so (`warming`), so a restart never lets a held
/// notice out at a desk. A desk silent for `staleAfter` is gone (the app quit, the machine slept,
/// the network dropped), and one that says it is leaving is gone at once. Locked so a push, a card
/// and a route can all ask without crossing an actor.
final class DeskRegistry: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        var report: DeskReportBody
        var heardAt: Date
    }

    static let staleAfter: TimeInterval = 90
    /// The patience a device that asked to be quiet but named none gets: Tailscode's own default.
    static let defaultAwayAfter: TimeInterval = 120
    static let lookedKept: TimeInterval = 86_400
    static let deskLimit = 32
    static let lookedPerReport = 64
    static let textLimit = 200
    /// A year of seconds: anything longer is a desk nobody is at, and no sum of it may overflow.
    static let idleLimit = 366 * 86_400

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var looks: [String: Date] = [:]
    private let startedAt: Date

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    /// Whether this process has not yet listened long enough to have heard every desk that is
    /// there.
    func warming(now: Date = Date()) -> Bool {
        now.timeIntervalSince(startedAt) < Self.staleAfter
    }

    /// Whether a device with this patience must still be treated as having its person at a desk:
    /// one is, or this process cannot tell yet.
    func mayBeOccupied(awayAfter: TimeInterval, now: Date = Date()) -> Bool {
        warming(now: now) || occupied(awayAfter: awayAfter, now: now) != nil
    }

    /// Takes a report, trimmed to what a well-behaved desk ever sends. Returns false for one
    /// that names no desk.
    @discardableResult
    func record(_ report: DeskReportBody, now: Date = Date()) -> Bool {
        let id = String(report.desk.prefix(Self.textLimit))
        guard !id.isEmpty else { return false }
        var report = report
        report.desk = id
        report.name = String(report.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.textLimit))
        report.idle = report.idle.map { min(max(0, $0), Self.idleLimit) }
        let looked = report.looked.prefix(Self.lookedPerReport)
            .filter { !$0.isEmpty && $0.count <= Self.textLimit }
        let ago = report.lookedAgo ?? [:]
        report.looked = []
        report.lookedAgo = nil
        lock.withLock {
            let windowStart =
                entries[id]?.heardAt ?? now.addingTimeInterval(-DeskReportBody.interval)
            for sessionID in looked {
                let seen =
                    ago[sessionID].map { now.addingTimeInterval(-TimeInterval(min(max(0, $0), 3600))) }
                    ?? windowStart
                looks[sessionID] = max(looks[sessionID] ?? .distantPast, seen)
            }
            if report.leaving {
                entries[id] = nil
            } else {
                entries[id] = Entry(report: report, heardAt: now)
            }
            prune(now: now)
        }
        return true
    }

    /// Every desk still worth reading, idle as of `now`.
    func presence(now: Date = Date(), away: Bool? = nil) -> DeskPresenceBody {
        lock.withLock {
            prune(now: now)
            let desks = entries.values
                .sorted { $0.report.desk < $1.report.desk }
                .map { entry in
                    let heard = max(0, now.timeIntervalSince(entry.heardAt))
                    return DeskBody(
                        desk: entry.report.desk, name: entry.report.name,
                        idle: entry.report.idle.map { $0 + Int(heard.rounded(.down)) },
                        locked: entry.report.locked, heard: Int(heard.rounded(.down)))
                }
            return DeskPresenceBody(desks: desks, looked: looks, away: away)
        }
    }

    /// The desk the person is at by this patience: heard lately, unlocked, input within
    /// `awayAfter`. The freshest input when several qualify.
    func occupied(awayAfter: TimeInterval, now: Date = Date()) -> DeskBody? {
        presence(now: now).desks
            .filter { desk in
                guard !desk.locked, TimeInterval(desk.heard) < Self.staleAfter, let idle = desk.idle
                else { return false }
                return TimeInterval(idle) < awayAfter
            }
            .min { ($0.idle ?? .max) < ($1.idle ?? .max) }
    }

    /// Whether a desk had this conversation on screen at or after `moment`.
    func looked(_ sessionID: String, since moment: Date) -> Bool {
        lock.withLock { looks[sessionID].map { $0 >= moment } ?? false }
    }

    private func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.heardAt) < Self.staleAfter }
        if entries.count > Self.deskLimit {
            let kept = entries.values.sorted { $0.heardAt > $1.heardAt }.prefix(Self.deskLimit)
            entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.report.desk, $0) })
        }
        looks = looks.filter { now.timeIntervalSince($0.value) < Self.lookedKept }
    }
}

/// `POST /presence` takes a desk's report and lets any notice held for a device whose person has
/// now left go out; `GET /presence` answers what is known; `GET /presence/wait?awayAfter=N` holds
/// until nobody has been at a desk for N seconds, the way `/sessions/:id/wait` holds for a turn:
/// a `\n` at once and every ten seconds, then one answer, `away: true`, or `away: false` once
/// `waitMax` has passed so the caller simply asks again.
func registerDeskRoutes(
    _ router: Router<BridgeRequestContext>, desks: DeskRegistry, devices: DevicePusher,
    hasAuth: Bool, waitMax: TimeInterval
) {
    router.post("presence") { request, _ in
        guard hasAuth else {
            return jsonResponse(
                ["error": "desk reports require an authenticated bridge (BRIDGE_PASSWORD or a tailnet)"],
                status: .forbidden)
        }
        guard let body = try? await decodeBody(DeskReportBody.self, request, limit: 64 * 1024),
            desks.record(body)
        else {
            return jsonResponse(["error": "bad request"], status: .badRequest)
        }
        Task { await devices.releaseHeld() }
        return jsonResponse(["ok": true])
    }

    router.post("push/hold") { request, _ in
        guard hasAuth else {
            return jsonResponse(
                ["error": "holding a notice requires an authenticated bridge (BRIDGE_PASSWORD or a tailnet)"],
                status: .forbidden)
        }
        guard let body = try? await decodeBody(HeldNoticeRequest.self, request, limit: 64 * 1024),
            !body.token.isEmpty, body.token.count <= 200, body.token.allSatisfy(\.isHexDigit),
            !body.identifier.isEmpty, body.identifier.count <= DeskRegistry.textLimit
        else {
            return jsonResponse(["error": "bad request"], status: .badRequest)
        }
        let held = await devices.holdForeign(body)
        if held { Task { await devices.releaseHeld() } }
        return jsonResponse(["ok": true, "held": held])
    }

    router.get("presence") { _, _ in
        jsonResponse(desks.presence())
    }

    router.get("presence/wait") { request, _ in
        let raw = request.uri.queryParameters.get("awayAfter").flatMap { Double($0) }
        let awayAfter = max(1, raw ?? DeskRegistry.defaultAwayAfter)
        let deadline = Date().addingTimeInterval(waitMax)
        let body = ResponseBody { writer in
            func send(_ value: DeskPresenceBody) async throws {
                let data = (try? JSONCoding.encoder.encode(value)) ?? Data("{}".utf8)
                var buffer = ByteBuffer()
                buffer.writeBytes(data)
                try await writer.write(buffer)
                try await writer.finish(nil)
            }
            func heartbeat() async throws {
                var buffer = ByteBuffer()
                buffer.writeString("\n")
                try await writer.write(buffer)
            }
            try await heartbeat()
            var lastHeartbeat = Date()
            while true {
                let now = Date()
                if !desks.mayBeOccupied(awayAfter: awayAfter, now: now) {
                    return try await send(desks.presence(now: now, away: true))
                }
                if now >= deadline {
                    return try await send(desks.presence(now: now, away: false))
                }
                if now.timeIntervalSince(lastHeartbeat) >= 10 {
                    try await heartbeat()
                    lastHeartbeat = now
                }
                try await Task.sleep(for: .seconds(1))
            }
        }
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: body)
    }
}

/// Lets go of held notices whose person has left, on a clock, because leaving is mostly silence:
/// a desk that stops reporting, input that stops coming. Cheap when nothing is held.
func startHeldSweep(devices: DevicePusher, every interval: TimeInterval = 10) {
    Task.detached {
        while true {
            try? await Task.sleep(for: .seconds(interval))
            await devices.releaseHeld()
        }
    }
}
