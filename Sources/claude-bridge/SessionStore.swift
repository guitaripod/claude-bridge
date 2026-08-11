import Foundation

/// Thread-safe fan-out of ``BridgeEvent``s to any number of subscribed SSE clients for one session.
final class Broadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<BridgeEvent>.Continuation] = [:]
    /// Every event published to this session also flows into the bridge-wide hub, where it gets
    /// a sequence number. Installed at creation; the per-session stream is unchanged.
    var tap: (@Sendable (BridgeEvent) -> Void)?

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
        tap?(event)
    }

    /// Ends one subscriber's stream. An SSE response otherwise never completes,
    /// so a graceful shutdown waits on it forever: the process ignores SIGTERM,
    /// survives its own restart, and a second bridge ends up sharing the store.
    func close(_ id: UUID) {
        let continuation = lock.withLock { continuations.removeValue(forKey: id) }
        continuation?.finish()
    }
}

actor SessionStore {
    private var sessions: [String: Session] = [:]
    private var order: [String] = []
    private var broadcasters: [String: Broadcaster] = [:]
    private var hubTap: (@Sendable (String, BridgeEvent) -> Void)?
    private let runner: ClaudeRunner
    private let defaults: MachineDefaults
    private let storeURL: URL
    private let projectsDir: String
    let pusher: LiveActivityPusher
    let devicePusher: DevicePusher
    private var hiddenTranscripts: Set<String>
    /// Counted, not a set: a `--fork-session` turn resumes its parent's Claude id, so parent and
    /// fork can legitimately hold the same key at once and whichever finishes first must not
    /// declare the other's turn over.
    private var runnerTurnClaudeIDs: [String: Int] = [:]
    /// Sessions with a turn this bridge is running, and the prompts waiting behind them. Two
    /// clients on one session are the normal case, so a second prompt queues rather than starting
    /// a second `claude -p --resume` against the same transcript in the same working directory.
    private var inFlight: Set<String> = []
    private var pendingPrompts: [String: [QueuedPrompt]] = [:]
    /// The same two facts — what is running, what is waiting — written where they survive the
    /// process. Everything above this line is lost the moment the machine stops, which is exactly
    /// when it matters most.
    private var journal: TurnJournal
    private let journalURL: URL

    private struct QueuedPrompt {
        let prompt: String
        let displayPrompt: String
        let model: String?
        let effort: String?

        var record: QueuedRecord {
            QueuedRecord(
                prompt: prompt, displayPrompt: displayPrompt, model: model, effort: effort)
        }

        init(prompt: String, displayPrompt: String, model: String?, effort: String?) {
            self.prompt = prompt
            self.displayPrompt = displayPrompt
            self.model = model
            self.effort = effort
        }

        init(_ record: QueuedRecord) {
            prompt = record.prompt
            displayPrompt = record.displayPrompt
            model = record.model
            effort = record.effort
        }
    }

    /// What ``send(_:request:)`` did with a prompt. Both outcomes are accepted (202): a client
    /// treats any non-2xx as message-lost and hands the text back to the composer, so refusing a
    /// queued prompt would eat it.
    enum SendOutcome: Sendable, Equatable {
        case started
        case queued(position: Int)
        case unknownSession
    }
    /// Attached after construction (the index is built from the same config, but later), so a
    /// finished turn can report *why* it ended when a goal drove it.
    private weak var index: TranscriptIndex?

    func attach(index: TranscriptIndex) {
        self.index = index
    }

    /// Whether an interrupted turn continues on its own when the session has no opinion of its own.
    /// A machine that is left running work unattended wants this; a machine somebody is sitting in
    /// front of does not, which is why it is a decision and not a behaviour.
    private let autoResumeDefault: Bool

    init(
        runner: ClaudeRunner, defaults: MachineDefaults, storeURL: URL,
        projectsDir: String = "", pusher: LiveActivityPusher = LiveActivityPusher(client: nil),
        devicePusher: DevicePusher = DevicePusher(client: nil, devicesURL: nil),
        autoResumeDefault: Bool = false
    ) {
        self.autoResumeDefault = autoResumeDefault
        self.pusher = pusher
        self.devicePusher = devicePusher
        self.runner = runner
        self.defaults = defaults
        self.storeURL = storeURL
        self.projectsDir = projectsDir
        journalURL = TurnJournal.url(besides: storeURL)
        journal = TurnJournal.load(from: journalURL)
        hiddenTranscripts = Self.loadHidden(from: Self.hiddenURL(for: storeURL))
        for session in Self.loadStored(from: storeURL) {
            sessions[session.id] = session
            order.append(session.id)
        }
    }

    func list(
        activeClaudeIDs: Set<String> = [], transcriptDates: [String: Date] = [:],
        agents: [String: AgentActivity] = [:], settings: [String: TranscriptSettings] = [:]
    ) -> [SessionSummary] {
        order.compactMap { id -> SessionSummary? in
            guard let session = sessions[id] else { return nil }
            var summary = session.summary
            let claudeID = session.claudeSessionID ?? session.id
            // A turn this bridge is running IS liveness, regardless of transcript recency: a
            // single tool can run quietly for ten minutes, and the row must not flicker to idle
            // while the process the bridge spawned is still working.
            summary.active = activeClaudeIDs.contains(claudeID)
                || inFlight.contains(id)
                || (runnerTurnClaudeIDs[claudeID] ?? 0) > 0
            // The record says what the session was created with; the transcript says what
            // answered last. A `/model` typed into a terminal only exists in the transcript.
            if let observed = settings[claudeID] {
                if let model = observed.model { summary.model = model }
                summary.effort = Self.reconciledEffort(
                    stored: summary.effort, observed: observed.effort)
            }
            if let working = agents[claudeID] {
                summary.agents = working.count
                summary.agentTask = working.task
            }
            if let fresh = transcriptDates[claudeID], fresh > summary.updatedAt {
                summary.updatedAt = fresh
            }
            if let interruption = session.interruption, !interruption.isResumed {
                summary.interrupted = true
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
            model: request.model ?? defaults.model(),
            effort: request.effort ?? defaults.effort(),
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

    /// The store session whose conversation lives in the given CLI transcript, if any — the id
    /// clients address; a discovered transcript is addressed by its own id.
    func sessionID(forClaudeID claudeID: String) -> String? {
        if sessions[claudeID] != nil { return claudeID }
        for (id, session) in sessions {
            if session.claudeSessionID == claudeID { return id }
            if session.priorClaudeSessionIDs?.contains(claudeID) == true { return id }
        }
        return nil
    }

    /// Wires every per-session broadcaster (existing and future) into the bridge-wide hub.
    func installHubTap(_ tap: @escaping @Sendable (String, BridgeEvent) -> Void) {
        hubTap = tap
        for (id, caster) in broadcasters {
            caster.tap = { event in tap(id, event) }
        }
    }

    func broadcaster(for id: String) -> Broadcaster {
        if let existing = broadcasters[id] { return existing }
        let created = Broadcaster()
        if let hubTap {
            created.tap = { event in hubTap(id, event) }
        }
        broadcasters[id] = created
        return created
    }

    /// Records the user's prompt, then either runs a Claude turn or queues the prompt behind the
    /// one already running. The message is appended and broadcast either way: a client drops its
    /// optimistic echo by user-message count, so a prompt the server accepted but has not started
    /// still has to exist in the transcript.
    @discardableResult
    func send(_ id: String, request: SendRequest) -> SendOutcome {
        let upload = storeAttachments(for: request, sessionID: id)
        return accept(
            id, display: request.text, runnerPrompt: upload.prompt, files: upload.files,
            model: request.model, effort: request.effort)
    }

    /// One prompt, in the two forms a turn needs it: what the person sees in their own transcript,
    /// and what the CLI is actually handed. They diverge whenever the bridge has to say something
    /// to the model that nobody typed — attachment paths, and the briefing that picks an
    /// interrupted turn back up — and conflating them puts machine-written prose in the
    /// conversation under someone else's name.
    @discardableResult
    private func accept(
        _ id: String, display: String, runnerPrompt: String, files: [FileRef],
        model: String?, effort: String?
    ) -> SendOutcome {
        guard var session = sessions[id] else { return .unknownSession }

        let userMessage = Message(
            id: UUID().uuidString, role: .user,
            parts: files.map { Part.file($0) } + [.text(display)], createdAt: Date())
        session.messages.append(userMessage)
        if session.title == "New chat"
            || (session.customTitle != true && session.messages.count <= 1)
        {
            session.title = Self.deriveTitle(display, fallback: session.title)
        }
        session.updatedAt = Date()
        sessions[id] = session
        moveToFront(id)
        persist()
        broadcaster(for: id).send(.messageUpserted(userMessage))

        let queued = QueuedPrompt(
            prompt: runnerPrompt, displayPrompt: display, model: model, effort: effort)
        guard !inFlight.contains(id) else {
            pendingPrompts[id, default: []].append(queued)
            journal.turns[id]?.queued.append(queued.record)
            journal.write(to: journalURL)
            return .queued(position: pendingPrompts[id]?.count ?? 1)
        }
        inFlight.insert(id)
        startTurn(id, queued)
        return .started
    }

    /// Launches one `claude -p` for a prompt whose turn slot this session already holds.
    private func startTurn(_ id: String, _ queued: QueuedPrompt) {
        guard var session = sessions[id] else {
            inFlight.remove(id)
            return
        }
        if let model = queued.model { session.model = model }
        if let effort = queued.effort { session.effort = effort }
        sessions[id] = session

        let caster = broadcaster(for: id)
        let runner = self.runner
        let resume = session.claudeSessionID
        let model = session.model.isEmpty ? defaults.model() : session.model
        let requestedEffort = session.effort.isEmpty ? defaults.effort() : session.effort
        let text = queued.prompt
        let ultracode = requestedEffort == Self.ultracodeEffort || Self.invokesUltracode(text)
        let effort =
            requestedEffort == Self.ultracodeEffort ? Self.ultracodeRunsAs : requestedEffort
        let fork = session.pendingFork == true
        let directory = session.directory

        let turnClaudeID = resume ?? id
        retainRunnerTurn(turnClaudeID)
        journal.turns[id] = TurnRecord(
            turnID: UUID().uuidString, sessionID: id, claudeSessionID: resume,
            prompt: text, displayPrompt: queued.displayPrompt, model: model, effort: effort,
            fork: fork, directory: directory, startedAt: Date(), pid: nil,
            queued: (pendingPrompts[id] ?? []).map(\.record))
        journal.write(to: journalURL)
        Task {
            let turnStart = Date()
            let outcome = await runner.run(
                prompt: text, resume: resume, model: model, effort: effort,
                ultracode: ultracode, fork: fork,
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

    private func retainRunnerTurn(_ claudeSessionID: String) {
        runnerTurnClaudeIDs[claudeSessionID, default: 0] += 1
    }

    private func releaseRunnerTurn(_ claudeSessionID: String) {
        guard let count = runnerTurnClaudeIDs[claudeSessionID] else { return }
        if count <= 1 {
            runnerTurnClaudeIDs[claudeSessionID] = nil
        } else {
            runnerTurnClaudeIDs[claudeSessionID] = count - 1
        }
    }

    /// Writes uploaded attachments to disk and appends their paths to the
    /// prompt so headless Claude reads them with the Read tool (which renders
    /// images natively — real vision input without touching the CLI's input
    /// format). The stored user message keeps the clean original text plus a
    /// file part per attachment, so a client can render what it sent — and can
    /// still render it after a reload, on another device, from the bytes the
    /// bridge kept. Only the runner sees the augmented prompt.
    private func storeAttachments(
        for request: SendRequest, sessionID: String
    ) -> (prompt: String, files: [FileRef]) {
        let attachments = request.attachments ?? []
        guard !attachments.isEmpty else { return (request.text, []) }
        let session = Self.safeFileComponent(sessionID)
        let dir = storeURL.deletingLastPathComponent()
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var references: [String] = []
        var files: [FileRef] = []
        for attachment in attachments {
            guard let data = Data(base64Encoded: attachment.dataBase64), !data.isEmpty else {
                continue
            }
            let name = "\(UUID().uuidString.prefix(8))-\(Self.attachmentName(attachment))"
            let url = dir.appendingPathComponent(name)
            guard (try? data.write(to: url)) != nil else { continue }
            let kind = attachment.mime.hasPrefix("image/") ? "image" : "file"
            references.append("Attached \(kind) (use the Read tool to view it): \(url.path)")
            files.append(
                FileRef(
                    path: url.path, mime: attachment.mime,
                    filename: attachment.filename ?? name,
                    url: "/attachments/\(session)/\(name)"))
        }
        Self.pruneAttachments(in: dir)
        guard !references.isEmpty else { return (request.text, files) }
        return (request.text + "\n\n" + references.joined(separator: "\n"), files)
    }

    /// Absolute path of a stored attachment, or nil if the name escapes the
    /// session's own directory — the only paths this bridge will hand back.
    nonisolated func attachmentURL(session: String, name: String) -> URL? {
        let root = storeURL.deletingLastPathComponent()
            .appendingPathComponent("attachments", isDirectory: true)
            .resolvingSymlinksInPath()
        let file = root
            .appendingPathComponent(Self.safeFileComponent(session), isDirectory: true)
            .appendingPathComponent(Self.safeFileComponent(name))
            .resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return file
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
    /// Turns already settled by ``finishTurn``. Mirroring runs in a detached task, so the final
    /// `messageUpserted` can arrive after the turn was persisted — without this it would re-open a
    /// live turn nothing will ever close, and every later fetch would serve the last assistant
    /// message twice.
    private var settledTurnMessageIDs: [String: String] = [:]

    func liveTurnMessage(_ id: String) -> Message? { liveTurns[id] }

    private func mirrorLiveTurn(_ id: String, _ event: BridgeEvent) {
        switch event {
        case .messageUpserted(let message) where message.role == .assistant:
            guard settledTurnMessageIDs[id] != message.id else { return }
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
        guard journal.turns[id] != nil else { return }
        journal.turns[id]?.pid = pid
        journal.write(to: journalURL)
    }

    /// Links the real Claude session id onto a stored session as soon as the runner reports it
    /// (the stream's `init` event), so the session's own live transcript counts as claimed for the
    /// whole first turn instead of surfacing as a second, effort-less "discovered" card alongside it.
    /// Handles mid-conversation id rotation (compaction/resume mints a fresh transcript id): the
    /// superseded id is retained via ``setClaudeSessionID(_:on:)`` so its transcript stays claimed.
    private func linkClaudeSession(_ id: String, claudeSessionID sid: String) {
        if journal.turns[id]?.claudeSessionID != sid, journal.turns[id] != nil {
            journal.turns[id]?.claudeSessionID = sid
            journal.write(to: journalURL)
        }
        guard var session = sessions[id], session.claudeSessionID != sid else { return }
        let supersededTurnID = session.claudeSessionID ?? id
        if let held = runnerTurnClaudeIDs.removeValue(forKey: supersededTurnID) {
            runnerTurnClaudeIDs[sid, default: 0] += held
        }
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

    /// Stops a turn this bridge is running by terminating its claude process and discards anything
    /// queued behind it; the runner's stream ends and the partial turn is persisted normally. Stop
    /// means stop — leaving the queue to drain would start a fresh turn the moment the one the user
    /// just killed ended.
    func abortTurn(_ id: String) -> (stopped: Bool, discarded: Int) {
        let discarded = pendingPrompts.removeValue(forKey: id)?.count ?? 0
        if journal.turns[id] != nil {
            journal.turns[id]?.queued = []
            journal.write(to: journalURL)
        }
        guard let pid = turnProcessIDs[id] else { return (false, discarded) }
        kill(pid, SIGTERM)
        return (true, discarded)
    }

    /// True while this bridge holds a turn slot for the session — including a prompt still waiting
    /// in its queue, which is why `/clear` consults it rather than the process table.
    func hasQueuedOrRunningTurn(_ id: String) -> Bool {
        inFlight.contains(id)
    }

    func hasRunnerTurnInFlight(claudeSessionID: String) -> Bool {
        runnerTurnClaudeIDs[claudeSessionID] != nil
    }

    /// True while this bridge's own runner is (or was, within the window)
    /// writing the session's transcript — used to tell our own transcript
    /// residue apart from an external process working in the session.
    func recentRunnerActivity(claudeSessionID: String, within seconds: TimeInterval) -> Bool {
        if runnerTurnClaudeIDs[claudeSessionID] != nil { return true }
        guard let finished = lastRunnerFinish[claudeSessionID] else { return false }
        return Date().timeIntervalSince(finished) < seconds
    }

    private var lastRunnerFinish: [String: Date] = [:]

    /// Backfills a compacted turn's numbers and summary from the transcript. The runner leaves an
    /// empty ``Compaction`` in stream order so the seam renders the moment the turn ends; this
    /// replaces it once the CLI has flushed the boundary record it never streams.
    private func fillCompaction(
        _ id: String, messageID: String, claudeSessionID: String?
    ) async {
        guard let claudeSessionID, let index else { return }
        for attempt in 0..<Self.compactionFillAttempts {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(700)) }
            guard let path = await index.path(for: claudeSessionID),
                let compaction = Compaction.lastRecorded(atPath: path), compaction.summary != nil
            else { continue }
            guard var session = sessions[id],
                let messageIndex = session.messages.firstIndex(where: { $0.id == messageID }),
                let partIndex = session.messages[messageIndex].parts.firstIndex(where: { part in
                    if case .compaction = part { return true }
                    return false
                })
            else { return }
            session.messages[messageIndex].parts[partIndex] = .compaction(compaction)
            sessions[id] = session
            persist()
            broadcaster(for: id).send(.messageUpserted(session.messages[messageIndex]))
            return
        }
    }

    /// The boundary record lands in the transcript around the time the turn ends, not before it.
    private static let compactionFillAttempts = 6

    private func finishTurn(
        _ id: String, outcome: ClaudeRunner.Outcome, turnClaudeID: String, startedAt: Date
    ) {
        let turnDuration = Date().timeIntervalSince(startedAt)
        turnProcessIDs[id] = nil
        clearJournal(id)
        liveTurns[id] = nil
        settledTurnMessageIDs[id] = outcome.message.id
        releaseRunnerTurn(turnClaudeID)
        lastRunnerFinish[turnClaudeID] = Date()
        if let newID = outcome.claudeSessionID, newID != turnClaudeID {
            releaseRunnerTurn(newID)
            lastRunnerFinish[newID] = Date()
        }
        defer { advanceQueue(id) }
        guard var session = sessions[id] else { return }
        if let existing = session.messages.firstIndex(where: { $0.id == outcome.message.id }) {
            session.messages[existing] = outcome.message
        } else {
            session.messages.append(outcome.message)
        }
        setClaudeSessionID(outcome.claudeSessionID, on: &session)
        session.pendingFork = nil
        // A resumed turn that reaches its end is the interruption over. Clearing it only here — and
        // never when the resume is merely sent — means a bridge that dies again mid-resume comes
        // back still knowing the work was cut off.
        if session.interruption?.isResumed == true {
            session.interruption = nil
            broadcaster(for: id).send(.interrupted(nil))
        }
        if let cost = outcome.costUSD { session.lastCostUSD = cost }
        if let tokens = outcome.tokens { session.lastTokens = tokens }
        session.updatedAt = Date()
        sessions[id] = session
        moveToFront(id)
        persist()
        maybeAutoTitle(id)
        if outcome.didCompact {
            let claudeID = session.claudeSessionID
            Task { await self.fillCompaction(id, messageID: outcome.message.id, claudeSessionID: claudeID) }
        }
        let toolCount = outcome.message.parts.count { part in
            if case .tool = part { return true }
            return false
        }
        let title = session.title
        let claudeID = session.claudeSessionID ?? id
        let index = self.index
        Task {
            await pusher.endTurn(sessionID: id, toolCount: toolCount, failed: false)
            let goal = await index?.goal(for: claudeID)
            await devicePusher.pushTurnEnd(
                sessionID: id, title: title, toolCount: toolCount, failed: false,
                duration: turnDuration, goal: goal)
        }
    }

    /// Starts whatever queued behind the turn that just ended, or gives the session's turn slot
    /// back. The session goes idle here rather than in ``ClaudeRunner``: the runner only knows its
    /// own process ended, and announcing idle with a prompt still queued drains every client's
    /// local queue into turns nobody asked for.
    private func advanceQueue(_ id: String) {
        if var queue = pendingPrompts[id], !queue.isEmpty {
            let next = queue.removeFirst()
            pendingPrompts[id] = queue.isEmpty ? nil : queue
            startTurn(id, next)
            return
        }
        pendingPrompts[id] = nil
        inFlight.remove(id)
        clearJournal(id)
        broadcaster(for: id).send(.status("idle"))
    }

    private func clearJournal(_ id: String) {
        guard journal.turns.removeValue(forKey: id) != nil else { return }
        journal.write(to: journalURL)
    }

    /// What a resume did with the briefing it composed.
    enum ResumeOutcome: Sendable, Equatable {
        case started
        case queued(position: Int)
        case noInterruption
        case unknownSession
    }

    /// The first thing this bridge does on the way back up: decide what became of every turn it had
    /// open when it stopped.
    ///
    /// The transcript is the authority, not the journal and not the process table — a turn that
    /// closed on disk finished, whether or not anything was alive to watch it, and a turn that
    /// never closed did not. Three outcomes, and every one of them says something: the answer is
    /// taken back out of the transcript and the queue behind it drains; or the child outlived us
    /// and is still working, in which case it is watched to its end rather than declared lost; or
    /// the work was cut off, which is a state with a name, a record of how far it got, and an offer
    /// to continue. What there is no longer is a fourth outcome where a conversation simply sits
    /// there looking finished.
    func recoverJournaledTurns() async {
        guard !journal.turns.isEmpty else { return }
        let bootedAt = MachineUptime.bootedAt()
        let records = journal.turns.values.sorted { $0.startedAt < $1.startedAt }
        for record in records {
            guard sessions[record.sessionID] != nil else {
                clearJournal(record.sessionID)
                continue
            }
            let claudeID = record.claudeSessionID ?? record.sessionID
            let path = await index?.path(for: claudeID)
            switch TurnRecovery.verdict(
                for: record, transcriptPath: path, bootedAt: bootedAt)
            {
            case .completed:
                await settleFromTranscript(record)
            case .stillRunning(let pid):
                adoptRunningTurn(record, pid: pid)
            case .interrupted:
                markInterrupted(record, transcriptPath: path)
            }
        }
    }

    /// Takes a finished turn back out of the transcript the CLI wrote while nothing was listening,
    /// then drains whatever was queued behind it. Those prompts were accepted and never started —
    /// nothing about them is half-done — so running them is what the session was already promised.
    private func settleFromTranscript(_ record: TurnRecord) async {
        let id = record.sessionID
        let claudeID = record.claudeSessionID ?? id
        if let fresh = await index?.session(claudeID), !fresh.messages.isEmpty,
            var session = sessions[id]
        {
            session.messages = fresh.messages
            if session.claudeSessionID == nil { session.claudeSessionID = claudeID }
            session.pendingFork = nil
            session.updatedAt = Date()
            sessions[id] = session
            moveToFront(id)
            persist()
            if let last = fresh.messages.last(where: { $0.role == .assistant }) {
                broadcaster(for: id).send(.messageUpserted(last))
            }
        }
        turnProcessIDs[id] = nil
        liveTurns[id] = nil
        clearJournal(id)
        let owed = record.queued.map(QueuedPrompt.init)
        guard let first = owed.first else {
            inFlight.remove(id)
            broadcaster(for: id).send(.status("idle"))
            return
        }
        inFlight.insert(id)
        pendingPrompts[id] = Array(owed.dropFirst())
        startTurn(id, first)
    }

    /// A claude that outlived the bridge. Its stdout died with us — the events of this turn are
    /// gone — but the work is not, and killing it to tidy up would throw away minutes of somebody's
    /// machine. The session says it is running, and the transcript is watched until the turn closes
    /// or the process goes.
    private func adoptRunningTurn(_ record: TurnRecord, pid: Int32) {
        let id = record.sessionID
        let claudeID = record.claudeSessionID ?? id
        inFlight.insert(id)
        turnProcessIDs[id] = pid
        retainRunnerTurn(claudeID)
        broadcaster(for: id).send(.status("running"))
        Task { await self.watchAdopted(record, pid: pid, claudeID: claudeID) }
    }

    /// How long an adopted turn is given before it is called interrupted regardless. Generous: a
    /// single overnight run is a real thing people do, and the process check ends the wait the
    /// moment it is actually over.
    private static let adoptedTurnDeadline: TimeInterval = 12 * 3_600

    private func watchAdopted(_ record: TurnRecord, pid: Int32, claudeID: String) async {
        let deadline = Date().addingTimeInterval(Self.adoptedTurnDeadline)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(5))
            let path = await index?.path(for: claudeID)
            if let path, TranscriptParser.isTurnClosed(atPath: path) {
                releaseRunnerTurn(claudeID)
                lastRunnerFinish[claudeID] = Date()
                await settleFromTranscript(record)
                return
            }
            guard ProcessProbe.isLiveClaude(pid) else {
                releaseRunnerTurn(claudeID)
                lastRunnerFinish[claudeID] = Date()
                let settled = await index?.path(for: claudeID)
                if let settled, TranscriptParser.isTurnClosed(atPath: settled) {
                    await settleFromTranscript(record)
                } else {
                    markInterrupted(record, transcriptPath: settled)
                }
                return
            }
        }
        releaseRunnerTurn(claudeID)
        markInterrupted(record, transcriptPath: await index?.path(for: claudeID))
    }

    private func markInterrupted(_ record: TurnRecord, transcriptPath: String?) {
        let id = record.sessionID
        let interruption = Interruption(
            turnID: record.turnID, prompt: record.displayPrompt, startedAt: record.startedAt,
            detectedAt: Date(), claudeSessionID: record.claudeSessionID,
            progress: TurnRecovery.progress(
                transcriptPath: transcriptPath, since: record.startedAt),
            queued: record.queued.map(\.displayPrompt), resumedAt: nil)
        turnProcessIDs[id] = nil
        liveTurns[id] = nil
        inFlight.remove(id)
        pendingPrompts[id] = nil
        clearJournal(id)
        guard var session = sessions[id] else { return }
        session.interruption = interruption
        session.updatedAt = Date()
        sessions[id] = session
        persist()
        let caster = broadcaster(for: id)
        caster.send(.interrupted(interruption))
        caster.send(.status("idle"))
        let title = session.title
        let tools = interruption.progress.toolCount
        let duration = interruption.detectedAt.timeIntervalSince(interruption.startedAt)
        Task {
            await pusher.endTurn(sessionID: id, toolCount: tools, failed: true)
            await devicePusher.pushTurnEnd(
                sessionID: id, title: title, toolCount: tools, failed: true,
                duration: duration, goal: nil)
        }
        guard session.autoResume ?? autoResumeDefault else { return }
        resumeInterrupted(id)
    }

    func interruption(_ id: String) -> Interruption? { sessions[id]?.interruption }

    /// Picks an interrupted turn back up.
    ///
    /// The prompt that goes out is a briefing, not the original words: the conversation is resumed
    /// so the model still has its own context, but what it does *not* have is any idea that it was
    /// cut off, or which of the things it started actually landed on disk. Re-sending the original
    /// would be a blind retry of work that may be half-done — the one outcome worth engineering
    /// against. What the person sees in their transcript is one line, because nobody typed the rest.
    @discardableResult
    func resumeInterrupted(_ id: String) -> ResumeOutcome {
        guard var session = sessions[id] else { return .unknownSession }
        guard var interruption = session.interruption, !interruption.isResumed else {
            return .noInterruption
        }
        interruption.resumedAt = Date()
        session.interruption = interruption
        sessions[id] = session
        persist()
        broadcaster(for: id).send(.interrupted(interruption))
        let outcome = accept(
            id, display: Self.resumeDisplayText,
            runnerPrompt: ResumeBrief.compose(interruption), files: [],
            model: nil, effort: nil)
        switch outcome {
        case .started: return .started
        case .queued(let position): return .queued(position: position)
        case .unknownSession: return .unknownSession
        }
    }

    static let resumeDisplayText = "Continue the turn that was interrupted."

    /// Lets go of an interruption without continuing it — the work is no longer wanted, or was
    /// done by hand. The record goes; the transcript keeps whatever actually happened.
    @discardableResult
    func dismissInterruption(_ id: String) -> Bool {
        guard var session = sessions[id], session.interruption != nil else { return false }
        session.interruption = nil
        sessions[id] = session
        persist()
        broadcaster(for: id).send(.interrupted(nil))
        return true
    }

    @discardableResult
    func setAutoResume(_ id: String, enabled: Bool) -> Bool {
        guard var session = sessions[id] else { return false }
        session.autoResume = enabled
        sessions[id] = session
        persist()
        return true
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

    /// The CLI's own "ultracode" prompt keyword never fires in print mode — it only trusts
    /// interactive human input — so the bridge honours it instead: a prompt that says the word
    /// opts that one turn into workflow orchestration, exactly as it would in a terminal.
    static func invokesUltracode(_ prompt: String) -> Bool {
        prompt.range(of: #"(?i)\bultracode\b"#, options: .regularExpression) != nil
    }

    /// The effort a session is reported at, given what it is recorded as and what its transcript
    /// last answered at. Ultracode is a mode the CLI has no name for — it runs as `xhigh` plus a
    /// settings flag — so the transcript can only ever *confirm* it, never contradict it: an
    /// observed `xhigh` against a session recorded as ultracode is the same turn described in the
    /// only vocabulary the transcript has, and overwriting it there is what made a chat started in
    /// ultracode open as plain xhigh on another client. Any other observed level was chosen after
    /// the fact — `/effort` in a terminal — and wins.
    static func reconciledEffort(stored: String, observed: String?) -> String {
        guard let observed, !observed.isEmpty else { return stored }
        if stored == ultracodeEffort && observed == ultracodeRunsAs { return stored }
        return observed
    }

    static let ultracodeEffort = "ultracode"
    static let ultracodeRunsAs = "xhigh"

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
        return stored.map { session in
            var healed = session
            healed.messages = dedupedByID(session.messages)
            return healed
        }
    }

    /// A concurrent-turn race once persisted the same assembled message twice;
    /// heal any such duplicates on load, keeping the newest occurrence in place.
    private static func dedupedByID(_ messages: [Message]) -> [Message] {
        var lastIndexByID: [String: Int] = [:]
        for (index, message) in messages.enumerated() { lastIndexByID[message.id] = index }
        guard lastIndexByID.count != messages.count else { return messages }
        return messages.enumerated().compactMap { index, message in
            lastIndexByID[message.id] == index ? message : nil
        }
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
