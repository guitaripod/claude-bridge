import Foundation
import Testing

@testable import claude_bridge

@Suite struct OpenCodeGoUsageTests {
    @Test func statusMapsGoWindowsWithExactMoney() throws {
        let snapshot = try OpenCodeGoUsage.parseStatus(statusJSON(product: "go"))

        #expect(snapshot.live)
        #expect(snapshot.providerName == "opencode go")
        #expect(snapshot.subtitle == "Go")
        #expect(snapshot.source.contains("console"))
        #expect(snapshot.error == nil)
        #expect(snapshot.details.contains { $0.key == "Extra usage" && $0.value == "Off" })
        #expect(snapshot.details.contains { $0.key == "Renews" && $0.value == "Yes" })
        #expect(snapshot.gauges.count == 3)

        let session = snapshot.gauges[0]
        #expect(session.key == "five_hour")
        #expect(session.label == "5-hour session")
        #expect(session.fraction == 0.2)
        #expect(session.usedUSD == 2.4)
        #expect(session.limitUSD == 12)
        #expect(session.trustedReset)
        #expect(session.startsAt == "2026-10-19T16:35:31Z")
        #expect(session.resetsAt == "2026-10-19T21:35:31Z")

        let weekly = snapshot.gauges[1]
        #expect(weekly.key == "weekly")
        #expect(weekly.fraction == 0.95)
        #expect(weekly.usedUSD == 28.5)
        #expect(weekly.limitUSD == 30)

        let monthly = snapshot.gauges[2]
        #expect(monthly.key == "monthly")
        #expect(monthly.fraction == 0.47)
        #expect(monthly.usedUSD == 28.2)
        #expect(monthly.limitUSD == 60)
        #expect(monthly.startsAt == "2026-10-07T21:43:55Z")
    }

    @Test func statusNamesGoPlusAndUsesItsOwnCeilings() throws {
        let snapshot = try OpenCodeGoUsage.parseStatus(statusJSON(product: "go-plus"))

        #expect(snapshot.subtitle == "Go Plus")
        #expect(snapshot.gauges[0].limitUSD == 48)
        #expect(snapshot.gauges[1].limitUSD == 120)
        #expect(snapshot.gauges[2].limitUSD == 240)
        #expect(snapshot.gauges[0].usedUSD == 9.6)
        #expect(snapshot.gauges[1].usedUSD == 114)
        #expect(snapshot.gauges[2].usedUSD == 112.8)
    }

    @Test func statusReadsStringAndNumericMicroCents() throws {
        let data = Data(
            #"""
            {
              "product": "go",
              "access": {
                "meters": {
                  "fiveHour": {
                    "usedMicroCents": 1200000000,
                    "limitMicroCents": "1200000000",
                    "resetsAt": 1792445731733
                  }
                }
              }
            }
            """#.utf8)
        let snapshot = try OpenCodeGoUsage.parseStatus(data)

        #expect(snapshot.gauges.count == 1)
        #expect(snapshot.gauges[0].fraction == 1)
        #expect(snapshot.gauges[0].usedUSD == 12)
        #expect(snapshot.gauges[0].limitUSD == 12)
        #expect(snapshot.gauges[0].resetsAt == "2026-10-19T21:35:31Z")
    }

    @Test func zenMapsPercentWithoutInventingMoney() throws {
        let data = Data(
            #"""
            {
              "usage": {
                "rolling": {
                  "status": "ok",
                  "percent": 10,
                  "resetsAt": "2026-10-19T21:35:31.733Z"
                },
                "weekly": {
                  "status": "ok",
                  "percent": 95,
                  "resetsAt": "2026-10-25T00:00:00.405Z"
                },
                "monthly": {
                  "status": "ok",
                  "percent": 47,
                  "resetsAt": "2026-11-07T21:43:55.405Z"
                }
              }
            }
            """#.utf8)
        let snapshot = try OpenCodeGoUsage.parseZen(data)

        #expect(snapshot.live)
        #expect(snapshot.gauges.map(\.key) == ["five_hour", "weekly", "monthly"])
        #expect(snapshot.gauges[0].fraction == 0.1)
        #expect(snapshot.gauges[0].usedUSD == nil)
        #expect(snapshot.gauges[0].limitUSD == nil)
        #expect(snapshot.gauges[1].fraction == 0.95)
        #expect(snapshot.gauges[2].fraction == 0.47)
    }

    @Test func zenDoesNotTurnAHalfMoneyPairIntoABalance() throws {
        let data = Data(
            #"""
            {"usage":{"rolling":{"status":"ok","percent":10,"usedMicroCents":"240000000"}}}
            """#.utf8)
        let snapshot = try OpenCodeGoUsage.parseZen(data)

        #expect(snapshot.gauges.count == 1)
        #expect(snapshot.gauges[0].usedUSD == nil)
        #expect(snapshot.gauges[0].limitUSD == nil)
    }

    @Test func aWalledWindowReadsAsExhausted() throws {
        let data = Data(
            #"""
            {"usage":{"rolling":{"status":"limit","percent":100}}}
            """#.utf8)
        let snapshot = try OpenCodeGoUsage.parseZen(data)

        #expect(snapshot.gauges.count == 1)
        #expect(snapshot.gauges[0].fraction == 1)
    }

    @Test func missingWindowsAreSkippedAndNothingIsInvented() throws {
        let data = Data(
            #"""
            {"usage":{"weekly":{"status":"ok","percent":12}}}
            """#.utf8)
        let snapshot = try OpenCodeGoUsage.parseZen(data)

        #expect(snapshot.gauges.count == 1)
        #expect(snapshot.gauges[0].key == "weekly")
        #expect(snapshot.gauges[0].fraction == 0.12)
        #expect(snapshot.gauges[0].resetsAt == nil)
    }

    @Test func noWindowsIsAFailure() {
        #expect(throws: (any Error).self) {
            try OpenCodeGoUsage.parseZen(Data(#"{"usage":{}}"#.utf8))
        }
    }

    @Test func bridgeTimestampsRoundTripWithoutAFormatter() {
        let date = Date(timeIntervalSince1970: 1_792_445_731.733)
        #expect(BridgeTimestamps.string(date) == "2026-10-19T21:35:31Z")
        #expect(BridgeTimestamps.date("2026-10-19T21:35:31.733Z") != nil)
        #expect(BridgeTimestamps.date("2026-10-19T21:35:31Z") != nil)
        #expect(BridgeTimestamps.date("not a date") == nil)
    }

    @Test func anExpiredKeyIsReportedWithoutTheBody() {
        let body = Data(
            #"""
            {"error":{"type":"authentication_error","code":"api_key_expired","message":"This API key has expired."}}
            """#.utf8)
        let failure = OpenCodeGoUsage.failure(status: 401, body: body)

        #expect(failure.description.contains("401"))
        #expect(failure.description.contains("This API key has expired."))
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

    private func statusJSON(product: String) -> Data {
        let sessionLimit = product == "go-plus" ? "4800000000" : "1200000000"
        let weeklyLimit = product == "go-plus" ? "12000000000" : "3000000000"
        let monthlyLimit = product == "go-plus" ? "24000000000" : "6000000000"
        let sessionUsed = product == "go-plus" ? "960000000" : "240000000"
        let weeklyUsed = product == "go-plus" ? "11400000000" : "2850000000"
        let monthlyUsed = product == "go-plus" ? "11280000000" : "2820000000"
        return Data(
            #"""
            {
              "product": "\#(product)",
              "renewalProduct": "\#(product)",
              "useBalance": false,
              "access": {
                "startsAt": "2026-10-07T21:43:55.405Z",
                "endsAt": "2026-11-07T21:43:55.405Z",
                "cancelAtPeriodEnd": false,
                "meters": {
                  "fiveHour": {
                    "startsAt": "2026-10-19T16:35:31.733Z",
                    "resetsAt": "2026-10-19T21:35:31.733Z",
                    "limitMicroCents": "\#(sessionLimit)",
                    "usedMicroCents": "\#(sessionUsed)"
                  },
                  "week": {
                    "startsAt": "2026-10-18T00:00:00.000Z",
                    "resetsAt": "2026-10-25T00:00:00.000Z",
                    "limitMicroCents": "\#(weeklyLimit)",
                    "usedMicroCents": "\#(weeklyUsed)"
                  },
                  "month": {
                    "resetsAt": "2026-11-07T21:43:55.405Z",
                    "limitMicroCents": "\#(monthlyLimit)",
                    "usedMicroCents": "\#(monthlyUsed)"
                  }
                }
              }
            }
            """#.utf8)
    }

    private func fixtureDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("go-usage-tests-\(UUID().uuidString)")
    }
}
