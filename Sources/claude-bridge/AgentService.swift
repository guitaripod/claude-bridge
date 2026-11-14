import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One agent as `GET /agents` reports it. States and facts only; every sentence a person reads
/// about it is written on the device.
struct AgentRow: Codable, Sendable, Equatable {
    struct Key: Codable, Sendable, Equatable {
        var env: String
        var name: String
        var url: String?
        var set: Bool
    }

    struct Method: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var description: String?
        var kind: String
    }

    var id: String
    var name: String
    var version: String?
    var description: String?
    var icon: String?
    var website: String?
    /// `found` (on this machine's PATH), `available` (run through npx or uvx without installing),
    /// `installed` (downloaded by this bridge), `custom`.
    var source: String
    var added: Bool
    /// `ready`, `checking`, `installing`, `notAdded`, `needsBrain`, `needsKey`, `needsSignIn`,
    /// `missingRuntime`, `failed`.
    var state: String
    var runtime: String?
    var failure: String?
    var models: [AcpSessionFacts.Choice]
    var currentModel: String?
    var efforts: [AcpSessionFacts.Choice]
    var keys: [Key]
    var signIn: [Method]
    var brain: AgentLedger.Brain?
    /// `hermes` or `openAIEnvironment` when the agent can be given a brain by this bridge.
    var brainStyle: String?
    var distribution: String?
    var checkedAt: Date?
}

struct AgentsReport: Codable, Sendable, Equatable {
    var agents: [AgentRow]
    var brains: [LocalBrain]
}

/// One registry agent as the "More agents" list shows it.
struct RegistryRow: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var version: String
    var description: String?
    var icon: String?
    var authors: [String]?
    var website: String?
    /// `npx`, `uvx` or `download`; nil when nothing in the registry runs on this platform.
    var distribution: String?
    var installable: Bool
    var runtime: String?
    /// `found`, `added`, `installed` or nil.
    var here: String?
}

/// A model a ready agent offers, as `GET /models` lists it beside Claude's.
struct AgentModelRow: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var provider: String
    var providerName: String
    var agent: Bool
    var variants: [String]?
    var contextWindow: Int?
}

struct BrainRequest: Codable, Sendable {
    /// `local` (a server on this machine) or `key` (a provider reached with a pasted key).
    var kind: String
    var brain: String?
    var model: String?
    var provider: String?
    var key: String?
}

enum AgentServiceError: Error, CustomStringConvertible, Sendable {
    case unknown(String)
    case refused(String)

    var description: String {
        switch self {
        case .unknown(let id): return "There is no agent \(id) on this machine."
        case .refused(let why): return why
        }
    }
}

/// The agents a machine can run besides Claude Code: which exist here, which somebody added, what
/// the last proof found, and how to start each. Proof is a real session opened and closed, never a
/// binary found on PATH; it runs on add, on request, after a brain, key or sign-in changes, and once
/// a day for an added agent — never at every start.
actor AgentService {
    let home: String
    let directory: URL
    private var ledger: AgentLedger
    private var registry: [RegistryAgent]
    private var registryFetchedAt: Date?
    private var brainCache: (at: Date, brains: [LocalBrain])?
    private var probing: Set<String> = []
    private var installing: Set<String> = []
    private var signIns: [String: AgentSignIn] = [:]
    private var onChange: (@Sendable () -> Void)?
    private let fetchRegistry: @Sendable () async -> Data?

    static let registryURL = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
    static let reproveAfter: TimeInterval = 24 * 3_600

    init(
        home: String, stateDirectory: URL,
        fetchRegistry: @escaping @Sendable () async -> Data? = { await AgentService.download(AgentService.registryURL) }
    ) {
        self.home = home
        directory = stateDirectory.appendingPathComponent("agents")
        ledger = AgentLedger.load(from: directory.appendingPathComponent("state.json"))
        let cached = directory.appendingPathComponent("registry.json")
        registry = (try? Data(contentsOf: cached)).flatMap(Self.parseRegistry) ?? []
        registryFetchedAt = (try? FileManager.default.attributesOfItem(atPath: cached.path))?[
            .modificationDate] as? Date
        self.fetchRegistry = fetchRegistry
    }

    func observe(_ change: @escaping @Sendable () -> Void) { onChange = change }

    private var ledgerURL: URL { directory.appendingPathComponent("state.json") }
    private var probeDirectory: URL { directory.appendingPathComponent("probe") }

    // MARK: - Reading

    func report(refreshBrains: Bool = false) async -> AgentsReport {
        await refreshRegistryIfStale()
        reproveStale()
        let brains = await localBrains(refresh: refreshBrains)
        return AgentsReport(agents: listedIDs().compactMap { row($0, brains: brains) }, brains: brains)
    }

    func registryRows() async -> [RegistryRow] {
        await refreshRegistryIfStale(force: registry.isEmpty)
        return registry.filter { !AgentRecipes.excludedRegistryIDs.contains($0.id) }.map { agent in
            let runtime = agent.distribution?.runtime
            let missing = runtime.map { !hasRuntime($0) } ?? false
            var here: String?
            if ledger.added.contains(agent.id) {
                here = "added"
            } else if ledger.installed[agent.id] != nil {
                here = "installed"
            } else if foundCommand(agent.id) != nil {
                here = "found"
            }
            return RegistryRow(
                id: agent.id, name: agent.name, version: agent.version, description: agent.description,
                icon: agent.icon, authors: agent.authors, website: agent.website,
                distribution: agent.distribution?.kindWord,
                installable: agent.distribution != nil && !missing, runtime: missing ? runtime : nil,
                here: here)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The models every ready agent offers, for `/models`.
    func modelRows() async -> [AgentModelRow] {
        if ledger.brains.values.contains(where: { $0.kind == "local" }) {
            _ = await localBrains(refresh: false)
        }
        return ledger.added.compactMap { id -> [AgentModelRow]? in
            guard let probe = ledger.probes[id], probe.state == "ready" else { return nil }
            let name = displayName(id)
            let efforts = probe.efforts.map(\.id)
            let offered = visibleModels(id, probe)
            let models = offered.isEmpty
                ? [AcpSessionFacts.Choice(id: Self.defaultModelID, name: name)] : offered
            return models.map { model in
                AgentModelRow(
                    id: model.id, name: prettyModelName(model, agent: id), provider: id,
                    providerName: name, agent: true, variants: efforts.isEmpty ? nil : efforts,
                    contextWindow: nil)
            }
        }.flatMap { $0 }
    }

    /// The model id that means "whatever the agent uses", for an agent that offers no choice.
    static let defaultModelID = "default"

    func isAgent(_ id: String) -> Bool { ledger.added.contains(id) }

    func isReady(_ id: String) -> Bool {
        ledger.added.contains(id) && ledger.probes[id]?.state == "ready"
    }

    func displayName(_ id: String) -> String {
        if let custom = ledger.custom[id] { return custom.name }
        if let recipe = AgentRecipes.recipe(id) { return recipe.name }
        return registry.first { $0.id == id }?.name ?? id
    }

    func authMethods(_ id: String) -> [AcpAgentFacts.AuthMethod] {
        ledger.probes[id]?.authMethods ?? []
    }

    /// How a conversation with this agent is started, in `directory`.
    func launch(for id: String, directory: String) -> AcpConnection.Launch? {
        guard let base = invocation(id) else { return nil }
        return AcpConnection.Launch(
            executable: base.executable, arguments: base.prefix + base.acpArgs,
            environment: environment(for: id, extra: base.environment), directory: directory)
    }

    // MARK: - Changing

    func add(_ id: String) async throws -> AgentRow {
        guard knows(id) else { throw AgentServiceError.unknown(id) }
        if !ledger.added.contains(id) { ledger.added.append(id) }
        save()
        await prove(id)
        return currentRow(id)
    }

    func remove(_ id: String) {
        ledger.added.removeAll { $0 == id }
        ledger.probes[id] = nil
        save()
    }

    func check(_ id: String) async throws -> AgentRow {
        guard knows(id) else { throw AgentServiceError.unknown(id) }
        await prove(id)
        return currentRow(id)
    }

    /// Puts a registry agent on this machine: an archive is downloaded, checked against the
    /// registry's sha256 and unpacked under the bridge's own directory; a package run by npx or uvx
    /// needs nothing on disk and is fetched by its first run. Either way it is added and proved.
    func install(_ id: String) async throws -> AgentRow {
        await refreshRegistryIfStale(force: registry.isEmpty)
        guard let agent = registry.first(where: { $0.id == id }), let distribution = agent.distribution
        else { throw AgentServiceError.unknown(id) }
        if let runtime = distribution.runtime, !hasRuntime(runtime) {
            throw AgentServiceError.refused(
                runtime == "node"
                    ? "\(agent.name) runs with npx, and Node.js is not installed on this machine."
                    : "\(agent.name) runs with uvx, and uv is not installed on this machine.")
        }
        installing.insert(id)
        changed()
        defer {
            installing.remove(id)
            changed()
        }
        if case .binary(let archive, let command, let args, let sha256) = distribution {
            let installed = try await Self.unpack(
                archive: archive, command: command, sha256: sha256,
                into: directory.appendingPathComponent(id).appendingPathComponent(agent.version))
            ledger.installed[id] = AgentLedger.Installed(
                version: agent.version, executable: installed, args: args)
        }
        if !ledger.added.contains(id) { ledger.added.append(id) }
        save()
        installing.remove(id)
        await prove(id)
        return currentRow(id)
    }

    func setKey(_ id: String, env name: String, value: String) async throws -> AgentRow {
        guard knows(id) else { throw AgentServiceError.unknown(id) }
        guard AgentKeys.isValidName(name), AgentKeys.isValidValue(value) else {
            throw AgentServiceError.refused("That key cannot be kept: it has to be one line.")
        }
        var keys = AgentKeys.read(in: directory, agent: id)
        keys[name] = value
        AgentKeys.write(keys, in: directory, agent: id)
        if !ledger.added.contains(id) { ledger.added.append(id) }
        save()
        await prove(id)
        return currentRow(id)
    }

    /// Gives an agent a model to think with, the way its own setup would have: Hermes through
    /// `hermes config set`, an OpenAI-compatible agent through the environment it is started in.
    func setBrain(_ id: String, _ request: BrainRequest) async throws -> AgentRow {
        guard knows(id), let style = brainStyle(id) else {
            throw AgentServiceError.refused("\(displayName(id)) is not given a brain by this machine.")
        }
        switch request.kind {
        case "local":
            let brains = await localBrains(refresh: true)
            guard let brain = brains.first(where: { $0.id == request.brain }) ?? brains.first,
                let model = request.model ?? brain.models.first?.id
            else {
                throw AgentServiceError.refused("No model server answered on this machine.")
            }
            try await applyLocalBrain(id, style: style, baseURL: brain.baseURL, model: model)
            ledger.brains[id] = AgentLedger.Brain(
                kind: "local", name: brain.name, baseURL: brain.baseURL, model: model, provider: nil)
        case "key":
            guard style == .hermes, let provider = request.provider,
                let spec = Self.keyProviders.first(where: { $0.id == provider }),
                let key = request.key, AgentKeys.isValidValue(key)
            else { throw AgentServiceError.refused("That provider and key cannot be used.") }
            var keys = AgentKeys.read(in: directory, agent: id)
            keys[spec.env] = key
            AgentKeys.write(keys, in: directory, agent: id)
            try await hermesConfig(
                id, [["model.provider", provider]], unset: ["model.base_url", "model.default", "model.api_key"])
            ledger.brains[id] = AgentLedger.Brain(
                kind: "key", name: spec.name, baseURL: nil, model: request.model, provider: provider)
        default:
            throw AgentServiceError.refused("Unknown brain \(request.kind).")
        }
        if !ledger.added.contains(id) { ledger.added.append(id) }
        save()
        await prove(id)
        return currentRow(id)
    }

    /// The providers Hermes can be handed a key for, and the variable it reads each from.
    static let keyProviders: [(id: String, name: String, env: String)] = [
        ("openrouter", "OpenRouter", "OPENROUTER_API_KEY"),
        ("anthropic", "Anthropic", "ANTHROPIC_API_KEY"),
        ("deepseek", "DeepSeek", "DEEPSEEK_API_KEY"),
        ("xai", "xAI", "XAI_API_KEY"),
    ]

    func startSignIn(_ id: String, method: String) async throws -> AgentSignInState {
        guard knows(id), let base = invocation(id) else { throw AgentServiceError.unknown(id) }
        signIns[id]?.cancel()
        let methods = ledger.probes[id]?.authMethods ?? []
        guard let chosen = methods.first(where: { $0.id == method }) ?? methods.first else {
            throw AgentServiceError.refused("\(displayName(id)) offers no way to sign in from here.")
        }
        let session = AgentSignIn(agent: id, method: chosen.id) { [weak self] finished in
            Task { await self?.signInEnded(id, finished) }
        }
        try? FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        if chosen.kind == "terminal" {
            try session.start(
                executable: base.executable, arguments: base.prefix + chosen.args,
                environment: environment(for: id, extra: base.environment.merging(chosen.env) { _, new in new }),
                directory: probeDirectory.path)
        } else {
            let launch = AcpConnection.Launch(
                executable: base.executable, arguments: base.prefix + base.acpArgs,
                environment: environment(for: id, extra: base.environment), directory: probeDirectory.path)
            Task { await self.authenticate(launch: launch, method: chosen.id, session: session) }
        }
        signIns[id] = session
        changed()
        return session.snapshot()
    }

    func signInState(_ id: String) -> AgentSignInState? { signIns[id]?.snapshot() }

    func signInInput(_ id: String, text: String) {
        signIns[id]?.send(text)
    }

    func cancelSignIn(_ id: String) {
        signIns[id]?.cancel()
        changed()
    }

    // MARK: - Proof

    /// Opens a real session in the agent and closes it again. What it answered, or the words it
    /// failed with, is the agent's state until the next proof.
    private func prove(_ id: String) async {
        guard !probing.contains(id) else { return }
        guard let base = invocation(id) else {
            ledger.probes[id] = AgentLedger.Probe(
                state: "missingRuntime", checkedAt: Date(), version: nil, models: [], currentModel: nil,
                efforts: [], failure: nil, authMethods: [])
            save()
            return
        }
        if let runtime = base.runtime, !hasRuntime(runtime) {
            ledger.probes[id] = AgentLedger.Probe(
                state: "missingRuntime", checkedAt: Date(), version: nil, models: [], currentModel: nil,
                efforts: [], failure: runtime, authMethods: [])
            save()
            return
        }
        probing.insert(id)
        changed()
        defer {
            probing.remove(id)
            changed()
        }
        try? FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        let launch = AcpConnection.Launch(
            executable: base.executable, arguments: base.prefix + base.acpArgs,
            environment: environment(for: id, extra: base.environment), directory: probeDirectory.path)
        let connection = AcpConnection(launch: launch)
        var facts = AcpAgentFacts()
        var probe = AgentLedger.Probe(
            state: "failed", checkedAt: Date(), version: nil, models: [], currentModel: nil, efforts: [],
            failure: nil, authMethods: [])
        do {
            try await connection.start()
            facts = try await connection.initialize()
            probe.version = facts.version
            probe.authMethods = facts.authMethods
            let session = try await connection.newSession(directory: probeDirectory.path)
            probe.state = "ready"
            probe.models = session.models
            probe.currentModel = session.currentModel
            probe.efforts = session.efforts
        } catch let failure as AcpFailure {
            probe.authMethods = facts.authMethods
            var text = failure.description
            if case .exited = failure, text.isEmpty { text = await connection.stderrTail() }
            probe.failure = String(text.prefix(600))
            probe.state = classify(id, failure: failure, text: text, facts: facts)
        } catch {
            probe.failure = String(error.localizedDescription.prefix(600))
            probe.state = "failed"
        }
        await connection.close()
        ledger.probes[id] = probe
        save()
    }

    private func classify(_ id: String, failure: AcpFailure, text: String, facts: AcpAgentFacts) -> String {
        let lowered = text.lowercased()
        let unsetKeys = keySpecs(id).filter { AgentKeys.read(in: directory, agent: id)[$0.env] == nil }
        if brainStyle(id) != nil,
            lowered.contains("no llm provider") || lowered.contains("provider configured")
                || lowered.contains("no model") || lowered.contains("model not configured")
        {
            return "needsBrain"
        }
        if failure.isAuthRequired || lowered.contains("api key") || lowered.contains("api_key")
            || lowered.contains("unauthorized") || lowered.contains("401")
        {
            if !unsetKeys.isEmpty { return "needsKey" }
            if !facts.authMethods.isEmpty { return "needsSignIn" }
        }
        if case .timedOut = failure { return "failed" }
        return "failed"
    }

    /// A sign-in the agent runs itself: `authenticate` over ACP, with whatever the agent prints on
    /// stderr meanwhile — usually the link to open — relayed as the sign-in's lines.
    private func authenticate(launch: AcpConnection.Launch, method: String, session: AgentSignIn) async {
        let connection = AcpConnection(launch: launch)
        let relay = Task {
            while !Task.isCancelled {
                session.record(await connection.stderrTail())
                try? await Task.sleep(for: .seconds(1))
            }
        }
        var succeeded = false
        do {
            try await connection.start()
            _ = try await connection.initialize()
            try await connection.authenticate(method: method)
            succeeded = true
        } catch {
            session.record(await connection.stderrTail() + "\n" + String(describing: error))
        }
        relay.cancel()
        await connection.close()
        session.finish(succeeded: succeeded)
    }

    private func signInEnded(_ id: String, _ session: AgentSignIn) async {
        guard signIns[id] === session else { return }
        changed()
        if session.succeeded { await prove(id) }
    }

    private func reproveStale() {
        let now = Date()
        for id in ledger.added where !probing.contains(id) {
            guard let probe = ledger.probes[id] else {
                Task { await self.prove(id) }
                continue
            }
            if now.timeIntervalSince(probe.checkedAt) > Self.reproveAfter {
                Task { await self.prove(id) }
            }
        }
    }

    // MARK: - Brains

    private func localBrains(refresh: Bool) async -> [LocalBrain] {
        if !refresh, let cache = brainCache, Date().timeIntervalSince(cache.at) < 60 { return cache.brains }
        let brains = await BrainFinder.find()
        brainCache = (Date(), brains)
        return brains
    }

    private func applyLocalBrain(_ id: String, style: AgentBrainStyle, baseURL: String, model: String)
        async throws
    {
        switch style {
        case .hermes:
            try await hermesConfig(
                id,
                [["model.provider", "custom"], ["model.base_url", baseURL], ["model.default", model]],
                unset: ["model.api_key"])
        case .openAIEnvironment:
            var keys = AgentKeys.read(in: directory, agent: id)
            keys["OPENAI_BASE_URL"] = baseURL
            keys["OPENAI_API_KEY"] = keys["OPENAI_API_KEY"] ?? "local"
            keys["OPENAI_MODEL"] = model
            AgentKeys.write(keys, in: directory, agent: id)
        }
    }

    private func hermesConfig(_ id: String, _ pairs: [[String]], unset: [String]) async throws {
        guard let base = invocation(id) else { throw AgentServiceError.unknown(id) }
        let environment = CommandLocator.environment(
            home: home, extra: base.environment.merging(AgentKeys.read(in: directory, agent: id)) { _, new in new })
        for key in unset {
            _ = await Self.run(base.executable, base.prefix + ["config", "unset", key], environment: environment)
        }
        for pair in pairs {
            let status = await Self.run(
                base.executable, base.prefix + ["config", "set", pair[0], pair[1]], environment: environment)
            guard status == 0 else {
                throw AgentServiceError.refused("Hermes would not take its \(pair[0]) (exit \(status)).")
            }
        }
    }

    /// The models an agent offers, narrowed for one that thinks with a local server to the ones
    /// that server lists for agents — an agent pointed at llama-swap otherwise offers every filter
    /// and phone twin on it. The model it is set to always stays.
    private func visibleModels(_ id: String, _ probe: AgentLedger.Probe) -> [AcpSessionFacts.Choice] {
        guard let brain = ledger.brains[id], brain.kind == "local",
            let server = brainCache?.brains.first(where: { $0.baseURL == brain.baseURL })
        else { return probe.models }
        let listed = Set(server.models.map(\.id))
        let kept = probe.models.filter { model in
            let bare = model.id.hasPrefix("custom:") ? String(model.id.dropFirst("custom:".count)) : model.id
            return listed.contains(bare) || model.id == probe.currentModel
        }
        return kept.isEmpty ? probe.models : kept
    }

    private func prettyModelName(_ model: AcpSessionFacts.Choice, agent: String) -> String {
        guard let brain = ledger.brains[agent], brain.kind == "local",
            let brains = brainCache?.brains, let server = brains.first(where: { $0.baseURL == brain.baseURL })
        else { return model.name }
        let bare = model.id.hasPrefix("custom:") ? String(model.id.dropFirst("custom:".count)) : model.id
        return server.models.first { $0.id == bare }?.name ?? model.name
    }

    // MARK: - How agents are run

    private struct Invocation {
        var executable: String
        var prefix: [String]
        var acpArgs: [String]
        var environment: [String: String]
        var runtime: String?
        var source: String
    }

    private func invocation(_ id: String) -> Invocation? {
        if let custom = ledger.custom[id], let path = CommandLocator.find(custom.command, home: home) {
            return Invocation(
                executable: path, prefix: [], acpArgs: custom.args, environment: [:], runtime: nil,
                source: "custom")
        }
        if let installed = ledger.installed[id], FileManager.default.isExecutableFile(atPath: installed.executable) {
            return Invocation(
                executable: installed.executable, prefix: [], acpArgs: installed.args, environment: [:],
                runtime: nil, source: "installed")
        }
        if let found = foundCommand(id) {
            let args = AgentRecipes.recipe(id)?.args ?? registryArgs(id) ?? []
            return Invocation(
                executable: found, prefix: [], acpArgs: args, environment: [:], runtime: nil, source: "found")
        }
        guard let distribution = AgentRecipes.recipe(id)?.fallback ?? registry.first(where: { $0.id == id })?.distribution
        else { return nil }
        switch distribution {
        case .npx(let package, let args, let env):
            let npx = CommandLocator.find("npx", home: home) ?? "npx"
            return Invocation(
                executable: npx, prefix: ["-y", package], acpArgs: args, environment: env, runtime: "node",
                source: "available")
        case .uvx(let package, let command, let args, let env):
            let uvx = CommandLocator.find("uvx", home: home) ?? "uvx"
            let prefix = command.map { ["--from", package, $0] } ?? [package]
            return Invocation(
                executable: uvx, prefix: prefix, acpArgs: args, environment: env, runtime: "uv",
                source: "available")
        case .binary:
            return nil
        }
    }

    private func registryArgs(_ id: String) -> [String]? {
        switch registry.first(where: { $0.id == id })?.distribution {
        case .npx(_, let args, _), .uvx(_, _, let args, _), .binary(_, _, let args, _): return args
        case nil: return nil
        }
    }

    private func foundCommand(_ id: String) -> String? {
        guard let recipe = AgentRecipes.recipe(id) else { return nil }
        for command in recipe.commands {
            if let path = CommandLocator.find(command, home: home) { return path }
        }
        return nil
    }

    private func environment(for id: String, extra: [String: String]) -> [String: String] {
        CommandLocator.environment(
            home: home, extra: extra.merging(AgentKeys.read(in: directory, agent: id)) { _, new in new })
    }

    private func hasRuntime(_ runtime: String) -> Bool {
        switch runtime {
        case "node": return CommandLocator.find("npx", home: home) != nil
        case "uv": return CommandLocator.find("uvx", home: home) != nil
        default: return true
        }
    }

    private func knows(_ id: String) -> Bool {
        AgentRecipes.recipe(id) != nil || ledger.custom[id] != nil || registry.contains { $0.id == id }
            || ledger.installed[id] != nil
    }

    private func brainStyle(_ id: String) -> AgentBrainStyle? { AgentRecipes.recipe(id)?.brain }

    private func keySpecs(_ id: String) -> [AgentKeySpec] { AgentRecipes.recipe(id)?.keys ?? [] }

    /// Every agent the machine's list shows: what was added, what is on PATH, and the agents this
    /// bridge can run without anything installed that are worth naming up front: Hermes, and any
    /// recipe the registry does not carry, whose install press would otherwise be nowhere.
    private func listedIDs() -> [String] {
        var ids = ledger.added
        for recipe in AgentRecipes.all where !ids.contains(recipe.id) {
            if foundCommand(recipe.id) != nil {
                ids.append(recipe.id)
            } else if let runtime = recipe.fallback?.runtime, hasRuntime(runtime),
                recipe.id == "hermes" || !registry.contains(where: { $0.id == recipe.id })
            {
                ids.append(recipe.id)
            }
        }
        for id in ledger.installed.keys.sorted() where !ids.contains(id) { ids.append(id) }
        return ids
    }

    private func currentRow(_ id: String) -> AgentRow {
        row(id, brains: brainCache?.brains ?? [])
            ?? AgentRow(
                id: id, name: displayName(id), source: "available", added: false, state: "failed",
                models: [], efforts: [], keys: [], signIn: [])
    }

    private func row(_ id: String, brains: [LocalBrain]) -> AgentRow? {
        let base = invocation(id)
        let added = ledger.added.contains(id)
        let probe = ledger.probes[id]
        let registryEntry = registry.first { $0.id == id }
        let recipe = AgentRecipes.recipe(id)
        var state: String
        if installing.contains(id) {
            state = "installing"
        } else if probing.contains(id) {
            state = "checking"
        } else if !added {
            state = "notAdded"
        } else if base == nil {
            state = "missingRuntime"
        } else if let runtime = base?.runtime, !hasRuntime(runtime) {
            state = "missingRuntime"
        } else {
            state = probe?.state ?? "checking"
        }
        if signIns[id]?.isRunning == true, state != "checking" { state = "needsSignIn" }
        let keyValues = AgentKeys.read(in: directory, agent: id)
        return AgentRow(
            id: id, name: displayName(id),
            version: probe?.version ?? ledger.installed[id]?.version,
            description: recipe?.description ?? registryEntry?.description,
            icon: registryEntry?.icon, website: recipe?.website ?? registryEntry?.website,
            source: base?.source ?? "available", added: added, state: state,
            runtime: state == "missingRuntime" ? (base?.runtime ?? registryEntry?.distribution?.runtime) : nil,
            failure: state == "failed" || state == "needsBrain" || state == "needsKey" || state == "needsSignIn"
                ? probe?.failure : nil,
            models: (probe.map { visibleModels(id, $0) } ?? []).map {
                AcpSessionFacts.Choice(id: $0.id, name: prettyModelName($0, agent: id), description: $0.description)
            },
            currentModel: probe?.currentModel, efforts: probe?.efforts ?? [],
            keys: keySpecs(id).map {
                AgentRow.Key(env: $0.env, name: $0.name, url: $0.url, set: keyValues[$0.env] != nil)
            },
            signIn: (probe?.authMethods ?? []).map {
                AgentRow.Method(id: $0.id, name: $0.name, description: $0.description, kind: $0.kind)
            },
            brain: ledger.brains[id], brainStyle: brainStyle(id)?.rawValue,
            distribution: (recipe?.fallback ?? registryEntry?.distribution)?.kindWord,
            checkedAt: probe?.checkedAt)
    }

    private func save() {
        ledger.write(to: ledgerURL)
        changed()
    }

    private func changed() { onChange?() }

    // MARK: - Registry

    private func refreshRegistryIfStale(force: Bool = false) async {
        if !force, let fetched = registryFetchedAt, Date().timeIntervalSince(fetched) < 24 * 3_600 { return }
        guard let data = await fetchRegistry(), let parsed = Self.parseRegistry(data), !parsed.isEmpty else {
            return
        }
        registry = parsed
        registryFetchedAt = Date()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("registry.json"), options: .atomic)
    }

    static func parseRegistry(_ data: Data) -> [RegistryAgent]? {
        struct File: Decodable {
            var agents: [Lenient]
        }
        struct Lenient: Decodable {
            var value: RegistryAgent?
            init(from decoder: Decoder) throws { value = try? RegistryAgent(from: decoder) }
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return file.agents.compactMap(\.value)
    }

    static func download(_ address: String) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("claude-bridge", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    // MARK: - Processes

    static func run(_ executable: String, _ arguments: [String], environment: [String: String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                finished.releaseFinished()
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.runAllowingBusyExecutable()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    private static func unpack(archive: String, command: String, sha256: String?, into target: URL) async throws
        -> String
    {
        guard let url = URL(string: archive) else { throw AgentServiceError.refused("The archive's address is not a URL.") }
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AgentServiceError.refused("The download did not arrive.")
        }
        if let sha256, AgentChecksum.sha256(of: file)?.lowercased() != sha256.lowercased() {
            try? FileManager.default.removeItem(at: file)
            throw AgentServiceError.refused("The download did not match the registry's checksum, so it was thrown away.")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let named = target.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: named)
        let status: Int32
        if named.pathExtension == "zip" {
            status = await run(
                CommandLocator.find("unzip", home: NSHomeDirectory()) ?? "/usr/bin/unzip",
                ["-q", "-o", named.path, "-d", target.path], environment: [:])
        } else {
            status = await run(
                CommandLocator.find("tar", home: NSHomeDirectory()) ?? "/usr/bin/tar",
                ["-xf", named.path, "-C", target.path], environment: [:])
        }
        try? FileManager.default.removeItem(at: named)
        guard status == 0 else { throw AgentServiceError.refused("The archive would not unpack (exit \(status)).") }
        let relative = command.hasPrefix("./") ? String(command.dropFirst(2)) : command
        let executable = target.appendingPathComponent(relative).path
        guard FileManager.default.fileExists(atPath: executable) else {
            throw AgentServiceError.refused("The archive held no \(relative).")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
        return executable
    }
}
