import Foundation

/// Thread-safe fan-out of ``BridgeEvent``s to any number of subscribed SSE clients for one session.
final class Broadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<BridgeEvent>.Continuation] = [:]

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

    init(runner: ClaudeRunner, defaultModel: String, defaultEffort: String, storeURL: URL) {
        self.runner = runner
        self.defaultModel = defaultModel
        self.defaultEffort = defaultEffort
        self.storeURL = storeURL
        for session in Self.loadStored(from: storeURL) {
            sessions[session.id] = session
            order.append(session.id)
        }
    }

    func list() -> [SessionSummary] {
        order.compactMap { sessions[$0]?.summary }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func get(_ id: String) -> Session? { sessions[id] }

    func create(_ request: CreateRequest) -> Session {
        let now = Date()
        let session = Session(
            id: UUID().uuidString,
            title: request.title ?? "New chat",
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

        let caster = broadcaster(for: id)
        caster.send(.messageUpserted(userMessage))

        let runner = self.runner
        let resume = session.claudeSessionID
        let model = session.model
        let effort = session.effort
        let text = request.text
        let fork = session.pendingFork == true

        Task {
            let outcome = await runner.run(
                prompt: text, resume: resume, model: model, effort: effort, fork: fork,
                emit: { caster.send($0) })
            await self.finishTurn(id, outcome: outcome)
        }
    }

    private func finishTurn(_ id: String, outcome: ClaudeRunner.Outcome) {
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

    private static func loadStored(from url: URL) -> [Session] {
        guard let data = try? Data(contentsOf: url),
            let stored = try? JSONCoding.decoder.decode([Session].self, from: data)
        else { return [] }
        return stored
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
