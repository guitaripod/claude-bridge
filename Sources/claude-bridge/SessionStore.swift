import Foundation

/// Thread-safe fan-out of ``BridgeEvent``s to any number of subscribed SSE clients for one session.
final class Broadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<BridgeEvent>.Continuation] = [:]

    var hasSubscribers: Bool {
        lock.withLock { !continuations.isEmpty }
    }

    func subscribe() -> (id: UUID, stream: AsyncStream<BridgeEvent>) {
        let id = UUID()
        let stream = AsyncStream<BridgeEvent> { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
        return (id, stream)
    }

    func send(_ event: BridgeEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(event) }
    }
}

actor SessionStore {
    private var sessions: [String: Session] = [:]
    private var order: [String] = []
    private var broadcasters: [String: Broadcaster] = [:]
    private let runner: ClaudeRunner
    private let defaultModel: String
    private let defaultEffort: String
    private let storeURL: URL
    private var hiddenTranscripts: Set<String>
    private var runnerTurnClaudeIDs: Set<String> = []

    init(runner: ClaudeRunner, defaultModel: String, defaultEffort: String, storeURL: URL) {
        self.runner = runner
        self.defaultModel = defaultModel
        self.defaultEffort = defaultEffort
        self.storeURL = storeURL
        hiddenTranscripts = Self.loadHidden(from: Self.hiddenURL(for: storeURL))
        for session in Self.loadStored(from: storeURL) {
            sessions[session.id] = session
            order.append(session.id)
        }
    }

    func list(
        activeClaudeIDs: Set<String> = [], transcriptDates: [String: Date] = [:]
    ) -> [SessionSummary] {
        order.compactMap { id -> SessionSummary? in
            guard let session = sessions[id] else { return nil }
            var summary = session.summary
            let claudeID = session.claudeSessionID ?? session.id
            summary.active = activeClaudeIDs.contains(claudeID)
            if let fresh = transcriptDates[claudeID], fresh > summary.updatedAt {
                summary.updatedAt = fresh
            }
            return summary
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func get(_ id: String) -> Session? { sessions[id] }

    /// Claude session ids already represented by a stored session, plus transcripts the user
    /// deleted — both are excluded from transcript discovery.
    func excludedTranscriptIDs() -> (claimed: Set<String>, hidden: Set<String>) {
        var claimed = Set(sessions.keys)
        for session in sessions.values {
            if let claudeID = session.claudeSessionID { claimed.insert(claudeID) }
        }
        return (claimed, hiddenTranscripts)
    }

    /// Materializes a discovered transcript as a stored session so it can be resumed, forked,
    /// or cleared. The session keeps the Claude session id as its own id, so client-held ids
    /// stay valid across adoption.
    func adopt(_ session: Session) -> Session {
        if let existing = sessions[session.id] { return existing }
        sessions[session.id] = session
        order.insert(session.id, at: 0)
        persist()
        return session
    }

    func hideTranscript(_ id: String) {
        hiddenTranscripts.insert(id)
        persistHidden()
    }

    func create(_ request: CreateRequest) -> Session {
        let now = Date()
        let session = Session(
            id: UUID().uuidString,
            title: request.title ?? "New chat",
            directory: Self.normalizedDirectory(request.directory),
            claudeSessionID: nil,
            model: request.model ?? defaultModel,
            effort: request.effort ?? defaultEffort,
            createdAt: now, updatedAt: now, messages: [], lastCostUSD: nil, lastTokens: nil,
            pendingFork: nil)
        sessions[session.id] = session
        order.insert(session.id, at: 0)
        persist()
        return session
    }

    /// Branches a session: a new session seeded with the source's history and resumable id, flagged
    /// to run its first turn with `--fork-session` so Claude diverges instead of mutating the parent.
    func fork(_ id: String) -> Session? {
        guard let source = sessions[id] else { return nil }
        let now = Date()
        let session = Session(
            id: UUID().uuidString,
            title: "Fork of \(source.title)",
            directory: source.directory,
            claudeSessionID: source.claudeSessionID,
            model: source.model,
            effort: source.effort,
            createdAt: now, updatedAt: now,
            messages: source.messages,
            lastCostUSD: source.lastCostUSD, lastTokens: source.lastTokens,
            pendingFork: source.claudeSessionID != nil ? true : nil)
        sessions[session.id] = session
        order.insert(session.id, at: 0)
        persist()
        return session
    }

    func rename(_ id: String, title: String) -> Bool {
        guard var session = sessions[id] else { return false }
        session.title = title
        sessions[id] = session
        persist()
        return true
    }

    func delete(_ id: String) {
        sessions[id] = nil
        order.removeAll { $0 == id }
        broadcasters[id] = nil
        persist()
    }

    /// Resets a session to a fresh Claude conversation (drops history and the resumable id).
    func clear(_ id: String) {
        guard var session = sessions[id] else { return }
        session.messages = []
        session.claudeSessionID = nil
        session.updatedAt = Date()
        sessions[id] = session
        persist()
    }

    func broadcaster(for id: String) -> Broadcaster {
        if let existing = broadcasters[id] { return existing }
        let created = Broadcaster()
        broadcasters[id] = created
        return created
    }

    /// Appends the user's prompt, runs a Claude turn, and streams events to subscribers.
    func send(_ id: String, request: SendRequest) {
        guard var session = sessions[id] else { return }
        if let model = request.model { session.model = model }
        if let effort = request.effort { session.effort = effort }

        let userMessage = Message(
            id: UUID().uuidString, role: .user, parts: [.text(request.text)], createdAt: Date())
        session.messages.append(userMessage)
        if session.title == "New chat" { session.title = Self.deriveTitle(request.text) }
        session.updatedAt = Date()
        sessions[id] = session
        moveToFront(id)
        persist()

        let caster = broadcaster(for: id)
        caster.send(.messageUpserted(userMessage))

        let runner = self.runner
        let resume = session.claudeSessionID
        let model = session.model
        let effort = session.effort
        let text = request.text
        let fork = session.pendingFork == true
        let directory = session.directory

        let turnClaudeID = resume ?? id
        runnerTurnClaudeIDs.insert(turnClaudeID)
        Task {
            let outcome = await runner.run(
                prompt: text, resume: resume, model: model, effort: effort, fork: fork,
                directory: directory,
                onStart: { pid in Task { await self.registerTurnProcess(id, pid: pid) } },
                emit: { caster.send($0) })
            await self.finishTurn(id, outcome: outcome, turnClaudeID: turnClaudeID)
        }
    }

    private var turnProcessIDs: [String: Int32] = [:]

    private func registerTurnProcess(_ id: String, pid: Int32) {
        turnProcessIDs[id] = pid
    }

    /// Stops a turn this bridge is running by terminating its claude process;
    /// the runner's stream ends and the partial turn is persisted normally.
    func abortTurn(_ id: String) -> Bool {
        guard let pid = turnProcessIDs[id] else { return false }
        kill(pid, SIGTERM)
        return true
    }

    func hasRunnerTurnInFlight(claudeSessionID: String) -> Bool {
        runnerTurnClaudeIDs.contains(claudeSessionID)
    }

    /// True while this bridge's own runner is (or was, within the window)
    /// writing the session's transcript — used to tell our own transcript
    /// residue apart from an external process working in the session.
    func recentRunnerActivity(claudeSessionID: String, within seconds: TimeInterval) -> Bool {
        if runnerTurnClaudeIDs.contains(claudeSessionID) { return true }
        guard let finished = lastRunnerFinish[claudeSessionID] else { return false }
        return Date().timeIntervalSince(finished) < seconds
    }

    private var lastRunnerFinish: [String: Date] = [:]

    private func finishTurn(_ id: String, outcome: ClaudeRunner.Outcome, turnClaudeID: String) {
        turnProcessIDs[id] = nil
        runnerTurnClaudeIDs.remove(turnClaudeID)
        lastRunnerFinish[turnClaudeID] = Date()
        if let newID = outcome.claudeSessionID { lastRunnerFinish[newID] = Date() }
        guard var session = sessions[id] else { return }
        session.messages.append(outcome.message)
        session.claudeSessionID = outcome.claudeSessionID
        session.pendingFork = nil
        if let cost = outcome.costUSD { session.lastCostUSD = cost }
        if let tokens = outcome.tokens { session.lastTokens = tokens }
        session.updatedAt = Date()
        sessions[id] = session
        moveToFront(id)
        persist()
    }

    private func moveToFront(_ id: String) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    private static func deriveTitle(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return String(firstLine.prefix(60))
    }

    private static func hiddenURL(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("hidden.json")
    }

    private static func loadHidden(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
            let ids = try? JSONCoding.decoder.decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    private func persistHidden() {
        let url = Self.hiddenURL(for: storeURL)
        guard let data = try? JSONCoding.encoder.encode(hiddenTranscripts.sorted()) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func loadStored(from url: URL) -> [Session] {
        guard let data = try? Data(contentsOf: url),
            let stored = try? JSONCoding.decoder.decode([Session].self, from: data)
        else { return [] }
        return stored
    }

    /// Expands `~`, requires an existing absolute path; falls back to the
    /// global workdir (nil) rather than letting the claude process die on a
    /// bad cwd.
    private static func normalizedDirectory(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        else { return nil }
        if path.hasPrefix("~") {
            path = NSString(string: path).expandingTildeInPath
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return path
    }

    private func persist() {
        let snapshot = order.compactMap { sessions[$0] }
        let url = storeURL
        guard let data = try? JSONCoding.encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

enum JSONCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
