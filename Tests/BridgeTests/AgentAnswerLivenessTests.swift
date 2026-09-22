import Foundation
import Testing

@testable import claude_bridge

/// A session that delegated to an agent used to read as live for three minutes after the agent
/// reported back, because liveness was the sidecar's mtime and nothing else. The parent is told in
/// so many words when an agent ends — a `tool_result` for a foreground call, a
/// `<task-notification>` for a background one — and a sidecar that word has answered is finished,
/// however recently it wrote.
@Suite struct AgentAnswerLivenessTests {
    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private let agentID = "aad92ed1e82e6bc3e"
    private let toolID = "toolu_01KgHsugZaj77U6cqUFhmo96"

    private func notification(at date: Date, queued: Bool = false) -> String {
        let text = """
            <task-notification>
            <task-id>\(agentID)</task-id>
            <status>completed</status>
            <summary>Agent "Sleep" finished</summary>
            </task-notification>
            """
        if queued {
            return line([
                "type": "queue-operation", "operation": "enqueue", "timestamp": stamp(date),
                "content": text,
            ])
        }
        return line([
            "type": "user", "uuid": UUID().uuidString, "timestamp": stamp(date),
            "message": ["role": "user", "content": text],
        ])
    }

    private struct World {
        let root: URL
        let sessionID: String
        let agentFile: URL
    }

    /// A parent that launched one background agent and closed its turn, with the agent's sidecar
    /// last written `agentWrote` ago and whatever else the parent heard afterwards.
    private func makeWorld(agentWrote: TimeInterval, heard: [String]) throws -> World {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-answers-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-tmp-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let launched = Date().addingTimeInterval(-agentWrote - 60)
        let lines = [
            line([
                "type": "user", "uuid": "u1", "timestamp": stamp(launched), "cwd": "/tmp/project",
                "message": ["role": "user", "content": "delegate it"],
            ]),
            line([
                "type": "assistant", "uuid": "a1", "timestamp": stamp(launched),
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "tool_use", "id": toolID, "name": "Agent", "input": [:]]
                    ],
                ],
            ]),
            line([
                "type": "user", "uuid": "u2", "timestamp": stamp(launched),
                "toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": agentID],
                "message": [
                    "role": "user",
                    "content": [
                        ["type": "tool_result", "tool_use_id": toolID, "content": "launched"]
                    ],
                ],
            ]),
            line([
                "type": "assistant", "uuid": "a2", "timestamp": stamp(launched),
                "message": [
                    "role": "assistant", "stop_reason": "end_turn",
                    "content": [["type": "text", "text": "started"]],
                ],
            ]),
        ] + heard
        try (lines.joined(separator: "\n") + "\n").write(
            to: project.appendingPathComponent("\(sessionID).jsonl"), atomically: true,
            encoding: .utf8)

        let sidecars = project.appendingPathComponent(sessionID).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: sidecars, withIntermediateDirectories: true)
        let wrote = Date().addingTimeInterval(-agentWrote)
        let agentFile = sidecars.appendingPathComponent("agent-\(agentID).jsonl")
        try line([
            "type": "assistant", "uuid": "s1", "timestamp": stamp(wrote), "isSidechain": true,
            "message": ["role": "assistant", "content": [["type": "text", "text": "working"]]],
        ]).write(to: agentFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: wrote], ofItemAtPath: agentFile.path)
        try line(["agentType": "general-purpose", "description": "Sleep", "toolUseId": toolID])
            .write(
                to: sidecars.appendingPathComponent("agent-\(agentID).meta.json"),
                atomically: true, encoding: .utf8)
        return World(root: root, sessionID: sessionID, agentFile: agentFile)
    }

    private func index(_ world: World) -> TranscriptIndex {
        TranscriptIndex(
            root: world.root,
            defaults: MachineDefaults(
                modelOverride: nil, effortOverride: nil, home: world.root.path))
    }

    @Test func anAgentThatReportedBackLetsTheRowSettleAtOnce() async throws {
        let world = try makeWorld(
            agentWrote: 20, heard: [notification(at: Date().addingTimeInterval(-19))])
        defer { try? FileManager.default.removeItem(at: world.root) }
        let index = index(world)

        #expect(!(await index.activeIDs(within: 180).contains(world.sessionID)))
        #expect(!(await index.hasWorkingAgents(world.sessionID)))
        let agents = await index.subagents(for: world.sessionID)
        #expect(agents.map(\.completed) == [true])
        #expect(agents.map(\.active) == [false])
    }

    /// The CLI queues the notification while a turn is busy; the queue record is already the word.
    @Test func aQueuedNotificationAnswersToo() async throws {
        let world = try makeWorld(
            agentWrote: 20,
            heard: [notification(at: Date().addingTimeInterval(-19), queued: true)])
        defer { try? FileManager.default.removeItem(at: world.root) }

        #expect(!(await index(world).activeIDs(within: 180).contains(world.sessionID)))
    }

    /// A background launch is answered at once, and that answer says only that it started.
    @Test func aRunningBackgroundAgentIsStillLive() async throws {
        let world = try makeWorld(agentWrote: 20, heard: [])
        defer { try? FileManager.default.removeItem(at: world.root) }
        let index = index(world)

        #expect(await index.activeIDs(within: 180).contains(world.sessionID))
        #expect(await index.hasWorkingAgents(world.sessionID))
        let agents = await index.subagents(for: world.sessionID)
        #expect(agents.map(\.completed) == [false])
        #expect(agents.map(\.active) == [true])
    }

    /// An agent that stopped with work of its own still out reports, then picks itself back up;
    /// writing past its report makes it live again.
    @Test func anAgentWritingPastItsReportIsLiveAgain() async throws {
        let world = try makeWorld(
            agentWrote: 20, heard: [notification(at: Date().addingTimeInterval(-60))])
        defer { try? FileManager.default.removeItem(at: world.root) }

        #expect(await index(world).activeIDs(within: 180).contains(world.sessionID))
    }

    @Test func answersSkipBackgroundLaunchesAndReadNotificationTags() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let launch = line([
            "type": "user", "timestamp": stamp(at),
            "toolUseResult": ["status": "async_launched"],
            "message": [
                "role": "user",
                "content": [["type": "tool_result", "tool_use_id": "toolu_bg", "content": "x"]],
            ],
        ])
        let finished = line([
            "type": "user", "timestamp": stamp(at.addingTimeInterval(1)),
            "toolUseResult": ["status": "completed"],
            "message": [
                "role": "user",
                "content": [["type": "tool_result", "tool_use_id": "toolu_fg", "content": "x"]],
            ],
        ])
        let heard = TranscriptParser.answers(
            in: Data((launch + "\n" + finished + "\n" + notification(at: at.addingTimeInterval(2))
                + "\n" + "{\"type\":\"user\",\"tool_use_id\":\"toolu_torn\"").utf8))

        #expect(heard["toolu_bg"] == nil)
        #expect(heard["toolu_fg"] == at.addingTimeInterval(1))
        #expect(heard[agentID] == at.addingTimeInterval(2))
        #expect(heard["toolu_torn"] == nil)
    }
}
