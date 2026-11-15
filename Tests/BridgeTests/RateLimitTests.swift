import Foundation
import Testing

@testable import claude_bridge

@Suite struct RateLimitTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private var weekReset: Date { now.addingTimeInterval(4 * 86_400) }

    private func event(
        status: String, type: String = "seven_day", utilization: Double?, reset: Date,
        windowStatus: String = "allowed"
    ) -> [String: Any] {
        var window: [String: Any] = ["resetsAt": reset.timeIntervalSince1970, "status": windowStatus]
        if let utilization { window["utilization"] = utilization }
        return [
            "type": "rate_limit_event",
            "rate_limit_info": [
                "status": status, "resetsAt": reset.timeIntervalSince1970, "rateLimitType": type,
                "overageStatus": "rejected", "isUsingOverage": false,
                "unifiedWindows": ["seven_day": window],
            ] as [String: Any],
            "uuid": "u", "session_id": "s",
        ]
    }

    private func weekly(_ fraction: Double, reset: Date? = nil) -> UsageGauge {
        UsageGauge(
            key: "weekly_all", label: "Weekly · all models", fraction: fraction,
            resetsAt: BridgeTimestamps.string(reset ?? weekReset), trustedReset: true)
    }

    private func reading(
        _ object: [String: Any], at date: Date
    ) throws -> RateLimitReading {
        try #require(RateLimitReading(event: object, now: date))
    }

    @Test func readsTheEventTheCLIStreams() throws {
        let reading = try reading(
            event(status: "allowed", utilization: 0.9953, reset: weekReset), at: now)
        #expect(reading.status == "allowed")
        #expect(reading.limitingWindow == "seven_day")
        #expect(reading.windows["seven_day"]?.utilization == 0.9953)
        #expect(reading.windows["seven_day"]?.resetsAt == weekReset)
        #expect(reading.answers)
        #expect(!reading.refuses("seven_day"))
        #expect(RateLimitReading(event: ["type": "assistant"], now: now) == nil)
    }

    @Test func aRoundedWallThatIsStillAnsweringReadsItsTrueFigure() throws {
        let reading = try reading(
            event(status: "allowed", utilization: 0.9953, reset: weekReset),
            at: now.addingTimeInterval(-600))
        let served = RateLimitOverlay.apply(
            [weekly(1.0)], readAt: now.addingTimeInterval(-30), reading: reading, now: now)
        #expect(served[0].fraction == 0.9953)
    }

    @Test func aRefusedWindowIsUsedUpWhateverTheRoundingSays() throws {
        let reading = try reading(
            event(status: "rejected", utilization: 0.996, reset: weekReset, windowStatus: "rejected"),
            at: now)
        let served = RateLimitOverlay.apply(
            [weekly(0.99)], readAt: now.addingTimeInterval(-40), reading: reading, now: now)
        #expect(served[0].fraction == 1)
        #expect(served[0].refused == true)
    }

    @Test func aWindowPastItsCapThatIsStillAnsweredIsNotAWall() throws {
        let reading = try reading(
            event(status: "allowed", utilization: 1.02, reset: weekReset, windowStatus: "rejected"),
            at: now)
        let served = RateLimitOverlay.apply(
            [weekly(1.0)], readAt: now.addingTimeInterval(-40), reading: reading, now: now)
        #expect(served[0].fraction == RateLimitOverlay.answeringPastCap)
        #expect(served[0].fraction < 1)
        #expect(served[0].refused == false)
    }

    @Test func aNewerEndpointReadingAfterAnEarlyResetOutranksAnOldRefusal() throws {
        let reading = try reading(
            event(status: "rejected", utilization: 1.0, reset: weekReset, windowStatus: "rejected"),
            at: now.addingTimeInterval(-180))
        let served = RateLimitOverlay.apply(
            [weekly(0)], readAt: now.addingTimeInterval(-10), reading: reading, now: now)
        #expect(served[0].fraction == 0)
        #expect(served[0].refused == nil)
    }

    @Test func aTurnThatSawTheNextWindowReplacesAnEndedReading() throws {
        let ended = now.addingTimeInterval(-120)
        let next = ended.addingTimeInterval(7 * 86_400)
        let reading = try reading(
            event(status: "allowed", utilization: 0.01, reset: next), at: now.addingTimeInterval(-30))
        let served = RateLimitOverlay.apply(
            [weekly(1.0, reset: ended)], readAt: now.addingTimeInterval(-600), reading: reading,
            now: now)
        #expect(served[0].fraction == 0.01)
        #expect(served[0].resetsAt == BridgeTimestamps.string(next))
    }

    @Test func anOldOrDisagreeingTurnReadingChangesNothing() throws {
        let stale = try reading(
            event(status: "allowed", utilization: 0.4, reset: weekReset),
            at: now.addingTimeInterval(-2 * 3600))
        #expect(
            RateLimitOverlay.apply([weekly(0.42)], readAt: now, reading: stale, now: now)[0].fraction
                == 0.42)
        let older = try reading(
            event(status: "allowed", utilization: 0.4, reset: weekReset),
            at: now.addingTimeInterval(-600))
        #expect(
            RateLimitOverlay.apply([weekly(0.47)], readAt: now, reading: older, now: now)[0].fraction
                == 0.47)
    }

    @Test func onlyTheWindowsATurnMeasuresAreTouched() throws {
        let reading = try reading(
            event(status: "rejected", utilization: 1, reset: weekReset, windowStatus: "rejected"),
            at: now)
        let scoped = UsageGauge(
            key: "weekly_scoped", label: "Weekly · Fable", fraction: 0.5,
            resetsAt: BridgeTimestamps.string(weekReset), trustedReset: true)
        let served = RateLimitOverlay.apply(
            [scoped], readAt: now.addingTimeInterval(-30), reading: reading, now: now)
        #expect(served[0].fraction == 0.5)
    }

    @Test func theLedgerKeepsTheNewestReadingAndItsFigures() async throws {
        let ledger = RateLimitLedger()
        let first = try reading(
            event(status: "allowed", utilization: 0.5, reset: weekReset), at: now)
        await ledger.note(first)
        let bare = RateLimitReading(
            observedAt: now.addingTimeInterval(10), status: "rejected",
            limitingWindow: "seven_day", limitingResetsAt: weekReset, windows: [:])
        await ledger.note(bare)
        let older = try reading(
            event(status: "allowed", utilization: 0.1, reset: weekReset),
            at: now.addingTimeInterval(-10))
        await ledger.note(older)
        let latest = try #require(await ledger.latest)
        #expect(latest.status == "rejected")
        #expect(latest.windows["seven_day"]?.utilization == 0.5)
    }

    @Test func aBareVerdictDoesNotInheritAWindowThatHasEnded() async throws {
        let ledger = RateLimitLedger()
        let ended = now.addingTimeInterval(-60)
        await ledger.note(
            try reading(
                event(status: "rejected", utilization: 1, reset: ended, windowStatus: "rejected"),
                at: now.addingTimeInterval(-600)))
        await ledger.note(
            RateLimitReading(
                observedAt: now, status: "allowed", limitingWindow: "seven_day",
                limitingResetsAt: weekReset, windows: [:]))
        let latest = try #require(await ledger.latest)
        #expect(latest.windows.isEmpty)
        #expect(latest.window("seven_day")?.resetsAt == weekReset)
    }

    @Test func aCachedReadingServesAWeekWhoseResetPassedAsReset() {
        let reset = now.addingTimeInterval(-30)
        let served = ClaudeUsage.cached(
            UsageSnapshot(
                providerName: "Claude", subtitle: "Max", source: "api.anthropic.com · live",
                live: true, gauges: [weekly(1.0, reset: reset), weekly(0.4)], details: []),
            now: now)
        #expect(!served.live)
        #expect(served.source.hasSuffix("cached"))
        #expect(served.gauges[0].fraction == 0)
        #expect(served.gauges[0].resetsAt == nil)
        #expect(served.gauges[0].startsAt == BridgeTimestamps.string(reset))
        #expect(served.gauges[1].fraction == 0.4)
    }

    @Test func theEndpointsUnroundedFigureIsPreferredWhereItAgrees() {
        let json: [String: Any] = [
            "seven_day": ["utilization": 99.6, "resets_at": "2026-11-19T21:00:00.444287+00:00"],
            "limits": [
                [
                    "kind": "weekly_all", "group": "weekly", "percent": 100, "severity": "critical",
                    "resets_at": "2026-11-19T21:00:00.444287+00:00", "is_active": true,
                ] as [String: Any],
                [
                    "kind": "weekly_scoped", "group": "weekly", "percent": 40, "severity": "normal",
                    "resets_at": "2026-11-19T21:00:00+00:00", "is_active": false,
                    "scope": ["model": ["display_name": "Fable"]],
                ] as [String: Any],
            ],
        ]
        let gauges = ClaudeUsage.gauges(from: json)
        #expect(gauges.count == 2)
        #expect(abs(gauges[0].fraction - 0.996) < 1e-9)
        #expect(gauges[0].trustedReset)
        #expect(gauges[0].resetsAt == "2026-11-19T21:00:00Z")
        #expect(gauges[1].fraction == 0.4)
        #expect(gauges[1].label == "Weekly · Fable")
    }

    @Test func aReadingWithAWindowThatHasResetIsAPictureOfTheEndedWindow() {
        let snapshot = UsageSnapshot(
            providerName: "Claude", subtitle: "Max", source: "api.anthropic.com · live", live: true,
            gauges: [weekly(1.0, reset: now.addingTimeInterval(-5))], details: [])
        #expect(snapshot.hasReset(after: now.addingTimeInterval(-60), by: now))
        #expect(!snapshot.hasReset(after: now.addingTimeInterval(-60), by: now.addingTimeInterval(-30)))
        #expect(!snapshot.hasReset(after: now.addingTimeInterval(-1), by: now))
    }

    @Test func aBackedOffCacheStillReadsOnceAfterAReset() async {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rate-limit-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = UsageSnapshotCache(name: "claude", directory: directory)
        let reset = Date().addingTimeInterval(-5)
        await cache.store(
            UsageSnapshot(
                providerName: "Claude", subtitle: "Max", source: "api.anthropic.com · live",
                live: true, gauges: [weekly(1.0, reset: reset)], details: []))
        await cache.noteAttempt(at: reset.addingTimeInterval(-60))
        await cache.noteFailure()
        #expect(await cache.inBackoff)
        #expect(await cache.owesReadAfterReset(now: Date()))
        await cache.noteAttempt(at: Date())
        #expect(!(await cache.owesReadAfterReset(now: Date())))
    }
}
