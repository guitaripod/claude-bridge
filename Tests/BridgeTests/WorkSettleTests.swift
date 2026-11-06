import Foundation
import Testing

@testable import claude_bridge

@Suite("A push waits for the work to be over, as each device asked")
struct WorkSettleTests {
    private let t0 = Date(timeIntervalSince1970: 1_900_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func ending(
        _ seconds: TimeInterval, failed: Bool = false, kind: CardDetail = .finished
    ) -> PendingEnding {
        PendingEnding(
            title: "Fix the queue", claudeID: "c1", failed: failed,
            ending: TurnWaitEnding(settled: kind), endedAt: at(seconds), lastMessageID: "m\(Int(seconds))",
            notice: NoticePush.additions(
                sessionID: "S1", messages: [], settled: kind, duration: 1, toolCount: 1,
                prompt: nil, server: nil))
    }

    private func device(_ token: String, _ rules: DeviceRules?) -> DeviceRegistration {
        DeviceRegistration(token: token, environment: "production", lastSeenAt: at(0), rules: rules)
    }

    @Test("A device with no rules hears only settled work, and a newer finish it cannot read is the default")
    func standardAndTolerantRules() throws {
        let decoded = try JSONDecoder().decode(
            DeviceRules.self, from: Data(#"{"finish":"whenTheMoonIsFull","minimumWork":30}"#.utf8))
        #expect(decoded.finish == .settled)
        #expect(decoded.minimumWork == 30)
        let old = try JSONDecoder().decode(
            DeviceRegisterRequest.self, from: Data(#"{"token":"t","environment":"production"}"#.utf8))
        #expect(old.rules == nil)
    }

    @Test("Each device hears finished work once: every-turn devices as the turn closes, the rest when it settles")
    func recipientsByOccasion() {
        let devices = [
            device("standard", nil),
            device("turns", DeviceRules(finish: .everyTurn)),
            device("long", DeviceRules(finish: .settled, minimumWork: 600)),
            device("failures", DeviceRules(finish: .failures)),
            device("muted", DeviceRules(finish: .settled, muted: ["S1"])),
            device("deaf", DeviceRules(finish: .never, needsYou: false)),
        ]
        func tokens(_ kind: NoticePush.Kind, _ occasion: DevicePusher.Occasion, failed: Bool = false, length: TimeInterval = 120) -> [String] {
            DevicePusher.recipients(
                devices, kind: kind, occasion: occasion, failed: failed, length: length,
                sessionID: "S1"
            ).map(\.token).sorted()
        }
        #expect(tokens(.done, .turnClosed) == ["turns"])
        #expect(tokens(.done, .workSettled) == ["standard"])
        #expect(tokens(.failed, .workSettled, failed: true, length: 3) == ["failures", "long", "standard"])
        #expect(tokens(.question, .turnClosed) == ["failures", "long", "muted", "standard", "turns"])
        #expect(tokens(.question, .workSettled).isEmpty)
    }

    @Test("A turn that leaves background work behind is not the end; the stretch spans every turn in it")
    func spanAcrossTurns() {
        var spans = WorkSpans()
        spans.turnEnded("S1", began: at(0), tools: 4, ending: ending(60))
        #expect(spans.reading("S1", working: true, now: at(600)) == .working)
        #expect(spans.settle("S1", working: true, now: at(600)) == nil)
        spans.turnEnded("S1", began: at(900), tools: 3, ending: ending(960))
        #expect(spans.reading("S1", working: false, now: at(965)) == .working)
        let settled = spans.settle("S1", working: false, now: at(960 + WorkSettle.grace))
        #expect(settled?.0.length == 960)
        #expect(settled?.0.tools == 7)
        #expect(settled?.0.lastMessageID == "m960")
        #expect(spans.settle("S1", working: false, now: at(2000)) == nil)
        guard case .settled(let done) = spans.reading("S1", working: false, now: at(2000)) else {
            Issue.record("a settled stretch reads settled")
            return
        }
        #expect(done?.tools == 7)
    }

    @Test("Background work that ends without a turn starts the grace from when it stopped")
    func quietWithoutATurn() {
        var spans = WorkSpans()
        spans.turnEnded("S1", began: at(0), tools: 1, ending: ending(30))
        spans.workStopped("S1", at: at(500))
        #expect(spans.due("S1") == at(500 + WorkSettle.grace))
        #expect(spans.settle("S1", working: false, now: at(505)) == nil)
        let settled = spans.settle("S1", working: false, now: at(511))
        #expect(settled?.0.length == 500)
        #expect(settled?.0.endedAt == at(500))
    }

    @Test("A turn that stops to ask ends the stretch: the answer starts new work")
    func askEndsTheSpan() {
        var spans = WorkSpans()
        spans.turnEnded("S1", began: at(0), tools: 1, ending: ending(30))
        spans.waitsOnPerson("S1")
        #expect(spans.waiting.isEmpty)
        #expect(spans.reading("S1", working: false, now: at(100)) == .settled(nil))
    }

    @Test("A wait held for settled work holds through background work and speaks for the whole stretch")
    func settledWait() {
        let last = LastTurnEnding(
            ending: .finished, title: "Fix the queue", toolCount: 3, duration: 12,
            lastMessageID: "m1", endedAt: at(60))
        let plain = TurnWaitResolution.reading(turnOpen: false, lastEnding: last, background: 2)
        #expect(TurnWaitResolution.settled(plain, .working) == nil)
        let done = SettledWork(
            ending: .finished, failed: false, title: "Fix the queue", length: 960, tools: 7,
            endedAt: at(960), lastMessageID: "m9")
        let held = TurnWaitResolution.settled(plain, .settled(done))
        #expect(held?.settled == true)
        #expect(held?.duration == 960)
        #expect(held?.toolCount == 7)
        #expect(held?.background == nil)
        let question = LastTurnEnding(
            ending: .question, title: "Pick", toolCount: 1, duration: nil, lastMessageID: nil,
            endedAt: at(60))
        let ask = TurnWaitResolution.reading(turnOpen: false, lastEnding: question, background: nil)
        #expect(TurnWaitResolution.settled(ask, .working)?.state == .needsYou)
        #expect(TurnWaitResolution.settled(nil, .settled(nil)) == nil)
    }
}
