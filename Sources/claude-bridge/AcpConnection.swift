import Foundation

/// What an ACP agent said about itself when it was greeted.
struct AcpAgentFacts: Sendable, Equatable {
    struct AuthMethod: Sendable, Equatable, Codable {
        var id: String
        var name: String
        var description: String?
        /// `agent` (the agent runs the flow itself after `authenticate`) or `terminal` (the client
        /// runs the agent again with `args` and `env`, interactively).
        var kind: String
        var args: [String]
        var env: [String: String]
    }

    var name: String?
    var version: String?
    var loadSession = false
    var resumeSession = false
    var images = false
    var authMethods: [AuthMethod] = []
    /// The name an agent files its own extensions under, when one of them is text added to the
    /// end of its system prompt as a session begins (`_meta.antigravity.systemPrompt.append`).
    var systemPromptExtension: String?
}

/// The choices an agent offers for a session, as `session/new` or `session/resume` reported them.
struct AcpSessionFacts: Sendable, Equatable {
    struct Choice: Sendable, Equatable, Codable {
        var id: String
        var name: String
        var description: String?
    }

    var sessionID: String
    var models: [Choice] = []
    var currentModel: String?
    /// The config option that picks the model, when the agent exposes one rather than the older
    /// `session/set_model`.
    var modelOption: String?
    var efforts: [Choice] = []
    var currentEffort: String?
    var effortOption: String?
    /// The thinking levels each model takes, when the agent says so by listing every pairing
    /// under the older `models` key (`gemini-4-neon-xhigh`) beside a model option that names the
    /// models alone. Empty for an agent whose levels are the same for every model.
    var modelEfforts: [String: [String]] = [:]

    /// Thinking levels from least to most, as agents spell them.
    static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// The level to set when `wanted` was asked for: itself where the agent offers it, the highest
    /// it offers when more was asked than it has, the lowest when less was. Nil for a word that is
    /// no level, and for a level the agent merely lacks between two it has: there the agent keeps
    /// the level it is at, rather than being moved to one nobody chose.
    static func nearestEffort(_ wanted: String, in offered: [String]) -> String? {
        if offered.contains(wanted) { return wanted }
        guard let rank = effortOrder.firstIndex(of: wanted) else { return nil }
        let ranked = offered.compactMap { level in effortOrder.firstIndex(of: level).map { ($0, level) } }
            .sorted { $0.0 < $1.0 }
        guard let lowest = ranked.first, let highest = ranked.last else { return nil }
        if rank > highest.0 { return highest.1 }
        if rank < lowest.0 { return lowest.1 }
        return nil
    }
}

/// A failure an agent reported, or the connection failing under it.
enum AcpFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case rpc(code: Int, message: String, detail: String?)
    case exited(String?)
    case timedOut(String)
    case notRunning

    var description: String {
        switch self {
        case .rpc(_, let message, let detail):
            guard let detail, !detail.isEmpty else { return message }
            return detail
        case .exited(let tail):
            guard let tail, !tail.isEmpty else { return "The agent exited." }
            return tail
        case .timedOut(let method): return "The agent did not answer \(method) in time."
        case .notRunning: return "The agent is not running."
        }
    }

    /// The agent asked to be signed in, by the spec's code or in so many words.
    var isAuthRequired: Bool {
        if case .rpc(let code, let message, let detail) = self {
            if code == -32000 { return true }
            let text = (message + " " + (detail ?? "")).lowercased()
            return text.contains("auth_required") || text.contains("authentication required")
                || text.contains("not authenticated") || text.contains("please log in")
                || text.contains("login required")
        }
        return false
    }
}

/// One agent process spoken to over the Agent Client Protocol: JSON-RPC 2.0, one message per line
/// on stdin and stdout. Requests this bridge sends are correlated by id; requests the agent sends
/// are answered here — a permission question with its allow option, since the bridge runs agents
/// with the same trust it gives Claude, and anything else as a method this client does not have;
/// `session/update` notifications go to the owner in the order they arrived.
actor AcpConnection {
    struct Launch: Sendable, Equatable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var directory: String
    }

    let launch: Launch
    private(set) var pid: Int32 = 0
    private(set) var isRunning = false
    private(set) var lastActivityAt = Date()
    private(set) var facts = AcpAgentFacts()
    /// The ACP session this connection is serving, once one was opened or resumed on it.
    private(set) var sessionID: String?

    private let process = Process()
    private let stdinPipe = Spawning.pipe()
    private let stdoutPipe = Spawning.pipe()
    private let stderrPipe = Spawning.pipe()
    private let exit = ExitLatch()
    private let errorTail = ErrorTail()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    /// A session whose history the agent is replaying in answer to `session/load`; its updates are
    /// the transcript this bridge already holds, so they are dropped rather than re-told.
    private var replaying: String?
    private let onUpdate: @Sendable (AcpConnection, Data) async -> Void
    private let onExit: @Sendable (AcpConnection) async -> Void

    static let greetTimeout: Duration = .seconds(240)
    static let sessionTimeout: Duration = .seconds(120)
    static let signInTimeout: Duration = .seconds(900)
    static let settingTimeout: Duration = .seconds(20)
    static let closeGrace: Duration = .seconds(3)

    init(
        launch: Launch, onUpdate: @escaping @Sendable (AcpConnection, Data) async -> Void = { _, _ in },
        onExit: @escaping @Sendable (AcpConnection) async -> Void = { _ in }
    ) {
        self.launch = launch
        self.onUpdate = onUpdate
        self.onExit = onExit
    }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.directory)
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in launch.environment { environment[key] = value }
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let latch = exit
        process.terminationHandler = { finished in
            finished.releaseFinished()
            latch.signal()
        }
        let tail = errorTail
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                tail.append(chunk)
            }
        }
        try process.runAllowingBusyExecutable()
        pid = process.processIdentifier
        isRunning = true
        lastActivityAt = Date()
        let lines = ClaudeRunner.lineStream(from: stdoutPipe.fileHandleForReading)
        Task { [weak self] in
            for await line in lines {
                guard let self else { return }
                await self.consume(line)
            }
            await self?.finished()
        }
    }

    /// The handshake. Asks for no file system and no terminal of the client's: the agent works with
    /// its own tools on the machine it is already on. It does say a sign-in can be run in a
    /// terminal, which is the only kind a person on another device can finish: an agent offers
    /// its paste-a-code sign-in to a client that says so and its open-a-browser one otherwise.
    func initialize() async throws -> AcpAgentFacts {
        let data = try await request(
            "initialize",
            [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false,
                    "auth": ["terminal": true],
                ],
                "clientInfo": [
                    "name": "claude-bridge", "title": "Tailscode",
                    "version": BridgeVersion.running?.version ?? "dev",
                ],
            ], timeout: Self.greetTimeout)
        facts = Self.agentFacts(data)
        return facts
    }

    /// Signs in the way the agent runs itself. One a person finishes in a browser is given the
    /// minutes that takes; one that only reads a key the agent already holds answers at once.
    func authenticate(method: String, attended: Bool = false) async throws {
        _ = try await request(
            "authenticate", ["methodId": method],
            timeout: attended ? Self.signInTimeout : Self.sessionTimeout)
    }

    /// Opens a session. An agent that asks to be signed in first is signed in with `method` when
    /// one is given (a sign-in that needs nobody, such as a kept key) and asked again.
    ///
    /// `note` is added to the end of the agent's system prompt where the agent takes one. It is
    /// handed over here and nowhere else: the agent keeps it with the conversation through every
    /// resume, and one handed over again would be said twice.
    func newSession(directory: String, signingInWith method: String? = nil, note: String? = nil)
        async throws -> AcpSessionFacts
    {
        var params: [String: Any] = ["cwd": directory, "mcpServers": [Any]()]
        if let note, !note.isEmpty, let own = facts.systemPromptExtension {
            params["_meta"] = [own: ["systemPrompt": ["append": note]]]
        }
        let data = try await signedIn(with: method) {
            try await self.request("session/new", params, timeout: Self.sessionTimeout)
        }
        guard let session = Self.sessionFacts(data, id: nil) else {
            throw AcpFailure.rpc(code: -32603, message: "The agent opened no session.", detail: nil)
        }
        sessionID = session.sessionID
        return session
    }

    /// Picks an existing conversation back up: `session/resume` where the agent has it (nothing is
    /// replayed), `session/load` otherwise (the replay is swallowed — the bridge already holds
    /// the transcript).
    func reopen(sessionID id: String, directory: String, signingInWith method: String? = nil)
        async throws -> AcpSessionFacts
    {
        let params: [String: Any] = ["sessionId": id, "cwd": directory, "mcpServers": [Any]()]
        let data: Data
        if facts.resumeSession {
            data = try await signedIn(with: method) {
                try await self.request("session/resume", params, timeout: Self.sessionTimeout)
            }
        } else if facts.loadSession {
            replaying = id
            defer { replaying = nil }
            data = try await signedIn(with: method) {
                try await self.request("session/load", params, timeout: Self.sessionTimeout)
            }
        } else {
            throw AcpFailure.rpc(code: -32601, message: "The agent cannot reopen a session.", detail: nil)
        }
        sessionID = id
        return Self.sessionFacts(data, id: id) ?? AcpSessionFacts(sessionID: id)
    }

    /// Runs a request, and when the agent answers that it must be signed in first, signs in with
    /// `method` and runs it once more. With no method the agent's answer stands.
    private func signedIn(with method: String?, _ ask: () async throws -> Data) async throws -> Data {
        do {
            return try await ask()
        } catch let failure as AcpFailure where failure.isAuthRequired {
            guard let method else { throw failure }
            do {
                try await authenticate(method: method)
            } catch {
                throw failure
            }
            return try await ask()
        }
    }

    /// One turn. Answers the stop reason once the agent has finished speaking; every update of the
    /// turn has gone to the owner before this returns, because both travel the same ordered line.
    func prompt(_ text: String) async throws -> String {
        guard let sessionID else { throw AcpFailure.notRunning }
        let data = try await request(
            "session/prompt",
            ["sessionId": sessionID, "prompt": [["type": "text", "text": text]]], timeout: nil)
        let object = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
            as? [String: Any]
        return object?["stopReason"] as? String ?? "end_turn"
    }

    func cancel() {
        guard let sessionID else { return }
        try? write(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionID]])
    }

    /// Chooses the model for the session, through whichever door the agent offered, and answers
    /// the session's choices as they stand afterwards: an agent whose thinking levels differ by
    /// model lists the new model's in its reply.
    @discardableResult
    func setModel(_ model: String, facts session: AcpSessionFacts) async throws -> AcpSessionFacts {
        guard let sessionID else { throw AcpFailure.notRunning }
        guard let option = session.modelOption else {
            _ = try await request(
                "session/set_model", ["sessionId": sessionID, "modelId": model],
                timeout: Self.settingTimeout)
            var updated = session
            updated.currentModel = model
            return updated
        }
        let data = try await request(
            "session/set_config_option",
            ["sessionId": sessionID, "configId": option, "value": model],
            timeout: Self.settingTimeout)
        return Self.updated(session, by: data)
    }

    @discardableResult
    func setEffort(_ effort: String, facts session: AcpSessionFacts) async throws -> AcpSessionFacts {
        guard let sessionID, let option = session.effortOption else { return session }
        let data = try await request(
            "session/set_config_option",
            ["sessionId": sessionID, "configId": option, "value": effort],
            timeout: Self.settingTimeout)
        return Self.updated(session, by: data)
    }

    /// A session's choices after a setting changed, read from the reply's config options. A reply
    /// that lists none leaves them as they were.
    static func updated(_ session: AcpSessionFacts, by data: Data) -> AcpSessionFacts {
        guard let fresh = sessionFacts(data, id: session.sessionID), fresh.modelOption != nil || fresh.effortOption != nil
        else { return session }
        var updated = session
        if fresh.modelOption != nil {
            updated.modelOption = fresh.modelOption
            updated.models = fresh.models
            updated.currentModel = fresh.currentModel
        }
        updated.effortOption = fresh.effortOption
        updated.efforts = fresh.efforts
        updated.currentEffort = fresh.currentEffort
        return updated
    }

    /// The last lines the agent wrote to stderr, for a failure nothing else explains.
    func stderrTail() -> String { errorTail.text() }

    func close() async {
        guard isRunning else { return }
        try? stdinPipe.fileHandleForWriting.close()
        guard await !exited(within: Self.closeGrace) else { return }
        await terminate()
    }

    func terminate() async {
        guard process.isRunning else { return }
        process.terminate()
        guard await !exited(within: Self.closeGrace) else { return }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func exited(within grace: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [exit] in
                await exit.wait()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: grace)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func request(_ method: String, _ params: [String: Any], timeout: Duration?)
        async throws -> Data
    {
        guard isRunning else { throw AcpFailure.notRunning }
        nextID += 1
        let id = nextID
        lastActivityAt = Date()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            } catch {
                pending[id] = nil
                continuation.resume(throwing: AcpFailure.exited(errorTail.text()))
                return
            }
            guard let timeout else { return }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id, method: method)
            }
        }
    }

    private func expire(_ id: Int, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: AcpFailure.timedOut(method))
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func consume(_ line: String) async {
        lastActivityAt = Date()
        guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let method = object["method"] as? String
        if let method, object["id"] != nil {
            answer(object, method: method)
            return
        }
        if method == "session/update" {
            guard let params = object["params"] as? [String: Any] else { return }
            if let replaying, params["sessionId"] as? String == replaying { return }
            guard let body = try? JSONSerialization.data(withJSONObject: params) else { return }
            await onUpdate(self, body)
            return
        }
        guard method == nil, let id = Self.intID(object["id"]),
            let continuation = pending.removeValue(forKey: id)
        else { return }
        if let error = object["error"] as? [String: Any] {
            continuation.resume(throwing: Self.failure(error))
            return
        }
        let result = object["result"] ?? NSNull()
        let body =
            (try? JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed))
            ?? Data("null".utf8)
        continuation.resume(returning: body)
    }

    /// A request from the agent. A permission question is answered yes, preferring a yes that does
    /// not outlive this call, so nothing the bridge says is written into the agent's own standing
    /// rules; every other request is a method this client does not offer.
    private func answer(_ object: [String: Any], method: String) {
        let id = object["id"] ?? NSNull()
        guard method == "session/request_permission" else {
            try? write([
                "jsonrpc": "2.0", "id": id,
                "error": ["code": -32601, "message": "Method not found: \(method)"],
            ])
            return
        }
        let options =
            ((object["params"] as? [String: Any])?["options"] as? [[String: Any]]) ?? []
        guard let chosen = Self.allowOption(options) else {
            try? write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]])
            return
        }
        try? write([
            "jsonrpc": "2.0", "id": id,
            "result": ["outcome": ["outcome": "selected", "optionId": chosen]],
        ])
    }

    static func allowOption(_ options: [[String: Any]]) -> String? {
        for kind in ["allow_once", "allow_always"] {
            if let option = options.first(where: { $0["kind"] as? String == kind }),
                let id = option["optionId"] as? String
            {
                return id
            }
        }
        return options.first { ($0["kind"] as? String)?.hasPrefix("allow") ?? false }?["optionId"]
            as? String
    }

    private func finished() async {
        isRunning = false
        try? stdinPipe.fileHandleForWriting.close()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let failure = AcpFailure.exited(errorTail.text())
        for (_, continuation) in pending { continuation.resume(throwing: failure) }
        pending = [:]
        await onExit(self)
    }

    private static func intID(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    private static func failure(_ error: [String: Any]) -> AcpFailure {
        let code = intID(error["code"]) ?? -32603
        let message = error["message"] as? String ?? "The agent refused."
        var detail: String?
        if let data = error["data"] as? String {
            detail = data
        } else if let data = error["data"] as? [String: Any] {
            detail = (data["details"] as? String) ?? (data["message"] as? String)
                ?? (data["detail"] as? String)
        }
        return .rpc(code: code, message: message, detail: detail)
    }

    static func agentFacts(_ data: Data) -> AcpAgentFacts {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AcpAgentFacts()
        }
        var facts = AcpAgentFacts()
        let info = object["agentInfo"] as? [String: Any]
        facts.name = (info?["title"] as? String) ?? (info?["name"] as? String)
        facts.version = info?["version"] as? String
        let capabilities = object["agentCapabilities"] as? [String: Any] ?? [:]
        facts.loadSession = capabilities["loadSession"] as? Bool ?? false
        let session = capabilities["sessionCapabilities"] as? [String: Any] ?? [:]
        facts.resumeSession = session["resume"] != nil
        let prompt = capabilities["promptCapabilities"] as? [String: Any] ?? [:]
        facts.images = prompt["image"] as? Bool ?? false
        let extensions = capabilities["_meta"] as? [String: Any] ?? [:]
        facts.systemPromptExtension = extensions.keys.sorted().first { name in
            let own = extensions[name] as? [String: Any]
            return (own?["systemPrompt"] as? [String: Any])?["append"] as? Bool == true
        }
        let methods = object["authMethods"] as? [[String: Any]] ?? []
        facts.authMethods = methods.compactMap { method in
            guard let id = method["id"] as? String else { return nil }
            return AcpAgentFacts.AuthMethod(
                id: id, name: method["name"] as? String ?? id,
                description: method["description"] as? String,
                kind: method["type"] as? String ?? "agent",
                args: method["args"] as? [String] ?? [],
                env: method["env"] as? [String: String] ?? [:])
        }
        return facts
    }

    static func sessionFacts(_ data: Data, id: String?) -> AcpSessionFacts? {
        let object =
            (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
            as? [String: Any] ?? [:]
        guard let sessionID = (object["sessionId"] as? String) ?? id else { return nil }
        var facts = AcpSessionFacts(sessionID: sessionID)
        let options = object["configOptions"] as? [[String: Any]] ?? []
        for option in options {
            let category = option["category"] as? String
            let choices = Self.choices(option)
            if category == "model", !choices.isEmpty {
                facts.modelOption = option["id"] as? String
                facts.models = choices
                facts.currentModel = Self.text(option["currentValue"])
            } else if category == "thought_level", !choices.isEmpty {
                facts.effortOption = option["id"] as? String
                facts.efforts = choices
                facts.currentEffort = Self.text(option["currentValue"])
            }
        }
        if facts.models.isEmpty, let models = object["models"] as? [String: Any] {
            let available = models["availableModels"] as? [[String: Any]] ?? []
            facts.models = available.compactMap { model in
                guard let id = model["modelId"] as? String else { return nil }
                return AcpSessionFacts.Choice(
                    id: id, name: model["name"] as? String ?? id,
                    description: model["description"] as? String)
            }
            facts.currentModel = models["currentModelId"] as? String
        } else if let models = object["models"] as? [String: Any] {
            let pairings = (models["availableModels"] as? [[String: Any]] ?? []).compactMap {
                $0["modelId"] as? String
            }
            facts.modelEfforts = Self.modelEfforts(models: facts.models.map(\.id), pairings: pairings)
        }
        return facts
    }

    /// Which thinking levels each model takes, read from ids that pair a model with a level
    /// (`gemini-4-neon-xhigh` is `gemini-4-neon` at `xhigh`). Only a level's own word counts as
    /// one, so a longer model name that merely begins with a shorter one is never taken for it,
    /// and nothing is answered unless every model was paired with at least one level.
    static func modelEfforts(models: [String], pairings: [String]) -> [String: [String]] {
        var levels: [String: [String]] = [:]
        for model in models {
            let found = pairings.compactMap { pairing -> String? in
                guard pairing.hasPrefix(model + "-") else { return nil }
                let level = String(pairing.dropFirst(model.count + 1))
                return AcpSessionFacts.effortOrder.contains(level) ? level : nil
            }
            guard !found.isEmpty else { return [:] }
            levels[model] = AcpSessionFacts.effortOrder.filter(found.contains)
        }
        return levels
    }

    private static func choices(_ option: [String: Any]) -> [AcpSessionFacts.Choice] {
        let raw = option["options"] as? [[String: Any]] ?? []
        var flat: [[String: Any]] = []
        for entry in raw {
            if let grouped = entry["options"] as? [[String: Any]] {
                flat += grouped
            } else {
                flat.append(entry)
            }
        }
        return flat.compactMap { entry in
            guard let value = Self.text(entry["value"]) else { return nil }
            return AcpSessionFacts.Choice(
                id: value, name: entry["name"] as? String ?? value,
                description: entry["description"] as? String)
        }
    }

    private static func text(_ raw: Any?) -> String? {
        if let value = raw as? String { return value }
        if let value = raw as? NSNumber { return value.stringValue }
        return nil
    }
}

/// The end of what an agent wrote to stderr, kept small and read only when something failed.
final class ErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private static let limit = 4_096

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        if buffer.count > Self.limit { buffer = buffer.suffix(Self.limit) }
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        let data = buffer
        lock.unlock()
        let raw = String(decoding: data, as: UTF8.self)
        let lines = raw.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return lines.suffix(6).joined(separator: "\n")
    }
}
