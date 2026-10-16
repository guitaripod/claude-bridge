import Foundation
import Testing

@testable import claude_bridge

@Suite("A turn-end push carries a structured notice")
struct NoticePushTests {
    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func tool(
        _ name: String, _ input: [String: Any], status: ToolStatus = .completed
    ) -> Part {
        .tool(ToolCall(id: UUID().uuidString, name: name, input: json(input), status: status))
    }

    private func assistant(_ parts: [Part]) -> Message {
        Message(id: UUID().uuidString, role: .assistant, parts: parts, createdAt: Date())
    }

    private func additions(
        _ messages: [Message], settled: CardDetail = .finished, duration: TimeInterval = 42.4,
        tools: Int = 2, prompt: String? = nil, errorText: String? = nil, server: String? = "arch"
    ) -> NoticePush.Additions {
        NoticePush.additions(
            sessionID: "S1", messages: messages, settled: settled, duration: duration,
            toolCount: tools, prompt: prompt, server: server,
            errorText: errorText)
    }

    private func payload(_ additions: NoticePush.Additions, usage: Bool = false) -> [String: Any] {
        let base: [String: Any] = [
            "aps": [
                "alert": ["title": "Fix the queue", "body": "Done in 42s · 2 tools"],
                "sound": "default",
                "mutable-content": 1,
                "thread-id": "S1",
                "interruption-level": "active",
            ],
            "sessionID": "S1",
        ]
        return NoticePush.merged(base, with: additions)
    }

    private func notice(_ payload: [String: Any]) -> [String: Any] {
        payload["notice"] as? [String: Any] ?? [:]
    }

    private func aps(_ payload: [String: Any]) -> [String: Any] {
        payload["aps"] as? [String: Any] ?? [:]
    }

    @Test("A done turn reports its last words, duration, tools and line tally")
    func doneTurn() {
        let messages = [
            assistant([
                .text("Looking."),
                tool("Edit", ["old_string": "a\nb", "new_string": "a\nb\nc"]),
                tool("Write", ["content": "1\n2\n3\n4"]),
                tool("Edit", ["old_string": "x", "new_string": "y"], status: .error),
            ]),
            assistant([.text("  "), .text("All fixed.")]),
        ]
        let result = payload(additions(messages))
        let notice = notice(result)
        #expect(notice["v"] as? Int == 1)
        #expect(notice["kind"] as? String == "done")
        #expect(notice["seconds"] as? Int == 42)
        #expect(notice["tools"] as? Int == 2)
        #expect(notice["added"] as? Int == 7)
        #expect(notice["removed"] as? Int == 2)
        #expect(notice["text"] as? String == "All fixed.")
        #expect(notice["server"] as? String == "arch")
        #expect(notice["agent"] as? String == "claudeCode")
        #expect(notice["prompt"] == nil)
        #expect(notice["options"] == nil)
    }

    @Test("An edit counts old lines removed and new lines added, a write only added")
    func tally() {
        let messages = [
            assistant([
                tool("Edit", ["old_string": "a\nb", "new_string": "a\nb\nc"]),
                tool("Write", ["content": "1\n2\n3\n4"]),
            ])
        ]
        let tally = NoticePush.lineTally(of: messages)
        #expect(tally.added == 7)
        #expect(tally.removed == 2)
        let writeOnly = NoticePush.lineTally(of: [assistant([tool("Write", ["content": "1\n2\n3\n4"])])])
        #expect(writeOnly.added == 4)
        #expect(writeOnly.removed == 0)
    }

    @Test("A failed turn carries the error and the prompt that began it")
    func failedTurn() {
        let result = payload(
            additions([], settled: .failed, prompt: "Please fix it", errorText: "Rate limited"))
        let notice = notice(result)
        #expect(notice["kind"] as? String == "failed")
        #expect(notice["text"] as? String == "Rate limited")
        #expect(notice["prompt"] as? String == "Please fix it")
        #expect(notice["options"] == nil)
        #expect(notice["added"] == nil)
    }

    @Test("A prompt over 400 characters is left out")
    func longPrompt() {
        let result = payload(
            additions([], settled: .failed, prompt: String(repeating: "p", count: 401)))
        #expect(notice(result)["prompt"] == nil)
    }

    @Test("An interrupted turn is failed, with no text")
    func interrupted() {
        let result = payload(additions([], settled: .interrupted, tools: 3))
        #expect(notice(result)["kind"] as? String == "failed")
        #expect(notice(result)["text"] == nil)
        #expect(notice(result)["tools"] as? Int == 3)
    }

    @Test("A question turn offers its options")
    func questionTurn() {
        let ask: [String: Any] = [
            "questions": [
                [
                    "question": "Which database?",
                    "header": "DB",
                    "multiSelect": false,
                    "options": [
                        ["label": "SQLite", "description": "Embedded"],
                        ["label": "Postgres"],
                    ],
                ]
            ]
        ]
        let messages = [assistant([.text("Need a choice."), tool("AskUserQuestion", ask, status: .running)])]
        let ending = SessionStore.ending(of: messages)
        #expect(ending == .question)
        let settled = CardDetail.settled(ending: ending, stopped: false, failed: false)
        let result = payload(additions(messages, settled: settled))
        let notice = notice(result)
        #expect(notice["kind"] as? String == "question")
        #expect(notice["text"] as? String == "Which database?")
        #expect(notice["multiple"] as? Bool == false)
        #expect(notice["free"] as? Bool == true)
        let options = notice["options"] as? [[String: Any]] ?? []
        #expect(options.count == 2)
        #expect(options[0]["label"] as? String == "SQLite")
        #expect(options[0]["detail"] as? String == "Embedded")
        #expect(options[1]["label"] as? String == "Postgres")
        #expect(options[1]["detail"] == nil)
    }

    @Test("Several questions give text but no options")
    func severalQuestions() {
        let ask: [String: Any] = [
            "questions": [
                ["question": "First?", "options": [["label": "A"]]],
                ["question": "Second?", "options": [["label": "B"]]],
            ]
        ]
        let messages = [assistant([tool("AskUserQuestion", ask, status: .running)])]
        let result = payload(additions(messages, settled: .question))
        #expect(notice(result)["text"] as? String == "First?")
        #expect(notice(result)["options"] == nil)
    }

    @Test("The aps keys follow the kind and the English alert is untouched")
    func apsKeys() {
        let done = aps(payload(additions([assistant([.text("ok")])])))
        #expect(done["category"] as? String == "tailscode.turn")
        #expect(done["relevance-score"] as? Double == 0.5)
        #expect(done["target-content-id"] as? String == "S1")
        #expect(done["summary-arg"] == nil)
        #expect(done["interruption-level"] as? String == "active")

        let failed = aps(payload(additions([], settled: .failed)))
        #expect(failed["category"] as? String == "tailscode.turn.failed")
        #expect(failed["relevance-score"] as? Double == 0.7)
        #expect(failed["interruption-level"] as? String == "active")

        let question = aps(payload(additions([], settled: .question)))
        #expect(question["category"] as? String == "tailscode.question")
        #expect(question["relevance-score"] as? Double == 0.9)
        #expect(question["interruption-level"] as? String == "time-sensitive")

        for aps in [done, failed, question] {
            let alert = aps["alert"] as? [String: Any]
            #expect(alert?["title"] as? String == "Fix the queue")
            #expect(alert?["body"] as? String == "Done in 42s · 2 tools")
            #expect(aps["sound"] as? String == "default")
            #expect(aps["mutable-content"] as? Int == 1)
            #expect(aps["thread-id"] as? String == "S1")
        }
        #expect(payload(additions([]))["sessionID"] as? String == "S1")
    }

    @Test("A 6,000-character answer is capped under the APNs budget")
    func sizeCap() {
        let long = String(repeating: "word ", count: 1_200)
        let result = NoticePush.fitted(payload(additions([assistant([.text(long)])])))
        #expect(NoticePush.size(of: result) < 3_800)
        let notice = notice(result)
        #expect(notice["kind"] as? String == "done")
        #expect(notice["seconds"] as? Int == 42)
        #expect((notice["text"] as? String)?.count ?? 0 <= 700)
    }

    @Test("A body over the limit gives up text, then prompt, then option details, in order")
    func shrinkOrder() {
        let long = String(repeating: "é", count: 700)
        let options = (0..<8).map { ["label": "Option \($0)", "detail": String(repeating: "d", count: 150)] }
        var base = payload(additions([], settled: .failed, prompt: String(repeating: "p", count: 400), errorText: long))
        var notice = notice(base)
        notice["options"] = options
        base["notice"] = notice

        let tight = NoticePush.size(of: base) - 900
        let fitted = NoticePush.fitted(base, limit: tight)
        let result = self.notice(fitted)
        #expect(NoticePush.size(of: fitted) <= tight)
        #expect(result["prompt"] != nil)
        #expect(((result["text"] as? String)?.count ?? 0) < 700)
        #expect((result["text"] as? String)?.hasSuffix("…") == true)

        let tighter = NoticePush.fitted(base, limit: 900)
        let shortened = self.notice(tighter)
        #expect(shortened["prompt"] == nil)
        #expect(((shortened["text"] as? String)?.count ?? 0) <= 16)
        let remaining = shortened["options"] as? [[String: Any]]
        #expect(remaining?.allSatisfy { $0["detail"] == nil } ?? true)
        #expect(NoticePush.size(of: tighter) <= 900)

        let bare = self.notice(NoticePush.fitted(base, limit: 1))
        #expect(bare["text"] == nil)
        #expect(bare["options"] == nil)
        #expect(bare["kind"] as? String == "failed")
        #expect(bare["seconds"] as? Int == 42)
    }
}
