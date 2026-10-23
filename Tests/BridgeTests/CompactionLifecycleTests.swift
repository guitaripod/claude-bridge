import Foundation
import Testing

@testable import claude_bridge

/// A client holds a compaction as running from the moment it is told one started until it is
/// told one ended, and queues every prompt behind it meanwhile. The bridge is the only thing
/// that knows when that is, so the frames it sends have to open a compaction once and close it
/// for good, whatever order or number of records the CLI wrote it in.
@Suite("Compaction lifecycle")
struct CompactionLifecycleTests {
    private static func status(chars: Int? = nil) -> [String: Any] {
        var object: [String: Any] = ["type": "system", "subtype": "status", "status": "compacting"]
        if let chars { object["compact_output_chars"] = chars }
        return object
    }
    private static var succeeded: [String: Any] {
        ["type": "system", "subtype": "status", "compact_result": "success"]
    }
    private static var failed: [String: Any] {
        ["type": "system", "subtype": "status", "compact_result": "failed"]
    }
    private static var boundary: [String: Any] {
        [
            "type": "system", "subtype": "compact_boundary",
            "compact_metadata": [
                "trigger": "auto", "pre_tokens": 900_000, "post_tokens": 14_000,
                "duration_ms": 70_000,
            ] as [String: Any],
        ]
    }
    private static var result: [String: Any] { ["type": "result", "subtype": "success"] }

    private func run(_ objects: [[String: Any]]) -> (events: [BridgeEvent], assembler: Assembler) {
        var assembler = Assembler(messageID: "X")
        var events: [BridgeEvent] = []
        for object in objects { assembler.ingest(object, emit: { events.append($0) }) }
        return (events, assembler)
    }

    private func phases(_ events: [BridgeEvent]) -> [String] {
        events.compactMap { event in
            if case .compaction(let phase, _) = event { return phase }
            return nil
        }
    }

    private func seams(_ events: [BridgeEvent]) -> [String] {
        Set(
            events.compactMap { event -> String? in
                guard case .messageUpserted(let message) = event, message.role == .system else {
                    return nil
                }
                return message.id
            }
        ).sorted()
    }

    @Test("The progress an automatic compaction repeats is not a second start")
    func progressIsNotAStart() {
        let ran = run([
            Self.status(chars: 0), Self.status(chars: 800), Self.status(chars: 4_000),
            Self.succeeded, Self.boundary, Self.result,
        ])
        #expect(phases(ran.events) == ["started", "finished"])
    }

    @Test("A progress report that outlives the finish does not reopen the compaction")
    func lateProgressIsIgnored() {
        let ran = run([
            Self.status(chars: 0), Self.succeeded, Self.status(chars: 12_000), Self.boundary,
            Self.status(chars: 12_500), Self.result,
        ])
        #expect(phases(ran.events) == ["started", "finished"])
    }

    @Test("A second compaction in one turn is announced again")
    func aSecondAttemptStartsAgain() {
        let ran = run([
            Self.status(chars: 0), Self.succeeded, Self.boundary,
            Self.status(chars: 0), Self.succeeded, Self.boundary, Self.result,
        ])
        #expect(phases(ran.events) == ["started", "finished", "started", "finished"])
        #expect(seams(ran.events).count == 2)
    }

    @Test("A boundary that lands before the result is one seam, not two")
    func boundaryFirstIsOneSeam() {
        let ran = run([Self.status(), Self.boundary, Self.succeeded, Self.result])
        #expect(seams(ran.events).count == 1)
        #expect(ran.assembler.finalMessages().filter { $0.role == .system }.count == 1)
        #expect(phases(ran.events) == ["started", "finished"])
    }

    @Test("A boundary with no status of its own still draws one seam and ends nothing it never began")
    func boundaryAlone() {
        let ran = run([Self.boundary, Self.result])
        #expect(seams(ran.events).count == 1)
        #expect(phases(ran.events).isEmpty)
    }

    @Test("A result that names a failure is a failure, not a seam")
    func failedResultDrawsNoSeam() {
        let ran = run([Self.status(), Self.failed, Self.result])
        #expect(phases(ran.events) == ["started", "failed"])
        #expect(seams(ran.events).isEmpty)
        #expect(!ran.assembler.didCompact)
    }

    @Test("A turn that closes on a compaction nobody finished says the compaction failed")
    func theTurnEndingClosesTheCompaction() {
        let ran = run([Self.status(chars: 0), Self.status(chars: 900), Self.result])
        #expect(phases(ran.events) == ["started", "failed"])
        guard case .compaction(_, let error)? = ran.events.last else {
            Issue.record("the last frame was not a compaction")
            return
        }
        #expect(error == Assembler.unfinishedCompaction)
    }

    @Test("A process that dies mid-compaction closes it the same way, and a stop only clears it")
    func aTurnCutShortClosesTheCompaction() {
        var cut = run([Self.status(chars: 0)])
        var events: [BridgeEvent] = []
        cut.assembler.closeOpenCompaction(stopped: false, emit: { events.append($0) })
        #expect(phases(events) == ["failed"])

        var stopped = run([Self.status(chars: 0)])
        events = []
        stopped.assembler.closeOpenCompaction(stopped: true, emit: { events.append($0) })
        #expect(phases(events) == ["finished"])
        stopped.assembler.closeOpenCompaction(stopped: true, emit: { events.append($0) })
        #expect(phases(events) == ["finished"])
    }
}
