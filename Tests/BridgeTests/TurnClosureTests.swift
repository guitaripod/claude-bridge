import Foundation
import Testing

@testable import claude_bridge

/// Whether a turn is over decides which chats a client draws as live, and it has to be read off
/// the transcript, because nothing else survives a CLI that ran in a terminal. These pin the
/// grammar: the newest line of the conversation decides, the CLI's own bookkeeping decides
/// nothing, and a subagent's turn is not this one's.
@Suite("When a turn is over")
struct TurnClosureTests {
    private func write(_ lines: [String]) throws -> String {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("closure-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(
            to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private func assistant(
        stop: String?, blocks: String = #"[{"type":"text","text":"hi"}]"#,
        model: String = "claude-opus-5", sidechain: Bool = false
    ) -> String {
        let reason = stop.map { "\"stop_reason\":\"\($0)\"," } ?? ""
        return """
            {"type":"assistant","uuid":"\(UUID().uuidString)","isSidechain":\(sidechain),"timestamp":"2026-08-12T10:00:00.000Z","message":{"id":"m","role":"assistant","model":"\(model)",\(reason)"content":\(blocks)}}
            """
    }

    private func user(_ content: String, meta: Bool = false, sidechain: Bool = false) -> String {
        """
        {"type":"user","uuid":"\(UUID().uuidString)","isMeta":\(meta),"isSidechain":\(sidechain),"timestamp":"2026-08-12T10:00:00.000Z","message":{"role":"user","content":"\(content)"}}
        """
    }

    private let toolResult = """
        {"type":"user","uuid":"tr","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
        """
    private let toolUse = #"[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]"#

    @Test("A model that finished speaking has finished its turn")
    func endTurnCloses() throws {
        for reason in ["end_turn", "stop_sequence", "max_tokens", "refusal"] {
            let path = try write([user("go"), assistant(stop: reason)])
            #expect(TranscriptParser.isTurnClosed(atPath: path), "stop_reason \(reason)")
        }
    }

    @Test("A model waiting on a tool has not")
    func toolUseStaysOpen() throws {
        let path = try write([user("go"), assistant(stop: "tool_use", blocks: toolUse)])
        #expect(!TranscriptParser.isTurnClosed(atPath: path))
    }

    @Test("A tool that came back leaves the turn running")
    func toolResultStaysOpen() throws {
        let path = try write([
            user("go"), assistant(stop: "tool_use", blocks: toolUse), toolResult,
        ])
        #expect(!TranscriptParser.isTurnClosed(atPath: path))
    }

    @Test("A line still being written is a turn still running")
    func missingStopReasonStaysOpen() throws {
        let path = try write([user("go"), assistant(stop: nil)])
        #expect(!TranscriptParser.isTurnClosed(atPath: path))
    }

    @Test("A prompt nobody has answered yet is a turn starting")
    func freshPromptIsOpen() throws {
        let path = try write([assistant(stop: "end_turn"), user("and now this")])
        #expect(!TranscriptParser.isTurnClosed(atPath: path))
    }

    @Test("An escape ends the turn it interrupted")
    func interruptionCloses() throws {
        let path = try write([
            user("go"), assistant(stop: "tool_use", blocks: toolUse),
            user("[Request interrupted by user]"),
        ])
        #expect(TranscriptParser.isTurnClosed(atPath: path))
    }

    @Test("The CLI's own bookkeeping decides nothing")
    func bookkeepingIsTransparent() throws {
        let path = try write([
            user("go"), assistant(stop: "end_turn"),
            #"{"type":"last-prompt","uuid":"lp"}"#,
            #"{"type":"attachment","uuid":"a1"}"#,
            #"{"type":"queue-operation","uuid":"q1"}"#,
            #"{"type":"mode","uuid":"m1"}"#,
            #"{"type":"ai-title","uuid":"t1"}"#,
        ])
        #expect(TranscriptParser.isTurnClosed(atPath: path))
    }

    @Test("A command's own output is not somebody typing")
    func localCommandOutputIsNotAPrompt() throws {
        for wrapper in ["<local-command-stdout>done</local-command-stdout>", "<task-notification>x"] {
            let path = try write([user("go"), assistant(stop: "end_turn"), user(wrapper)])
            #expect(TranscriptParser.isTurnClosed(atPath: path), "\(wrapper)")
        }
    }

    @Test("A meta line the CLI injected is not somebody typing")
    func metaIsNotAPrompt() throws {
        let path = try write([
            user("go"), assistant(stop: "end_turn"), user("system reminder", meta: true),
        ])
        #expect(TranscriptParser.isTurnClosed(atPath: path))
    }

    @Test("A subagent's turn is not this conversation's")
    func sidechainIsIgnored() throws {
        let finished = try write([
            user("go"), assistant(stop: "end_turn"),
            assistant(stop: "tool_use", blocks: toolUse, sidechain: true),
            user("sub thinking", sidechain: true),
        ])
        #expect(TranscriptParser.isTurnClosed(atPath: finished))

        let running = try write([
            user("go"), assistant(stop: "tool_use", blocks: toolUse),
            assistant(stop: "end_turn", sidechain: true),
        ])
        #expect(!TranscriptParser.isTurnClosed(atPath: running))
    }

    @Test("A synthetic answer is not the model speaking")
    func syntheticIsIgnored() throws {
        let path = try write([
            user("go"), assistant(stop: "tool_use", blocks: toolUse),
            assistant(stop: "end_turn", model: "<synthetic>"),
        ])
        #expect(!TranscriptParser.isTurnClosed(atPath: path))
    }

    @Test("The marker the CLI does not write is still believed when it appears")
    func turnDurationStillCloses() throws {
        let path = try write([
            user("go"), assistant(stop: nil),
            #"{"type":"system","subtype":"turn_duration","uuid":"s1"}"#,
        ])
        #expect(TranscriptParser.isTurnClosed(atPath: path))
    }

    @Test("A transcript with nothing to go on stays open rather than guessing")
    func emptyTranscriptIsOpen() throws {
        let path = try write([#"{"type":"last-prompt","uuid":"lp"}"#])
        #expect(!TranscriptParser.isTurnClosed(atPath: path))
        #expect(TranscriptParser.isTurnClosed(atPath: "/nowhere/at/all.jsonl") == false)
    }

    @Test("A tail full of one enormous tool result still finds the answer behind it")
    func widensPastAHugeTail() throws {
        let filler = String(repeating: "x", count: 90_000)
        let path = try write([
            user("go"), assistant(stop: "end_turn"),
            """
            {"type":"attachment","uuid":"big","note":"\(filler)"}
            """,
        ])
        #expect(TranscriptParser.isTurnClosed(atPath: path))
    }
}
