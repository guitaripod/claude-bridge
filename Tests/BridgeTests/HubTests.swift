import Foundation
import Testing

@testable import claude_bridge

/// The hub's one promise: every observable change has a position, and a client holding a cursor
/// either replays exactly what it missed or is told the window is gone. No third outcome.
@Suite struct HubTests {
    private func seqs(_ frames: [HubFrame]) -> [UInt64] { frames.map(\.seq) }

    @Test func replayIsExactlyWhatWasMissed() async {
        let hub = Hub()
        for index in 1...5 {
            await hub.publish(.listRemove(id: "s\(index)"))
        }
        let attachment = await hub.attach(sinceEpoch: hub.epoch, sinceSeq: 2)
        #expect(seqs(attachment.replay) == [3, 4, 5])
        #expect(!attachment.tooOld)
        await hub.detach(attachment.id)
    }

    @Test func aForeignEpochIsTooOld() async {
        let hub = Hub()
        await hub.publish(.listRemove(id: "s"))
        let attachment = await hub.attach(sinceEpoch: "another-epoch", sinceSeq: 1)
        #expect(attachment.tooOld)
        #expect(attachment.replay.isEmpty)
        await hub.detach(attachment.id)
    }

    @Test func aCursorOffTheRingIsTooOld() async {
        let hub = Hub()
        for index in 1...9000 {
            await hub.publish(.listRemove(id: "s\(index)"))
        }
        let attachment = await hub.attach(sinceEpoch: hub.epoch, sinceSeq: 3)
        #expect(attachment.tooOld)
        await hub.detach(attachment.id)
    }

    /// A frame published concurrently with an attach lands exactly once: in the replay or in the
    /// live stream, never both, never neither.
    @Test func attachRaceLosesNothingAndDuplicatesNothing() async {
        let hub = Hub()
        await hub.publish(.listRemove(id: "seed"))

        let publisher = Task {
            for index in 0..<500 {
                await hub.publish(.listRemove(id: "p\(index)"))
                if index.isMultiple(of: 50) { await Task.yield() }
            }
        }
        try? await Task.sleep(for: .milliseconds(2))
        let attachment = await hub.attach(sinceEpoch: hub.epoch, sinceSeq: 1)
        await publisher.value
        await hub.publish(.listRemove(id: "fence"))

        var received = seqs(attachment.replay)
        for await frame in attachment.stream {
            received.append(frame.seq)
            if received.count == 500 + 1 { break }
        }
        #expect(received == Array(2...UInt64(502)), "gap or duplicate in \(received.count) frames")
        await hub.detach(attachment.id)
    }

    @Test func heartbeatsReachSubscribersWithoutConsumingSeq() async {
        let hub = Hub()
        let attachment = await hub.attach(sinceEpoch: nil, sinceSeq: nil)
        let before = await hub.seq
        await hub.publishHeartbeat()
        var sawBeat = false
        for await frame in attachment.stream {
            if case .heartbeat(let seq) = frame.event {
                #expect(seq == before)
                sawBeat = true
            }
            break
        }
        #expect(sawBeat)
        #expect(await hub.seq == before)
        await hub.detach(attachment.id)
    }
}
