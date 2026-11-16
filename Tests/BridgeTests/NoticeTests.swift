import Foundation
import Testing

@testable import claude_bridge

/// The harness writes the end of background work as a line of its own and starts a turn on it. For
/// a long time that line reached every client as a prompt, so a conversation's history read as if
/// its person had typed `Background command "…" completed (exit code 0)` between their own
/// questions. These pin what says whose line it is: the sentence stays for a client that knows no
/// better, and beside it rides what the line is.
@Suite("The harness's line is not the reader's")
struct NoticeTests {
    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func asked(_ words: String) -> String {
        line([
            "type": "user", "uuid": "u1", "timestamp": "2026-11-16T09:00:00.000Z",
            "message": ["role": "user", "content": words],
        ])
    }

    private func launched(_ tool: String, id: String, input: [String: Any], banner: String) -> [String] {
        [
            line([
                "type": "assistant", "uuid": "a-\(id)", "timestamp": "2026-11-16T09:00:02.000Z",
                "message": [
                    "role": "assistant",
                    "content": [["type": "tool_use", "id": id, "name": tool, "input": input]],
                ],
            ]),
            line([
                "type": "user", "uuid": "r-\(id)", "timestamp": "2026-11-16T09:00:02.030Z",
                "message": [
                    "role": "user",
                    "content": [["type": "tool_result", "tool_use_id": id, "content": banner]],
                ],
            ]),
        ]
    }

    private func reported(_ body: String, uuid: String = "n1", blocks: Bool = false) -> String {
        let content: Any = blocks ? [["type": "text", "text": body]] : body
        return line([
            "type": "user", "uuid": uuid, "timestamp": "2026-11-16T09:04:12.000Z",
            "message": ["role": "user", "content": content],
        ])
    }

    private func fold(_ lines: [String]) -> [Message] {
        var fold = TranscriptFold()
        _ = fold.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        return fold.snapshot
    }

    private func words(_ message: Message?) -> String? {
        guard let message else { return nil }
        for part in message.parts {
            if case .text(let text) = part { return text }
        }
        return nil
    }

    @Test("What somebody typed carries no notice")
    func aPromptIsAPrompt() {
        let messages = fold([asked("wait for the release and tell me")])

        #expect(messages.first?.role == .user)
        #expect(messages.first?.notice == nil)
    }

    @Test("A command that came back is named by the harness's own quotes, and keeps its sentence")
    func aCommandComesBack() {
        let messages = fold(
            [asked("wait for the release")]
                + launched(
                    "Bash", id: "toolu_b1",
                    input: ["command": "gh run watch 88213", "run_in_background": true],
                    banner: "Command running in background with ID: bg_7")
                + [
                    reported(
                        """
                        <task-notification>
                        <task-id>bg_7</task-id>
                        <tool-use-id>toolu_b1</tool-use-id>
                        <status>completed</status>
                        <summary>Background command "Wait for the 1.33.1 release workflow" completed (exit code 0)</summary>
                        </task-notification>
                        """)
                ])

        let said = messages.last { $0.id == "n1" }
        #expect(said?.role == .user)
        #expect(words(said) == #"Background command "Wait for the 1.33.1 release workflow" completed (exit code 0)"#)
        #expect(
            said?.notice
                == Notice(work: .command, outcome: .completed, title: "Wait for the 1.33.1 release workflow"))
    }

    @Test("An agent that failed says so, and is an agent because of the call that sent it out")
    func anAgentFails() {
        let messages = fold(
            [asked("look into the auth module")]
                + launched(
                    "Task", id: "toolu_t1", input: ["description": "Audit the auth module"],
                    banner: "Async agent launched successfully. agentId: a81")
                + [
                    reported(
                        """
                        <task-notification>
                        <task-id>a81</task-id>
                        <tool-use-id>toolu_t1</tool-use-id>
                        <status>failed</status>
                        <summary>Agent "Audit the auth module" failed</summary>
                        </task-notification>
                        """)
                ])

        #expect(
            messages.last { $0.id == "n1" }?.notice
                == Notice(work: .agent, outcome: .failed, title: "Audit the auth module"))
    }

    @Test("A report with no sentence is named by the call that started the work")
    func theCallNamesIt() {
        let messages = fold(
            [asked("explore")]
                + launched(
                    "Task", id: "toolu_t2", input: ["description": "Map the stores"],
                    banner: "Async agent launched successfully. agentId: a90")
                + [
                    reported(
                        """
                        <task-notification>
                        <task-id>a90</task-id>
                        <tool-use-id>toolu_t2</tool-use-id>
                        <status>completed</status>
                        <usage><tool_uses>14</tool_uses></usage>
                        </task-notification>
                        """)
                ])

        let said = messages.last { $0.id == "n1" }
        #expect(said?.notice == Notice(work: .agent, outcome: .completed, title: "Map the stores"))
        #expect(words(said)?.hasPrefix("Background agent finished") == true)
    }

    @Test("A report naming no call this conversation made is read from its own sentence")
    func aStrangerIsReadFromItsSentence() {
        let messages = fold([
            asked("carry on"),
            reported(
                """
                <task-notification>
                <task-id>bg_old</task-id>
                <status>killed</status>
                <summary>Background command "npm run dev" was stopped</summary>
                </task-notification>
                """, blocks: true),
        ])

        #expect(
            messages.last { $0.id == "n1" }?.notice
                == Notice(work: .command, outcome: .stopped, title: "npm run dev"))
    }

    @Test("A name with quotes of its own is kept whole")
    func quotesInsideTheName() {
        let messages = fold([
            asked("go"),
            reported(
                """
                <task-notification>
                <task-id>bg_q</task-id>
                <status>completed</status>
                <summary>Background command "echo "done"" completed (exit code 0)</summary>
                </task-notification>
                """),
        ])

        #expect(messages.last { $0.id == "n1" }?.notice?.title == #"echo "done""#)
    }

    @Test("A notice rides beside the fields an older client already reads, and is absent otherwise")
    func theWireAddsAndRenamesNothing() throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let plain = Message(id: "m", role: .user, parts: [.text("hi")], createdAt: stamp)
        let noted = Message(
            id: "n", role: .user, parts: [.text("Background command \"x\" completed")],
            createdAt: stamp, notice: Notice(work: .command, outcome: .completed, title: "x"))

        let plainJSON = String(data: try JSONEncoder().encode(plain), encoding: .utf8) ?? ""
        let notedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(noted)) as? [String: Any]

        #expect(!plainJSON.contains("notice"))
        #expect(notedJSON?["role"] as? String == "user")
        #expect(
            notedJSON?["notice"] as? [String: String]
                == ["work": "command", "outcome": "completed", "title": "x"])
    }
}
