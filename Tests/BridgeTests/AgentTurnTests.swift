import Foundation
import Testing

@testable import claude_bridge

/// A machine with one ACP agent on it: the fixture in `Fixtures/fake-acp-agent.py`, added and
/// proved, run by the store exactly as Hermes or Gemini CLI would be.
private struct AgentMachine {
    let root: URL
    let store: SessionStore
    let agents: AgentService

    init(proved: Bool = true) async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-tests-\(UUID().uuidString)", isDirectory: true)
        let agentsDirectory = root.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-acp-agent.py").path
        var ledger = AgentLedger()
        ledger.added = ["fake"]
        ledger.custom["fake"] = AgentLedger.CustomAgent(
            name: "Fake", command: "python3", args: [fixture])
        if proved {
            ledger.probes["fake"] = AgentLedger.Probe(
                state: "ready", checkedAt: Date(), version: "9.9.9",
                models: [.init(id: "fast", name: "Fast"), .init(id: "deep", name: "Deep")],
                currentModel: "fast", efforts: [.init(id: "low", name: "Low"), .init(id: "high", name: "High")],
                failure: nil, authMethods: [])
        }
        ledger.write(to: agentsDirectory.appendingPathComponent("state.json"))
        agents = AgentService(
            home: NSHomeDirectory(), stateDirectory: root, fetchRegistry: { nil })
        let runner = ClaudeRunner(claudePath: "/bin/false", workdir: root.path, permissionMode: "default")
        store = SessionStore(
            runner: runner,
            defaults: MachineDefaults(modelOverride: "sonnet", effortOverride: "medium", home: root.path),
            storeURL: root.appendingPathComponent("sessions.json"), projectsDir: root.path)
        await store.attach(agents: agents)
    }

    func cleanUp() async {
        await store.shutdownProcesses()
        try? FileManager.default.removeItem(at: root)
    }
}

private func until(_ limit: Duration, _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
}

private func text(of message: Message) -> String {
    message.parts.compactMap { part -> String? in
        if case .text(let value) = part { return value }
        return nil
    }.joined()
}

private func tools(of message: Message) -> [ToolCall] {
    message.parts.compactMap { part -> ToolCall? in
        if case .tool(let call) = part { return call }
        return nil
    }
}

@Suite("ACP agent turns", .serialized)
struct AgentTurnTests {

    @Test("A turn with an agent streams through the same store a Claude turn does")
    func agentTurn() async throws {
        let machine = try await AgentMachine()
        let session = await machine.store.create(CreateRequest(directory: machine.root.path))
        let outcome = await machine.store.send(
            session.id, request: SendRequest(text: "hello there", model: "fake/deep", effort: "high"))
        #expect(outcome == .started)
        try await until(.seconds(20)) {
            await !machine.store.hasQueuedOrRunningTurn(session.id)
        }
        let stored = try #require(await machine.store.get(session.id))
        #expect(stored.agent == "fake")
        #expect(stored.agentName == "Fake")
        #expect(stored.agentSessionID == "fake-1")
        #expect(stored.title == "Fake titled chat")
        let answer = try #require(stored.messages.last { $0.role == .assistant })
        #expect(text(of: answer).contains("model=deep effort=high you said: hello there"))
        let calls = tools(of: answer)
        let shell = try #require(calls.first { $0.name == "Bash" })
        #expect(shell.input.contains("uname -s"))
        #expect(shell.status == .completed)
        #expect(shell.output == "Linux")
        #expect(calls.contains { $0.name == "TodoWrite" && $0.input.contains("Answer") })
        #expect(
            answer.parts.contains { part in
                if case .reasoning(let value) = part { return value.contains("thinking") }
                return false
            })

        _ = await machine.store.send(session.id, request: SendRequest(text: "again", model: "fake/deep"))
        try await until(.seconds(20)) {
            await !machine.store.hasQueuedOrRunningTurn(session.id)
        }
        let again = try #require(await machine.store.get(session.id))
        #expect(again.agentSessionID == "fake-1")
        let last = try #require(again.messages.last { $0.role == .assistant })
        #expect(text(of: last).contains("you said: again"))
        await machine.cleanUp()
    }

    @Test("An agent's refusal is the turn's own words, not a silent end")
    func agentFailure() async throws {
        let machine = try await AgentMachine()
        let session = await machine.store.create(CreateRequest(directory: machine.root.path))
        _ = await machine.store.send(session.id, request: SendRequest(text: "FAIL now", model: "fake/fast"))
        try await until(.seconds(20)) {
            await !machine.store.hasQueuedOrRunningTurn(session.id)
        }
        let stored = try #require(await machine.store.get(session.id))
        let answer = try #require(stored.messages.last { $0.role == .assistant })
        #expect(text(of: answer).contains("the fake agent was told to fail"))
        await machine.cleanUp()
    }

    @Test("A conversation bound to an agent refuses a Claude model rather than mixing the two")
    func bindingHolds() async throws {
        let machine = try await AgentMachine()
        let session = await machine.store.create(CreateRequest(directory: machine.root.path))
        _ = await machine.store.send(session.id, request: SendRequest(text: "hi", model: "fake/fast"))
        try await until(.seconds(20)) {
            await !machine.store.hasQueuedOrRunningTurn(session.id)
        }
        _ = await machine.store.send(session.id, request: SendRequest(text: "now opus", model: "other/x"))
        try await until(.seconds(20)) {
            await !machine.store.hasQueuedOrRunningTurn(session.id)
        }
        let stored = try #require(await machine.store.get(session.id))
        let answer = try #require(stored.messages.last { $0.role == .assistant })
        #expect(text(of: answer).contains("Carry it"))
        #expect(stored.agent == "fake")
        await machine.cleanUp()
    }

    @Test("The models a ready agent offers are listed with the agent as their provider")
    func modelRows() async throws {
        let machine = try await AgentMachine()
        let rows = await machine.agents.modelRows()
        #expect(rows.map(\.id) == ["fast", "deep"])
        #expect(rows.allSatisfy { $0.provider == "fake" && $0.providerName == "Fake" && $0.agent })
        #expect(rows.first?.variants == ["low", "high"])
        await machine.cleanUp()
    }

    @Test("A proof opens a real session and reads the agent's models and levels")
    func proof() async throws {
        let machine = try await AgentMachine(proved: false)
        let row = try await machine.agents.check("fake")
        #expect(row.state == "ready")
        #expect(row.version == "9.9.9")
        #expect(row.models.map(\.id) == ["fast", "deep"])
        #expect(row.efforts.map(\.id) == ["low", "high"])
        #expect(row.signIn.first?.kind == "terminal")
        await machine.cleanUp()
    }

    @Test("A scheduled run that has nothing new is one plain line, read, and settled quiet")
    func quietRun() async throws {
        let machine = try await AgentMachine()
        let scheduler = Scheduler(
            url: machine.root.appendingPathComponent("schedules.json"), store: machine.store)
        await machine.store.observeTurnEnds { id, note in await scheduler.turnEnded(id, note) }
        let schedule = try await scheduler.create(
            ScheduleDraft(
                text: "QUIET check the news", title: nil, model: "fake/fast", effort: nil,
                directory: machine.root.path, rule: ScheduleRule(kind: "daily", hour: 7, minute: 0),
                timeZone: "UTC", thread: "continue", quiet: true, sessionID: nil, createdBy: "test"))
        #expect(schedule.quiet)
        let first = try await scheduler.runNow(schedule.id)
        let sessionID = try #require(first.sessionID)
        try await until(.seconds(20)) {
            await scheduler.schedule(schedule.id)?.runs.first?.outcome == "answered"
        }
        #expect(await scheduler.schedule(schedule.id)?.runs.first?.outcome == "answered")
        let made = try #require(await machine.store.get(sessionID))
        #expect(made.scheduleID == schedule.id)
        #expect(made.summary.scheduled == true)

        _ = try await scheduler.runNow(schedule.id)
        try await until(.seconds(20)) {
            await scheduler.schedule(schedule.id)?.runs.first?.outcome == "quiet"
        }
        let runs = try #require(await scheduler.schedule(schedule.id)?.runs)
        #expect(runs.map(\.outcome) == ["quiet", "answered"])
        #expect(runs.allSatisfy { $0.sessionID == sessionID })
        let stored = try #require(await machine.store.get(sessionID))
        let user = try #require(stored.messages.last { $0.role == .user })
        #expect(text(of: user) == "QUIET check the news")
        let answer = try #require(stored.messages.last { $0.role == .assistant })
        #expect(text(of: answer) == SessionStore.nothingNewLine)
        let marked = await machine.store.stampingMarks([stored.summary])
        let readAt = try #require(marked.first?.readAt)
        #expect(readAt >= stored.updatedAt.addingTimeInterval(-1))
        await machine.cleanUp()
    }
}
