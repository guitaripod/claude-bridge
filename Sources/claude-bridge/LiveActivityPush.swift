import Crypto
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

/// Drives the app's Live Activities over APNs while the phone is suspended:
/// the app registers each activity's push token, and turn events push the
/// same content-state shape the app renders locally. ActivityKit decodes the
/// payload with a default JSONDecoder, so dates travel as seconds since the
/// 2001 reference date.
actor LiveActivityPusher {
    struct Config {
        var keyPEM: String
        var keyID: String
        var teamID: String
        var topic: String
    }

    private struct Entry {
        var registration: LiveActivityRegistration
        var lastPushAt: Date = .distantPast
        var lastPhase: String = "thinking"
        var toolCount: Int = 0
        var lastTool: String?
    }

    private let config: Config?
    private var entries: [String: Entry] = [:]
    private var jwt: (token: String, at: Date)?

    init(config: Config?) {
        self.config = config
    }

    var enabled: Bool { config != nil }

    func register(_ registration: LiveActivityRegistration, sessionID: String) {
        entries[sessionID] = Entry(registration: registration)
        log("live-activity token registered for \(sessionID) (\(registration.environment))")
    }

    func noteEvent(_ event: BridgeEvent, sessionID: String) {
        guard config != nil, var entry = entries[sessionID] else { return }
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
        guard config != nil, let entry = entries.removeValue(forKey: sessionID) else { return }
        let tools = max(entry.toolCount, toolCount ?? 0)
        let duration = Date().timeIntervalSince(entry.registration.startedAt)
        let summary: String
        if failed {
            summary = "Something went wrong"
        } else {
            var parts = ["Done in \(Self.compactDuration(duration))"]
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
        phase: String, statusText: String, endedAt: Date?
    ) {
        guard let config else { return }
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
            aps["dismissal-date"] = Int(Date().addingTimeInterval(30).timeIntervalSince1970)
        }
        let registration = entry.registration
        Task {
            await self.send(payload: ["aps": aps], registration: registration, config: config)
        }
    }

    private func send(
        payload: [String: Any], registration: LiveActivityRegistration, config: Config
    ) async {
        guard let token = signedJWT(config) else {
            log("live-activity push skipped — cannot sign APNs JWT")
            return
        }
        let host = registration.environment == "production"
            ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(registration.token)"),
            let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(config.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                log("live-activity push ok (\(payload.description.count) bytes)")
            } else {
                log("live-activity push failed \(status): \(String(data: data, encoding: .utf8) ?? "")")
            }
        } catch {
            log("live-activity push error: \(error)")
        }
    }

    private func signedJWT(_ config: Config) -> String? {
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

    private static func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(max(seconds, 1))s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[live-activity] \(message)\n".utf8))
    }
}
