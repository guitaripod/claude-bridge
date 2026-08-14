import Foundation
import Testing

@testable import claude_bridge

/// A machine that replaces itself while nobody is watching has to be wrong about nothing, so the
/// two facts it decides on — is anything running, and has this commit already refused to build —
/// are pinned here rather than left to be re-derived by the next reader.
@Suite struct UnattendedUpdateTests {
    @Test func nothingCountedIsNotNothingRunning() {
        let unswept = MachineQuiet.read(turns: 0, signingIn: false, swept: false)
        #expect(!unswept.quiet)
        #expect(unswept.reason != nil)

        #expect(MachineQuiet.read(turns: 0, signingIn: false, swept: true).quiet)
    }

    /// A sign-in is a pseudo-terminal waiting on a code somebody is reading off a browser on
    /// another machine. No turn is running and stopping it still loses their work.
    @Test func aSignInIsWorkInFlight() {
        let signing = MachineQuiet.read(turns: 0, signingIn: true, swept: true)
        #expect(!signing.quiet)
        #expect(signing.turns == 0)
        #expect(signing.reason?.contains("signing") == true)
    }

    @Test func aRunningTurnCountsItselfInWords() {
        let one = MachineQuiet.read(turns: 1, signingIn: false, swept: true)
        #expect(!one.quiet)
        #expect(one.reason == "A turn is running on that machine.")
        #expect(MachineQuiet.read(turns: 3, signingIn: false, swept: true).reason?.hasPrefix("3") == true)
    }

    /// The whole point of the failure memory: a commit that cannot build on this machine must not
    /// be rebuilt at full load every half hour forever.
    @Test func aFailedCommitBacksOffAndANewerOneDoesNot() {
        let now = Date()
        var policy = UpdatePolicy(enabled: true)
        #expect(policy.allows(target: "abc1234", now: now))

        policy.noteFailure(target: "abc1234", now: now)
        #expect(!policy.allows(target: "abc1234", now: now))
        #expect(policy.allows(target: "def5678", now: now))
        #expect(policy.allows(target: "abc1234", now: now.addingTimeInterval(2 * 3600)))

        let firstRetry = policy.retryAfter
        policy.noteFailure(target: "abc1234", now: now)
        #expect(policy.failures == 2)
        #expect(policy.retryAfter ?? now > firstRetry ?? now)
    }

    @Test func theBackoffIsCapped() {
        var policy = UpdatePolicy()
        let now = Date()
        for _ in 0..<40 { policy.noteFailure(target: "abc1234", now: now) }
        #expect(
            (policy.retryAfter ?? now).timeIntervalSince(now) <= UpdatePolicy.maximumBackoff + 1)
    }

    /// An update that lands clears the corpse, so the next failure starts its own count rather than
    /// inheriting a delay from something already fixed.
    @Test func successForgetsTheFailure() {
        var policy = UpdatePolicy()
        policy.noteFailure(target: "abc1234")
        policy.noteSuccess(target: "def5678")
        #expect(policy.failedTarget == nil)
        #expect(policy.failures == 0)
        #expect(policy.retryAfter == nil)
        #expect(policy.lastTarget == "def5678")
        #expect(policy.allows(target: "abc1234"))
    }

    /// An obstacle is rendered by three clients and persisted whole by each of them, so a checkout
    /// with a thousand untracked files states a count rather than shipping a thousand rows.
    @Test func anObstacleIsCappedAndSaysHowMuchItLeftOut() {
        let obstacle = UpdateObstacle(
            kind: "dirty", summary: "many files",
            items: (0..<25).map { "Sources/file\($0).swift" })
        #expect(obstacle.items.count == UpdateObstacle.itemLimit)
        #expect(obstacle.more == 25 - UpdateObstacle.itemLimit)

        let small = UpdateObstacle(kind: "ahead", summary: "one", items: ["a commit"])
        #expect(small.more == 0)
    }

    /// The two ends read the commit from different places — `git rev-parse` answers forty
    /// characters and the status reports seven — so a memory keyed to one while every question
    /// arrives in the other is a backoff that never holds anything off.
    @Test func theBackoffRecognisesACommitWhicheverWayItIsSpelled() {
        let full = "abc1234def5678901234567890abcdef12345678"
        var policy = UpdatePolicy()
        policy.noteFailure(target: full)

        #expect(!policy.allows(target: "abc1234"))
        #expect(!policy.allows(target: full))
        #expect(policy.failedTarget == "abc1234")

        policy.noteSuccess(target: full)
        #expect(policy.lastTarget == "abc1234")
    }
}

/// The stamp says what this *process* is, and it is read once, at startup — so a stamp that is not
/// about this binary is a wrong answer no restart can correct. The installer writes it after the
/// build it describes; a binary newer than its stamp came from some other hand, and believing it
/// there is what made a machine restart on a loop over a build that was already loaded.
@Suite struct BuildStampTests {
    private static let built = Date(timeIntervalSince1970: 1_770_000_000)

    @Test func aBinaryNewerThanItsStampIsNotTheBinaryTheStampDescribes() {
        #expect(
            !BridgeVersion.stampDescribes(
                builtAt: Self.built, executableModified: Self.built.addingTimeInterval(60)))
    }

    @Test func theInstallersOwnOrderIsBelieved() {
        #expect(
            BridgeVersion.stampDescribes(
                builtAt: Self.built, executableModified: Self.built.addingTimeInterval(-3)))
        #expect(
            BridgeVersion.stampDescribes(builtAt: Self.built, executableModified: Self.built))
    }

    /// Nothing to compare against is not evidence of a lie: a stamp from a bridge too old to date
    /// itself, or a filesystem that will not answer, keeps the signal it was written for.
    @Test func anUndatableStampKeepsItsSignal() {
        #expect(BridgeVersion.stampDescribes(builtAt: nil, executableModified: Self.built))
        #expect(BridgeVersion.stampDescribes(builtAt: Self.built, executableModified: nil))
    }
}
