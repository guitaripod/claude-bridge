import Foundation
import Testing

@testable import claude_bridge

/// A turn's own account, folded out of the transcript as the messages are built.
///
/// The conversation's ledger already had this arithmetic; what these pin is that a client reading
/// one answer gets the same numbers as a client reading the whole session — the same charge-once
/// rule, the same turn boundary, and a clock that starts where the person pressed return rather
/// than where the model finally spoke.
@Suite("Turn account")
struct TurnAccountTests {
    private func fold(_ lines: [String]) -> [Message] {
        var fold = TranscriptFold()
        _ = fold.consume(Data(lines.joined(separator: "\n").appending("\n").utf8))
        return fold.snapshot
    }

    private func user(_ text: String, at: String) -> String {
        """
        {"type":"user","uuid":"\(UUID().uuidString)","timestamp":"\(at)","message":{"role":"user","content":"\(text)"}}
        """
    }

    private func assistant(
        _ text: String, at: String, id: String, model: String = "claude-opus-5",
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0
    ) -> String {
        """
        {"type":"assistant","uuid":"\(UUID().uuidString)","timestamp":"\(at)","message":{"id":"\(id)","role":"assistant","model":"\(model)","content":[{"type":"text","text":"\(text)"}],"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite)}}}
        """
    }

    @Test("A turn carries what its own calls consumed, and what answered it")
    func turnCarriesItsAccount() {
        let messages = fold([
            user("do the thing", at: "2026-08-16T10:00:00.000Z"),
            assistant(
                "working", at: "2026-08-16T10:00:04.000Z", id: "m1", input: 120, output: 300,
                cacheRead: 40_000, cacheWrite: 2_000),
            assistant(
                "done", at: "2026-08-16T10:00:20.000Z", id: "m2", input: 10, output: 700,
                cacheRead: 42_000),
        ])
        #expect(messages.count == 2)
        let turn = messages[1]
        #expect(turn.role == .assistant)
        #expect(turn.model == "claude-opus-5")
        #expect(turn.usage?.output == 1000)
        #expect(turn.usage?.input == 130)
        #expect(turn.usage?.cacheRead == 82_000)
        #expect(turn.usage?.cacheWrite == 2_000)
        #expect(turn.seconds == 20)
        #expect((turn.costUSD ?? 0) > 0)
    }

    @Test("A call whose usage is repeated on every line it wrote is charged once")
    func chargesEachCallOnce() {
        let messages = fold([
            user("hello", at: "2026-08-16T10:00:00.000Z"),
            assistant("part one", at: "2026-08-16T10:00:02.000Z", id: "m1", output: 500),
            assistant("part two", at: "2026-08-16T10:00:03.000Z", id: "m1", output: 500),
        ])
        #expect(messages[1].usage?.output == 500)
    }

    @Test("The clock starts when the person pressed return")
    func clockStartsAtThePrompt() {
        let messages = fold([
            user("think hard", at: "2026-08-16T10:00:00.000Z"),
            assistant("here", at: "2026-08-16T10:00:30.000Z", id: "m1", output: 10),
        ])
        #expect(messages[1].seconds == 30)
    }

    @Test("Each turn's account is its own")
    func turnsDoNotBleed() {
        let messages = fold([
            user("one", at: "2026-08-16T10:00:00.000Z"),
            assistant("a", at: "2026-08-16T10:00:05.000Z", id: "m1", output: 100),
            user("two", at: "2026-08-16T10:01:00.000Z"),
            assistant("b", at: "2026-08-16T10:01:10.000Z", id: "m2", output: 250),
        ])
        #expect(messages.count == 4)
        #expect(messages[1].usage?.output == 100)
        #expect(messages[1].seconds == 5)
        #expect(messages[3].usage?.output == 250)
        #expect(messages[3].seconds == 10)
    }

    @Test("A turn the CLI recorded no usage for reports none rather than zero")
    func noUsageIsNotZero() {
        let bare = """
            {"type":"assistant","uuid":"u1","timestamp":"2026-08-16T10:00:05.000Z","message":{"id":"m1","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"hi"}]}}
            """
        let messages = fold([user("hello", at: "2026-08-16T10:00:00.000Z"), bare])
        #expect(messages[1].usage == nil)
        #expect(messages[1].costUSD == nil)
        #expect(messages[1].model == "claude-opus-5")
        #expect(messages[1].seconds == 5)
    }
}
