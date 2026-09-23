import Foundation
import Testing

@testable import claude_bridge

/// A chat is dated by the last thing said in it. The CLI writes its own bookkeeping into the same
/// file whenever a process leaves a session — reaped after half an hour, or stopped by a restart —
/// and a list that read the file's date moved each of those chats up to the moment it was written.
@Suite struct TranscriptDatesTests {
    private let said = Date(timeIntervalSince1970: 1_790_000_000)

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func transcript(_ lines: [String], modified: Date) throws -> (root: URL, id: String, path: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dates-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-home-dates")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let file = project.appendingPathComponent("\(id).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        return (root, id, file.path)
    }

    private func prompt(at date: Date, text: String = "what changed") -> String {
        #"{"type":"user","uuid":"\#(UUID().uuidString)","timestamp":"\#(iso(date))","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func answer(at date: Date) -> String {
        #"{"type":"assistant","uuid":"\#(UUID().uuidString)","timestamp":"\#(iso(date))","message":{"id":"m","role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#
    }

    private func leaving(at date: Date) -> [String] {
        [
            #"{"type":"queue-operation","operation":"dequeue","timestamp":"\#(iso(date))","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"what changed","sessionId":"s"}"#,
            #"{"type":"cost-state","sessionId":"s","totalCostUSD":1.5}"#,
            #"{"type":"frame-link","sessionId":"s","path":"/tmp/a.html","timestamp":"\#(iso(date))"}"#,
            #"{"type":"mode","mode":"normal","sessionId":"s"}"#,
        ]
    }

    private func index(_ root: URL) -> TranscriptIndex {
        TranscriptIndex(
            root: root,
            defaults: MachineDefaults(modelOverride: "sonnet", effortOverride: "high", home: NSTemporaryDirectory()))
    }

    @Test func aProcessLeavingDoesNotMoveItsChat() async throws {
        let reaped = said.addingTimeInterval(30 * 60)
        let fixture = try transcript(
            [prompt(at: said.addingTimeInterval(-5)), answer(at: said)] + leaving(at: reaped), modified: reaped)
        #expect(TranscriptParser.lastContentDate(atPath: fixture.path) == said)
        let dates = await index(fixture.root).transcriptDates()
        #expect(dates[fixture.id] == said)
    }

    @Test func aHugeLastResultIsFoundThroughAWiderWindow() throws {
        let result =
            #"{"type":"user","uuid":"r1","timestamp":"\#(iso(said))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"\#(String(repeating: "y", count: 200 * 1024))"}]}}"#
        let fixture = try transcript(
            [answer(at: said.addingTimeInterval(-10)), result] + leaving(at: said.addingTimeInterval(3600)),
            modified: said.addingTimeInterval(3600))
        #expect(TranscriptParser.lastContentDate(atPath: fixture.path) == said)
    }
}
