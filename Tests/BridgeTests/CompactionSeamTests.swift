import Foundation
import Testing

@testable import claude_bridge

/// A compaction is a seam in the conversation, and both records of a conversation — the turn the
/// bridge streams and the transcript it reads back — have to hold it in the same shape, or a
/// client watching a `/compact` land sees the seam twice and the chat stays live after it.
@Suite("Compaction seams")
struct CompactionSeamTests {
    private static var boundary: [String: Any] {
        [
        "type": "system", "subtype": "compact_boundary",
        "compact_metadata": [
            "trigger": "manual", "pre_tokens": 513_000, "post_tokens": 12_400,
            "duration_ms": 133_000,
        ] as [String: Any],
        ]
    }
    private static var compacting: [String: Any] {
        [
        "type": "system", "subtype": "status", "status": "compacting",
        ]
    }
    private static var compacted: [String: Any] {
        [
        "type": "system", "subtype": "status", "compact_result": "ok",
        ]
    }
    private static var result: [String: Any] { ["type": "result", "subtype": "success"] }

    private static func delta(_ text: String) -> [String: Any] {
        [
            "type": "stream_event",
            "event": [
                "type": "content_block_delta", "index": 0, "delta": ["text": text],
            ] as [String: Any],
        ]
    }

    private static func blockStart() -> [String: Any] {
        [
            "type": "stream_event",
            "event": [
                "type": "content_block_start", "index": 0,
                "content_block": ["type": "text"] as [String: Any],
            ] as [String: Any],
        ]
    }

    private func seam(_ message: Message) -> Compaction? {
        guard message.parts.count == 1, case .compaction(let value) = message.parts[0] else {
            return nil
        }
        return value
    }

    private func upserts(_ events: [BridgeEvent]) -> [Message] {
        events.compactMap { event in
            if case .messageUpserted(let message) = event { return message }
            return nil
        }
    }

    @Test("A manual /compact settles as one seam under the bubble the store announced")
    func manualCompactIsTheAnnouncedMessage() {
        var assembler = Assembler(messageID: "X")
        var events: [BridgeEvent] = []
        for object in [Self.compacting, Self.compacted, Self.boundary, Self.result] {
            assembler.ingest(object, emit: { events.append($0) })
        }
        let messages = assembler.finalMessages()
        #expect(messages.map(\.id) == ["X"])
        #expect(messages.map(\.role) == [.system])
        #expect(seam(messages[0])?.tokensBefore == 513_000)
        #expect(seam(messages[0])?.trigger == "manual")
        #expect(assembler.didCompact)
        let announced = upserts(events)
        #expect(announced.allSatisfy { $0.id == "X" && $0.role == .system })
        #expect(announced.last.flatMap(seam)?.tokensAfter == 12_400)
    }

    @Test("A compaction in the middle of an answer splits it around the seam")
    func midTurnCompactionSplitsTheAnswer() {
        var assembler = Assembler(messageID: "X")
        var events: [BridgeEvent] = []
        let emit: (BridgeEvent) -> Void = { events.append($0) }
        assembler.ingest(Self.blockStart(), emit: emit)
        assembler.ingest(Self.delta("before the seam"), emit: emit)
        assembler.ingest(Self.compacting, emit: emit)
        assembler.ingest(Self.compacted, emit: emit)
        assembler.ingest(Self.boundary, emit: emit)
        assembler.ingest(Self.blockStart(), emit: emit)
        assembler.ingest(Self.delta("after the seam"), emit: emit)
        assembler.ingest(Self.result, emit: emit)

        let messages = assembler.finalMessages()
        #expect(messages.count == 3)
        #expect(messages[0].id == "X")
        #expect(messages.map(\.role) == [.assistant, .system, .assistant])
        #expect(messages[2].id != "X")
        #expect(seam(messages[1]) != nil)
        #expect(messages[1].id != "X" && messages[1].id != messages[2].id)

        let announced = upserts(events)
        let seamAt = announced.firstIndex { $0.role == .system }
        let afterAt = announced.firstIndex { $0.id == messages[2].id }
        #expect(seamAt != nil && afterAt != nil && seamAt! < afterAt!)
        let deltaTargets = events.compactMap { event -> String? in
            if case .partTextDelta(let id, _) = event { return id }
            return nil
        }
        #expect(deltaTargets == ["X", messages[2].id])
    }

    @Test("A compaction before the first word leaves no empty bubble behind")
    func compactionBeforeTheFirstWord() {
        var assembler = Assembler(messageID: "X")
        var events: [BridgeEvent] = []
        let emit: (BridgeEvent) -> Void = { events.append($0) }
        assembler.ingest(Self.compacting, emit: emit)
        assembler.ingest(Self.compacted, emit: emit)
        assembler.ingest(Self.boundary, emit: emit)
        assembler.ingest(Self.blockStart(), emit: emit)
        assembler.ingest(Self.delta("the answer"), emit: emit)
        assembler.ingest(Self.result, emit: emit)

        let messages = assembler.finalMessages()
        #expect(messages.map(\.role) == [.system, .assistant])
        #expect(messages[0].id == "X")
        let announced = upserts(events)
        #expect(announced.contains { $0.id == messages[1].id && $0.role == .assistant })
        #expect(!announced.contains { $0.id == "X" && $0.role == .assistant })
    }

    private func fold(_ lines: [String]) -> [Message] {
        var fold = TranscriptFold()
        _ = fold.consume(Data(lines.joined(separator: "\n").appending("\n").utf8))
        return fold.snapshot
    }

    private func user(_ content: String, at: String, meta: Bool = false, summary: Bool = false)
        -> String
    {
        let escaped = content.replacingOccurrences(of: "\n", with: "\\n")
        return """
            {"type":"user","uuid":"\(UUID().uuidString)","isMeta":\(meta),"isCompactSummary":\(summary),"timestamp":"\(at)","message":{"role":"user","content":"\(escaped)"}}
            """
    }

    private func assistant(_ text: String, at: String) -> String {
        """
        {"type":"assistant","uuid":"\(UUID().uuidString)","timestamp":"\(at)","message":{"id":"m","role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    private func boundary(at: String) -> String {
        """
        {"type":"system","subtype":"compact_boundary","uuid":"\(UUID().uuidString)","timestamp":"\(at)","compactMetadata":{"trigger":"manual","preTokens":513000,"postTokens":12400,"durationMs":133000}}
        """
    }

    /// The CLI writes a `/compact` the way it happened on disk: the seam and its summary first,
    /// then the record of the prompt that asked for it, stamped when it was typed.
    private var manualCompactTranscript: [String] {
        [
            user("push that", at: "2026-09-16T11:36:00.000Z"),
            assistant("Pushed.", at: "2026-09-16T11:36:10.000Z"),
            boundary(at: "2026-09-16T11:38:30.916Z"),
            user(
                "This session is being continued from a previous conversation.",
                at: "2026-09-16T11:38:30.915Z", summary: true),
            user(
                "<local-command-caveat>Caveat: generated by the user</local-command-caveat>",
                at: "2026-09-16T11:36:46.798Z", meta: true),
            user(
                "<command-name>/compact</command-name>\n<command-message>compact</command-message>\n<command-args></command-args>",
                at: "2026-09-16T11:36:46.798Z"),
            user("<local-command-stdout>Compacted </local-command-stdout>", at: "2026-09-16T11:38:31.027Z"),
        ]
    }

    @Test("The prompt that asked for a compaction is read back above the seam it caused")
    func promptSitsAboveTheSeamItAsked() {
        let messages = fold(manualCompactTranscript)
        #expect(messages.map(\.role) == [.user, .assistant, .user, .system])
        if case .text(let prompt) = messages[2].parts[0] {
            #expect(prompt == "/compact")
        } else {
            Issue.record("the prompt was not read back as text")
        }
        #expect(seam(messages[3])?.tokensBefore == 513_000)
        #expect(seam(messages[3])?.summary?.hasPrefix("This session") == true)
    }

    @Test("A compacted chat is over once the compaction is")
    func manualCompactCloses() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seam-\(UUID().uuidString).jsonl")
        try manualCompactTranscript.joined(separator: "\n").appending("\n").write(
            to: file, atomically: true, encoding: .utf8)
        #expect(TranscriptParser.isTurnClosed(atPath: file.path))
    }

    @Test("A compaction that fired before the answer leaves the prompt waiting")
    func autoCompactBeforeTheAnswerStaysOpen() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seam-\(UUID().uuidString).jsonl")
        try [
            user("go on", at: "2026-09-16T11:36:00.000Z"),
            boundary(at: "2026-09-16T11:36:30.000Z"),
            user("This session is being continued.", at: "2026-09-16T11:36:30.000Z", summary: true),
        ].joined(separator: "\n").appending("\n").write(
            to: file, atomically: true, encoding: .utf8)
        #expect(!TranscriptParser.isTurnClosed(atPath: file.path))
    }

    private func message(_ id: String, _ role: Role, _ parts: [Part]) -> Message {
        Message(id: id, role: role, parts: parts, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test("The transcript's seam wears the name the turn streamed it under")
    func seamPairsWithSeam() {
        let stored = [
            message("STORE-U", .user, [.text("/compact")]),
            message("STORE-S", .system, [.compaction(Compaction(tokensBefore: 513_000))]),
        ]
        let folded = [
            message("fold-u", .user, [.text("/compact")]),
            message(
                "fold-s", .system,
                [.compaction(Compaction(tokensBefore: 513_000, summary: "the summary"))]),
        ]
        let named = SessionStore.named(folded, asPublishedIn: stored)
        #expect(named.map(\.id) == ["STORE-U", "STORE-S"])
    }

    @Test("A seam is never taken for the answer that follows it")
    func seamNeverPairsWithWords() {
        let stored = [
            message("STORE-U", .user, [.text("/compact")]),
            message("STORE-S", .assistant, [.compaction(Compaction())]),
            message("STORE-U2", .user, [.text("next")]),
        ]
        let folded = [
            message("fold-u", .user, [.text("/compact")]),
            message("fold-a", .assistant, [.text("Done.")]),
            message("fold-u2", .user, [.text("next")]),
        ]
        let named = SessionStore.named(folded, asPublishedIn: stored)
        #expect(named.map(\.id) == ["STORE-U", "fold-a", "fold-u2"])
    }

    @Test("Across a gap a seam is identified by its numbers alone")
    func seamAnchorsOnItsNumbers() {
        let stored = [
            message("STORE-A", .assistant, [.text("a partial the store kept")]),
            message("STORE-S", .system, [.compaction(Compaction(tokensBefore: 513_000))]),
            message("STORE-T", .system, [.compaction(Compaction(tokensBefore: 99))]),
        ]
        let folded = [
            message("fold-a", .assistant, [.text("what the terminal wrote instead, quite different")]),
            message("fold-t", .system, [.compaction(Compaction(tokensBefore: 99))]),
        ]
        let named = SessionStore.named(folded, asPublishedIn: stored)
        #expect(named.map(\.id) == ["fold-a", "STORE-T"])
    }
}
