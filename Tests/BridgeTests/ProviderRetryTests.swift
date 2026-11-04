import Foundation
import Testing

@testable import claude_bridge

/// A request to Anthropic that fails and is tried again leaves the turn open and silent for as
/// long as the CLI waits. The CLI says so on every attempt; the bridge has to pass that on as a
/// state that opens with the first report and closes the moment an attempt answers or the turn
/// ends, so a client never shows a wait that is over or misses one that is happening.
@Suite("Provider retry")
struct ProviderRetryTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func retry(
        attempt: Int, delayMs: Int = 8000, error: String? = "overloaded", status: Int? = 529,
        waitedMs: Int? = nil
    ) -> [String: Any] {
        var object: [String: Any] = [
            "type": "system", "subtype": "api_retry", "attempt": attempt, "max_retries": 10,
            "retry_delay_ms": delayMs,
        ]
        if let error { object["error"] = error }
        object["error_status"] = status.map { $0 as Any } ?? NSNull()
        if let waitedMs { object["no_response"] = ["waited_ms": waitedMs, "retry_wait_ms": 2000] }
        return object
    }

    private static var textStart: [String: Any] {
        [
            "type": "stream_event",
            "event": [
                "type": "content_block_start", "index": 0,
                "content_block": ["type": "text", "text": ""],
            ] as [String: Any],
        ]
    }

    private static var result: [String: Any] { ["type": "result", "subtype": "success"] }

    private func waits(_ objects: [[String: Any]]) -> [RetryWait?] {
        var assembler = Assembler(messageID: "X")
        var events: [BridgeEvent] = []
        for object in objects {
            assembler.ingest(object, now: Self.now, emit: { events.append($0) })
        }
        return events.compactMap { event -> RetryWait?? in
            if case .retry(let wait) = event { return .some(wait) }
            return nil
        }
    }

    @Test("Each attempt replaces the wait, and the next answer ends it once")
    func attemptsThenAnswer() throws {
        let seen = waits([Self.retry(attempt: 1), Self.retry(attempt: 2, delayMs: 16000), Self.textStart, Self.textStart])
        #expect(seen.count == 3)
        let first = try #require(seen[0])
        #expect(first.attempt == 1)
        #expect(first.maxRetries == 10)
        #expect(first.status == 529)
        #expect(first.nextAttemptAt == Self.now.addingTimeInterval(8))
        #expect(first.reason == "Anthropic's API is overloaded (529)")
        #expect(seen[1]?.attempt == 2)
        #expect(seen[1]?.nextAttemptAt == Self.now.addingTimeInterval(16))
        #expect(seen[2] == nil)
    }

    @Test("A turn that ends while waiting closes the wait")
    func resultEndsTheWait() {
        let seen = waits([Self.retry(attempt: 3), Self.result])
        #expect(seen.count == 2)
        #expect(seen.last! == nil)
    }

    @Test("A turn that never waited says nothing about waiting")
    func noRetryNoFrames() {
        #expect(waits([Self.textStart, Self.result]).isEmpty)
    }

    @Test("A request nobody answered says how long it waited")
    func noResponse() {
        let seen = waits([Self.retry(attempt: 1, error: nil, status: nil, waitedMs: 60_400)])
        #expect(seen.first??.reason == "Anthropic's API did not answer for 60 s")
        #expect(seen.first??.status == nil)
    }

    @Test("The frame a client reads carries the wait, and the end of one carries none")
    func wireShape() throws {
        let wait = RetryWait(
            attempt: 2, maxRetries: 10, reason: "Anthropic is rate limiting requests (429)",
            status: 429, nextAttemptAt: Self.now)
        let open = try JSONSerialization.jsonObject(
            with: JSONCoding.encoder.encode(BridgeEvent.retry(wait))) as? [String: Any]
        #expect(open?["type"] as? String == "retry")
        let body = open?["retry"] as? [String: Any]
        #expect(body?["attempt"] as? Int == 2)
        #expect(body?["reason"] as? String == "Anthropic is rate limiting requests (429)")
        #expect(body?["nextAttemptAt"] as? String == "2027-01-15T08:00:00Z")
        let closed = try JSONSerialization.jsonObject(
            with: JSONCoding.encoder.encode(BridgeEvent.retry(nil))) as? [String: Any]
        #expect(closed?["type"] as? String == "retry")
        #expect(closed?["retry"] == nil)
        let decoded = try JSONCoding.decoder.decode(
            BridgeEvent.self, from: JSONCoding.encoder.encode(BridgeEvent.retry(wait)))
        guard case .retry(let back) = decoded else {
            Issue.record("decoded \(decoded)")
            return
        }
        #expect(back == wait)
    }
}
