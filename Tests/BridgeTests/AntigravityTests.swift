import Foundation
import Testing

@testable import claude_bridge

/// A machine whose Antigravity is `Fixtures/fake-antigravity-agent.py`: it answers in the shapes
/// `agy acp` 1.5.18 was recorded sending, under the id the recipe knows, so the recipe's own rules
/// (sign-in first, a key that signs in for it, levels per model) are what is exercised.
private struct AntigravityMachine {
    static let id = "antigravity-acp"

    let root: URL
    let store: SessionStore
    let agents: AgentService
    let agentHome: URL

    init(signedIn: Bool = true) async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("antigravity-tests-\(UUID().uuidString)", isDirectory: true)
        let agentsDirectory = root.appendingPathComponent("agents")
        agentHome = root.appendingPathComponent("agy-home")
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentHome, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-antigravity-agent.py").path
        var ledger = AgentLedger()
        ledger.added = [Self.id]
        ledger.custom[Self.id] = AgentLedger.CustomAgent(
            name: "Antigravity", command: "python3", args: [fixture])
        ledger.write(to: agentsDirectory.appendingPathComponent("state.json"))
        var environment = ["FAKE_AGY_HOME": agentHome.path]
        if signedIn { environment["GEMINI_API_KEY"] = "test-key" }
        AgentKeys.write(environment, in: agentsDirectory, agent: Self.id)
        agents = AgentService(
            home: NSHomeDirectory(), stateDirectory: root, fetchRegistry: { nil }, fetchRelease: { _ in nil })
        let runner = ClaudeRunner(claudePath: "/bin/false", workdir: root.path, permissionMode: "default")
        store = SessionStore(
            runner: runner,
            defaults: MachineDefaults(modelOverride: "sonnet", effortOverride: "medium", home: root.path),
            storeURL: root.appendingPathComponent("sessions.json"), projectsDir: root.path)
        await store.attach(agents: agents)
        if signedIn { _ = try await agents.check(Self.id) }
    }

    /// Takes the key away and forgets the sign-in, as a revoked or expired one would leave things.
    func signOut() {
        AgentKeys.write(["FAKE_AGY_HOME": agentHome.path], in: root.appendingPathComponent("agents"), agent: Self.id)
        try? FileManager.default.removeItem(at: agentHome.appendingPathComponent("method"))
        try? FileManager.default.removeItem(at: agentHome.appendingPathComponent("signed-in"))
    }

    func send(_ session: String, _ words: String, model: String = "fast", effort: String? = nil) async throws {
        _ = await store.send(
            session, request: SendRequest(text: words, model: "\(Self.id)/\(model)", effort: effort))
        try await settle(session)
    }

    func settle(_ session: String) async throws {
        try await until(.seconds(20)) { await !store.hasQueuedOrRunningTurn(session) }
    }

    func answer(_ session: String) async throws -> Message {
        let stored = try #require(await store.get(session))
        return try #require(stored.messages.last { $0.role == .assistant })
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

private func calls(in message: Message) -> [ToolCall] {
    message.parts.compactMap { part -> ToolCall? in
        if case .tool(let call) = part { return call }
        return nil
    }
}

private func input(_ call: ToolCall) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(call.input.utf8)) as? [String: Any]) ?? [:]
}

@Suite("Antigravity", .serialized)
struct AntigravityTests {

    @Test("Signed out, it needs a sign-in the phone can finish, with the key as another way in")
    func needsSignIn() async throws {
        let machine = try await AntigravityMachine(signedIn: false)
        let row = try await machine.agents.check(AntigravityMachine.id)
        #expect(row.state == "needsSignIn")
        #expect(row.failure == "Authentication required")
        let terminal = try #require(row.signIn.first { $0.kind == "terminal" })
        #expect(terminal.id == "terminal-login")
        #expect(row.keys.map(\.env) == ["GEMINI_API_KEY"])
        #expect(row.keys.first?.alternative == true)
        #expect(row.keys.first?.set == false)
        #expect(await machine.agents.modelRows().isEmpty)
        await machine.cleanUp()
    }

    @Test("A pasted key signs it in with the method the key answers, and it stays signed in")
    func keySignsIn() async throws {
        let machine = try await AntigravityMachine(signedIn: false)
        _ = try await machine.agents.check(AntigravityMachine.id)
        let row = try await machine.agents.setKey(AntigravityMachine.id, env: "GEMINI_API_KEY", value: "pasted")
        #expect(row.state == "ready")
        #expect(row.version == "1.5.18")
        #expect(row.keys.first?.set == true)
        #expect(await machine.agents.unattendedSignIn(AntigravityMachine.id) == "gemini-api-key")
        let method = try String(contentsOf: machine.agentHome.appendingPathComponent("method"), encoding: .utf8)
        #expect(method == "gemini-api-key")
        await machine.cleanUp()
    }

    @Test("Each model is listed with the thinking levels it takes, not one list for all")
    func levelsPerModel() async throws {
        let machine = try await AntigravityMachine()
        let rows = await machine.agents.modelRows()
        #expect(rows.map(\.id) == ["deep", "fast"])
        #expect(rows.first { $0.id == "deep" }?.variants == ["low", "medium", "high", "xhigh"])
        #expect(rows.first { $0.id == "fast" }?.variants == ["low", "high"])
        #expect(rows.allSatisfy { $0.providerName == "Antigravity" })
        await machine.cleanUp()
    }

    @Test("A level is set after the model, from the levels the new model takes, the top one when more was asked than it has")
    func modelThenLevel() async throws {
        let machine = try await AntigravityMachine()
        let session = await machine.store.create(CreateRequest(directory: machine.root.path))
        try await machine.send(session.id, "hello", model: "deep", effort: "xhigh")
        #expect(text(of: try await machine.answer(session.id)).contains("model=deep effort=xhigh"))
        try await machine.send(session.id, "again", model: "deep", effort: "max")
        #expect(text(of: try await machine.answer(session.id)).contains("model=deep effort=xhigh"))

        let other = await machine.store.create(CreateRequest(directory: machine.root.path))
        try await machine.send(other.id, "hello", model: "fast", effort: "xhigh")
        #expect(text(of: try await machine.answer(other.id)).contains("model=fast effort=high"))
        await machine.cleanUp()
    }

    @Test("Its tools are drawn as the tools they are, with a command's own output and its failure")
    func tools() async throws {
        let machine = try await AntigravityMachine()
        let session = await machine.store.create(CreateRequest(directory: machine.root.path))
        try await machine.send(session.id, "TOUR please")
        let stored = try #require(await machine.store.get(session.id))
        #expect(stored.title == "A tour of the tools")
        let answer = try await machine.answer(session.id)
        let made = calls(in: answer)
        #expect(made.map(\.name) == ["Bash", "Write", "Edit", "TodoWrite", "Bash"])
        guard made.count == 5 else { return }

        let ran = made[0]
        #expect(input(ran)["command"] as? String == "echo hello > out.txt && cat out.txt")
        #expect(input(ran)["description"] as? String == "Write greeting file")
        #expect(ran.output == "hello")
        #expect(ran.status == .completed)

        #expect(input(made[1])["file_path"] as? String == "/work/notes.md")
        #expect(input(made[1])["content"] as? String == "# Notes\n\nfirst line\n")
        #expect(input(made[2])["old_string"] as? String == "first line")
        #expect(input(made[2])["new_string"] as? String == "first line, edited")

        let todos = try #require(input(made[3])["todos"] as? [[String: Any]])
        #expect(todos.map { $0["status"] as? String } == ["completed", "in_progress", "completed", "pending"])
        #expect(todos.map { $0["content"] as? String } == ["Write greeting", "Edit notes", "Ask around (skipped)", "Report back"])

        let failed = made[4]
        #expect(failed.status == .error)
        #expect(failed.output == "ls: cannot access '/definitely/not/here': No such file or directory")
        #expect(text(of: answer).contains("Tour finished."))
        await machine.cleanUp()
    }

    @Test("A question it asks is a card left open, the turn ends waiting on the person, and the answer goes by message")
    func question() async throws {
        let machine = try await AntigravityMachine()
        let session = await machine.store.create(CreateRequest(directory: machine.root.path))
        try await machine.send(session.id, "ASK me first")
        let asked = try await machine.answer(session.id)
        let card = try #require(calls(in: asked).first)
        #expect(card.name == "AskUserQuestion")
        #expect(card.status == .running)
        let questions = try #require(input(card)["questions"] as? [[String: Any]])
        #expect(questions.map { $0["question"] as? String } == [
            "Which database should the service use?", "Which features do you want?",
        ])
        #expect(questions.map { $0["multiSelect"] as? Bool } == [false, true])
        let labels = (questions[0]["options"] as? [[String: Any]])?.map { $0["label"] as? String }
        #expect(labels == ["Postgres (Recommended)", "SQLite"])
        #expect(text(of: asked) == "I need to know one thing first.")
        #expect(await machine.store.lastEnding(session.id)?.ending == .question)

        try await machine.send(session.id, "Answering \"Which database should the service use?\": Postgres")
        let answered = try await machine.answer(session.id)
        #expect(answered.id != asked.id)
        #expect(calls(in: answered).isEmpty)
        #expect(text(of: answered).hasPrefix("answered: Answering"))
        #expect(await machine.store.lastEnding(session.id)?.ending == .finished)
        await machine.cleanUp()
    }

    @Test("A request its model refused fails the turn with the service's own words")
    func modelRefusal() async throws {
        let machine = try await AntigravityMachine()
        let session = await machine.store.create(CreateRequest(directory: machine.root.path))
        try await machine.send(session.id, "QUOTA now")
        #expect(
            text(of: try await machine.answer(session.id))
                == "You have exhausted your capacity on this model. (429)")
        #expect(await machine.store.lastEnding(session.id)?.ending == .failed)

        try await machine.send(session.id, "QUOTA after a PARTIAL answer")
        #expect(text(of: try await machine.answer(session.id)) == "Half an answer.")
        #expect(await machine.store.lastEnding(session.id)?.ending == .failed)
        await machine.cleanUp()
    }

    @Test("Stopping a turn leaves its running command stopped, not failed")
    func stop() async throws {
        let machine = try await AntigravityMachine()
        let session = await machine.store.create(CreateRequest(directory: machine.root.path))
        _ = await machine.store.send(
            session.id, request: SendRequest(text: "SLEEP a while", model: "\(AntigravityMachine.id)/fast"))
        try await until(.seconds(20)) { await machine.store.liveTurnMessage(session.id)?.parts.count ?? 0 > 1 }
        #expect(await machine.store.abortTurn(session.id).stopped)
        try await machine.settle(session.id)
        let call = try #require(calls(in: try await machine.answer(session.id)).first)
        #expect(call.name == "Bash")
        #expect(call.status == .stopped)
        #expect(await machine.store.lastEnding(session.id)?.ending == .cancelled)
        await machine.cleanUp()
    }

    @Test("The note about Tailscode is handed over when a conversation begins and never again")
    func noteOnce() async throws {
        let machine = try await AntigravityMachine()
        let session = await machine.store.create(CreateRequest(directory: machine.root.path))
        try await machine.send(session.id, "hello")
        #expect(text(of: try await machine.answer(session.id)).contains("notes=1"))
        let record = try Data(contentsOf: machine.agentHome.appendingPathComponent("sessions/agy-2.json"))
        let notes = try #require((try JSONSerialization.jsonObject(with: record) as? [String: Any])?["notes"] as? [String])
        #expect(notes == [ClientNote.agentText])

        await machine.store.shutdownProcesses()
        try await machine.send(session.id, "again")
        let stored = try #require(await machine.store.get(session.id))
        #expect(stored.agentSessionID == "agy-2")
        #expect(text(of: try await machine.answer(session.id)).contains("notes=1 you said: again"))
        await machine.cleanUp()
    }

    @Test("Found signed out in a conversation, it says where to sign in, reads as needing it, and keeps the conversation")
    func signedOutMidway() async throws {
        let machine = try await AntigravityMachine()
        let session = await machine.store.create(CreateRequest(directory: machine.root.path))
        try await machine.send(session.id, "hello")
        machine.signOut()
        await machine.store.shutdownProcesses()

        try await machine.send(session.id, "are you there")
        #expect(text(of: try await machine.answer(session.id)) == SessionStore.signedOutWords("Antigravity"))
        #expect(await machine.store.lastEnding(session.id)?.ending == .failed)
        let row = try #require(await machine.agents.report().agents.first { $0.id == AntigravityMachine.id })
        #expect(row.state == "needsSignIn")
        #expect(await machine.agents.modelRows().isEmpty)
        #expect(await machine.store.get(session.id)?.agentSessionID == "agy-2")

        _ = try await machine.agents.setKey(AntigravityMachine.id, env: "GEMINI_API_KEY", value: "again")
        try await machine.send(session.id, "back")
        #expect(text(of: try await machine.answer(session.id)).contains("notes=1 you said: back"))
        #expect(await machine.store.get(session.id)?.agentSessionID == "agy-2")
        await machine.cleanUp()
    }

    @Test("The sign-in is the agent's own, run in a terminal on the machine: its link out, the code back")
    func signInRelay() async throws {
        #if !os(macOS)
            guard CommandLocator.find("script", home: NSHomeDirectory()) != nil else { return }
        #endif
        let machine = try await AntigravityMachine(signedIn: false)
        _ = try await machine.agents.check(AntigravityMachine.id)
        _ = try await machine.agents.startSignIn(AntigravityMachine.id, method: "terminal-login")
        try await until(.seconds(20)) {
            await machine.agents.signInState(AntigravityMachine.id)?.links.isEmpty == false
        }
        let waiting = try #require(await machine.agents.signInState(AntigravityMachine.id))
        #expect(waiting.state == "running")
        #expect(waiting.links.first?.hasPrefix("https://accounts.google.com/") == true)
        let listed = try #require(await machine.agents.report().agents.first { $0.id == AntigravityMachine.id })
        #expect(listed.state == "needsSignIn")

        await machine.agents.signInInput(AntigravityMachine.id, text: "wrong-code")
        try await until(.seconds(20)) {
            await machine.agents.signInState(AntigravityMachine.id)?.state == "failed"
        }
        let refused = try #require(await machine.agents.signInState(AntigravityMachine.id))
        #expect(refused.exitCode == 1)
        #expect(refused.lines.contains { $0.contains("couldn't log in") })

        _ = try await machine.agents.startSignIn(AntigravityMachine.id, method: "terminal-login")
        try await until(.seconds(20)) {
            await machine.agents.signInState(AntigravityMachine.id)?.links.isEmpty == false
        }
        await machine.agents.signInInput(AntigravityMachine.id, text: "good-code")
        try await until(.seconds(20)) {
            await machine.agents.report().agents.first { $0.id == AntigravityMachine.id }?.state == "ready"
        }
        #expect(await machine.agents.signInState(AntigravityMachine.id)?.state == "succeeded")
        #expect(await machine.agents.report().agents.first { $0.id == AntigravityMachine.id }?.state == "ready")
        await machine.cleanUp()
    }
}

@Suite("Antigravity's protocol, read")
struct AntigravityReadingTests {

    @Test("The recipe runs the CLI's own ACP server and downloads the CLI where there is none")
    func recipe() throws {
        let recipe = try #require(AgentRecipes.recipe("antigravity-acp"))
        #expect(recipe.commands == ["agy", "antigravity"])
        #expect(recipe.args == ["acp"])
        #expect(recipe.signInFirst)
        #expect(recipe.minimumVersion == "1.5.0")
        #expect(recipe.keys.first?.method == "gemini-api-key")
        let release = try #require(recipe.release)
        #expect(release.address == "https://api.github.com/repos/google-antigravity/antigravity-cli/releases/latest")
        #expect(release.assets["linux-x86_64"] == "agy_cli_linux_x64.tar.gz")
        #expect(release.assets["darwin-aarch64"] == "agy_cli_mac_arm64.tar.gz")
    }

    @Test("A release is the archive named for this machine, with the digest GitHub publishes for it")
    func release() throws {
        let release = try #require(AgentRecipes.recipe("antigravity-acp")?.release)
        let answer = """
            {"tag_name": "1.5.18", "assets": [
              {"name": "agy_cli_linux_arm64.tar.gz", "digest": "sha256:aaaa",
               "browser_download_url": "https://github.com/x/releases/download/1.5.18/agy_cli_linux_arm64.tar.gz"},
              {"name": "agy_cli_linux_x64.tar.gz", "digest": "sha256:a4960723",
               "browser_download_url": "https://github.com/x/releases/download/1.5.18/agy_cli_linux_x64.tar.gz"},
              {"name": "agy_cli_mac_x64.tar.gz",
               "browser_download_url": "https://github.com/x/releases/download/1.5.18/agy_cli_mac_x64.tar.gz"}]}
            """
        let resolved = try #require(release.resolve(Data(answer.utf8), platform: "linux-x86_64"))
        #expect(resolved.version == "1.5.18")
        #expect(
            resolved.distribution
                == .binary(
                    archive: "https://github.com/x/releases/download/1.5.18/agy_cli_linux_x64.tar.gz",
                    command: "./antigravity", args: ["acp"], sha256: "a4960723"))
        #expect(release.resolve(Data(answer.utf8), platform: "darwin-x86_64") == nil)
        #expect(release.resolve(Data(answer.utf8), platform: "darwin-aarch64") == nil)
        #expect(release.resolve(Data("rate limited".utf8), platform: "linux-x86_64") == nil)
    }

    @Test("Versions compare number by number")
    func versions() {
        #expect(AgentVersion.isOlder("1.4.9", than: "1.5.0"))
        #expect(AgentVersion.isOlder("1.4.12", than: "1.5.0"))
        #expect(!AgentVersion.isOlder("1.5.0", than: "1.5.0"))
        #expect(!AgentVersion.isOlder("1.5.18", than: "1.5.2"))
        #expect(!AgentVersion.isOlder("1.10", than: "1.5.0"))
        #expect(AgentVersion.isOlder("agy v1.4.9 (build 7)", than: "1.5.0"))
        #expect(!AgentVersion.isOlder("no version here", than: "1.5.0"))
    }

    @Test("The greeting is read for the terminal sign-in and where a note is added to the system prompt")
    func greeting() throws {
        let greeting: [String: Any] = [
            "protocolVersion": 1,
            "agentCapabilities": [
                "loadSession": true, "sessionCapabilities": ["resume": [String: Any]()],
                "_meta": ["antigravity": ["tier": true, "systemPrompt": ["append": true]]],
            ],
            "agentInfo": ["name": "Antigravity ACP Server", "version": "1.5.18"],
            "authMethods": [
                ["id": "oauth-personal", "name": "Log in with Google"],
                [
                    "id": "terminal-login", "name": "Log in from the terminal", "type": "terminal",
                    "args": ["--login"],
                ],
            ],
        ]
        let facts = AcpConnection.agentFacts(try JSONSerialization.data(withJSONObject: greeting))
        #expect(facts.version == "1.5.18")
        #expect(facts.resumeSession)
        #expect(facts.systemPromptExtension == "antigravity")
        #expect(facts.authMethods.map(\.kind) == ["agent", "terminal"])
        #expect(facts.authMethods.last?.args == ["--login"])
    }

    @Test("A sign-in's long link is said as its site in the lines and kept whole beside them")
    func signInLines() {
        let link = "https://accounts.google.com/o/oauth2/auth?access_type=offline&client_id=1071006060591-example.apps.googleusercontent.com&code_challenge=abc&redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback"
        let printed = [
            "Open this link in a browser to log in with Google:", link,
            "Then paste the authorization code, or the full URL of the page you land on, and press Enter:",
        ]
        let links = AgentSignIn.links(in: printed)
        #expect(links == [link])
        #expect(
            AgentSignIn.abridged(printed, links: links) == [
                printed[0], "https://accounts.google.com/…", printed[2],
            ])
        let short = ["Visit https://example.com/device and enter ABCD-1234", "https://example.com/device"]
        #expect(AgentSignIn.abridged(short, links: AgentSignIn.links(in: short)) == short)
    }

    @Test("A model's levels are read from the ids that pair it with one")
    func pairings() {
        let levels = AcpConnection.modelEfforts(
            models: ["gemini-4-neon", "gemini-3.1-pro", "gemini-4"],
            pairings: [
                "gemini-4-neon-high", "gemini-4-neon-xhigh", "gemini-4-neon-medium", "gemini-4-neon-low",
                "gemini-3.1-pro-high", "gemini-3.1-pro-low", "gemini-4-low",
            ])
        #expect(levels["gemini-4-neon"] == ["low", "medium", "high", "xhigh"])
        #expect(levels["gemini-3.1-pro"] == ["low", "high"])
        #expect(levels["gemini-4"] == ["low"])
        #expect(AcpConnection.modelEfforts(models: ["a", "b"], pairings: ["a-low"]).isEmpty)
    }

    @Test("The level set is the one asked for, or the end of the agent's range it lies beyond")
    func nearestLevel() {
        #expect(AcpSessionFacts.nearestEffort("high", in: ["low", "high"]) == "high")
        #expect(AcpSessionFacts.nearestEffort("max", in: ["low", "medium", "high", "xhigh"]) == "xhigh")
        #expect(AcpSessionFacts.nearestEffort("xhigh", in: ["default", "high", "low"]) == "high")
        #expect(AcpSessionFacts.nearestEffort("medium", in: ["low", "high"]) == nil)
        #expect(AcpSessionFacts.nearestEffort("minimal", in: ["low", "high"]) == "low")
        #expect(AcpSessionFacts.nearestEffort("ultracode", in: ["low", "high"]) == nil)
        #expect(AcpSessionFacts.nearestEffort("high", in: []) == nil)
    }

    @Test("A model failure said in the answer is read into the service's message and its status")
    func executorFailure() {
        #expect(
            AcpTranslator.executorFailure(
                "\n⚠ agent executor error: generating and executing: Error 401, Message: API key not valid. Please pass a valid API key., Status: UNAUTHENTICATED, Details: []\n")
                == "API key not valid. Please pass a valid API key. (401)")
        #expect(
            AcpTranslator.executorFailure(
                "⚠ agent executor error: generating and executing: Error 429, Message: Quota, Status: A, Details: [x, Status: y]")
                == "Quota (429)")
        #expect(AcpTranslator.executorFailure("⚠ agent executor error: the model went away") == "the model went away")
        #expect(AcpTranslator.executorFailure("⚠ agent executor error:") == "The agent's model did not answer.")
        #expect(AcpTranslator.executorFailure("The agent executor error: is a phrase I can explain.") == nil)
        #expect(AcpTranslator.executorFailure("Done.") == nil)
    }

    @Test("A command's output is what it printed, without the agent's receipt around it")
    func commandOutput() {
        let receipt = "Created At: 2026-11-28T06:51:21+02:00\nCompleted At: 2026-11-28T06:51:21+02:00\nCommand exited with code 0.\n\nCommand output:\nline one\r\nline two\r\n"
        #expect(AcpTranslator.commandOutput(["output": receipt, "exit_code": 0]) == "line one\nline two")
        #expect(
            AcpTranslator.commandOutput(["output": "Command exited with code 3.\n\nCommand output:\n", "exit_code": 3])
                == "Exited with code 3.")
        #expect(AcpTranslator.commandOutput(["output": "plain"]) == nil)
        #expect(AcpTranslator.exitedWithError(["rawOutput": ["output": "", "exit_code": 2]]))
        #expect(!AcpTranslator.exitedWithError(["rawOutput": ["output": "", "exit_code": 0]]))
        #expect(!AcpTranslator.exitedWithError(["rawOutput": "file does not exist"]))
    }

    @Test("A web search, a subagent and a tool with no Claude twin are named for what they are")
    func otherTools() {
        let search = AcpTranslator.named([
            "name": "search_web", "kind": "search", "title": "\"agent client protocol\" on Web",
            "rawInput": ["query": "agent client protocol"],
        ])
        #expect(search.0 == "WebSearch")
        #expect(search.1["query"] as? String == "agent client protocol")

        let subagent = AcpTranslator.named([
            "name": "invoke_subagent", "kind": "other", "title": "Run invoke_subagent",
            "rawInput": ["TypeName": "researcher", "Role": "Codebase Researcher", "Prompt": "List the files."],
        ])
        #expect(subagent.0 == "Agent")
        #expect(subagent.1["description"] as? String == "Codebase Researcher")
        #expect(subagent.1["prompt"] as? String == "List the files.")
        #expect(subagent.1["subagent_type"] as? String == "researcher")

        let other = AcpTranslator.named([
            "name": "manage_task", "kind": "other", "title": "Run manage_task", "rawInput": ["Action": "list"],
        ])
        #expect(other.0 == "manage_task")
        #expect(other.1["Action"] as? String == "list")

        let read = AcpTranslator.named([
            "name": "read_file", "kind": "read", "title": "File proj/notes.md",
            "locations": [["path": "/repo/proj/notes.md"]], "rawInput": ["Path": "/repo/proj/notes.md"],
        ])
        #expect(read.0 == "Read")
        #expect(read.1["file_path"] as? String == "/repo/proj/notes.md")
    }

    @Test("An answer to a question asked before this turn settles nothing new and draws no second card")
    func lateAnswer() {
        var translator = AcpTranslator()
        let late: [String: Any] = [
            "sessionId": "s",
            "update": [
                "sessionUpdate": "tool_call_update", "toolCallId": "ask-0", "name": "ask_question",
                "status": "completed", "kind": "other", "title": "Run ask_question",
                "rawInput": ["questions": [["question": "Which?", "options": ["A", "B"]]]],
            ],
        ]
        #expect(translator.translate(late).isEmpty)
        #expect(translator.closeOpenCalls().isEmpty)
    }
}
