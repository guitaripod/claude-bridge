import Foundation
import Testing

@testable import claude_bridge

/// A stand-in for the `claude` CLI: it records that it ran, emits one init line so the runner
/// learns a session id, holds the turn open long enough for a second client to send, then exits.
/// The real defect these tests cover is two of these running at once against one transcript.
private struct FakeClaude {
    let root: URL
    let binary: String
    let invocationLog: URL

    init(holdSeconds: Double = 0.6, sessionID: String = "fake-session") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        invocationLog = root.appendingPathComponent("invocations.log")
        _ = FileManager.default.createFile(atPath: invocationLog.path, contents: Data())
        let script = root.appendingPathComponent("fake-claude")
        // `/usr/bin/printf` rather than the shell builtin: a builtin's stdout is block-buffered
        // into a pipe and would only flush at exit, so the runner would not learn the session id
        // until the turn it is meant to identify had already ended.
        let body = """
            #!/bin/sh
            echo "start $$" >> "\(invocationLog.path)"
            /usr/bin/printf '%s\\n' '{"type":"system","subtype":"init","session_id":"\(sessionID)"}'
            sleep \(holdSeconds)
            echo "end $$" >> "\(invocationLog.path)"
            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        binary = script.path
    }

    /// Lines the fake wrote, in the order it wrote them — `start`/`end` pairs that interleave when
    /// two turns overlap and nest perfectly when they are serialized.
    func invocations() -> [String] {
        let text = (try? String(contentsOf: invocationLog, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    var starts: Int { invocations().count { $0.hasPrefix("start") } }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func makeStore(_ fake: FakeClaude) -> (SessionStore, URL) {
    let storeURL = fake.root.appendingPathComponent("sessions.json")
    let runner = ClaudeRunner(
        claudePath: fake.binary, workdir: fake.root.path, permissionMode: "default")
    let store = SessionStore(
        runner: runner, defaultModel: "sonnet", defaultEffort: "medium", storeURL: storeURL,
        projectsDir: fake.root.path)
    return (store, storeURL)
}

@Suite("Turn serialization")
struct TurnSerializationTests {

    @Test("A second prompt during a running turn queues instead of starting a second claude")
    func secondPromptQueues() async throws {
        let fake = try FakeClaude()
        defer { fake.cleanUp() }
        let (store, _) = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        let first = await store.send(session.id, request: SendRequest(text: "one"))
        let second = await store.send(session.id, request: SendRequest(text: "two"))

        #expect(first == .started)
        #expect(second == .queued(position: 1))

        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.starts == 1)

        try await Task.sleep(for: .seconds(2))
        #expect(fake.starts == 2)
        #expect(await store.hasQueuedOrRunningTurn(session.id) == false)

        let stored = await store.get(session.id)
        #expect(stored?.messages.count(where: { $0.role == .user }) == 2)
    }

    @Test("Turns never overlap: every start is closed before the next one opens")
    func turnsNeverOverlap() async throws {
        let fake = try FakeClaude(holdSeconds: 0.3)
        defer { fake.cleanUp() }
        let (store, _) = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        for index in 0..<3 {
            _ = await store.send(session.id, request: SendRequest(text: "prompt \(index)"))
        }
        try await Task.sleep(for: .seconds(3))

        let log = fake.invocations()
        #expect(log.count == 6)
        for pair in stride(from: 0, to: log.count, by: 2) {
            #expect(log[pair].hasPrefix("start"))
            #expect(log[pair + 1].hasPrefix("end"))
        }
    }

    @Test("Stopping a turn discards what queued behind it")
    func abortDrainsTheQueue() async throws {
        let fake = try FakeClaude(holdSeconds: 1.5)
        defer { fake.cleanUp() }
        let (store, _) = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "one"))
        try await Task.sleep(for: .milliseconds(300))
        _ = await store.send(session.id, request: SendRequest(text: "two"))

        let result = await store.abortTurn(session.id)
        #expect(result.stopped)
        #expect(result.discarded == 1)

        try await Task.sleep(for: .seconds(2))
        #expect(fake.starts == 1)
        #expect(await store.hasQueuedOrRunningTurn(session.id) == false)
    }

    @Test("A fork's first turn is not mistaken for its parent's")
    func forkDoesNotStealTheParentsTurnSlot() async throws {
        let fake = try FakeClaude(holdSeconds: 1.0)
        defer { fake.cleanUp() }
        let (store, _) = makeStore(fake)
        let parent = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(parent.id, request: SendRequest(text: "parent turn"))
        try await Task.sleep(for: .milliseconds(800))

        let forked = try #require(await store.fork(parent.id))
        #expect(forked.claudeSessionID == "fake-session")
        #expect(await store.hasQueuedOrRunningTurn(forked.id) == false)

        _ = await store.send(forked.id, request: SendRequest(text: "fork turn"))
        #expect(await store.hasQueuedOrRunningTurn(forked.id))
        #expect(await store.hasRunnerTurnInFlight(claudeSessionID: "fake-session"))

        try await Task.sleep(for: .milliseconds(600))
        #expect(await store.hasQueuedOrRunningTurn(parent.id) == false)
        #expect(await store.hasRunnerTurnInFlight(claudeSessionID: "fake-session"))

        try await Task.sleep(for: .seconds(2))
        #expect(await store.hasRunnerTurnInFlight(claudeSessionID: "fake-session") == false)
    }
}

/// The list's `active` flag must follow the bridge's own knowledge of a running turn, not just
/// transcript recency — a single quiet tool can run for ten minutes without writing a byte, and
/// the row must stay live the whole time.
@Suite("Runner liveness")
struct RunnerLivenessTests {
    @Test("A session with a bridge-run turn lists as active even with a silent transcript")
    func runnerTurnIsLive() async throws {
        let fake = try FakeClaude(holdSeconds: 0.8)
        defer { fake.cleanUp() }
        let (store, _) = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        let before = await store.list().first { $0.id == session.id }
        #expect(before?.active != true)

        _ = await store.send(session.id, request: SendRequest(text: "work quietly"))
        try await Task.sleep(for: .milliseconds(250))
        let during = await store.list().first { $0.id == session.id }
        #expect(during?.active == true, "a held turn must read as live with no transcript growth")

        try await Task.sleep(for: .seconds(1.5))
        let after = await store.list().first { $0.id == session.id }
        #expect(after?.active != true)
    }
}
