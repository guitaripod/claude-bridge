import Foundation
import Testing

@testable import claude_bridge

/// Every push the pusher handed APNs, in the order it handed them.
private actor Recorder: LiveActivityTransport {
    private var sent: [Sent] = []
    private var answer: (Int, String?) = (200, nil)

    func pushLiveActivity(
        body: Data, token: String, environment: String, priority: String
    ) async -> (status: Int, reason: String?) {
        sent.append(Sent(body: body, priority: priority))
        return answer
    }

    func answer(_ status: Int, _ reason: String?) { answer = (status, reason) }
    func pushes() -> [Sent] { sent }
}

private struct Sent: Sendable {
    let body: Data
    let priority: String

    var aps: [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return object?["aps"] as? [String: Any] ?? [:]
    }
    var event: String? { aps["event"] as? String }
    var state: [String: Any] { aps["content-state"] as? [String: Any] ?? [:] }
    var detail: String? { state["detail"] as? String }
    var phase: String? { state["phase"] as? String }
}

@Suite("A Live Activity outlives its turn")
struct LiveActivityPushTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func registration(token: String = "abc") -> LiveActivityRegistration {
        LiveActivityRegistration(
            token: token, environment: "production", startedAt: start, title: "Fix the queue")
    }

    private func running(_ id: String, _ name: String = "Bash") -> BridgeEvent {
        .toolUpserted(messageID: "m", ToolCall(id: id, name: name, input: "", status: .running))
    }

    @Test("A turn that ends settles its card instead of ending it")
    func endingSettles() async {
        let recorder = Recorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.noteEvent(running("t1"), sessionID: "s", now: start.addingTimeInterval(5))
        await pusher.endTurn(
            sessionID: "s", toolCount: 1, ending: .finished, title: "Queue drains in order",
            now: start.addingTimeInterval(300))
        await pusher.settled()
        let pushes = await recorder.pushes()
        #expect(pushes.count == 2)
        #expect(pushes[0].detail == "tool")
        #expect(pushes[0].state["lastTool"] as? String == "Bash")
        #expect(pushes[0].aps["stale-date"] != nil)
        let settled = pushes[1]
        #expect(settled.event == "update")
        #expect(settled.detail == "finished")
        #expect(settled.phase == "done")
        #expect(settled.priority == "10")
        #expect(settled.state["endedAt"] as? Double == start.addingTimeInterval(300).timeIntervalSinceReferenceDate)
        #expect(settled.state["title"] as? String == "Queue drains in order")
        #expect(settled.state["lastTool"] == nil)
        #expect(settled.state["statusText"] as? String == "Done in 5m 0s · 1 tool")
        #expect(settled.aps["stale-date"] == nil)
        #expect(settled.aps["dismissal-date"] == nil)
        #expect(settled.aps["relevance-score"] as? Int == 10)
        #expect(await pusher.card("s")?.isSettled == true)
    }

    @Test("A settled card leaves the island after an hour and the Lock Screen after four")
    func retirement() async {
        let recorder = Recorder()
        let pusher = LiveActivityPusher(transport: recorder)
        let ended = start.addingTimeInterval(60)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.endTurn(sessionID: "s", toolCount: 0, ending: .finished, now: ended)
        await pusher.tick(now: ended.addingTimeInterval(59 * 60), inFlight: [])
        await pusher.settled()
        #expect(await recorder.pushes().count == 1)
        await pusher.tick(now: ended.addingTimeInterval(60 * 60), inFlight: [])
        await pusher.settled()
        let pushes = await recorder.pushes()
        #expect(pushes.count == 2)
        #expect(pushes[1].event == "end")
        #expect(
            pushes[1].aps["dismissal-date"] as? Int
                == Int(ended.addingTimeInterval(4 * 3600).timeIntervalSince1970))
        #expect(pushes[1].detail == "finished")
        #expect(await pusher.card("s") == nil)
    }

    @Test("The conversation's next turn takes the card back, from the beginning")
    func nextTurnRevives() async {
        let recorder = Recorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.noteEvent(running("t1"), sessionID: "s", now: start.addingTimeInterval(5))
        await pusher.endTurn(
            sessionID: "s", toolCount: 1, ending: .finished, now: start.addingTimeInterval(60))
        let next = start.addingTimeInterval(600)
        await pusher.noteEvent(.status("running"), sessionID: "s", now: next)
        await pusher.settled()
        let revived = await recorder.pushes().last
        #expect(revived?.detail == "thinking")
        #expect(revived?.phase == "thinking")
        #expect(revived?.state["startedAt"] as? Double == next.timeIntervalSinceReferenceDate)
        #expect(revived?.state["endedAt"] == nil)
        #expect(revived?.state["toolCount"] as? Int == 0)
        #expect(revived?.aps["relevance-score"] as? Int == 50)
        #expect(revived?.aps["stale-date"] != nil)
        let card = await pusher.card("s")
        #expect(card?.isSettled == false)
        #expect(card?.turnOpen == true)
    }

    @Test("A running status on a card whose turn is already open is not a new turn")
    func runningMidTurnIsQuiet() async {
        let recorder = Recorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.noteEvent(.status("running"), sessionID: "s", now: start.addingTimeInterval(1))
        await pusher.settled()
        #expect(await recorder.pushes().isEmpty)
        #expect(await pusher.card("s")?.startedAt == start)
    }

    @Test("A card registered after its turn ended is taken over by the next turn")
    func lateRegistration() async {
        let recorder = Recorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: false)
        let next = start.addingTimeInterval(1200)
        await pusher.noteEvent(.status("running"), sessionID: "s", now: next)
        await pusher.settled()
        let pushes = await recorder.pushes()
        #expect(pushes.count == 1)
        #expect(pushes[0].state["startedAt"] as? Double == next.timeIntervalSinceReferenceDate)
    }

    @Test("A call overtaken on the way is refused rather than undoing what came after it")
    func overtakenCalls() async {
        let recorder = Recorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.noteEvent(running("t1"), sessionID: "s", now: start.addingTimeInterval(20))
        await pusher.endTurn(
            sessionID: "s", toolCount: 0, ending: .interrupted, now: start.addingTimeInterval(10))
        #expect(await pusher.card("s")?.isSettled == false)
        await pusher.noteEvent(running("t0"), sessionID: "s", now: start.addingTimeInterval(15))
        #expect(await pusher.card("s")?.toolCount == 1)
        await pusher.endTurn(
            sessionID: "s", toolCount: 1, ending: .finished, now: start.addingTimeInterval(30))
        #expect(await pusher.card("s")?.detail == "finished")
    }

    @Test("A turn that ended on a question is remembered as the question")
    func question() async {
        let recorder = Recorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.noteEvent(
            running("q", "AskUserQuestion"), sessionID: "s", now: start.addingTimeInterval(3))
        await pusher.endTurn(
            sessionID: "s", toolCount: 1, ending: .question, now: start.addingTimeInterval(4))
        await pusher.settled()
        let pushes = await recorder.pushes()
        #expect(pushes[0].detail == "question")
        #expect(pushes[0].phase == "approval")
        #expect(pushes.last?.detail == "question")
        #expect(pushes.last?.aps["relevance-score"] as? Int == 100)
        #expect(pushes.last?.state["statusText"] as? String == "Waiting for your answer")
    }

    @Test("A failure reported mid-turn, and a stop somebody pressed, outrank a plain finish")
    func failuresAndStops() async {
        let recorder = Recorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "a", turnOpen: true)
        await pusher.noteEvent(.error("API Error: 529"), sessionID: "a")
        await pusher.endTurn(sessionID: "a", toolCount: 0, ending: .finished)
        await pusher.register(registration(token: "def"), sessionID: "b", turnOpen: true)
        await pusher.noteStopped(sessionID: "b")
        await pusher.endTurn(sessionID: "b", toolCount: 0, ending: .answerless)
        await pusher.register(registration(token: "ghi"), sessionID: "c", turnOpen: true)
        await pusher.endTurn(sessionID: "c", toolCount: 0, ending: .interrupted)
        #expect(await pusher.card("a")?.detail == "failed")
        #expect(await pusher.card("b")?.detail == "cancelled")
        #expect(await pusher.card("c")?.detail == "interrupted")
        await pusher.settled()
        let phases = await recorder.pushes().compactMap(\.phase)
        #expect(phases == ["error", "done", "error"])
    }

    @Test("A tool is counted once however often it is written")
    func toolsCountOnce() async {
        let pusher = LiveActivityPusher(transport: Recorder())
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.noteEvent(running("t1"), sessionID: "s", now: start)
        await pusher.noteEvent(running("t1"), sessionID: "s", now: start.addingTimeInterval(1))
        await pusher.noteEvent(running("t2", "Read"), sessionID: "s", now: start.addingTimeInterval(2))
        #expect(await pusher.card("s")?.toolCount == 2)
        #expect(await pusher.card("s")?.tool == "Read")
    }

    @Test("Work the machine is still carrying keeps a settled card truthful")
    func backgroundOnASettledCard() async {
        let recorder = Recorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.endTurn(
            sessionID: "s", toolCount: 2, ending: .finished, now: start.addingTimeInterval(30))
        await pusher.noteEvent(
            .background(BackgroundWork(tasks: 2, task: nil, since: nil, stalled: nil)),
            sessionID: "s", now: start.addingTimeInterval(40))
        await pusher.noteEvent(.background(nil), sessionID: "s", now: start.addingTimeInterval(50))
        await pusher.settled()
        let pushes = await recorder.pushes()
        #expect(pushes.count == 3)
        #expect(pushes[1].state["background"] as? Int == 2)
        #expect(pushes[1].priority == "5")
        #expect(pushes[2].state["background"] == nil)
    }

    @Test("A live card is written again before the phone calls it stale, but only while its turn runs")
    func heartbeat() async {
        let recorder = Recorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.noteEvent(running("t1"), sessionID: "s", now: start)
        await pusher.tick(now: start.addingTimeInterval(9 * 60), inFlight: ["s"])
        await pusher.tick(now: start.addingTimeInterval(10 * 60), inFlight: [])
        await pusher.settled()
        #expect(await recorder.pushes().count == 1)
        await pusher.tick(now: start.addingTimeInterval(10 * 60), inFlight: ["s"])
        await pusher.settled()
        let pushes = await recorder.pushes()
        #expect(pushes.count == 2)
        #expect(pushes[1].priority == "5")
        #expect(pushes[1].detail == "tool")
    }

    @Test("A card the phone no longer has is forgotten at APNs' word")
    func deadToken() async {
        let recorder = Recorder()
        await recorder.answer(410, "Unregistered")
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.endTurn(sessionID: "s", toolCount: 0, ending: .finished)
        await pusher.settled()
        #expect(await pusher.card("s") == nil)
    }

    @Test("A restart keeps a settled card's clock and admits a live card's turn is gone")
    func restart() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("live-activities.json")
        let ended = start.addingTimeInterval(120)
        let before = LiveActivityPusher(transport: Recorder(), activitiesURL: file)
        await before.register(registration(), sessionID: "settled", turnOpen: true)
        await before.endTurn(sessionID: "settled", toolCount: 3, ending: .finished, now: ended)
        await before.register(registration(token: "b"), sessionID: "orphan", turnOpen: true)
        await before.register(registration(token: "c"), sessionID: "journaled", turnOpen: true)
        await before.settled()

        let recorder = Recorder()
        let after = LiveActivityPusher(transport: recorder, activitiesURL: file)
        await after.restore(journaled: ["journaled"], now: ended.addingTimeInterval(600))
        await after.settled()
        let pushes = await recorder.pushes()
        #expect(pushes.count == 1)
        #expect(pushes[0].detail == "lost")
        #expect(pushes[0].phase == "done")
        #expect(await after.card("orphan")?.isSettled == true)
        #expect(await after.card("settled")?.endedAt == ended)
        #expect(await after.card("settled")?.toolCount == 3)
        #expect(await after.card("journaled")?.isSettled == false)

        await after.tick(now: ended.addingTimeInterval(3600), inFlight: [])
        await after.settled()
        #expect(await recorder.pushes().last?.event == "end")
        #expect(await after.card("settled") == nil)
    }

    @Test("A file written by the bridge before cards had a shape still loads, as live cards")
    func legacyFile() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("live-activities.json")
        let legacy = """
            [{"sessionID":"s","registration":{"token":"abc","environment":"production",\
            "startedAt":"2027-01-15T08:00:00Z","title":"Old card"}}]
            """
        try Data(legacy.utf8).write(to: file)
        let pusher = LiveActivityPusher(transport: Recorder(), activitiesURL: file)
        let card = await pusher.card("s")
        #expect(card?.title == "Old card")
        #expect(card?.isSettled == false)
        #expect(card?.turnOpen == true)
    }

    @Test("How a turn ended is read off its own messages")
    func endingOfMessages() {
        func answer(_ parts: [Part]) -> Message {
            Message(id: UUID().uuidString, role: .assistant, parts: parts, createdAt: start)
        }
        let asking = ToolCall(id: "q", name: "AskUserQuestion", input: "{}", status: .running)
        var answered = asking
        answered.status = .completed
        #expect(SessionStore.ending(of: [answer([.text("Which one?"), .tool(asking)])]) == .question)
        #expect(SessionStore.ending(of: [answer([.tool(answered), .text("Done.")])]) == .finished)
        #expect(SessionStore.ending(of: [answer([.text("  ")])]) == .answerless)
        #expect(SessionStore.ending(of: [answer([.text("Here it is.")])]) == .finished)
        #expect(SessionStore.ending(of: []) == .finished)
    }
}
