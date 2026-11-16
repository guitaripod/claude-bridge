import Foundation
import Testing

@testable import claude_bridge

private actor StartRecorder: LiveActivityTransport {
    struct Sent: Sendable {
        let body: Data
        let token: String
        let priority: String
    }

    private var sent: [Sent] = []
    private var answers: [String: (Int, String?)] = [:]

    func pushLiveActivity(
        body: Data, token: String, environment: String, priority: String
    ) async -> (status: Int, reason: String?) {
        sent.append(Sent(body: body, token: token, priority: priority))
        return answers[token] ?? (200, nil)
    }

    func answer(_ token: String, _ status: Int, _ reason: String?) { answers[token] = (status, reason) }
    func all() -> [Sent] { sent }
}

private func aps(_ body: Data) -> [String: Any] {
    let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    return object?["aps"] as? [String: Any] ?? [:]
}

@Suite("A turn started anywhere gets a card on every device that follows")
struct LiveActivityStartTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func starter(
        _ device: String, token: String? = nil, follows: Bool = true, limit: Int? = nil,
        muted: [String]? = nil
    ) -> LiveActivityStarter {
        LiveActivityStarter(
            token: token ?? "start-\(device)", deviceID: device, profileID: "profile-1",
            profileName: "studio", follows: follows, cardLimit: limit, muted: muted)
    }

    private func pusher(_ recorder: StartRecorder) -> LiveActivityPusher {
        LiveActivityPusher(transport: recorder, startDelay: 3600)
    }

    @Test("A turn no device sent starts a card that names the conversation, the machine and its profile")
    func startsCard() async throws {
        let recorder = StartRecorder()
        let pusher = pusher(recorder)
        await pusher.registerStarter(starter("phone"))
        await pusher.noteEvent(.status("running"), sessionID: "s", now: start, title: "Fix the queue")
        await pusher.startCards("s", turn: start, now: start.addingTimeInterval(4))
        await pusher.settled()
        let sent = await recorder.all()
        #expect(sent.count == 1)
        let first = try #require(sent.first)
        #expect(first.token == "start-phone")
        #expect(first.priority == "10")
        let body = aps(first.body)
        #expect(body["event"] as? String == "start")
        #expect(body["attributes-type"] as? String == "ChatActivityAttributes")
        let attributes = try #require(body["attributes"] as? [String: Any])
        #expect(attributes["sessionID"] as? String == "s")
        #expect(attributes["sessionTitle"] as? String == "Fix the queue")
        #expect(attributes["serverName"] as? String == "studio")
        #expect(attributes["profileID"] as? String == "profile-1")
        #expect(body["input-push-token"] as? Int == 1)
        let alert = try #require(body["alert"] as? [String: Any])
        #expect(alert["sound"] as? String == LiveActivityPusher.silentSound)
        let state = try #require(body["content-state"] as? [String: Any])
        #expect(state["detail"] as? String == "thinking")
        #expect(state["startedAt"] as? Double == start.timeIntervalSinceReferenceDate)
    }

    @Test("A device that already holds the card, opted out, muted the chat or is at its limit gets none")
    func skips() async throws {
        let recorder = StartRecorder()
        let pusher = pusher(recorder)
        await pusher.registerStarter(starter("sender"))
        await pusher.registerStarter(starter("off", follows: false))
        await pusher.registerStarter(starter("muter", muted: ["s"]))
        await pusher.registerStarter(starter("full", limit: 1))
        await pusher.registerStarter(starter("tablet"))
        await pusher.register(
            LiveActivityRegistration(
                token: "other-card", environment: "production", startedAt: start,
                title: "Other", deviceID: "full"),
            sessionID: "other", turnOpen: true)
        await pusher.noteEvent(.status("running"), sessionID: "s", now: start, title: "t")
        await pusher.register(
            LiveActivityRegistration(
                token: "sender-card", environment: "production", startedAt: start,
                title: "t", deviceID: "sender"),
            sessionID: "s", turnOpen: true)
        await pusher.startCards("s", turn: start, now: start.addingTimeInterval(4))
        await pusher.startCards("s", turn: start, now: start.addingTimeInterval(8))
        await pusher.settled()
        let tokens = await recorder.all().map(\.token)
        #expect(tokens == ["start-tablet"], "only the tablet, and only once a turn")
    }

    @Test("A card two devices follow is pushed to both, each alerted its own way at the ending")
    func bothDevices() async throws {
        let recorder = StartRecorder()
        let pusher = pusher(recorder)
        await pusher.register(
            LiveActivityRegistration(
                token: "phone-card", environment: "production", startedAt: start, title: "t",
                endAlert: "silent", deviceID: "phone"),
            sessionID: "s", turnOpen: true)
        await pusher.register(
            LiveActivityRegistration(
                token: "tablet-card", environment: "production", startedAt: start, title: "t",
                deviceID: "tablet"),
            sessionID: "s", turnOpen: true)
        #expect(await pusher.card("s")?.registrations.count == 2)
        await pusher.endTurn(sessionID: "s", toolCount: 1, ending: .finished, now: start.addingTimeInterval(30))
        await pusher.settled()
        let sent = await recorder.all()
        let phone = try #require(sent.last { $0.token == "phone-card" })
        let tablet = try #require(sent.last { $0.token == "tablet-card" })
        #expect(aps(phone.body)["alert"] != nil)
        #expect(aps(tablet.body)["alert"] == nil)
    }

    @Test("A dead start token forgets the device, and a dead card token drops only that device's card")
    func deadTokens() async throws {
        let recorder = StartRecorder()
        await recorder.answer("start-gone", 410, "Unregistered")
        await recorder.answer("tablet-card", 410, "Unregistered")
        let pusher = pusher(recorder)
        await pusher.registerStarter(starter("gone", token: "start-gone"))
        await pusher.noteEvent(.status("running"), sessionID: "s", now: start, title: "t")
        await pusher.startCards("s", turn: start, now: start.addingTimeInterval(4))
        await pusher.settled()
        #expect(await pusher.starter("gone") == nil)
        await pusher.register(
            LiveActivityRegistration(
                token: "phone-card", environment: "production", startedAt: start, title: "t", deviceID: "phone"),
            sessionID: "s", turnOpen: true)
        await pusher.register(
            LiveActivityRegistration(
                token: "tablet-card", environment: "production", startedAt: start, title: "t", deviceID: "tablet"),
            sessionID: "s", turnOpen: true)
        await pusher.endTurn(sessionID: "s", toolCount: 0, ending: .finished, now: start.addingTimeInterval(9))
        await pusher.settled()
        #expect(await pusher.card("s")?.registrations.map(\.deviceID) == ["phone"])
    }

    @Test("A device's card registered after a start joins the turn the bridge has been telling")
    func joinsTurn() async throws {
        let recorder = StartRecorder()
        let pusher = pusher(recorder)
        await pusher.registerStarter(starter("phone"))
        await pusher.noteEvent(.status("running"), sessionID: "s", now: start, title: "t")
        await pusher.noteEvent(
            .toolUpserted(messageID: "m", ToolCall(id: "x", name: "Bash", input: #"{"command":"swift test"}"#, status: .running)),
            sessionID: "s", now: start.addingTimeInterval(2))
        await pusher.register(
            LiveActivityRegistration(
                token: "phone-card", environment: "production", startedAt: start, title: "t", deviceID: "phone"),
            sessionID: "s", turnOpen: true)
        let card = try #require(await pusher.card("s"))
        #expect(card.detail == "tool")
        #expect(card.toolCount == 1)
        #expect(card.startedAt == start)
        #expect(card.registrations.count == 1)
    }

    @Test("Without a device that follows, a turn opens no card of its own")
    func noStarters() async {
        let pusher = pusher(StartRecorder())
        await pusher.noteEvent(.status("running"), sessionID: "s", now: start, title: "t")
        #expect(await pusher.card("s") == nil)
    }

    @Test("A device's start token survives a restart")
    func startersPersist() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("live-activities.json")
        let first = LiveActivityPusher(transport: StartRecorder(), activitiesURL: file)
        await first.registerStarter(starter("phone"))
        let second = LiveActivityPusher(transport: StartRecorder(), activitiesURL: file)
        #expect(await second.starter("phone")?.profileName == "studio")
        await second.forgetStarter(deviceID: "phone")
        let third = LiveActivityPusher(transport: StartRecorder(), activitiesURL: file)
        #expect(await third.starter("phone") == nil)
    }

    @Test("A card stored with one registration loads as a card with one")
    func legacyCard() throws {
        let stored = """
            {"sessionID":"s","registration":{"token":"abc","environment":"production","startedAt":0,"title":"t"},\
            "title":"t","startedAt":0,"detail":"finished","toolCount":1,"background":0,"failed":false,\
            "stopped":false,"turnOpen":false,"endedAt":10,"lastPushAt":10,"lastEventAt":10}
            """
        let card = try JSONDecoder().decode(LiveActivityCard.self, from: Data(stored.utf8))
        #expect(card.registrations.map(\.token) == ["abc"])
        let again = try JSONDecoder().decode(LiveActivityCard.self, from: JSONEncoder().encode(card))
        #expect(again == card)
    }
}

@Suite("The start waits for the phone that sent the turn")
struct LiveActivityStartDelayTests {
    @Test("A turn's scheduled start goes out by itself once the delay has passed")
    func scheduled() async throws {
        let recorder = StartRecorder()
        let pusher = LiveActivityPusher(transport: recorder, startDelay: 0.05)
        await pusher.registerStarter(
            LiveActivityStarter(token: "start-phone", deviceID: "phone", profileID: "p", profileName: "studio", follows: true))
        await pusher.noteEvent(.status("running"), sessionID: "s", now: Date(), title: "t")
        try await Task.sleep(for: .milliseconds(400))
        await pusher.settled()
        #expect(await recorder.all().map(\.token) == ["start-phone"])
    }
}
