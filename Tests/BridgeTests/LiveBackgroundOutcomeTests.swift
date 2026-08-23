import Foundation
import Testing

@testable import claude_bridge

/// The same reporting seam as ``BackgroundOutcomeTests``, on the other path.
///
/// A turn this bridge runs is assembled from the CLI's stdout, not from the transcript, and what it
/// assembles is what `GET /sessions/{id}` serves — so a client watching a live session sees the
/// call that launched background work, and, until this, never saw it end: its spinner turned
/// forever. These drive real `<task-notification>` shapes, copied out of a live transcript, through
/// the runner and the store the way the CLI delivers them.
@Suite("Background work reporting back into a live turn")
struct LiveBackgroundOutcomeTests {
    /// A stand-in for the `claude` CLI that replays one prepared script of stream-json lines per
    /// turn, so a report can be made to arrive in the turn after the one that launched the work —
    /// which is where it nearly always arrives in life.
    private struct ScriptedClaude {
        let root: URL
        let binary: String

        init(turns: [[String]]) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("bridge-bg-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (index, lines) in turns.enumerated() {
                try (lines.joined(separator: "\n") + "\n").write(
                    to: root.appendingPathComponent("turn-\(index + 1).jsonl"), atomically: true,
                    encoding: .utf8)
            }
            let script = root.appendingPathComponent("scripted-claude")
            let body = """
                #!/bin/sh
                root="\(root.path)"
                n=$(cat "$root/turn" 2>/dev/null || echo 1)
                echo $((n + 1)) > "$root/turn"
                [ -f "$root/turn-$n.jsonl" ] && /bin/cat "$root/turn-$n.jsonl"
                exit 0
                """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: script.path)
            binary = script.path
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private static func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private static let initLine = line([
        "type": "system", "subtype": "init", "session_id": "live-session",
    ])

    /// The three lines a background launch actually arrives as: the tool block opening, its input
    /// streaming in, and the harness's own result carrying the launch banner.
    private static func launch(toolID: String, taskID: String, name: String = "Workflow") -> [String]
    {
        [
            line([
                "type": "stream_event",
                "event": [
                    "type": "content_block_start", "index": 0,
                    "content_block": ["type": "tool_use", "id": toolID, "name": name],
                ],
            ]),
            line([
                "type": "stream_event",
                "event": [
                    "type": "content_block_delta", "index": 0,
                    "delta": ["type": "input_json_delta", "partial_json": "{\"scriptPath\":\"x\"}"],
                ],
            ]),
            line(["type": "stream_event", "event": ["type": "content_block_stop", "index": 0]]),
            line([
                "type": "user", "uuid": "u-result",
                "message": [
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result", "tool_use_id": toolID,
                            "content":
                                "Workflow launched in background. Task ID: \(taskID)\nSummary: Map the video subsystem\nRun ID: wf_4aea71a8-bf9",
                        ]
                    ],
                ],
            ]),
        ]
    }

    private static func notification(_ body: String, uuid: String = "u-note") -> String {
        line([
            "type": "user", "uuid": uuid, "timestamp": "2026-08-22T06:57:25.393Z",
            "origin": ["kind": "task-notification"],
            "message": ["role": "user", "content": body],
        ])
    }

    private static let namedCall = notification(
        """
        <task-notification>
        <task-id>w8r9zz5zf</task-id>
        <tool-use-id>toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr</tool-use-id>
        <status>completed</status>
        <summary>Background workflow "tailscode-video-understand" completed</summary>
        <result>"mapped the subsystem"</result>
        </task-notification>
        """)

    private static let taskOnly = notification(
        """
        <task-notification>
        <task-id>w8r9zz5zf</task-id>
        <status>stopped</status>
        <summary>No completion record was found for background workflow "tailscode-video-understand".</summary>
        </task-notification>
        """)

    private static let unknownCall = notification(
        """
        <task-notification>
        <task-id>zzzznever</task-id>
        <tool-use-id>toolu_nobody_ever_saw</tool-use-id>
        <status>completed</status>
        <summary>Background command "somebody else's" completed (exit code 0)</summary>
        </task-notification>
        """)

    private func store(_ claude: ScriptedClaude) -> SessionStore {
        SessionStore(
            runner: ClaudeRunner(
                claudePath: claude.binary, workdir: claude.root.path, permissionMode: "default"),
            defaults: MachineDefaults(
                modelOverride: "sonnet", effortOverride: "medium", home: claude.root.path),
            storeURL: claude.root.appendingPathComponent("sessions.json"),
            projectsDir: claude.root.path)
    }

    /// Sends one prompt and waits for the turn to be over, so the assertions read a settled store.
    private func turn(_ store: SessionStore, _ id: String, _ text: String) async throws {
        _ = await store.send(id, request: SendRequest(text: text))
        for _ in 0..<200 {
            if await store.hasQueuedOrRunningTurn(id) == false { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("turn never finished")
    }

    private func background(_ session: Session?, toolID: String) -> BackgroundOutcome? {
        for message in session?.messages ?? [] {
            for part in message.parts {
                if case .tool(let call) = part, call.id == toolID { return call.background }
            }
        }
        return nil
    }

    @Test("A report naming the call seats the ending on it")
    func namedCallSeats() async throws {
        let claude = try ScriptedClaude(turns: [
            [Self.initLine] + Self.launch(
                toolID: "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr", taskID: "w8r9zz5zf") + [Self.namedCall]
        ])
        defer { claude.cleanUp() }
        let store = self.store(claude)
        let session = await store.create(CreateRequest(directory: claude.root.path))
        try await turn(store, session.id, "map the video subsystem")

        let outcome = background(
            await store.get(session.id), toolID: "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr")
        #expect(outcome?.status == .completed)
        #expect(outcome?.taskID == "w8r9zz5zf")
        #expect(outcome?.result == "mapped the subsystem")
    }

    @Test("A report naming only a task finds its call through the launch banner")
    func taskIDFindsCallViaBanner() async throws {
        let claude = try ScriptedClaude(turns: [
            [Self.initLine] + Self.launch(
                toolID: "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr", taskID: "w8r9zz5zf") + [Self.taskOnly]
        ])
        defer { claude.cleanUp() }
        let store = self.store(claude)
        let session = await store.create(CreateRequest(directory: claude.root.path))
        try await turn(store, session.id, "map the video subsystem")

        let outcome = background(
            await store.get(session.id), toolID: "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr")
        #expect(outcome?.status == .stopped)
        #expect(outcome?.taskID == "w8r9zz5zf")
    }

    @Test("A report for a call this bridge never saw changes nothing")
    func unknownCallIsDropped() async throws {
        let claude = try ScriptedClaude(turns: [
            [Self.initLine] + Self.launch(
                toolID: "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr", taskID: "w8r9zz5zf")
                + [Self.unknownCall]
        ])
        defer { claude.cleanUp() }
        let store = self.store(claude)
        let session = await store.create(CreateRequest(directory: claude.root.path))
        try await turn(store, session.id, "map the video subsystem")

        let stored = await store.get(session.id)
        #expect(background(stored, toolID: "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr") == nil)
        #expect(background(stored, toolID: "toolu_nobody_ever_saw") == nil)
        #expect(stored?.messages.isEmpty == false)
    }

    @Test("The same report twice lands once")
    func repeatedReportIsIdempotent() async throws {
        let claude = try ScriptedClaude(turns: [
            [Self.initLine] + Self.launch(
                toolID: "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr", taskID: "w8r9zz5zf")
                + [Self.namedCall, Self.notification(Self.namedCallBody, uuid: "u-note-2")]
        ])
        defer { claude.cleanUp() }
        let store = self.store(claude)
        let session = await store.create(CreateRequest(directory: claude.root.path))
        try await turn(store, session.id, "map the video subsystem")

        let stored = await store.get(session.id)
        let calls = (stored?.messages ?? []).flatMap(\.parts).compactMap { part -> ToolCall? in
            if case .tool(let call) = part { return call }
            return nil
        }
        #expect(calls.count { $0.id == "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr" } == 1)
        #expect(calls.first?.background?.status == .completed)
    }

    @Test("A report in a later turn still reaches the call persisted in an earlier one")
    func reportReachesAPersistedCall() async throws {
        let claude = try ScriptedClaude(turns: [
            [Self.initLine] + Self.launch(
                toolID: "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr", taskID: "w8r9zz5zf"),
            [Self.initLine, Self.namedCall],
        ])
        defer { claude.cleanUp() }
        let store = self.store(claude)
        let session = await store.create(CreateRequest(directory: claude.root.path))
        try await turn(store, session.id, "map the video subsystem")
        #expect(background(await store.get(session.id), toolID: "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr") == nil)

        try await turn(store, session.id, "anything else")
        for _ in 0..<40 {
            if background(await store.get(session.id), toolID: "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr") != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let outcome = background(
            await store.get(session.id), toolID: "toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr")
        #expect(outcome?.status == .completed)
        #expect(outcome?.summary?.contains("tailscode-video-understand") == true)
    }

    private static let namedCallBody = """
        <task-notification>
        <task-id>w8r9zz5zf</task-id>
        <tool-use-id>toolu_01Vbu9mSv2N3qiPJ3B2ZP6Nr</tool-use-id>
        <status>completed</status>
        <summary>Background workflow "tailscode-video-understand" completed</summary>
        <result>"mapped the subsystem"</result>
        </task-notification>
        """
}
