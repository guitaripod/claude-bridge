import Foundation
import Testing

@testable import claude_bridge

private let currentChangelog = ReleaseWorld.changelog([("1.0.0", ["The first release."])])
private let newerChangelog = ReleaseWorld.changelog([
    ("1.1.0", ["Updates itself from a release."]), ("1.0.0", ["The first release."]),
])

private func scenarioName(_ label: String) -> String { "\(label)-\(UUID().uuidString.prefix(8))" }

private func installedCurrent(_ label: String) -> ReleaseMachine {
    let world = ReleaseWorld.shared
    let scenario = scenarioName(label)
    #expect(world.publish(scenario, version: "1.0.0", changelog: currentChangelog))
    let (machine, ran) = ReleaseMachine.install(from: world.base(scenario))
    #expect(ran.status == 0, "\(ran.output)")
    return machine
}

private func installedAndBehind(_ label: String) -> ReleaseMachine {
    let world = ReleaseWorld.shared
    let scenario = scenarioName(label)
    #expect(world.publish(scenario, version: "1.0.0", changelog: currentChangelog))
    let (machine, ran) = ReleaseMachine.install(from: world.base(scenario))
    #expect(ran.status == 0, "\(ran.output)")
    #expect(world.publish(scenario, version: "1.1.0", changelog: newerChangelog))
    return machine
}

private func quiet(_ service: UpdateService) async {
    await service.attach(quiet: { MachineQuiet(quiet: true, turns: 0, reason: nil) }, settle: {})
}

/// A restart is the one press that loads the build already on disk, so it is refused when nothing is
/// owed unless it is asked for anyway, and an anyway restart waits for quiet like any other restart
/// but never counts as an update taken.
@Suite struct PlainRestartTests {
    @Test func aRestartWithNothingWaitingIsRefusedUnlessAskedAnyway() async throws {
        let installed = installedCurrent("plain-refused")
        let terminations = Counter()
        let service = installed.service(terminations: terminations)
        await quiet(service)

        let (accepted, status) = await service.restart()
        #expect(accepted == false)
        #expect(status.reason?.contains("already running the build") == true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(terminations.count == 0)
    }

    @Test func aRestartAskedAnywayWaitsForQuietAndHandsTheMachineToItsSupervisor() async throws {
        let installed = installedCurrent("plain-anyway")
        let terminations = Counter()
        let service = installed.service(terminations: terminations)
        await quiet(service)

        let (accepted, started) = await service.restart(anyway: true)
        #expect(accepted == true)
        #expect(started.job?.kind == .restart)
        #expect(started.job?.reloadOnly == true)
        #expect([UpdateJob.Step.waitForIdle, .restart, .done].contains(started.job?.step))

        let exited = await eventually { terminations.count > 0 }
        #expect(exited, "the bridge never handed itself to its supervisor")

        let after = await service.status(refreshing: false)
        #expect([UpdateJob.Step.restart, .done].contains(after.job?.step))
        #expect(after.automation?.lastTakenAt == nil)
    }

    @Test func aRestartAskedAnywayIsRefusedWhileAnUpdateIsUnderWay() async throws {
        let installed = installedAndBehind("plain-busy")
        let service = installed.service()
        await quiet(service)

        let (started, _) = await service.start()
        #expect(started)
        let (accepted, refused) = await service.restart(anyway: true)
        #expect(accepted == false)
        #expect(refused.reason?.contains("under way") == true)
    }
}
