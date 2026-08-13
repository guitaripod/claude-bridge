import Foundation
import Testing

@testable import claude_bridge

@Suite struct OpenCodeGoUsageTests {
    @Test func liveSnapshotMapsEveryWindow() throws {
        let snapshot = try OpenCodeGoUsage.parseLive([
            "rolling": ["status": "ok", "percent": 10, "resetsAt": "2026-08-13T16:35:31.733Z"],
            "weekly": ["status": "ok", "percent": 95, "resetsAt": "2026-08-17T00:00:00.405Z"],
            "monthly": ["status": "ok", "percent": 47, "resetsAt": "2026-09-07T21:43:55.405Z"],
        ])
        #expect(snapshot.live)
        #expect(snapshot.providerName == "opencode go")
        #expect(snapshot.source.contains("live"))
        #expect(snapshot.gauges.count == 3)

        let rolling = snapshot.gauges[0]
        #expect(rolling.key == "rolling")
        #expect(rolling.label == "5-hour")
        #expect(rolling.fraction == 0.1)
        #expect(rolling.usedUSD == 1.2)
        #expect(rolling.limitUSD == 12)
        #expect(rolling.trustedReset)
        #expect(rolling.resetsAt == "2026-08-13T16:35:31Z")

        let weekly = snapshot.gauges[1]
        #expect(weekly.fraction == 0.95)
        #expect(weekly.usedUSD == 28.5)
        #expect(weekly.limitUSD == 30)

        let monthly = snapshot.gauges[2]
        #expect(monthly.fraction == 0.47)
        #expect(monthly.usedUSD == 28.2)
        #expect(monthly.limitUSD == 60)
    }

    @Test func aWalledWindowReadsAsExhausted() throws {
        let snapshot = try OpenCodeGoUsage.parseLive([
            "rolling": ["status": "limit", "percent": 100],
        ])
        #expect(snapshot.gauges.count == 1)
        #expect(snapshot.gauges[0].fraction == 1)
    }

    @Test func missingWindowsAreSkippedAndNothingIsInvented() throws {
        let snapshot = try OpenCodeGoUsage.parseLive([
            "weekly": ["status": "ok", "percent": 12],
        ])
        #expect(snapshot.gauges.count == 1)
        #expect(snapshot.gauges[0].key == "weekly")
        #expect(snapshot.gauges[0].fraction == 0.12)
    }

    @Test func noWindowsIsAFailure() {
        #expect(throws: (any Error).self) {
            try OpenCodeGoUsage.parseLive([:])
        }
    }

    @Test func theGoKeyComesFromOpencodesAuthFile() throws {
        let dir = fixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opencode = dir.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: opencode, withIntermediateDirectories: true)
        let auth = ["opencode-go": ["type": "api", "key": "sk-test-key"]]
        try JSONSerialization.data(withJSONObject: auth)
            .write(to: opencode.appendingPathComponent("auth.json"))
        setenv("XDG_DATA_HOME", dir.path, 1)
        defer { unsetenv("XDG_DATA_HOME") }
        #expect(OpenCodeGoUsage.goKey() == "sk-test-key")
    }

    @Test func noGoAccountIsNoKey() throws {
        let dir = fixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("XDG_DATA_HOME", dir.path, 1)
        defer { unsetenv("XDG_DATA_HOME") }
        #expect(OpenCodeGoUsage.goKey() == nil)
    }

    private func fixtureDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("go-usage-tests-\(UUID().uuidString)")
    }
}
