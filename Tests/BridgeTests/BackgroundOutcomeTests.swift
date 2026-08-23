import Foundation
import Testing

@testable import claude_bridge

/// The harness reports the end of background work in its own line, minutes after the call that
/// started it already answered. That line is rendered down to one sentence for the reader — and for
/// a long time that was all of it that survived, which left every client holding a call that had
/// launched something and no record anywhere that it ever stopped. These pin the seam: the sentence
/// still reads as a sentence, and the ending still reaches the call it belongs to.
@Suite("Background work reporting back")
struct BackgroundOutcomeTests {
    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func launch(id: String = "toolu_01", taskID: String = "w2cxy65y7") -> [String] {
        [
            line([
                "type": "user", "uuid": "u1", "timestamp": "2026-08-15T09:00:00.000Z",
                "message": ["role": "user", "content": "find me the cheapest flights"],
            ]),
            line([
                "type": "assistant", "uuid": "a1", "timestamp": "2026-08-15T09:00:02.000Z",
                "message": [
                    "role": "assistant",
                    "content": [
                        [
                            "type": "tool_use", "id": id, "name": "Workflow",
                            "input": ["name": "flyr"],
                        ]
                    ],
                ],
            ]),
            line([
                "type": "user", "uuid": "u2", "timestamp": "2026-08-15T09:00:02.030Z",
                "message": [
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result", "tool_use_id": id,
                            "content":
                                "Workflow launched in background. Task ID: \(taskID)\nRun ID: wf_6e8",
                        ]
                    ],
                ],
            ]),
        ]
    }

    private func notification(_ body: String, uuid: String = "u3") -> String {
        line([
            "type": "user", "uuid": uuid, "timestamp": "2026-08-15T09:04:12.000Z",
            "message": ["role": "user", "content": body],
        ])
    }

    private func fold(_ lines: [String]) -> [Message] {
        var fold = TranscriptFold()
        _ = fold.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        return fold.snapshot
    }

    private func workflowCall(in messages: [Message]) -> ToolCall? {
        for message in messages {
            for part in message.parts {
                if case .tool(let call) = part, call.name == "Workflow" { return call }
            }
        }
        return nil
    }

    @Test("A run still out has no ending on its call, however long ago it launched")
    func aLaunchAloneIsNotAnEnding() {
        let call = workflowCall(in: fold(launch()))

        #expect(call?.status == .completed)
        #expect(call?.background == nil)
    }

    @Test("The report reaches the call it names, with the answer unwrapped from its JSON")
    func theReportReachesItsCall() {
        let messages = fold(
            launch() + [
                notification(
                    """
                    <task-notification>
                    <task-id>w2cxy65y7</task-id>
                    <tool-use-id>toolu_01</tool-use-id>
                    <status>completed</status>
                    <summary>Dynamic workflow "flyr" completed</summary>
                    <result>"**704 EUR**\\nHEL→SIN via Istanbul"</result>
                    </task-notification>
                    """)
            ])

        let outcome = workflowCall(in: messages)?.background
        #expect(outcome?.status == .completed)
        #expect(outcome?.taskID == "w2cxy65y7")
        #expect(outcome?.result == "**704 EUR**\nHEL→SIN via Istanbul")
        #expect(outcome?.summary == #"Dynamic workflow "flyr" completed"#)
        #expect(outcome?.reportedAt == TranscriptParser.parseTimestamp("2026-08-15T09:04:12.000Z"))
    }

    @Test("And the reader still gets the one sentence, not the markup")
    func theSentenceSurvivesToo() {
        let messages = fold(
            launch() + [
                notification(
                    """
                    <task-notification>
                    <task-id>w2cxy65y7</task-id>
                    <tool-use-id>toolu_01</tool-use-id>
                    <status>completed</status>
                    <summary>Dynamic workflow "flyr" completed</summary>
                    <duration_ms>252000</duration_ms>
                    <result>"…"</result>
                    </task-notification>
                    """)
            ])

        guard case .text(let text)? = messages.last?.parts.first else {
            Issue.record("the notification left no sentence behind")
            return
        }
        #expect(text == #"Dynamic workflow "flyr" completed · 4m 12s"#)
        #expect(!text.contains("<task-id>"))
    }

    @Test("A sweep naming several orphaned tasks and no call still finds the call that launched one")
    func anOrphanSweepBindsByTaskID() {
        let messages = fold(
            launch() + [
                notification(
                    """
                    <task-notification>
                    <task-id>w2cxy65y7</task-id>
                    <task-id>bqsd3fhdl</task-id>
                    <task-id>__orphan_summary__:shell</task-id>
                    <status>stopped</status>
                    <summary>2 background task(s) have no completion record.</summary>
                    </task-notification>
                    """)
            ])

        let outcome = workflowCall(in: messages)?.background
        #expect(outcome?.status == .stopped)
        #expect(outcome?.taskID == "w2cxy65y7")
        #expect(outcome?.result == nil)
    }

    @Test("A report for somebody else's call changes nothing here")
    func anUnrelatedReportIsIgnored() {
        let messages = fold(
            launch() + [
                notification(
                    """
                    <task-notification>
                    <task-id>elsewhere</task-id>
                    <tool-use-id>toolu_99</tool-use-id>
                    <status>completed</status>
                    <summary>Something else finished</summary>
                    </task-notification>
                    """)
            ])

        #expect(workflowCall(in: messages)?.background == nil)
    }

    @Test("A status word nobody knows is an ending that did not claim success")
    func anUnknownStatusIsAFailure() {
        let notification = TranscriptParser.taskNotification(
            "<task-notification><task-id>t</task-id><status>exploded</status>"
                + "<summary>it went badly</summary></task-notification>")

        #expect(notification?.status == .failed)
        #expect(notification?.taskIDs == ["t"])
    }

    @Test("A report that named no status said what happened by whether it returned anything")
    func silenceOnStatusReadsFromTheResult() {
        let answered = TranscriptParser.taskNotification(
            "<task-notification><task-id>t</task-id><result>\"ok\"</result></task-notification>")
        let empty = TranscriptParser.taskNotification(
            "<task-notification><task-id>t</task-id></task-notification>")

        #expect(answered?.status == .completed)
        #expect(answered?.result == "ok")
        #expect(empty?.status == .failed)
    }

    @Test("A result that is not JSON is kept exactly as it came")
    func plainResultsAreVerbatim() {
        let notification = TranscriptParser.taskNotification(
            #"<task-notification><task-id>t</task-id><result>{"a":"b"}</result></task-notification>"#)

        #expect(notification?.result == #"{"a":"b"}"#)
    }

    @Test("The ending travels to a client as a field, not as prose it would have to parse")
    func theOutcomeIsOnTheWire() throws {
        let call = ToolCall(
            id: "toolu_01", name: "Workflow", input: "{}", output: "launched", status: .completed,
            background: BackgroundOutcome(
                taskID: "w2cxy65y7", status: .stopped, summary: "no record", result: nil,
                reportedAt: Date(timeIntervalSince1970: 1_700_000_252)))
        let encoded = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: encoded)

        #expect(decoded.background == call.background)
        #expect(String(data: encoded, encoding: .utf8)?.contains("\"status\":\"stopped\"") == true)
    }
}
