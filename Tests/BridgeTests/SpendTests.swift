import Foundation
import Testing

@testable import claude_bridge

/// What a conversation cost is read from the file the CLI writes anyway, so these pin the two
/// things that reading can get wrong: where one turn ends and the next begins, and which tier each
/// token is billed at.
@Suite struct SpendTests {
    private func write(_ lines: [String]) throws -> String {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spend-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(
            to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private func user(_ text: String, at: String) -> String {
        """
        {"type":"user","uuid":"\(UUID().uuidString)","timestamp":"\(at)","message":{"role":"user","content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    private func toolResult(at: String) -> String {
        """
        {"type":"user","uuid":"\(UUID().uuidString)","timestamp":"\(at)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
        """
    }

    private func assistant(
        model: String, at: String, input: Int = 0, output: Int = 0, cacheRead: Int = 0,
        write5m: Int = 0, write1h: Int = 0
    ) -> String {
        let created = write5m + write1h
        return """
            {"type":"assistant","uuid":"\(UUID().uuidString)","timestamp":"\(at)","message":{"id":"m","role":"assistant","model":"\(model)","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(created),"cache_creation":{"ephemeral_5m_input_tokens":\(write5m),"ephemeral_1h_input_tokens":\(write1h)}}}}
            """
    }

    @Test("A turn is one prompt and every call the agent made answering it")
    func groupsCallsIntoTurns() throws {
        let path = try write([
            user("port the renderer", at: "2026-08-07T10:00:00.000Z"),
            assistant(model: "claude-opus-5", at: "2026-08-07T10:00:04.000Z", output: 100),
            toolResult(at: "2026-08-07T10:00:05.000Z"),
            assistant(model: "claude-opus-5", at: "2026-08-07T10:00:09.000Z", output: 300),
            user("now the tests", at: "2026-08-07T10:05:00.000Z"),
            assistant(model: "claude-opus-5", at: "2026-08-07T10:05:06.000Z", output: 50),
        ])

        let report = try #require(SpendReader.read(transcriptPath: path))
        #expect(report.turns.count == 2)
        #expect(report.turns[0].calls == 2)
        #expect(report.turns[0].tokens.output == 400)
        #expect(report.turns[0].prompt == "port the renderer")
        #expect(report.turns[0].seconds == 9)
        #expect(report.turns[1].calls == 1)
        #expect(report.tokens.output == 450)
    }

    @Test("Every tier is billed at its own multiple of the input rate")
    func pricesEachTokenTier() throws {
        let path = try write([
            user("go", at: "2026-08-07T10:00:00.000Z"),
            assistant(
                model: "claude-opus-5", at: "2026-08-07T10:00:01.000Z",
                input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                write5m: 1_000_000, write1h: 1_000_000),
        ])

        let report = try #require(SpendReader.read(transcriptPath: path))
        #expect(abs(report.costUSD - (5 + 25 + 0.5 + 6.25 + 10)) < 0.0001)
        #expect(report.tokens.cacheWrite == 2_000_000)
        #expect(report.estimated)
    }

    @Test("A model's rate follows its family, and an unknown one is priced as the flagship")
    func ratesFollowTheFamily() {
        #expect(Rate.forModel("claude-haiku-4-5").input == 1)
        #expect(Rate.forModel("claude-sonnet-5").output == 15)
        #expect(Rate.forModel("claude-fable-5").output == 50)
        #expect(Rate.forModel("claude-opus-5").output == 25)
        #expect(Rate.forModel("something-new").output == 25)
    }

    @Test("Cache writes with no tier breakdown fall into the cheaper tier rather than vanishing")
    func untieredCacheWritesStillCount() throws {
        let line = """
            {"type":"assistant","uuid":"u","timestamp":"2026-08-07T10:00:00.000Z","message":{"id":"m","role":"assistant","model":"claude-opus-5","content":[],"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":400000}}}
            """
        let path = try write([line])
        let report = try #require(SpendReader.read(transcriptPath: path))
        #expect(report.tokens.cacheWrite == 400_000)
        #expect(abs(report.costUSD - (0.4 * 5 * 1.25)) < 0.0001)
    }

    @Test("Each model's share is its own, ordered by what it cost")
    func splitsByModel() throws {
        let path = try write([
            user("a", at: "2026-08-07T10:00:00.000Z"),
            assistant(model: "claude-haiku-4-5", at: "2026-08-07T10:00:01.000Z", output: 1_000_000),
            user("b", at: "2026-08-07T10:01:00.000Z"),
            assistant(model: "claude-opus-5", at: "2026-08-07T10:01:01.000Z", output: 1_000_000),
        ])

        let report = try #require(SpendReader.read(transcriptPath: path))
        #expect(report.byModel.count == 2)
        #expect(report.byModel[0].model == "claude-opus-5")
        #expect(report.byModel[0].costUSD > report.byModel[1].costUSD)
        #expect(report.byModel[1].turns == 1)
    }

    @Test("A transcript with nothing priced in it reports nothing rather than zero")
    func emptyTranscriptReportsNothing() throws {
        let path = try write([user("hello", at: "2026-08-07T10:00:00.000Z")])
        #expect(SpendReader.read(transcriptPath: path) == nil)
        #expect(SpendReader.read(transcriptPath: "/nowhere/at/all.jsonl") == nil)
    }
}
