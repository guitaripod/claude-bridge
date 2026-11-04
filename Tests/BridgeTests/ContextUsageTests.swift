import Foundation
import Testing

@testable import claude_bridge

/// The CLI's own count of what fills a conversation's window, read into the shape clients get.
@Suite("Context usage")
struct ContextUsageTests {
    private static let reply = #"""
        {"categories":[{"id":"system_prompt","name":"System prompt","tokens":3625,"color":"promptBorder","kind":"used"},
         {"id":"system_tools_deferred","name":"System tools (deferred)","tokens":20901,"isDeferred":true,"kind":"deferred"},
         {"id":"messages","name":"Messages","tokens":282,"kind":"used"},
         {"id":"autocompact_buffer","name":"Autocompact buffer","tokens":33000,"kind":"buffer"},
         {"id":"free_space","name":"Free space","tokens":933067,"kind":"free"}],
         "totalTokens":33933,"maxTokens":1000000,"rawMaxTokens":1000000,"percentage":3,
         "model":"claude-haiku-5-5","memoryFiles":[{"path":"/home/me/.claude/CLAUDE.md","type":"User","tokens":3456}],
         "autoCompactThreshold":967000,"isAutoCompactEnabled":true,
         "messageBreakdown":{"toolCallTokens":5,"toolResultTokens":40,"attachmentTokens":0,"assistantMessageTokens":10,
          "userMessageTokens":214,"redirectedContextTokens":3,"unattributedTokens":10,"toolCallsByType":[]},
         "apiUsage":null,"futureField":{"x":1}}
        """#

    @Test func theCLIsAnswerIsReadWhole() throws {
        let report = try #require(ContextUsageReport.read(Data(Self.reply.utf8)))
        #expect(report.model == "claude-haiku-5-5")
        #expect(report.totalTokens == 33933)
        #expect(report.maxTokens == 1_000_000)
        #expect(report.autoCompactAt == 967_000)
        #expect(report.categories.map(\.id) == ["system_prompt", "system_tools_deferred", "messages", "autocompact_buffer", "free_space"])
        #expect(report.categories[1].kind == "deferred")
        #expect(report.messages == .init(user: 214, assistant: 10, toolCalls: 5, toolResults: 40, attachments: 0, other: 13))
        #expect(report.memoryFiles == [.init(path: "/home/me/.claude/CLAUDE.md", tokens: 3456)])
    }

    @Test func autoCompactionTurnedOffHasNoThreshold() throws {
        let off = Self.reply.replacingOccurrences(of: #""isAutoCompactEnabled":true"#, with: #""isAutoCompactEnabled":false"#)
        #expect(try #require(ContextUsageReport.read(Data(off.utf8))).autoCompactAt == nil)
    }

    @Test func anAnswerWithoutTotalsIsNoAnswer() {
        #expect(ContextUsageReport.read(Data(#"{"categories":[]}"#.utf8)) == nil)
        #expect(ContextUsageReport.read(Data("not json".utf8)) == nil)
    }
}
