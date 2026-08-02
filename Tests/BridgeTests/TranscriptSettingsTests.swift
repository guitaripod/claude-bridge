import Foundation
import Testing

@testable import claude_bridge

/// A conversation can change model or effort halfway through — `/model`, `/effort`, or a client
/// sending its own — and only the transcript records it. These pin the rule that the *last*
/// answer is the authority, so a badge never keeps advertising what a session was started with.
@Suite struct TranscriptSettingsTests {
    private func write(_ lines: [String]) throws -> String {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(
            to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private func assistant(model: String, effort: String?) -> String {
        let effortField = effort.map { ",\"effort\":\"\($0)\"" } ?? ""
        return """
            {"type":"assistant","uuid":"\(UUID().uuidString)","timestamp":"2026-08-02T10:00:00.000Z"\(effortField),"message":{"id":"m","role":"assistant","model":"\(model)","content":[{"type":"text","text":"hi"}]}}
            """
    }

    @Test func readsTheLastAnswerNotTheFirst() throws {
        let path = try write([
            assistant(model: "claude-opus-5", effort: "medium"),
            assistant(model: "claude-fable-5", effort: "high"),
        ])
        let settings = TranscriptParser.lastSettings(atPath: path)
        #expect(settings.model == "claude-fable-5")
        #expect(settings.effort == "high")
    }

    @Test func skipsSyntheticAndNonAssistantLines() throws {
        let path = try write([
            assistant(model: "claude-fable-5", effort: "high"),
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"next"}}"#,
            assistant(model: "<synthetic>", effort: nil),
            #"{"type":"system","subtype":"turn_duration","uuid":"s1"}"#,
        ])
        let settings = TranscriptParser.lastSettings(atPath: path)
        #expect(settings.model == "claude-fable-5")
        #expect(settings.effort == "high")
    }

    @Test func aTranscriptWithNoAnswerYieldsNothing() throws {
        let path = try write([
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"only a prompt"}}"#
        ])
        #expect(TranscriptParser.lastSettings(atPath: path) == TranscriptSettings())
    }

    /// An answer far above a long tail of tool results still has to be found — the first window
    /// holds none, and the widened one must.
    @Test func widensTheWindowPastALongTail() throws {
        let filler = (0..<400).map { index in
            #"{"type":"user","uuid":"t\#(index)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"\#(String(repeating: "y", count: 900))"}]}}"#
        }
        let path = try write([assistant(model: "claude-fable-5", effort: "max")] + filler)
        let settings = TranscriptParser.lastSettings(atPath: path)
        #expect(settings.model == "claude-fable-5")
        #expect(settings.effort == "max")
    }

    @Test func anEffortlessAnswerReportsItsModelAlone() throws {
        let path = try write([assistant(model: "claude-sonnet-5", effort: nil)])
        let settings = TranscriptParser.lastSettings(atPath: path)
        #expect(settings.model == "claude-sonnet-5")
        #expect(settings.effort == nil)
    }
}
