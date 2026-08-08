import Foundation
import Testing

@testable import claude_bridge

/// Search's promise: it finds what was actually said — prose, reasoning, the command that ran and
/// what it answered — across every conversation on the machine, and it never claims a completeness
/// it did not deliver.
@Suite struct TranscriptSearchTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// One transcript, written the way the CLI writes them: one JSON object per line.
    @discardableResult
    private func write(_ lines: [[String: Any]], project: String, in root: URL) throws -> String {
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body =
            lines.compactMap {
                (try? JSONSerialization.data(withJSONObject: $0)).flatMap {
                    String(data: $0, encoding: .utf8)
                }
            }.joined(separator: "\n") + "\n"
        try body.write(
            to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        return id
    }

    /// A subagent transcript, filed where the CLI files them: under the conversation that spawned
    /// it, at whatever depth.
    private func writeSubagent(
        _ lines: [[String: Any]], project: String, session: String, workflow: String? = nil,
        in root: URL
    ) throws {
        var dir = root.appendingPathComponent(project).appendingPathComponent(session)
            .appendingPathComponent("subagents")
        if let workflow { dir = dir.appendingPathComponent("workflows").appendingPathComponent(workflow) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body =
            lines.compactMap {
                (try? JSONSerialization.data(withJSONObject: $0)).flatMap {
                    String(data: $0, encoding: .utf8)
                }
            }.joined(separator: "\n") + "\n"
        try body.write(
            to: dir.appendingPathComponent("agent-\(UUID().uuidString).jsonl"), atomically: true,
            encoding: .utf8)
    }

    private func user(_ text: String) -> [String: Any] {
        ["type": "user", "cwd": "/home/m/proj", "message": ["content": text]]
    }

    private func assistant(_ blocks: [[String: Any]]) -> [String: Any] {
        ["type": "assistant", "cwd": "/home/m/proj", "message": ["content": blocks]]
    }

    @Test("Prose in either voice is findable")
    func findsProse() async throws {
        let root = try makeRoot()
        try write(
            [user("how do I mount a squashfs"), assistant([["type": "text", "text": "Use unsquashfs"]])],
            project: "a", in: root)
        try write([user("something else entirely")], project: "b", in: root)

        let byQuestion = await TranscriptSearch.run(root: root, query: "squashfs", limit: 10)
        #expect(byQuestion.hits.count == 1)
        let byAnswer = await TranscriptSearch.run(root: root, query: "unsquashfs", limit: 10)
        #expect(byAnswer.hits.count == 1)
        #expect(byAnswer.hits.first?.matches.first?.role == .assistant)
    }

    @Test("The command that ran and what it answered are findable too")
    func findsToolTraffic() async throws {
        let root = try makeRoot()
        try write(
            [
                assistant([
                    [
                        "type": "tool_use", "id": "t1", "name": "Bash",
                        "input": ["command": "btrfs subvolume snapshot /home /snap"],
                    ]
                ]),
                [
                    "type": "user", "cwd": "/home/m/proj",
                    "message": [
                        "content": [
                            [
                                "type": "tool_result", "tool_use_id": "t1",
                                "content": "Create a snapshot of '/home'",
                            ]
                        ]
                    ],
                ],
            ], project: "a", in: root)

        let command = await TranscriptSearch.run(root: root, query: "subvolume snapshot", limit: 10)
        #expect(command.hits.first?.matches.contains { $0.kind == "Bash" } == true)
        let output = await TranscriptSearch.run(root: root, query: "Create a snapshot", limit: 10)
        #expect(output.hits.first?.matches.contains { $0.kind == "result" } == true)
    }

    @Test("Reasoning is searchable, and says that is what it was")
    func findsReasoning() async throws {
        let root = try makeRoot()
        try write(
            [assistant([["type": "thinking", "thinking": "the mtime ordering is the tricky part"]])],
            project: "a", in: root)
        let found = await TranscriptSearch.run(root: root, query: "mtime ordering", limit: 10)
        #expect(found.hits.first?.matches.first?.kind == "reasoning")
    }

    @Test("Several words narrow rather than widen")
    func termsAreConjunctive() async throws {
        let root = try makeRoot()
        try write([user("the cascade renders markdown safely")], project: "a", in: root)
        try write([user("the cascade is a wave")], project: "b", in: root)
        #expect(await TranscriptSearch.run(root: root, query: "cascade markdown", limit: 10).hits.count == 1)
        #expect(await TranscriptSearch.run(root: root, query: "cascade", limit: 10).hits.count == 2)
    }

    @Test("Case is not a thing anyone remembers about a phrase they read")
    func caseInsensitive() async throws {
        let root = try makeRoot()
        try write([user("The Taptic Engine is absent here")], project: "a", in: root)
        #expect(await TranscriptSearch.run(root: root, query: "taptic ENGINE", limit: 10).hits.count == 1)
    }

    @Test("A snippet carries enough either side to recognise the match by, and says where it cut")
    func snippetsAreWindowed() async throws {
        let root = try makeRoot()
        let filler = String(repeating: "padding words ", count: 60)
        try write([user(filler + "NEEDLE" + filler)], project: "a", in: root)
        let text = try #require(
            await TranscriptSearch.run(root: root, query: "needle", limit: 10).hits.first?.matches.first?
                .text)
        #expect(text.contains("NEEDLE"))
        #expect(text.hasPrefix("…"))
        #expect(text.hasSuffix("…"))
        #expect(text.count < 250)
    }

    @Test("A conversation reports every place it matched, not only the ones returned")
    func totalOutrunsReturned() async throws {
        let root = try makeRoot()
        let lines = (0..<20).map { user("occurrence number \($0) of the word beacon") }
        try write(lines, project: "a", in: root)
        let hit = try #require(await TranscriptSearch.run(root: root, query: "beacon", limit: 10).hits.first)
        #expect(hit.total == 20)
        #expect(hit.matches.count == TranscriptSearch.matchesPerSession)
    }

    @Test("Nothing said is nothing found, and an empty query is not a match for everything")
    func emptyCases() async throws {
        let root = try makeRoot()
        try write([user("hello")], project: "a", in: root)
        #expect(await TranscriptSearch.run(root: root, query: "absent", limit: 10).hits.isEmpty)
        #expect(await TranscriptSearch.run(root: root, query: "   ", limit: 10).hits.isEmpty)
        #expect(await TranscriptSearch.run(root: root, query: "   ", limit: 10).scanned == 0)
    }

    @Test("A limit is a limit, and reaching it is admitted rather than hidden")
    func limitIsReported() async throws {
        let root = try makeRoot()
        for index in 0..<6 { try write([user("shared word marker \(index)")], project: "p\(index)", in: root) }
        let capped = await TranscriptSearch.run(root: root, query: "marker", limit: 2)
        #expect(capped.hits.count == 2)
        #expect(capped.truncated)
        #expect(await TranscriptSearch.run(root: root, query: "marker", limit: 20).truncated == false)
    }

    @Test("What a subagent did is found under the conversation that sent it")
    func subagentWorkIsFound() async throws {
        let root = try makeRoot()
        let session = try write([user("audit the login flow")], project: "a", in: root)
        try writeSubagent(
            [assistant([["type": "text", "text": "the session cookie is never rotated"]])],
            project: "a", session: session, in: root)
        try writeSubagent(
            [assistant([["type": "thinking", "thinking": "checking the rotation window"]])],
            project: "a", session: session, workflow: "wf_1", in: root)

        let found = await TranscriptSearch.run(root: root, query: "rotated", limit: 10)
        #expect(found.hits.count == 1)
        #expect(found.hits.first?.sessionID == session)
        #expect(found.hits.first?.title == "audit the login flow")
        let nested = await TranscriptSearch.run(root: root, query: "rotation window", limit: 10)
        #expect(nested.hits.first?.sessionID == session)
    }

    @Test("A conversation and its subagents are one row, not several")
    func subagentsFoldIntoOneRow() async throws {
        let root = try makeRoot()
        let session = try write([user("the beacon is missing")], project: "a", in: root)
        try writeSubagent([assistant([["type": "text", "text": "beacon found"]])],
            project: "a", session: session, in: root)
        try writeSubagent([assistant([["type": "text", "text": "beacon again"]])],
            project: "a", session: session, in: root)

        let found = await TranscriptSearch.run(root: root, query: "beacon", limit: 10)
        #expect(found.hits.count == 1)
        #expect(found.hits.first?.total == 3)
        #expect(found.hits.first?.matches.count == 3)
    }

    @Test("A subagent whose conversation is gone is not offered as somewhere to go back to")
    func orphanedSubagentsAreLeftOut() async throws {
        let root = try makeRoot()
        try writeSubagent([assistant([["type": "text", "text": "orphan marker here"]])],
            project: "a", session: UUID().uuidString, in: root)
        #expect(await TranscriptSearch.run(root: root, query: "orphan marker", limit: 10).hits.isEmpty)
    }

    @Test("A conversation carries where it happened, so a result can name its project")
    func hitsCarryDirectory() async throws {
        let root = try makeRoot()
        try write([user("find me")], project: "a", in: root)
        #expect(await TranscriptSearch.run(root: root, query: "find me", limit: 5).hits.first?.directory
            == "/home/m/proj")
    }
}
