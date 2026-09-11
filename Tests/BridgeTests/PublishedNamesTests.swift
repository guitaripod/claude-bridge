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

    @Test("A message the store never recorded is a gap, not the end of the pairing")
    func gapInTheFoldIsStepped() {
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
        #expect(named.map(\.id) == ["STORE-U", "fold-s", "STORE-A"])
    }

    /// The duplicate that came back after 5812898: one early turn the two records disagree about,
    /// and every answer after it — including the one the client just watched arrive — was handed
    /// over again under the CLI's own id.
    @Test("One early disagreement no longer renames everything after it")
    func earlyDivergenceDoesNotRenameTheRest() {
        let answer = "These are made-up but plausible wall times for a full suite."
        let stored = [
            message("STORE-U1", .user, "first"),
            message("STORE-A1", .assistant, "a partial the store kept"),
            message("STORE-U2", .user, "make a table"),
            message("STORE-A2", .assistant, answer),
        ]
        let folded = [
            message("fold-u1", .user, "first"),
            message("fold-a1", .assistant, "what the terminal wrote instead, entirely different"),
            message("fold-x", .assistant, "and a second line the store never saw at all"),
            message("fold-u2", .user, "make a table"),
            message("fold-a2", .assistant, answer),
        ]
        let named = SessionStore.named(folded, asPublishedIn: stored)
        #expect(named.map(\.id) == ["STORE-U1", "fold-a1", "fold-x", "STORE-U2", "STORE-A2"])
    }

    @Test("A short word is never evidence enough to jump a gap")
    func shortWordsDoNotAnchor() {
        let stored = [
            message("STORE-U", .user, "go"),
            message("STORE-A", .assistant, "Done."),
            message("STORE-B", .assistant, "Done."),
        ]
        let folded = [
            message("fold-x", .assistant, "something the store never held, long enough to matter"),
            message("fold-b", .assistant, "Done."),
        ]
        let named = SessionStore.named(folded, asPublishedIn: stored)
        #expect(named.map(\.id) == ["fold-x", "fold-b"])
    }

    @Test("A conversation this bridge holds nothing for is left as it is")
    func nothingPublishedChangesNothing() {
        let folded = [message("fold-u", .user, "hello")]
        #expect(SessionStore.named(folded, asPublishedIn: []).map(\.id) == ["fold-u"])
    }
}
