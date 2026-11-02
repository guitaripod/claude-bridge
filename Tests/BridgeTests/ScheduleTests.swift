import Foundation
import Testing

@testable import claude_bridge

private let utc: Calendar = Scheduler.calendar(TimeZone(identifier: "UTC")!)

private func at(_ text: String) -> Date {
    let format = ISO8601DateFormatter()
    return format.date(from: text)!
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var moment: Date
    init(_ moment: Date) { self.moment = moment }
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return moment
    }
    func set(_ value: Date) {
        lock.lock()
        moment = value
        lock.unlock()
    }
}

@Suite("Schedule rules")
struct ScheduleRuleTests {
    @Test("Every day at an hour asks next today when the hour is ahead, tomorrow when it passed")
    func daily() {
        let rule = ScheduleRule(kind: "daily", hour: 8, minute: 30)
        #expect(rule.next(after: at("2026-11-02T07:00:00Z"), calendar: utc) == at("2026-11-02T08:30:00Z"))
        #expect(rule.next(after: at("2026-11-02T08:30:00Z"), calendar: utc) == at("2026-11-03T08:30:00Z"))
    }

    @Test("Weekdays skip Saturday and Sunday")
    func weekdays() {
        let rule = ScheduleRule(kind: "weekdays", hour: 7, minute: 0)
        #expect(rule.next(after: at("2026-11-06T09:00:00Z"), calendar: utc) == at("2026-11-09T07:00:00Z"))
    }

    @Test("Weekly asks on its own day")
    func weekly() {
        let rule = ScheduleRule(kind: "weekly", hour: 9, minute: 0, weekday: 2)
        #expect(rule.next(after: at("2026-11-02T10:00:00Z"), calendar: utc) == at("2026-11-09T09:00:00Z"))
    }

    @Test("Every few hours steps from its anchor")
    func hours() {
        let rule = ScheduleRule(kind: "hours", hour: 3, minute: 15, every: 6)
        #expect(rule.next(after: at("2026-11-02T10:00:00Z"), calendar: utc) == at("2026-11-02T15:15:00Z"))
        #expect(rule.next(after: at("2026-11-02T22:00:00Z"), calendar: utc) == at("2026-11-03T03:15:00Z"))
    }

    @Test("A one-off has one moment, and none once it passed")
    func once() {
        let rule = ScheduleRule(kind: "once", at: at("2026-11-02T21:00:00Z"))
        #expect(rule.next(after: at("2026-11-02T20:00:00Z"), calendar: utc) == at("2026-11-02T21:00:00Z"))
        #expect(rule.next(after: at("2026-11-02T21:00:00Z"), calendar: utc) == nil)
    }

    @Test("A rule the bridge cannot keep says why")
    func problems() {
        #expect(ScheduleRule(kind: "daily", hour: 25, minute: 0).problem() != nil)
        #expect(ScheduleRule(kind: "weekly", hour: 8, minute: 0).problem() != nil)
        #expect(ScheduleRule(kind: "hours", hour: 0, minute: 0, every: 0).problem() != nil)
        #expect(ScheduleRule(kind: "fortnightly", hour: 8, minute: 0).problem() != nil)
        #expect(ScheduleRule(kind: "weekdays", hour: 8, minute: 0).problem() == nil)
    }
}

@Suite("Scheduler", .serialized)
struct SchedulerTests {
    private func makeStore(_ root: URL) -> SessionStore {
        let runner = ClaudeRunner(claudePath: "/bin/false", workdir: root.path, permissionMode: "default")
        return SessionStore(
            runner: runner,
            defaults: MachineDefaults(modelOverride: "sonnet", effortOverride: "medium", home: root.path),
            storeURL: root.appendingPathComponent("sessions.json"), projectsDir: root.path)
    }

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("schedule-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A machine that was off asks once for what it owed, and says how many it missed")
    func catchUpOnce() async throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let clock = Clock(at("2026-11-02T06:00:00Z"))
        let file = base.appendingPathComponent("schedules.json")
        let first = Scheduler(url: file, store: makeStore(base), now: { clock.now })
        let made = try await first.create(
            ScheduleDraft(
                text: "check the build", rule: ScheduleRule(kind: "hours", hour: 0, minute: 0, every: 1),
                timeZone: "UTC"))
        #expect(made.next == at("2026-11-02T07:00:00Z"))
        clock.set(at("2026-11-02T10:20:00Z"))
        let later = Scheduler(url: file, store: makeStore(base), now: { clock.now })
        await later.catchUp()
        let runs = try #require(await later.schedule(made.id)?.runs)
        #expect(runs.count == 1)
        #expect(runs.first?.outcome == "caughtUp")
        #expect(runs.first?.missed == 4)
        #expect(runs.first?.scheduledFor == at("2026-11-02T10:00:00Z"))
        #expect(await later.schedule(made.id)?.next == at("2026-11-02T11:00:00Z"))
    }

    @Test("A machine off for longer than the window records the misses and asks nothing")
    func longOutage() async throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let clock = Clock(at("2026-11-02T06:00:00Z"))
        let file = base.appendingPathComponent("schedules.json")
        let first = Scheduler(url: file, store: makeStore(base), now: { clock.now })
        let made = try await first.create(
            ScheduleDraft(text: "morning news", rule: ScheduleRule(kind: "daily", hour: 7, minute: 0), timeZone: "UTC"))
        clock.set(at("2026-11-04T23:00:00Z"))
        let later = Scheduler(url: file, store: makeStore(base), now: { clock.now })
        await later.catchUp()
        let run = try #require(await later.schedule(made.id)?.runs.first)
        #expect(run.outcome == "missed")
        #expect(run.missed == 3)
        #expect(run.failure == "off")
        #expect(await later.schedule(made.id)?.next == at("2026-11-05T07:00:00Z"))
    }

    @Test("A time already gone is refused at creation, and so is a fifty-first schedule")
    func refusals() async throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let clock = Clock(at("2026-11-02T12:00:00Z"))
        let scheduler = Scheduler(
            url: base.appendingPathComponent("schedules.json"), store: makeStore(base), now: { clock.now })
        await #expect(throws: ScheduleError.self) {
            _ = try await scheduler.create(
                ScheduleDraft(text: "too late", rule: ScheduleRule(kind: "once", at: at("2026-11-02T11:00:00Z"))))
        }
        for index in 0..<Scheduler.limit {
            _ = try await scheduler.create(
                ScheduleDraft(text: "n\(index)", rule: ScheduleRule(kind: "daily", hour: 8, minute: 0)))
        }
        await #expect(throws: ScheduleError.self) {
            _ = try await scheduler.create(
                ScheduleDraft(text: "one more", rule: ScheduleRule(kind: "daily", hour: 8, minute: 0)))
        }
    }
}
