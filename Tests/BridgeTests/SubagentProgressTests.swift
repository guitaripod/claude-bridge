import Foundation
import Testing

@testable import claude_bridge

/// A live subagent must say what it is doing — tool count, current tool, todo position — and the
/// accumulator must be incremental: feeding the same bytes in two halves ends in the same state.
@Suite struct SubagentProgressTests {
    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func assistantTool(_ name: String, _ input: [String: Any]) -> String {
        line([
            "type": "assistant", "uuid": UUID().uuidString,
            "timestamp": "2026-08-02T10:00:00.000Z",
            "message": [
                "role": "assistant",
                "content": [["type": "tool_use", "id": "t\(UUID().uuidString)", "name": name, "input": input]],
            ],
        ])
    }

    private var fixture: String {
        [
            line([
                "type": "user", "uuid": "u1", "timestamp": "2026-08-02T09:59:00.000Z",
                "message": ["role": "user", "content": "migrate the settings screen"],
            ]),
            assistantTool(
                "TodoWrite",
                [
                    "todos": [
                        ["content": "read the old screen", "status": "completed"],
                        ["content": "port the toggles", "status": "in_progress"],
                        ["content": "wire persistence", "status": "pending"],
                    ]
                ]),
            assistantTool("Read", ["file_path": "/tmp/app/Settings.swift"]),
            assistantTool("Bash", ["command": "swift build -c release\necho done"]),
        ].joined(separator: "\n") + "\n"
    }

    @Test func accumulatesToolsTodosAndStart() {
        var progress = SubagentProgress()
        TranscriptParser.accumulateProgress(&progress, data: Data(fixture.utf8))
        #expect(progress.toolCount == 2)
        #expect(progress.currentTool == "Bash swift build -c release")
        #expect(progress.todosDone == 1)
        #expect(progress.todosTotal == 3)
        #expect(progress.currentTodo == "port the toggles")
        #expect(progress.startedAt != nil)
    }

    @Test func twoHalvesEndInTheSameStateAsOnePass() {
        let whole = Data(fixture.utf8)
        var one = SubagentProgress()
        TranscriptParser.accumulateProgress(&one, data: whole)

        let lines = fixture.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.prefix(2).joined(separator: "\n") + "\n"
        let tail = lines.dropFirst(2).joined(separator: "\n")
        var two = SubagentProgress()
        TranscriptParser.accumulateProgress(&two, data: Data(head.utf8))
        TranscriptParser.accumulateProgress(&two, data: Data(tail.utf8))

        #expect(one.toolCount == two.toolCount)
        #expect(one.currentTool == two.currentTool)
        #expect(one.todosDone == two.todosDone)
        #expect(one.currentTodo == two.currentTodo)
    }

    /// The full route: a session with one live sidecar and one journal-completed one reports
    /// progress for the live agent only.
    @Test func listingCarriesProgressForLiveAgentsOnly() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("progress-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-tmp-work", isDirectory: true)
        let sessionID = UUID().uuidString
        let sidecars = project.appendingPathComponent(
            "\(sessionID)/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecars, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let prompt = line([
            "type": "user", "uuid": "u", "timestamp": stamp,
            "message": ["role": "user", "content": "port the toggles"],
        ])
        let recent = line([
            "type": "assistant", "uuid": "a", "timestamp": stamp,
            "message": [
                "role": "assistant",
                "content": [["type": "tool_use", "id": "tx", "name": "Read",
                             "input": ["file_path": "/tmp/x.swift"]]],
            ],
        ])
        try (prompt + "\n" + recent + "\n").write(
            to: sidecars.appendingPathComponent("agent-alive1.jsonl"),
            atomically: true, encoding: .utf8)
        try (prompt + "\n").write(
            to: sidecars.appendingPathComponent("agent-done1.jsonl"),
            atomically: true, encoding: .utf8)
        try #"{"type":"result","agentId":"done1"}"#.write(
            to: sidecars.appendingPathComponent("journal.jsonl"),
            atomically: true, encoding: .utf8)
        try (prompt + "\n").write(
            to: project.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true, encoding: .utf8)

        let index = TranscriptIndex(root: root, defaultModel: "sonnet", defaultEffort: "high")
        let agents = await index.subagents(for: sessionID)
        let alive = try #require(agents.first { $0.id == "alive1" })
        let done = try #require(agents.first { $0.id == "done1" })
        #expect(alive.active)
        #expect(alive.toolCount == 1)
        #expect(alive.currentTool == "Read x.swift")
        #expect(done.completed)
        #expect(done.toolCount == nil)
    }
}
