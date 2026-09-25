import Foundation
import Testing

@testable import claude_bridge

/// `/sessions/:id/wait` is built from one pure rule (``TurnWaitResolution``) plus a wire shape
/// that tolerates the heartbeat newlines it is written after; these tests cover both without
/// spinning up the HTTP route itself, which only adds polling and a clock around this decision.
@Suite("A wait resolves the moment a turn stops owing the person nothing")
struct TurnWaitTests {
    private let ended = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A session with nothing open answers at once, with nothing to say")
    func alreadyIdleWithNoHistory() {
        let reading = TurnWaitResolution.reading(
            turnOpen: false, lastEnding: nil, background: nil)
        #expect(reading?.state == .ended)
        #expect(reading?.waited == false)
        #expect(reading?.ending == nil)
    }

    @Test("A turn that is still open answers nothing — the wait must keep holding")
    func stillOpenHoldsTheWait() {
        let last = LastTurnEnding(
            ending: .finished, title: "Fix the queue", toolCount: 3, duration: 12,
            lastMessageID: "m1", endedAt: ended)
        #expect(TurnWaitResolution.reading(turnOpen: true, lastEnding: last, background: nil) == nil)
    }

    @Test("A turn that finished resolves with its ending and everything recorded about it")
    func finishedTurnResolves() {
        let last = LastTurnEnding(
            ending: .finished, title: "Fix the queue", toolCount: 3, duration: 12.5,
            lastMessageID: "m1", endedAt: ended)
        let reading = TurnWaitResolution.reading(turnOpen: false, lastEnding: last, background: 2)
        #expect(reading?.state == .ended)
        #expect(reading?.ending == .finished)
        #expect(reading?.title == "Fix the queue")
        #expect(reading?.toolCount == 3)
        #expect(reading?.duration == 12.5)
        #expect(reading?.lastMessageID == "m1")
        #expect(reading?.endedAt == ended)
        #expect(reading?.background == 2)
    }

    @Test("A turn cut off by a stop reads as cancelled, and a failure as failed")
    func stoppedAndFailedReadTheirOwnEnding() {
        let card = CardDetail.settled(ending: .finished, stopped: true, failed: false)
        #expect(TurnWaitEnding(settled: card) == .cancelled)
        let failedCard = CardDetail.settled(ending: .finished, stopped: false, failed: true)
        #expect(TurnWaitEnding(settled: failedCard) == .failed)
    }

    @Test("A turn that ended on a question resolves needsYou, not ended")
    func questionResolvesNeedsYou() {
        let last = LastTurnEnding(
            ending: .question, title: "Pick a plan", toolCount: 1, duration: nil,
            lastMessageID: nil, endedAt: ended)
        let reading = TurnWaitResolution.reading(turnOpen: false, lastEnding: last, background: nil)
        #expect(reading?.state == .needsYou)
        #expect(reading?.ending == .question)
    }

    @Test("An interrupted turn always reads interrupted, whatever was pressed or reported")
    func interruptedOutranksStoppedAndFailed() {
        #expect(
            TurnWaitEnding(settled: CardDetail.settled(ending: .interrupted, stopped: true, failed: true))
                == .interrupted)
    }

    @Test("The hold that reached its cap answers running, and says it waited")
    func cappedAnswersRunning() {
        let capped = TurnWaitResolution.capped()
        #expect(capped.state == .running)
        #expect(capped.waited == true)
        #expect(capped.ending == nil)
    }

    @Test("Every optional field is left out of the wire rather than written null")
    func omittedFieldsStayOmitted() throws {
        let data = try JSONCoding.encoder.encode(TurnWait(state: .running, waited: true))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("null"))
        #expect(text.contains("\"state\":\"running\""))
        #expect(text.contains("\"waited\":true"))
    }

    @Test("A body written after the heartbeat's leading whitespace still decodes")
    func leadingWhitespaceDecodes() throws {
        let body = TurnWait(
            state: .ended, waited: true, ending: .finished, title: "Fix the queue", toolCount: 2,
            background: nil, duration: 30, lastMessageID: "m9", endedAt: ended)
        let payload = try JSONCoding.encoder.encode(body)
        let framed = Data("\n\n".utf8) + payload
        let decoded = try JSONCoding.decoder.decode(TurnWait.self, from: framed)
        #expect(decoded == body)
    }
}
