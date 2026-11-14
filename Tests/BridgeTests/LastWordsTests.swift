import Foundation
import Testing

@testable import claude_bridge

/// A row nobody has read quotes the answer that closed its last turn. These pin which words are
/// the quote, which turns have none, and which rows are allowed to carry one.
@Suite struct LastWordsTests {
    private func write(_ lines: [String]) throws -> String {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("words-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(
            to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func said(_ text: String, model: String = "claude-opus-5", sidechain: Bool = false)
        throws -> String
    {
        try line([
            "type": "assistant", "isSidechain": sidechain,
            "message": [
                "role": "assistant", "model": model, "stop_reason": "end_turn",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    private func prompt(_ text: String) throws -> String {
        try line(["type": "user", "message": ["role": "user", "content": text]])
    }

    private func toolCall() throws -> String {
        try line([
            "type": "assistant",
            "message": [
                "role": "assistant", "model": "claude-opus-5", "stop_reason": "tool_use",
                "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": [:]]],
            ],
        ])
    }

    private func toolResult() throws -> String {
        try line([
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]],
            ],
        ])
    }

    @Test func quotesTheNewestAnswerOfTheLastTurn() throws {
        let path = try write([
            try prompt("first"), try said("An older answer."),
            try prompt("second"), try said("Working on it."), try toolCall(), try toolResult(),
            try said("Shipped 1.84 (222); it is VALID."),
        ])
        #expect(TranscriptParser.lastWords(atPath: path) == "Shipped 1.84 (222); it is VALID.")
    }

    @Test func aTurnThatEndedWithoutAWordQuotesNothing() throws {
        let path = try write([
            try prompt("first"), try said("An older answer."),
            try prompt("second"), try toolCall(), try toolResult(),
        ])
        #expect(TranscriptParser.lastWords(atPath: path) == nil)
    }

    @Test func aSubagentAndTheCLIsOwnLinesAreNotTheAnswer() throws {
        let path = try write([
            try prompt("go"), try said("The real answer."),
            try said("A subagent's report.", sidechain: true),
            try said("No response requested.", model: "<synthetic>"),
            try prompt("<task-notification>done</task-notification>"),
        ])
        #expect(TranscriptParser.lastWords(atPath: path) == "The real answer.")
    }

    @Test func anAnswerAboveALongTailIsStillFound() throws {
        let filler = try (0..<400).map { _ in
            try line([
                "type": "user",
                "message": [
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result", "tool_use_id": "x",
                            "content": String(repeating: "y", count: 900),
                        ]
                    ],
                ],
            ])
        }
        let path = try write([try prompt("go"), try said("Found above the tail.")] + filler)
        #expect(TranscriptParser.lastWords(atPath: path) == "Found above the tail.")
    }

    @Test func markupComesOffAndCodeIsSkipped() {
        let text = """
            ## Result

            **Fixed** the `render()` hold: see [the notes](https://example.com/a).

            ```swift
            let never = "quoted"
            ```

            | a | b |
            |---|---|
            - Tests pass
            """
        #expect(
            LastWords.digest(text)
                == "Result Fixed the render() hold: see the notes. Tests pass")
    }

    @Test func aLongAnswerIsCutAtAWord() throws {
        let text = String(repeating: "seven letters ", count: 40)
        let digest = try #require(LastWords.digest(text))
        #expect(digest.count <= LastWords.limit)
        #expect(digest.hasSuffix("…"))
        #expect(!digest.dropLast().hasSuffix(" "))
        #expect(digest.dropLast().split(separator: " ").allSatisfy { $0 == "seven" || $0 == "letters" })
    }

    @Test func nothingButMarkupIsNothing() {
        #expect(LastWords.digest("```\ncode only\n```") == nil)
        #expect(LastWords.digest("---\n\n   ") == nil)
    }

    @Test func onlyARowThatMayBeUnreadCarriesTheQuote() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let moved = now.addingTimeInterval(-3600)
        #expect(LastWords.mayBeUnread(updatedAt: moved, readAt: nil, now: now))
        #expect(LastWords.mayBeUnread(updatedAt: moved, readAt: moved.addingTimeInterval(-60), now: now))
        #expect(!LastWords.mayBeUnread(updatedAt: moved, readAt: moved, now: now))
        #expect(!LastWords.mayBeUnread(updatedAt: moved, readAt: moved.addingTimeInterval(30), now: now))
        let stale = now.addingTimeInterval(-LastWords.window - 60)
        #expect(!LastWords.mayBeUnread(updatedAt: stale, readAt: nil, now: now))
    }

    @Test func theLedgerTakesTheQuoteOffAReadRow() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let moved = now.addingTimeInterval(-600)
        var summary = SessionSummary(
            id: "s1", title: "t", model: "opus", effort: "", createdAt: moved, updatedAt: moved)
        summary.lastWords = "Done."
        var ledger = MarksLedger()
        #expect(ledger.stamping(summary, now: now).lastWords == "Done.")
        ledger.apply(MarkChange(read: .seen, at: now), to: "s1", updatedAt: moved, now: now)
        #expect(ledger.stamping(summary, now: now).lastWords == nil)
    }
}
