import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct LiveActivityRegistration: Codable, Sendable {
    var token: String
    var environment: String
    var startedAt: Date
    var title: String
}

private struct StoredActivity: Codable, Sendable {
    var sessionID: String
    var registration: LiveActivityRegistration
}

/// Drives the app's Live Activities over APNs while the phone is suspended:
/// the app registers each activity's push token, and turn events push the
/// same content-state shape the app renders locally. ActivityKit decodes the
/// payload with a default JSONDecoder, so dates travel as seconds since the
/// 2001 reference date.
actor LiveActivityPusher {
    private struct Entry {
        var registration: LiveActivityRegistration
        var lastPushAt: Date = .distantPast
        var lastPhase: String = "thinking"
        var toolCount: Int = 0
        var lastTool: String?
    }

    private let client: APNSClient?
    private let activitiesURL: URL?
    private var entries: [String: Entry]

    init(client: APNSClient?, activitiesURL: URL? = nil) {
        self.client = client
        self.activitiesURL = activitiesURL
        entries = Self.load(from: activitiesURL)
    }

    var enabled: Bool { client != nil }

    func register(_ registration: LiveActivityRegistration, sessionID: String) {
        entries[sessionID] = Entry(registration: registration)
        persist()
        log("live-activity token registered for \(sessionID) (\(registration.environment))")
    }

    /// Ends every activity left registered by a previous process. A turn cannot
    /// survive the bridge dying, so anything still on a Lock Screen at startup
    /// is a turn nobody will ever report the end of — the phone would otherwise
    /// hold it until its stale date with no way for this process to reach it,
    /// because the update token only ever lived in the dead process's memory.
    func endOrphans() {
        guard client != nil, !entries.isEmpty else {
            entries = [:]
            persist()
            return
        }
        log("ending \(entries.count) live-activity(s) orphaned by a restart")
        for (sessionID, entry) in entries {
            push(
                sessionID: sessionID, entry: entry, event: "end", phase: "done",
                statusText: "Reconnect to see how it ended", endedAt: Date(), dismissAfter: 0)
        }
        entries = [:]
        persist()
    }

    func noteEvent(_ event: BridgeEvent, sessionID: String) {
        guard client != nil, var entry = entries[sessionID] else { return }
        var phase = entry.lastPhase
        var statusText: String?
        switch event {
        case .toolUpserted(_, let tool):
            if tool.status == .running {
                phase = "tool"
                statusText = "Running \(tool.name)"
                entry.lastTool = tool.name
            }
            entry.toolCount = max(entry.toolCount, countIncrement(entry, tool))
        case .partTextDelta:
            phase = "responding"
            statusText = "Writing…"
        default:
            return
        }
        let phaseChanged = phase != entry.lastPhase
        let due = Date().timeIntervalSince(entry.lastPushAt) > 8
        guard phaseChanged || due else {
            entries[sessionID] = entry
            return
        }
        entry.lastPhase = phase
        entry.lastPushAt = Date()
        entries[sessionID] = entry
        push(
            sessionID: sessionID, entry: entry, event: "update",
            phase: phase, statusText: statusText ?? "Working…", endedAt: nil)
    }

    func endTurn(sessionID: String, toolCount: Int?, failed: Bool) {
        guard client != nil, let entry = entries.removeValue(forKey: sessionID) else { return }
        persist()
        let tools = max(entry.toolCount, toolCount ?? 0)
        let duration = Date().timeIntervalSince(entry.registration.startedAt)
        let summary: String
        if failed {
            summary = "Something went wrong"
        } else {
            var parts = ["Done in \(PushFormatting.compactDuration(duration))"]
            if tools > 0 { parts.append("\(tools) tool\(tools == 1 ? "" : "s")") }
            summary = parts.joined(separator: " · ")
        }
        var finished = entry
        finished.toolCount = tools
        push(
            sessionID: sessionID, entry: finished, event: "end",
            phase: failed ? "error" : "done", statusText: summary, endedAt: Date())
    }

    private func countIncrement(_ entry: Entry, _ tool: ToolCall) -> Int {
        entry.toolCount + (tool.status == .running ? 1 : 0)
    }

    private func push(
        sessionID: String, entry: Entry, event: String,
        phase: String, statusText: String, endedAt: Date?, dismissAfter: TimeInterval = 30
    ) {
        guard let client else { return }
        var contentState: [String: Any] = [
            "phase": phase,
            "statusText": statusText,
            "toolCount": entry.toolCount,
            "startedAt": entry.registration.startedAt.timeIntervalSinceReferenceDate,
            "title": entry.registration.title,
        ]
        if let tool = entry.lastTool { contentState["lastTool"] = tool }
        if let endedAt { contentState["endedAt"] = endedAt.timeIntervalSinceReferenceDate }
        var aps: [String: Any] = [
            "timestamp": Int(Date().timeIntervalSince1970),
            "event": event,
            "content-state": contentState,
        ]
        if event == "end" {
            aps["dismissal-date"] = Int(Date().addingTimeInterval(dismissAfter).timeIntervalSince1970)
        }
        let registration = entry.registration
        guard let body = try? JSONSerialization.data(withJSONObject: ["aps": aps]) else { return }
        Task {
            await self.send(body: body, registration: registration, client: client)
        }
    }

    private func send(
        body: Data, registration: LiveActivityRegistration, client: APNSClient
    ) async {
        let (status, reason) = await client.send(
            body: body, token: registration.token, environment: registration.environment,
            topic: client.config.topic, pushType: "liveactivity", priority: "10")
        if status == 200 {
            log("live-activity push ok")
        } else {
            log("live-activity push failed \(status): \(reason ?? "no reason")")
        }
    }

    private static func load(from url: URL?) -> [String: Entry] {
        guard let url, let data = try? Data(contentsOf: url),
            let stored = try? JSONCoding.decoder.decode([StoredActivity].self, from: data)
        else { return [:] }
        return Dictionary(
            stored.map { ($0.sessionID, Entry(registration: $0.registration)) },
            uniquingKeysWith: { _, new in new })
    }

    private func persist() {
        guard let activitiesURL else { return }
        let snapshot = entries
            .map { StoredActivity(sessionID: $0.key, registration: $0.value.registration) }
            .sorted { $0.sessionID < $1.sessionID }
        guard let data = try? JSONCoding.encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: activitiesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: activitiesURL, options: .atomic)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[live-activity] \(message)\n".utf8))
    }
}
