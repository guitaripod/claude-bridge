import Foundation
import Testing

@testable import claude_bridge

private actor BriefRecorder: LiveActivityTransport {
    private var sent: [Data] = []

    func pushLiveActivity(
        body: Data, token: String, environment: String, priority: String
    ) async -> (status: Int, reason: String?) {
        sent.append(body)
        return (200, nil)
    }

    func bodies() -> [Data] { sent }
}

private func aps(_ body: Data) -> [String: Any] {
    let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    return object?["aps"] as? [String: Any] ?? [:]
}

private func brief(_ body: Data) -> [String: Any] {
    (aps(body)["content-state"] as? [String: Any])?["brief"] as? [String: Any] ?? [:]
}

@Suite("A card says what the wall's tile says")
struct LiveActivityBriefTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func registration(endAlert: String? = nil) -> LiveActivityRegistration {
        LiveActivityRegistration(
            token: "abc", environment: "production", startedAt: start, title: "Fix the queue",
            endAlert: endAlert)
    }

    private func tool(
        _ id: String, _ name: String, _ input: [String: Any], _ status: ToolStatus
    ) -> BridgeEvent {
        let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
        return .toolUpserted(
            messageID: "m",
            ToolCall(id: id, name: name, input: String(decoding: data, as: UTF8.self), status: status))
    }

    @Test("A step travels as the tool's name and the fields its plain reading needs")
    func steps() async throws {
        let recorder = BriefRecorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.noteEvent(
            tool("toolu_0123456789abcdef", "Edit", ["file_path": "/src/A.swift", "old_string": "secret\nold", "new_string": "new"], .running),
            sessionID: "s", now: start.addingTimeInterval(1))
        await pusher.noteEvent(
            tool("toolu_0123456789abcdef", "Edit", ["file_path": "/src/A.swift", "old_string": "secret\nold", "new_string": "new"], .completed),
            sessionID: "s", now: start.addingTimeInterval(3))
        await pusher.noteEvent(
            tool("t2", "Bash", ["command": "swift test", "description": "Run tests", "timeout": 100], .running),
            sessionID: "s", now: start.addingTimeInterval(6))
        await pusher.settled()
        let last = try #require(await recorder.bodies().last)
        let sent = brief(last)
        let steps = try #require(sent["steps"] as? [[String: Any]])
        #expect(steps.count == 2)
        #expect(steps[0]["id"] as? String == "456789abcdef")
        #expect(steps[0]["tool"] as? String == "Edit")
        #expect(steps[0]["state"] as? String == "done")
        #expect(steps[0]["input"] as? [String: String] == ["file_path": "/src/A.swift"])
        #expect(steps[1]["input"] as? [String: String] == ["command": "swift test", "description": "Run tests"])
        #expect(steps[1]["state"] as? String == "running")
        #expect(sent["files"] as? Int == 1)
        #expect(sent["added"] as? Int == 1)
        #expect(sent["removed"] as? Int == 2)
        let beat = try #require(sent["beat"] as? String)
        #expect(beat.count == 24)
        #expect(sent["moved"] as? Double == start.addingTimeInterval(6).timeIntervalSinceReferenceDate)
        #expect(
            aps(last)["stale-date"] as? Int
                == Int(start.addingTimeInterval(6 + LiveActivityPusher.quietAfter).timeIntervalSince1970))
    }

    @Test("A to-do list becomes the plan, and a question the ask")
    func planAndAsk() async throws {
        let recorder = BriefRecorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        let todos: [[String: Any]] = [
            ["content": "Read the code", "status": "completed", "activeForm": "Reading the code"],
            ["content": "Fix the timer", "status": "in_progress", "activeForm": "Fixing the timer"],
            ["content": "Run the suite", "status": "pending", "activeForm": "Running the suite"],
        ]
        await pusher.noteEvent(tool("p", "TodoWrite", ["todos": todos], .completed), sessionID: "s", now: start.addingTimeInterval(1))
        await pusher.noteEvent(
            tool("q", "AskUserQuestion", ["questions": [["question": "Which branch?", "options": []]]], .running),
            sessionID: "s", now: start.addingTimeInterval(4))
        await pusher.settled()
        let last = try #require(await recorder.bodies().last)
        let plan = try #require(brief(last)["plan"] as? [String: Any])
        #expect(plan["done"] as? Int == 1)
        #expect(plan["total"] as? Int == 3)
        #expect(plan["current"] as? String == "Fixing the timer")
        #expect(plan["next"] as? String == "Run the suite")
        #expect(brief(last)["ask"] as? String == "Which branch?")
        let state = aps(last)["content-state"] as? [String: Any]
        #expect(state?["detail"] as? String == "question")
        #expect(
            aps(last)["stale-date"] as? Int
                == Int(start.addingTimeInterval(4 + 1800).timeIntervalSince1970),
            "a turn waiting on its question is not quiet")
    }

    @Test("An ending opens the island when the person asked for it, silently or with a sound")
    func endingAlerts() async throws {
        for (choice, sound) in [("silent", LiveActivityPusher.silentSound), ("sound", "default")] {
            let recorder = BriefRecorder()
            let pusher = LiveActivityPusher(transport: recorder)
            await pusher.register(registration(endAlert: choice), sessionID: "s", turnOpen: true)
            await pusher.noteEvent(
                .messageUpserted(
                    Message(
                        id: "a", role: .assistant, parts: [.text("The **queue** drains in order now.")],
                        createdAt: start, model: "claude-opus-4-5")),
                sessionID: "s", now: start.addingTimeInterval(2))
            await pusher.endTurn(sessionID: "s", toolCount: 3, ending: .finished, now: start.addingTimeInterval(90))
            await pusher.settled()
            let settled = try #require(await recorder.bodies().last)
            let alert = try #require(aps(settled)["alert"] as? [String: Any])
            #expect(alert["title"] as? String == "Fix the queue")
            #expect((alert["body"] as? [String: Any])?["loc-key"] as? String == "Done")
            #expect(alert["sound"] as? String == sound)
            #expect(brief(settled)["said"] as? String == "The queue drains in order now.")
            #expect(brief(settled)["model"] as? String == "claude-opus-4-5")
            #expect(brief(settled)["beat"] == nil)
            #expect(aps(settled)["stale-date"] == nil)
        }
    }

    @Test("No alert for a card that should settle quietly, nor for a turn somebody stopped")
    func quietEndings() async throws {
        let recorder = BriefRecorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(), sessionID: "s", turnOpen: true)
        await pusher.endTurn(sessionID: "s", toolCount: 0, ending: .finished, now: start.addingTimeInterval(30))
        let stopping = LiveActivityPusher(transport: recorder)
        await stopping.register(registration(endAlert: "silent"), sessionID: "t", turnOpen: true)
        await stopping.noteStopped(sessionID: "t", now: start.addingTimeInterval(10))
        await stopping.endTurn(sessionID: "t", toolCount: 0, ending: .finished, now: start.addingTimeInterval(11))
        await pusher.settled()
        await stopping.settled()
        for body in await recorder.bodies() { #expect(aps(body)["alert"] == nil) }
    }

    @Test("A brief too big for a push gives up its parts until the push fits")
    func fitsAPush() async throws {
        let recorder = BriefRecorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(registration(endAlert: "silent"), sessionID: "s", turnOpen: true)
        let huge = String(repeating: "x", count: 2_000)
        for index in 0..<6 {
            var input: [String: Any] = [:]
            for key in CardBrief.inputKeys { input[key] = huge }
            await pusher.noteEvent(
                tool("t\(index)", "Bash", input, .completed), sessionID: "s",
                now: start.addingTimeInterval(Double(index) * 10))
        }
        await pusher.endTurn(sessionID: "s", toolCount: 6, ending: .finished, now: start.addingTimeInterval(200))
        await pusher.settled()
        let bodies = await recorder.bodies()
        #expect(!bodies.isEmpty)
        for body in bodies {
            #expect(body.count <= LiveActivityPusher.payloadLimit)
            let sent = try JSONSerialization.data(withJSONObject: brief(body))
            #expect(sent.count <= CardBrief.byteBudget)
        }
    }

    @Test("A registration from an app before the ending choice reads as settling quietly")
    func registrationDecodes() throws {
        let old = try JSONDecoder().decode(
            LiveActivityRegistration.self,
            from: Data(#"{"token":"a","environment":"production","startedAt":0,"title":"t"}"#.utf8))
        #expect(old.endAlert == nil)
        let new = try JSONDecoder().decode(
            LiveActivityRegistration.self,
            from: Data(#"{"token":"a","environment":"production","startedAt":0,"title":"t","endAlert":"silent"}"#.utf8))
        #expect(new.endAlert == "silent")
    }

    @Test("Markdown is taken off the agent's last words")
    func plainWords() {
        #expect(CardBrief.plain("## Done\n- fixed **the** `timer` in [Backoff](x.swift)") == "Done fixed the timer in Backoff")
    }
}

@Suite("A card running at ultracode says so while it runs")
struct LiveActivityUltracodeTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("The rainbow rides a live card and leaves with the turn")
    func ultra() async throws {
        let recorder = BriefRecorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.noteTurn(sessionID: "s", ultracode: true)
        await pusher.register(
            LiveActivityRegistration(token: "a", environment: "production", startedAt: start, title: "t"),
            sessionID: "s", turnOpen: true)
        await pusher.noteEvent(
            .toolUpserted(messageID: "m", ToolCall(id: "x", name: "Bash", input: "{}", status: .running)),
            sessionID: "s", now: start.addingTimeInterval(1))
        await pusher.endTurn(sessionID: "s", toolCount: 1, ending: .finished, now: start.addingTimeInterval(9))
        await pusher.settled()
        let bodies = await recorder.bodies()
        #expect(brief(bodies[0])["ultra"] as? Bool == true)
        #expect(brief(bodies[1])["ultra"] == nil)
    }
}

@Suite("A long path keeps the file's name")
struct LiveActivityPathTests {
    @Test("A path cut to the input limit is cut from its start")
    func pathSuffix() {
        var brief = CardBrief()
        let path = "/" + String(repeating: "deep/", count: 60) + "Backoff.swift"
        brief.absorb(ToolCall(id: "e", name: "Read", input: #"{"file_path":"\#(path)"}"#, status: .completed))
        let kept = brief.steps.first?.input?["file_path"]
        #expect(kept?.hasSuffix("Backoff.swift") == true)
        #expect(kept?.count == CardBrief.inputLimit)
    }

    @Test("A turn that ended on its question keeps the question on the settled card")
    func settledQuestion() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = BriefRecorder()
        let pusher = LiveActivityPusher(transport: recorder)
        await pusher.register(
            LiveActivityRegistration(token: "a", environment: "production", startedAt: start, title: "t"),
            sessionID: "s", turnOpen: true)
        await pusher.noteEvent(
            .toolUpserted(
                messageID: "m",
                ToolCall(id: "q", name: "AskUserQuestion", input: #"{"questions":[{"question":"Which branch?"}]}"#, status: .running)),
            sessionID: "s", now: start.addingTimeInterval(1))
        await pusher.endTurn(sessionID: "s", toolCount: 1, ending: .question, now: start.addingTimeInterval(3))
        await pusher.settled()
        let settled = try #require(await recorder.bodies().last)
        #expect(brief(settled)["ask"] as? String == "Which branch?")
    }
}
