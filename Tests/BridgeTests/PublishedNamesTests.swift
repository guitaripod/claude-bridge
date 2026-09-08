import Foundation
import Testing

@testable import claude_bridge

@Suite("The names a conversation is published under")
struct PublishedNamesTests {
    private func message(_ id: String, _ role: Role, _ text: String) -> Message {
        Message(id: id, role: role, parts: [.text(text)], createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test("The transcript's account keeps the names the client already has")
    func foldWearsPublishedIDs() {
        let stored = [
            message("STORE-U", .user, "hello"),
            message("STORE-A", .assistant, "the answer"),
        ]
        let folded = [
            message("fold-u", .user, "hello"),
            message("fold-a", .assistant, "the answer"),
        ]
        let named = SessionStore.named(folded, asPublishedIn: stored)
        #expect(named.map(\.id) == ["STORE-U", "STORE-A"])
        #expect(named.map { $0.parts.count } == [1, 1])
    }

    @Test("A turn this bridge never saw keeps the only name it has")
    func unpublishedKeepsFoldID() {
        let stored = [message("STORE-U", .user, "hello")]
        let folded = [
            message("fold-u", .user, "hello"),
            message("fold-a", .assistant, "the answer"),
            message("fold-u2", .user, "and again"),
        ]
        let named = SessionStore.named(folded, asPublishedIn: stored)
        #expect(named.map(\.id) == ["STORE-U", "fold-a", "fold-u2"])
    }

    @Test("A partial the store recorded is an opening of the finished answer")
    func partialPairsWithItsFinishedSelf() {
        let stored = [
            message("STORE-U", .user, "hello"),
            message("STORE-A", .assistant, "the ans"),
        ]
        let folded = [
            message("fold-u", .user, "hello"),
            message("fold-a", .assistant, "the answer, whole"),
        ]
        let named = SessionStore.named(folded, asPublishedIn: stored)
        #expect(named.map(\.id) == ["STORE-U", "STORE-A"])
        #expect(SessionStore.named(folded, asPublishedIn: stored)[1].parts.count == 1)
    }

    @Test("Two different messages are never given each other's name")
    func divergenceStopsThePairing() {
        let stored = [
            message("STORE-U", .user, "hello"),
            message("STORE-A", .assistant, "one answer"),
        ]
        let folded = [
            message("fold-u", .user, "hello"),
            message("fold-a", .assistant, "a different answer"),
        ]
        let named = SessionStore.named(folded, asPublishedIn: stored)
        #expect(named.map(\.id) == ["STORE-U", "fold-a"])
    }

    @Test("A role the store never recorded stops the pairing rather than shifting it")
    func roleMismatchStopsThePairing() {
        let stored = [
            message("STORE-U", .user, "hello"),
            message("STORE-A", .assistant, "the answer"),
        ]
        let folded = [
            message("fold-u", .user, "hello"),
            message("fold-s", .system, "a compaction"),
            message("fold-a", .assistant, "the answer"),
        ]
        let named = SessionStore.named(folded, asPublishedIn: stored)
        #expect(named.map(\.id) == ["STORE-U", "fold-s", "fold-a"])
    }

    @Test("A conversation this bridge holds nothing for is left as it is")
    func nothingPublishedChangesNothing() {
        let folded = [message("fold-u", .user, "hello")]
        #expect(SessionStore.named(folded, asPublishedIn: []).map(\.id) == ["fold-u"])
    }
}
