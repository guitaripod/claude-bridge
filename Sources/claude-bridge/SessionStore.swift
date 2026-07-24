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
    private let projectsDir: String
    let pusher: LiveActivityPusher
    let devicePusher: DevicePusher
    private var hiddenTranscripts: Set<String>
    private var runnerTurnClaudeIDs: Set<String> = []

    init(
        runner: ClaudeRunner, defaultModel: String, defaultEffort: String, storeURL: URL,
        projectsDir: String = "", pusher: LiveActivityPusher = LiveActivityPusher(client: nil),
        devicePusher: DevicePusher = DevicePusher(client: nil, devicesURL: nil)
    ) {
        self.pusher = pusher
        self.devicePusher = devicePusher
        self.runner = runner
        self.defaultModel = defaultModel
        self.defaultEffort = defaultEffort
        self.storeURL = storeURL
        self.projectsDir = projectsDir
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
            if let priors = session.priorClaudeSessionIDs { claimed.formUnion(priors) }
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
        session.customTitle = true
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

    /// Every transcript id a session has owned — its current and prior Claude
    /// ids, plus its own id when that is itself a transcript. Deleting a session
    /// hides all of them so a rotated or compacted transcript can't resurface as
    /// a "discovered" card once its owner is gone.
    func ownedTranscriptIDs(_ id: String) -> Set<String> {
        var ids: Set<String> = [id]
        if let session = sessions[id] {
            if let claude = session.claudeSessionID { ids.insert(claude) }
            if let priors = session.priorClaudeSessionIDs { ids.formUnion(priors) }
        }
        return ids
    }

    /// Resets a session to a fresh Claude conversation (drops history and the resumable id).
    func clear(_ id: String) {
        guard var session = sessions[id] else { return }
        session.messages = []
        session.claudeSessionID = nil
        session.priorClaudeSessionIDs = nil
        session.autoTitled = nil
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
        if session.title == "New chat"
            || (session.customTitle != true && session.messages.count <= 1)
        {
            session.title = Self.deriveTitle(request.text, fallback: session.title)
        }
        session.updatedAt = Date()
        sessions[id] = session
        moveToFront(id)
        persist()

        let caster = broadcaster(for: id)
        caster.send(.messageUpserted(userMessage))

        let runner = self.runner
        let resume = session.claudeSessionID
        let model = session.model
        let effort = session.effort.isEmpty ? defaultEffort : session.effort
        let text = promptText(for: request, sessionID: id)
        let fork = session.pendingFork == true
        let directory = session.directory

        let turnClaudeID = resume ?? id
        runnerTurnClaudeIDs.insert(turnClaudeID)
        Task {
            let turnStart = Date()
            let outcome = await runner.run(
                prompt: text, resume: resume, model: model, effort: effort, fork: fork,
                directory: directory,
                onStart: { pid in Task { await self.registerTurnProcess(id, pid: pid) } },
                onSessionID: { sid in Task { await self.linkClaudeSession(id, claudeSessionID: sid) } },
                emit: { event in
                    caster.send(event)
                    Task {
                        await self.mirrorLiveTurn(id, event)
                        await self.pusher.noteEvent(event, sessionID: id)
                    }
                })
            await self.finishTurn(
                id, outcome: outcome, turnClaudeID: turnClaudeID, startedAt: turnStart)
        }
    }

    /// Writes uploaded attachments to disk and appends their paths to the
    /// prompt so headless Claude reads them with the Read tool (which renders
    /// images natively — real vision input without touching the CLI's input
    /// format). The stored user message keeps the clean original text; only
    /// the runner sees the augmented prompt.
    private func promptText(for request: SendRequest, sessionID: String) -> String {
        let attachments = request.attachments ?? []
        guard !attachments.isEmpty else { return request.text }
        let dir = storeURL.deletingLastPathComponent()
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(Self.safeFileComponent(sessionID), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var references: [String] = []
        for attachment in attachments {
            guard let data = Data(base64Encoded: attachment.dataBase64), !data.isEmpty else {
                continue
            }
            let name = "\(UUID().uuidString.prefix(8))-\(Self.attachmentName(attachment))"
            let url = dir.appendingPathComponent(name)
            guard (try? data.write(to: url)) != nil else { continue }
            let kind = attachment.mime.hasPrefix("image/") ? "image" : "file"
            references.append("Attached \(kind) (use the Read tool to view it): \(url.path)")
        }
        Self.pruneAttachments(in: dir)
        guard !references.isEmpty else { return request.text }
        return request.text + "\n\n" + references.joined(separator: "\n")
    }

    private static func attachmentName(_ attachment: SendAttachment) -> String {
        if let filename = attachment.filename {
            let base = safeFileComponent((filename as NSString).lastPathComponent)
            if !base.isEmpty { return String(base.suffix(64)) }
        }
        let ext = extensionForMime[attachment.mime] ?? "bin"
        return "attachment.\(ext)"
    }

    private static let extensionForMime: [String: String] = [
        "image/jpeg": "jpg", "image/png": "png", "image/heic": "heic", "image/gif": "gif",
        "image/webp": "webp", "application/pdf": "pdf", "text/plain": "txt",
    ]

    private static func safeFileComponent(_ raw: String) -> String {
        String(
            raw.map {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_"
            })
    }

    /// Keeps a session's attachment directory bounded: oldest files beyond the
    /// cap are deleted (they were only needed for the turn that referenced them).
    private static func pruneAttachments(in dir: URL, cap: Int = 32) {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        guard files.count > cap else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - cap) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Partial assistant message of the in-flight turn, under the same message
    /// id the event stream uses — so a client that fetches mid-turn sees the
    /// turn so far and subsequent deltas still land on it.
    private var liveTurns: [String: Message] = [:]

    func liveTurnMessage(_ id: String) -> Message? { liveTurns[id] }

    private func mirrorLiveTurn(_ id: String, _ event: BridgeEvent) {
        switch event {
        case .messageUpserted(let message) where message.role == .assistant:
            liveTurns[id] = message
        case .partTextDelta(let messageID, let delta):
            guard var message = liveTurns[id], message.id == messageID else { return }
            if case .text(let existing) = message.parts.last {
                message.parts[message.parts.count - 1] = .text(existing + delta)
            } else {
                message.parts.append(.text(delta))
            }
            liveTurns[id] = message
        case .toolUpserted(let messageID, let tool):
            guard var message = liveTurns[id], message.id == messageID else { return }
            let index = message.parts.firstIndex { part in
                if case .tool(let call) = part { return call.id == tool.id }
                return false
            }
            if let index {
                message.parts[index] = .tool(tool)
            } else {
                message.parts.append(.tool(tool))
            }
            liveTurns[id] = message
        default:
            break
        }
    }

    private var turnProcessIDs: [String: Int32] = [:]

    private func registerTurnProcess(_ id: String, pid: Int32) {
        turnProcessIDs[id] = pid
    }

    /// Links the real Claude session id onto a stored session as soon as the runner reports it
    /// (the stream's `init` event), so the session's own live transcript counts as claimed for the
    /// whole first turn instead of surfacing as a second, effort-less "discovered" card alongside it.
    /// Handles mid-conversation id rotation (compaction/resume mints a fresh transcript id): the
    /// superseded id is retained via ``setClaudeSessionID(_:on:)`` so its transcript stays claimed.
    private func linkClaudeSession(_ id: String, claudeSessionID sid: String) {
        guard var session = sessions[id], session.claudeSessionID != sid else { return }
        let supersededTurnID = session.claudeSessionID ?? id
        if runnerTurnClaudeIDs.remove(supersededTurnID) != nil { runnerTurnClaudeIDs.insert(sid) }
        setClaudeSessionID(sid, on: &session)
        sessions[id] = session
        persist()
    }

    /// Repoints a session at a new resumable Claude id, preserving any id it
    /// replaces so the superseded (rotated/compacted) transcript stays claimed
    /// and never resurfaces as a duplicate discovered session.
    private func setClaudeSessionID(_ new: String?, on session: inout Session) {
        if let old = session.claudeSessionID, old != new {
            var priors = session.priorClaudeSessionIDs ?? []
            if !priors.contains(old) { priors.append(old) }
            session.priorClaudeSessionIDs = priors
        }
        session.claudeSessionID = new
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

    private func finishTurn(
        _ id: String, outcome: ClaudeRunner.Outcome, turnClaudeID: String, startedAt: Date
    ) {
        let turnDuration = Date().timeIntervalSince(startedAt)
        turnProcessIDs[id] = nil
        liveTurns[id] = nil
        runnerTurnClaudeIDs.remove(turnClaudeID)
        lastRunnerFinish[turnClaudeID] = Date()
        if let newID = outcome.claudeSessionID {
            runnerTurnClaudeIDs.remove(newID)
            lastRunnerFinish[newID] = Date()
        }
        guard var session = sessions[id] else { return }
        session.messages.append(outcome.message)
        setClaudeSessionID(outcome.claudeSessionID, on: &session)
        session.pendingFork = nil
        if let cost = outcome.costUSD { session.lastCostUSD = cost }
        if let tokens = outcome.tokens { session.lastTokens = tokens }
        session.updatedAt = Date()
        sessions[id] = session
        moveToFront(id)
        persist()
        maybeAutoTitle(id)
        let toolCount = outcome.message.parts.count { part in
            if case .tool = part { return true }
            return false
        }
        let title = session.title
        Task {
            await pusher.endTurn(sessionID: id, toolCount: toolCount, failed: false)
            await devicePusher.pushTurnEnd(
                sessionID: id, title: title, toolCount: toolCount, failed: false,
                duration: turnDuration)
        }
    }

    /// After the first completed turn (and after /clear), replace the
    /// prompt-derived title with a short LLM-written one. A user rename
    /// (customTitle) always wins, including against a title call already in
    /// flight.
    private func maybeAutoTitle(_ id: String) {
        guard let session = sessions[id],
            session.customTitle != true, session.autoTitled != true,
            let user = session.messages.first(where: { $0.role == .user })
                .map(Self.plainText), !user.isEmpty,
            let assistant = session.messages.first(where: { $0.role == .assistant })
                .map(Self.plainText), !assistant.isEmpty
        else { return }
        let binary = runner.claudePath
        let projects = projectsDir
        Task.detached { [weak self] in
            guard let title = await Titler.title(
                binary: binary, projectsDir: projects, user: user, assistant: assistant)
            else { return }
            await self?.applyAutoTitle(id, title: title)
        }
    }

    private func applyAutoTitle(_ id: String, title: String) {
        guard var session = sessions[id], session.customTitle != true else { return }
        session.title = title
        session.autoTitled = true
        sessions[id] = session
        persist()
    }

    private static func plainText(_ message: Message) -> String {
        message.parts.compactMap { part in
            if case .text(let value) = part { return value }
            return nil
        }.joined(separator: "\n")
    }

    private func moveToFront(_ id: String) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// A readable list title from a raw prompt: the first real line (slash
    /// commands and markup skipped), whitespace collapsed, cut at a word
    /// boundary, sentence-cased. The LLM titler replaces this after the
    /// first turn; this keeps the list sane in the meantime.
    static func deriveTitle(_ text: String, fallback: String = "New chat") -> String {
        let cleaned = text.replacingOccurrences(
            of: "<[^>]{1,80}>", with: " ", options: .regularExpression)
        let line = cleaned
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("/") }
        guard var title = line else { return fallback }
        title = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if title.count > 48 {
            let prefix = String(title.prefix(48))
            if let space = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: space) > 24 {
                title = String(prefix[..<space]) + "…"
            } else {
                title = prefix + "…"
            }
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;–—-"))
        guard !title.isEmpty else { return fallback }
        return title.prefix(1).uppercased() + title.dropFirst()
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
