import Foundation
import Testing

@testable import claude_bridge

/// Which lines from a conversation's process start a turn the CLI began by itself. A background
/// agent goes on speaking on the parent's stdout after the parent's turn has closed; those lines
/// are the agent's, and a turn opened for them held the chat busy, with every message sent to it
/// waiting, until the agent finished.
@Suite("Lines that start a turn nobody typed")
struct UnsolicitedTurnTests {
    private func object(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    @Test("the parent speaking, or its process starting, opens a turn")
    func parentLinesOpen() {
        #expect(
            SessionStore.opensTurn(
                object(
                    #"{"type":"assistant","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"The agent finished."}]}}"#
                )))
        #expect(
            SessionStore.opensTurn(
                object(
                    #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"message_start"}}"#
                )))
        #expect(SessionStore.opensTurn(object(#"{"type":"system","subtype":"init"}"#)))
    }

    @Test("a background agent speaking after the parent's result does not")
    func subagentLinesDoNot() {
        #expect(
            !SessionStore.opensTurn(
                object(
                    #"{"type":"assistant","parent_tool_use_id":"toolu_014Axch5EzrBPk9QwEJvwVdq","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"s"}]}}"#
                )))
        #expect(
            !SessionStore.opensTurn(
                object(
                    #"{"type":"stream_event","parent_tool_use_id":"toolu_014Axch5EzrBPk9QwEJvwVdq","event":{"type":"message_start"}}"#
                )))
        #expect(
            !SessionStore.opensTurn(
                object(
                    #"{"type":"user","parent_tool_use_id":"toolu_014Axch5EzrBPk9QwEJvwVdq","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"done"}]}}"#
                )))
    }

    @Test("the CLI's bookkeeping and a lone result never do")
    func bookkeepingDoesNot() {
        #expect(!SessionStore.opensTurn(object(#"{"type":"system","subtype":"task_notification"}"#)))
        #expect(!SessionStore.opensTurn(object(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#)))
        #expect(!SessionStore.opensTurn(object(#"{"type":"result","subtype":"success"}"#)))
    }
}
