import Foundation
import Testing

@testable import claude_bridge

/// A run launched into the background is the one kind of work whose parent turn closes at second
/// one: the launch answers in milliseconds, the model stops speaking, and the session then goes
/// quiet for as long as its agents think. Neither mtime fact liveness was built on can see that,
/// so the run's own ledger has to — and it has to stop saying so when the run ends, or a machine
/// would hold a LIVE NOW seat forever on a harness that died.
@Suite struct WorkflowLivenessTests {
    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// A parent that launched a run and then finished speaking — `stop_reason` is `end_turn`, so
    /// the turn is genuinely closed, which is the whole trap.
    private var closedParent: String {
        [
            line([
                "type": "user", "uuid": "u1", "timestamp": "2026-08-15T09:00:00.000Z",
                "cwd": "/tmp/project",
                "message": ["role": "user", "content": "audit the whole thing"],
            ]),
            line([
                "type": "assistant", "uuid": "a1", "timestamp": "2026-08-15T09:00:02.000Z",
                "message": [
                    "role": "assistant", "stop_reason": "end_turn",
                    "content": [["type": "text", "text": "Workflow launched in background."]],
                ],
            ]),
        ].joined(separator: "\n") + "\n"
    }

    private struct World {
        let root: URL
        let transcript: String
        let runDir: URL
        let sessionID: String
    }

    private func makeWorld(
        started: Int, results: Int, agentAge: TimeInterval, marker: Bool
    ) throws -> World {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wf-liveness-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-tmp-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let transcript = project.appendingPathComponent("\(sessionID).jsonl")
        try closedParent.write(to: transcript, atomically: true, encoding: .utf8)

        let runID = "wf_test"
        let runDir = project.appendingPathComponent(sessionID)
            .appendingPathComponent("subagents/workflows/\(runID)")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        var journal: [String] = []
        for index in 0..<started {
            journal.append(line(["type": "started", "agentId": "a\(index)"]))
        }
        for index in 0..<results {
            journal.append(line(["type": "result", "agentId": "a\(index)"]))
        }
        let journalURL = runDir.appendingPathComponent("journal.jsonl")
        try (journal.joined(separator: "\n") + "\n").write(
            to: journalURL, atomically: true, encoding: .utf8)

        let stamp = Date().addingTimeInterval(-agentAge)
        let stampText = ISO8601DateFormatter().string(from: stamp)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp], ofItemAtPath: journalURL.path)
        for index in 0..<started {
            let file = runDir.appendingPathComponent("agent-a\(index).jsonl")
            try line([
                "type": "assistant", "uuid": "s\(index)",
                "timestamp": stampText,
                "message": ["role": "assistant", "content": [["type": "text", "text": "working"]]],
            ]).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: stamp], ofItemAtPath: file.path)
            try line(["agentType": "workflow-subagent", "spawnDepth": 1]).write(
                to: runDir.appendingPathComponent("agent-a\(index).meta.json"), atomically: true,
                encoding: .utf8)
        }

        if marker {
            let markers = project.appendingPathComponent(sessionID)
                .appendingPathComponent("workflows")
            try FileManager.default.createDirectory(
                at: markers, withIntermediateDirectories: true)
            try line(["status": "completed"]).write(
                to: markers.appendingPathComponent("\(runID).json"), atomically: true,
                encoding: .utf8)
        }

        return World(
            root: root, transcript: transcript.path, runDir: runDir, sessionID: sessionID)
    }

    private func index(_ world: World) -> TranscriptIndex {
        TranscriptIndex(
            root: world.root,
            defaults: MachineDefaults(
                modelOverride: nil, effortOverride: nil, home: world.root.path))
    }

    @Test func aQuietRunWithAgentsStillOutIsLive() async throws {
        let world = try makeWorld(started: 8, results: 3, agentAge: 300, marker: false)
        defer { try? FileManager.default.removeItem(at: world.root) }
        let index = index(world)

        #expect(await index.activeIDs(within: 180).contains(world.sessionID))
        #expect(await index.hasWorkingAgents(world.sessionID))
    }

    @Test func aFinishedRunLetsTheRowSettle() async throws {
        let world = try makeWorld(started: 8, results: 3, agentAge: 300, marker: true)
        defer { try? FileManager.default.removeItem(at: world.root) }
        let index = index(world)

        #expect(!(await index.activeIDs(within: 180).contains(world.sessionID)))
    }

    @Test func aBalancedLedgerLetsTheRowSettle() async throws {
        let world = try makeWorld(started: 8, results: 8, agentAge: 300, marker: false)
        defer { try? FileManager.default.removeItem(at: world.root) }
        let index = index(world)

        #expect(!(await index.activeIDs(within: 180).contains(world.sessionID)))
    }

    /// A harness that died leaves its ledger unbalanced forever; the bound is what stops that from
    /// holding a seat all afternoon.
    @Test func anAbandonedRunIsGivenUpRatherThanHeldForever() async throws {
        let world = try makeWorld(started: 8, results: 3, agentAge: 3600, marker: false)
        defer { try? FileManager.default.removeItem(at: world.root) }
        let index = index(world)

        #expect(!(await index.activeIDs(within: 180).contains(world.sessionID)))
    }

    /// An agent the ledger started and has no result for is out until the ledger says otherwise,
    /// however long it thinks — the ninety-second rule is a tool's scale, not a run's.
    @Test func aThinkingAgentIsStillCounted() async throws {
        let world = try makeWorld(started: 4, results: 1, agentAge: 300, marker: false)
        defer { try? FileManager.default.removeItem(at: world.root) }
        let index = index(world)

        let agents = await index.subagents(for: world.sessionID)
        #expect(agents.filter { $0.active == true }.count == 3)
        #expect(agents.filter { $0.completed == true }.count == 1)
    }
}
