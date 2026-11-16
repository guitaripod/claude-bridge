import Foundation
import Testing

@testable import claude_bridge

private actor AlertRecorder: DevicePushTransport {
    nonisolated var bundleTopic: String { "com.example.app" }
    private var sent: [(token: String, body: Data)] = []

    func send(
        body: Data, token: String, environment: String,
        topic: String, pushType: String, priority: String, collapseID: String?
    ) async -> (status: Int, reason: String?) {
        sent.append((token, body))
        return (200, nil)
    }

    func tokens() -> [String] { sent.map(\.token) }
}

private actor LiveRecorder: LiveActivityTransport {
    private var sent: [(token: String, body: Data)] = []

    func pushLiveActivity(
        body: Data, token: String, environment: String, priority: String
    ) async -> (status: Int, reason: String?) {
        sent.append((token, body))
        return (200, nil)
    }

    func all() -> [(token: String, body: Data)] { sent }
}

@Suite("A phone stays quiet while its person is at a desk, and hears what they left unread")
struct DeskTests {
    private let t0 = Date(timeIntervalSince1970: 1_900_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func report(
        _ desk: String = "arch", idle: Int? = 0, locked: Bool = false, leaving: Bool = false,
        looked: [String] = [], ago: [String: Int]? = nil
    ) -> DeskReportBody {
        DeskReportBody(
            desk: desk, name: desk, idle: idle, locked: locked, leaving: leaving, looked: looked,
            lookedAgo: ago)
    }

    @Test("A desk is there while it reports, is unlocked and saw input within the device's patience")
    func occupancy() {
        let desks = DeskRegistry(startedAt: .distantPast)
        desks.record(report(idle: 10), now: at(0))
        #expect(desks.occupied(awayAfter: 120, now: at(0))?.desk == "arch")
        #expect(desks.occupied(awayAfter: 120, now: at(60))?.idle == 70, "idle keeps counting between reports")
        #expect(desks.occupied(awayAfter: 60, now: at(50)) == nil, "the patience ran out")
        #expect(desks.occupied(awayAfter: 600, now: at(89)) != nil)
        #expect(desks.occupied(awayAfter: 600, now: at(90)) == nil, "a silent desk has gone")
        #expect(desks.presence(now: at(90)).desks.isEmpty)

        desks.record(report(idle: 0, locked: true), now: at(100))
        #expect(desks.occupied(awayAfter: 600, now: at(100)) == nil, "a locked screen is someone who left")
        desks.record(report(idle: 0), now: at(110))
        #expect(desks.occupied(awayAfter: 600, now: at(110)) != nil)
        desks.record(report(idle: 0, leaving: true), now: at(111))
        #expect(desks.occupied(awayAfter: 600, now: at(111)) == nil, "a desk going to sleep is gone at once")

        desks.record(report("blind", idle: nil), now: at(120))
        #expect(desks.occupied(awayAfter: 600, now: at(120)) == nil, "a desk that cannot tell is nobody")
        #expect(!desks.record(report("", idle: 0), now: at(120)))
    }

    @Test("A look is dated when it happened, or to the start of its window when the desk cannot say")
    func looks() throws {
        let desks = DeskRegistry(startedAt: .distantPast)
        desks.record(report(looked: ["s1", "", String(repeating: "x", count: 500)]), now: at(5))
        #expect(desks.looked("s1", since: at(-25)), "a first report's window is the beat before it")
        #expect(!desks.looked("s1", since: at(-24)))
        desks.record(report(), now: at(35))
        desks.record(report(looked: ["s2"]), now: at(65))
        #expect(desks.looked("s2", since: at(35)) && !desks.looked("s2", since: at(36)))
        desks.record(report(looked: ["s3"], ago: ["s3": 4]), now: at(95))
        #expect(desks.looked("s3", since: at(91)) && !desks.looked("s3", since: at(92)))
        desks.record(report(idle: Int.max), now: at(100))
        #expect(desks.presence(now: at(130)).desks.first?.idle == DeskRegistry.idleLimit + 30, "a huge idle never overflows")
        #expect(desks.presence(now: at(100)).looked.keys.sorted() == ["s1", "s2", "s3"])
        let body = try JSONCoding.encoder.encode(desks.presence(now: at(100)))
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains(#""heard":0"#))
        let decoded = try JSONCoding.decoder.decode(
            DeskReportBody.self, from: Data(#"{"desk":"d","idle":3,"future":true}"#.utf8))
        #expect(decoded == DeskReportBody(desk: "d", name: "", idle: 3))
    }

    @Test("Rules carry the wish to stay quiet and its patience; an older phone's rules carry neither")
    func rules() throws {
        let quiet = try JSONDecoder().decode(
            DeviceRules.self,
            from: Data(#"{"finish":"settled","quietAtDesk":true,"awayAfter":300}"#.utf8))
        #expect(quiet.deskPatience == 300)
        let defaulted = DeviceRules(finish: .settled, quietAtDesk: true)
        #expect(defaulted.deskPatience == DeskRegistry.defaultAwayAfter)
        #expect(DeviceRules.standard.deskPatience == nil)
        #expect(DeviceRules(finish: .settled, quietAtDesk: false, awayAfter: 60).deskPatience == nil)
    }

    private func pusher(
        _ recorder: AlertRecorder, desks: DeskRegistry, url: URL? = nil
    ) async -> DevicePusher {
        let pusher = DevicePusher(client: recorder, devicesURL: url, desks: desks)
        await pusher.register(
            token: "aa", environment: "production",
            rules: DeviceRules(finish: .settled, quietAtDesk: true, awayAfter: 120))
        await pusher.register(token: "bb", environment: "production", rules: DeviceRules(finish: .settled))
        return pusher
    }

    private func finish(_ pusher: DevicePusher, _ sessionID: String = "s1") async {
        await pusher.pushTurnEnd(
            sessionID: sessionID, title: "Fix the queue", toolCount: 2, failed: false,
            duration: 300, occasion: .workSettled)
    }

    @Test("At a desk the quiet phone's notice is held while every other device hears at once")
    func holds() async {
        let recorder = AlertRecorder()
        let desks = DeskRegistry(startedAt: .distantPast)
        desks.record(report(idle: 5))
        let pusher = await pusher(recorder, desks: desks)
        await finish(pusher)
        #expect(await recorder.tokens() == ["bb"])
        #expect(await pusher.heldPushes(for: "aa").map(\.sessionID) == ["s1"])
        await finish(pusher)
        #expect(await pusher.heldPushes(for: "aa").count == 1, "a later notice replaces the held one")
        await pusher.releaseHeld()
        #expect(await recorder.tokens() == ["bb", "bb"], "nothing goes while the person is still there")
    }

    @Test("Leaving the desk hands over what is still news, and drops what was seen or moved on")
    func releases() async {
        let recorder = AlertRecorder()
        let desks = DeskRegistry(startedAt: .distantPast)
        desks.record(report(idle: 5))
        let pusher = await pusher(recorder, desks: desks)
        await pusher.setNewsCheck { id, _, _ in id != "moved" }
        await finish(pusher, "s1")
        await finish(pusher, "seen")
        await finish(pusher, "moved")
        desks.record(report(idle: 7, looked: ["seen"], ago: ["seen": 0]))
        await pusher.releaseHeld()
        #expect(await recorder.tokens() == ["bb", "bb", "bb"])
        desks.record(report(idle: 0, locked: true))
        await pusher.releaseHeld()
        #expect(await recorder.tokens() == ["bb", "bb", "bb", "aa"], "only the unseen, unmoved notice")
        #expect(await pusher.heldPushes(for: "aa").isEmpty)
        await pusher.releaseHeld()
        #expect(await recorder.tokens().count == 4, "a released notice never goes twice")
    }

    @Test("A quiet phone with no start token still gets an ending that does not open the island at a desk")
    func noStarter() async throws {
        let recorder = LiveRecorder()
        let desks = DeskRegistry(startedAt: .distantPast)
        let pusher = LiveActivityPusher(transport: recorder, startDelay: 3600, desks: desks)
        await pusher.noteDeskRules(
            deviceID: "phone", rules: DeviceRules(finish: .settled, quietAtDesk: true, awayAfter: 120))
        desks.record(report(idle: 1), now: t0)
        await pusher.register(
            LiveActivityRegistration(
                token: "phone-card", environment: "production", startedAt: t0, title: "t",
                endAlert: "sound", deviceID: "phone"),
            sessionID: "s", turnOpen: true)
        await pusher.endTurn(sessionID: "s", toolCount: 1, ending: .finished, now: at(30))
        await pusher.settled()
        let ending = try #require(await recorder.all().last { $0.token == "phone-card" })
        let object = try #require(try JSONSerialization.jsonObject(with: ending.body) as? [String: Any])
        #expect((object["aps"] as? [String: Any])?["alert"] == nil)
        await pusher.noteDeskRules(deviceID: "phone", rules: DeviceRules(finish: .settled, quietAtDesk: false))
        #expect(!(await pusher.quietAtDesk("phone", now: at(31))), "turning it off on the phone reaches the cards")
    }

    @Test("A bridge that just started holds what it holds until every desk has had time to speak")
    func warmUp() async {
        let recorder = AlertRecorder()
        let start = Date()
        let desks = DeskRegistry(startedAt: start)
        #expect(desks.mayBeOccupied(awayAfter: 120, now: start.addingTimeInterval(10)))
        #expect(!desks.mayBeOccupied(awayAfter: 120, now: start.addingTimeInterval(DeskRegistry.staleAfter)))
        let pusher = await pusher(recorder, desks: desks)
        await finish(pusher)
        #expect(await recorder.tokens() == ["bb"], "a quiet phone's notice waits while the bridge cannot tell")
        await pusher.releaseHeld(now: start.addingTimeInterval(30))
        #expect(await recorder.tokens() == ["bb"])
        await pusher.releaseHeld(now: start.addingTimeInterval(DeskRegistry.staleAfter + 1))
        #expect(await recorder.tokens() == ["bb", "aa"], "and goes once nobody has spoken for a whole window")
    }

    @Test("A phone's own notice is held for it, goes once its person leaves, and only a look drops it")
    func foreign() async throws {
        let recorder = AlertRecorder()
        let desks = DeskRegistry(startedAt: .distantPast)
        desks.record(report(idle: 5))
        let pusher = await pusher(recorder, desks: desks)
        await pusher.setNewsCheck { _, _, _ in false }
        let request = HeldNoticeRequest(
            token: "aa", identifier: "done:ses_1", title: "Fix the queue", body: "Done in 2m",
            sessionID: "ses_1", threadID: nil, category: "tailscode.turn",
            userInfo: #"{"sessionID":"ses_1","profileID":"p1","aps":{"x":1}}"#)
        #expect(await pusher.holdForeign(request))
        #expect(!(await pusher.holdForeign(HeldNoticeRequest(
            token: "ff", identifier: "x", title: "", body: "", sessionID: nil, threadID: nil,
            category: nil, userInfo: nil))), "an unknown device's notice is not taken")
        await pusher.releaseHeld()
        #expect(await recorder.tokens().isEmpty)
        desks.record(report(idle: 0, locked: true))
        await pusher.releaseHeld()
        #expect(await recorder.tokens() == ["aa"], "a conversation this bridge does not hold is news until looked at")
        let body = try #require(DevicePusher.foreignBody(HeldNoticeRequest(
            token: "aa", identifier: "i", title: "T", body: "B", sessionID: "s", threadID: nil,
            category: "c", userInfo: #"{"profileID":"p","aps":{"bad":1}}"#)))
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let aps = try #require(object["aps"] as? [String: Any])
        #expect(aps["category"] as? String == "c")
        #expect(aps["thread-id"] as? String == "s")
        #expect(aps["bad"] == nil)
        #expect(object["profileID"] as? String == "p")
    }

    @Test("Held notices survive a restart, and an unregistered phone's are dropped")
    func persistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("devices.json")
        let recorder = AlertRecorder()
        let desks = DeskRegistry(startedAt: .distantPast)
        desks.record(report(idle: 5))
        let first = await pusher(recorder, desks: desks, url: url)
        await finish(first)
        let second = DevicePusher(client: recorder, devicesURL: url, desks: desks)
        #expect(await second.heldPushes(for: "aa").count == 1)
        await second.unregister(token: "aa")
        #expect(await second.heldPushes(for: "aa").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: DevicePusher.heldURL(url).path))
    }

    @Test("A quiet phone gets no new card and an ending that does not open the island while at a desk")
    func liveActivities() async throws {
        let recorder = LiveRecorder()
        let desks = DeskRegistry(startedAt: .distantPast)
        let pusher = LiveActivityPusher(transport: recorder, startDelay: 3600, desks: desks)
        var quiet = LiveActivityStarter(
            token: "start-phone", deviceID: "phone", profileID: "p", profileName: "studio",
            follows: true)
        quiet.adopt(DeviceRules(finish: .settled, quietAtDesk: true, awayAfter: 120))
        await pusher.registerStarter(quiet)
        await pusher.registerStarter(
            LiveActivityStarter(
                token: "start-tablet", deviceID: "tablet", profileID: "p", profileName: "studio",
                follows: true))
        desks.record(report(idle: 1), now: t0)
        #expect(await pusher.quietAtDesk("phone", now: t0))
        #expect(!(await pusher.quietAtDesk("tablet", now: t0)))
        await pusher.noteEvent(.status("running"), sessionID: "s", now: t0, title: "t")
        await pusher.startCards("s", turn: t0, now: at(4))
        await pusher.settled()
        #expect(await recorder.all().map(\.token) == ["start-tablet"])

        await pusher.register(
            LiveActivityRegistration(
                token: "phone-card", environment: "production", startedAt: t0, title: "t",
                endAlert: "sound", deviceID: "phone"),
            sessionID: "s", turnOpen: true)
        await pusher.endTurn(sessionID: "s", toolCount: 1, ending: .finished, now: at(30))
        await pusher.settled()
        let ending = try #require(await recorder.all().last { $0.token == "phone-card" })
        let object = try #require(try JSONSerialization.jsonObject(with: ending.body) as? [String: Any])
        let aps = try #require(object["aps"] as? [String: Any])
        #expect(aps["alert"] == nil, "the card settles in place while the person is at the desk")
    }
}
