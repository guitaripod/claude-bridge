import Foundation

/// Everything observable on this bridge, in one totally-ordered log. Every event is assigned a
/// position (`seq`) under an `epoch` minted at process start *before* it reaches any wire; a
/// bounded ring keeps recent frames so a reconnecting client replays exactly what it missed; a
/// cursor that fell off the ring gets `reset` — told, never left to guess.
enum HubEvent: Sendable {
    case session(id: String, event: BridgeEvent)
    case listUpsert(SessionSummary)
    case listRemove(id: String)
    case agents(sessionID: String, agents: [SubagentSummary])
    /// Liveness only: not sequenced, not replayed — a subscriber that hears nothing else hears
    /// this every ten seconds, so silence is distinguishable from death.
    case heartbeat(seq: UInt64)
}

struct HubFrame: Sendable {
    let seq: UInt64
    let event: HubEvent
}

actor Hub {
    let epoch: String
    private(set) var seq: UInt64 = 0
    private var ring: [HubFrame] = []
    private static let ringLimit = 8192
    private var subscribers: [UUID: AsyncStream<HubFrame>.Continuation] = [:]

    init() {
        let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
        epoch = String((0..<12).map { _ in alphabet.randomElement()! })
    }

    var oldestReplayableSeq: UInt64 { ring.first?.seq ?? seq &+ 1 }

    func publish(_ event: HubEvent) {
        seq &+= 1
        let frame = HubFrame(seq: seq, event: event)
        ring.append(frame)
        if ring.count > Self.ringLimit { ring.removeFirst(ring.count - Self.ringLimit) }
        for continuation in subscribers.values { continuation.yield(frame) }
    }

    /// Delivered to every subscriber, never sequenced, never replayed.
    func publishHeartbeat() {
        let frame = HubFrame(seq: 0, event: .heartbeat(seq: seq))
        for continuation in subscribers.values { continuation.yield(frame) }
    }

    func runHeartbeats() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            publishHeartbeat()
        }
    }

    struct Attachment {
        let id: UUID
        let stream: AsyncStream<HubFrame>
        /// Frames the cursor missed, in order — empty for a fresh client.
        let replay: [HubFrame]
        /// The cursor predates the ring (or another epoch): the client must refetch what it
        /// renders, because the missed frames are gone.
        let tooOld: Bool
        let headSeq: UInt64
    }

    /// Replay computation and registration in one critical section: a frame published
    /// concurrently is either ≤ the computed head (in the replay) or after it (delivered to the
    /// now-registered subscriber). There is no interleaving where it is neither.
    func attach(sinceEpoch: String?, sinceSeq: UInt64?) -> Attachment {
        let id = UUID()
        var replay: [HubFrame] = []
        var tooOld = false
        if let sinceEpoch, let sinceSeq {
            if sinceEpoch == epoch, sinceSeq &+ 1 >= oldestReplayableSeq {
                replay = ring.filter { $0.seq > sinceSeq }
            } else {
                tooOld = true
            }
        }
        let stream = AsyncStream<HubFrame>(bufferingPolicy: .bufferingNewest(4096)) {
            continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.detach(id) }
            }
        }
        return Attachment(id: id, stream: stream, replay: replay, tooOld: tooOld, headSeq: seq)
    }

    func detach(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    func closeAll() {
        for (_, continuation) in subscribers { continuation.finish() }
        subscribers.removeAll()
    }
}

/// Watching is a property of the machine, not of a subscriber. Every second this loop compares
/// each session's summary against what it last published and pushes the difference; every
/// transcript that grew is folded forward and its changed messages published — whether or not a
/// single client is connected. A foreign `claude` typing in a terminal reaches every open app
/// within a sweep.
actor ObserverLoop {
    private let index: TranscriptIndex
    private let store: SessionStore
    private let hub: Hub

    private var lastSummaries: [String: SessionSummary] = [:]
    private var lastSizes: [String: Int] = [:]
    /// The first sweep records where every transcript ends without folding or publishing a byte:
    /// growth is what happens after the observer starts, not the gigabyte of history before it.
    private var baselined = false
    private var lastAgents: [String: [SubagentSummary]] = [:]
    private var lastGoals: [String: GoalStatus?] = [:]
    /// Sessions whose bytes changed while this bridge's own runner held the turn: the runner
    /// already streamed that content under its own ids, so the fold's version is not re-published
    /// — same contract as the legacy per-session watcher.
    private var suppressedUntil: [String: Date] = [:]
    private static let runnerGrace: TimeInterval = 5
    private var tick = 0
    /// Whether this loop has counted the world even once. Before it has, "nothing is running" is
    /// something nobody has established rather than something anybody knows.
    var hasSwept: Bool { tick > 0 }
    private var lastActivity: [String: AgentActivity] = [:]

    init(index: TranscriptIndex, store: SessionStore, hub: Hub) {
        self.index = index
        self.store = store
        self.hub = hub
    }

    func run() async {
        while !Task.isCancelled {
            await sweep()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// List rows and transcript growth move every second; the agent scan — sidecar walks and
    /// progress tails for every live fan-out — runs at a third of that. It was the per-second
    /// scan that queued a 27-second `/sessions/:id` behind the index actor.
    func sweep() async {
        tick += 1
        if tick % 3 == 1 {
            lastActivity = await index.agentActivity()
            await publishAgentChanges()
        }
        await publishListChanges()
        await publishTranscriptGrowth()
    }

    /// What the last sweep computed, at most a second old — `GET /sessions` serves this instead
    /// of recomputing the world per request while a live turn keeps the index busy.
    func summariesSnapshot() -> [SessionSummary] {
        lastSummaries.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func currentSummaries() async -> [String: SessionSummary] {
        let active = await index.activeIDs(within: TranscriptIndex.activityWindow)
        let dates = await index.transcriptDates()
        let agents = lastActivity
        let settings = await index.transcriptSettings()
        let stored = await store.list(
            activeClaudeIDs: active, transcriptDates: dates, agents: agents, settings: settings)
        let (claimed, hidden) = await store.excludedTranscriptIDs()
        let discovered = await index.list(excluding: claimed, hidden: hidden)
        var byID: [String: SessionSummary] = [:]
        for summary in stored + discovered { byID[summary.id] = summary }
        return byID
    }

    private func publishListChanges() async {
        let current = await currentSummaries()
        for (id, summary) in current where lastSummaries[id] != summary {
            await hub.publish(.listUpsert(summary))
            let wasActive = lastSummaries[id]?.active ?? false
            if summary.active != wasActive {
                await hub.publish(
                    .session(id: id, event: .status(summary.active == true ? "running" : "idle")))
            }
        }
        for id in lastSummaries.keys where current[id] == nil {
            await hub.publish(.listRemove(id: id))
        }
        lastSummaries = current
    }

    private func publishTranscriptGrowth() async {
        let paths = await index.pathsByID()
        if !baselined {
            baselined = true
            for (_, path) in paths {
                if let size = TranscriptIndex.statSize(path) { lastSizes[path] = size }
            }
            return
        }
        for (claudeID, path) in paths {
            let size = TranscriptIndex.statSize(path)
            guard let size, size != lastSizes[path] else { continue }
            lastSizes[path] = size
            let sessionID = await store.sessionID(forClaudeID: claudeID) ?? claudeID
            if await store.hasRunnerTurnInFlight(claudeSessionID: claudeID) {
                suppressedUntil[path] = Date().addingTimeInterval(Self.runnerGrace)
                _ = await index.advanceReportingChanges(atPath: path)
                continue
            }
            guard let advance = await index.advanceReportingChanges(atPath: path) else { continue }
            if let goal = advance.goal, lastGoals[path] != .some(goal) {
                lastGoals[path] = goal
                await hub.publish(.session(id: sessionID, event: .goal(goal)))
            }
            if Date() < suppressedUntil[path] ?? .distantPast { continue }
            guard !advance.changed.isEmpty else { continue }
            for message in advance.messages where advance.changed.contains(message.id) {
                await hub.publish(.session(id: sessionID, event: .messageUpserted(message)))
            }
        }
    }

    private func publishAgentChanges() async {
        let threshold = Date().addingTimeInterval(-TranscriptIndex.subagentActivityWindow)
        let latests = await index.sidecarLatestsByID()
        let paths = await index.pathsByID()
        for (claudeID, _) in paths {
            let hasRecent = latests[claudeID].map { $0 > threshold } ?? false
            let hadAgents = !(lastAgents[claudeID] ?? []).isEmpty
            guard hasRecent || hadAgents else { continue }
            let agents = await index.subagents(for: claudeID)
            let live = agents.filter { $0.active == true }
            guard live != (lastAgents[claudeID] ?? []) else { continue }
            lastAgents[claudeID] = live
            let sessionID = await store.sessionID(forClaudeID: claudeID) ?? claudeID
            await hub.publish(.agents(sessionID: sessionID, agents: agents))
        }
    }
}

struct StreamHello: Encodable {
    let proto: Int
    let epoch: String
    let seq: UInt64
    let oldestSeq: UInt64
    let heartbeat: Int
    /// True when the presented cursor could not be replayed: the client must refetch what it
    /// renders before treating later frames as a complete picture.
    let reset: Bool
}

struct Heartbeat: Encodable {
    let seq: UInt64
    let t: Date
}

struct SessionFramePayload: Encodable {
    let session: String
    let event: BridgeEvent
}

struct AgentsFramePayload: Encodable {
    let session: String
    let agents: [SubagentSummary]
}
