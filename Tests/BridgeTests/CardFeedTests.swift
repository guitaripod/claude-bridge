import Foundation
import Testing

@testable import claude_bridge

private actor Log {
    private(set) var seen: [Int] = []
    func note(_ value: Int) { seen.append(value) }
}

private actor Silent: LiveActivityTransport {
    func pushLiveActivity(
        body: Data, token: String, environment: String, priority: String
    ) async -> (status: Int, reason: String?) { (200, nil) }
}

@Suite("A card hears its turns in order")
struct CardFeedTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Steps reach the pusher in the order they were sent")
    func order() async {
        let feed = CardFeed()
        let log = Log()
        for value in 0..<500 {
            feed.send { await log.note(value) }
        }
        await feed.drained()
        #expect(await log.seen == Array(0..<500))
    }

    @Test("A queued prompt's turn brings back the card its previous turn just settled")
    func queuedTurnRevivesTheCard() async {
        let pusher = LiveActivityPusher(transport: Silent())
        let feed = CardFeed()
        await pusher.register(
            LiveActivityRegistration(
                token: "t", environment: "production", startedAt: start, title: "Port"),
            sessionID: "s", turnOpen: true)
        let ended = start.addingTimeInterval(300)
        let next = ended.addingTimeInterval(0.01)
        feed.send {
            await pusher.endTurn(sessionID: "s", toolCount: 108, ending: .finished, now: ended)
        }
        feed.send { await pusher.noteEvent(.status("running"), sessionID: "s", now: next) }
        await feed.drained()
        let card = await pusher.card("s")
        #expect(card?.isSettled == false)
        #expect(card?.turnOpen == true)
        #expect(card?.startedAt == next)
        #expect(card?.toolCount == 0)
        await pusher.settled()
    }
}
