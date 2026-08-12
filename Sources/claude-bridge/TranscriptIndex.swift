import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Read-only view over `~/.claude/projects`: every Claude Code CLI transcript on this machine
/// becomes a listable, resumable session. One `.jsonl` file is one session — the CLI keeps a
/// stable session id across `--resume` and appends turns to the same file.
actor TranscriptIndex {
    struct Entry: Sendable {
        var id: String
        var title: String
        var directory: String?
        var model: String?
        /// The reasoning effort the last answer actually ran at, read from the transcript — the
        /// CLI records it per line, and a `/effort` typed into a terminal never reaches any
        /// stored session record.
        var effort: String?
        var createdAt: Date
        var updatedAt: Date
        var path: String
    }

    private struct CacheSlot {
        var mtime: Date
        var size: Int
        var entry: Entry?
        var contentDate: Date?
        var turnClosed = false
    }

    struct FoldState: Sendable {
        var fold: TranscriptFold
        var offset: Int
        var includeSidechain: Bool
        /// What the most recent advance changed — consumed by the observer, empty on no growth.
        var lastChanged: Set<String> = []
    }

    private let root: URL
    private let defaults: MachineDefaults
    private var cache: [String: CacheSlot] = [:]
    private var pathByID: [String: String] = [:]
    private var folds: [String: FoldState] = [:]
    private var foldOrder: [String] = []
    private var foldTasks: [String: Task<FoldState?, Never>] = [:]
    private static let foldCacheLimit = 24
    private var lastScanAt: ContinuousClock.Instant?
    private static let scanDebounce: Duration = .seconds(2)

    init(root: URL, defaults: MachineDefaults) {
        self.root = root
        self.defaults = defaults
    }

    func list(excluding claimed: Set<String>, hidden: Set<String>) -> [SessionSummary] {
        scan()
        return cache.values
            .compactMap { slot -> SessionSummary? in
                guard let entry = slot.entry, !claimed.contains(entry.id),
                    !hidden.contains(entry.id)
                else { return nil }
                return summary(for: entry, turnClosed: slot.turnClosed)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func contains(_ id: String) -> Bool {
        if pathByID[id] == nil { scan() }
        return pathByID[id] != nil
    }

    func path(for id: String) -> String? {
        if pathByID[id] == nil { scan() }
        return pathByID[id]
    }

    func updatedAt(for id: String) -> Date? {
        guard let path = path(for: id) else { return nil }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
            .contentModificationDateKey
        ])
        return values?.contentModificationDate ?? cache[path]?.mtime
    }

    /// Session ids whose transcript (or subagent sidecar files) were written to
    /// within the window — "someone (this bridge or an interactive CLI) is
    /// working in this session right now". Subagent activity matters: while a
    /// session fans work out to agents, its main transcript can stay quiet for
    /// minutes even though it is very much live.
    func activeIDs(within seconds: TimeInterval) -> Set<String> {
        scan()
        let threshold = Date().addingTimeInterval(-seconds)
        var ids = Set<String>()
        for (path, slot) in cache {
            guard let entry = slot.entry else { continue }
            let lastContent = slot.contentDate ?? slot.mtime
            let turnOpen = !slot.turnClosed && lastContent > threshold
            if turnOpen || isSidecarActive(transcriptPath: path, after: threshold) {
                ids.insert(entry.id)
            }
        }
        return ids
    }

    /// Machine-wide "someone is working" signal: any session with an open turn
    /// or subagent sidecar activity within the window.
    func anyActivity(within seconds: TimeInterval) -> Bool {
        !activeIDs(within: seconds).isEmpty
    }

    /// What the agents of each fanned-out session are doing right now, keyed by
    /// session id. Only sessions whose sidecars were written to recently are
    /// described: a client needs this to say *why* a session with a silent
    /// transcript is live, and reading meta files for quiet sessions would cost
    /// a directory walk per session per poll for nothing.
    func agentActivity() -> [String: AgentActivity] {
        scan()
        let threshold = Date().addingTimeInterval(-Self.subagentActivityWindow)
        var activity: [String: AgentActivity] = [:]
        for (path, slot) in cache {
            guard let entry = slot.entry,
                isSidecarActive(transcriptPath: path, after: threshold),
                let detail = agentActivity(transcriptPath: path)
            else { continue }
            activity[entry.id] = detail
        }
        return activity
    }

    /// Whether a session has agents working for it right now.
    func hasWorkingAgents(_ id: String) -> Bool {
        guard let path = path(for: id) else { return false }
        return isSidecarActive(
            transcriptPath: path, after: Date().addingTimeInterval(-Self.subagentActivityWindow))
    }

    private func agentActivity(transcriptPath: String) -> AgentActivity? {
        let threshold = Date().addingTimeInterval(-Self.subagentActivityWindow)
        let resolved = resolvedTools(transcriptPath: transcriptPath)
        let working = Self.sidecarDirs(transcriptPath: transcriptPath)
            .flatMap { subagents(in: $0, threshold: threshold, resolved: resolved) }
            .filter(\.active)
        guard !working.isEmpty else { return nil }
        return AgentActivity(
            count: working.count,
            task: working.count == 1 ? working[0].title : nil)
    }

    /// Directories that can hold subagent transcripts: the session's
    /// `subagents/` dir plus one `workflows/<runID>/` level beneath it.
    /// The session a transcript belongs to: its own file name, or — for a
    /// subagent sidecar under `<sessionID>/subagents/` — the session that spawned it.
    nonisolated static func sessionID(forTranscriptPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let components = url.pathComponents
        if let index = components.lastIndex(of: "subagents"), index > 0 {
            return components[index - 1]
        }
        return url.deletingPathExtension().lastPathComponent
    }

    nonisolated static func sidecarDirs(transcriptPath: String) -> [URL] {
        let root = URL(fileURLWithPath: transcriptPath)
            .deletingPathExtension()
            .appendingPathComponent("subagents")
        var dirs = [root]
        let workflows = root.appendingPathComponent("workflows")
        if let runs = try? FileManager.default.contentsOfDirectory(
            at: workflows, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles)
        {
            dirs.append(contentsOf: runs)
        }
        return dirs
    }

    /// Subagent sidecars for a session: one summary per `agent-*.jsonl` under
    /// `<sessionID>/subagents/` (including workflow runs), described by the
    /// sibling `.meta.json` the CLI writes alongside.
    func subagents(for id: String) -> [SubagentSummary] {
        guard let transcriptPath = path(for: id) else { return [] }
        let threshold = Date().addingTimeInterval(-Self.subagentActivityWindow)
        let resolved = resolvedTools(transcriptPath: transcriptPath)
        return Self.sidecarDirs(transcriptPath: transcriptPath).flatMap { dir in
            subagents(in: dir, threshold: threshold, resolved: resolved)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    static let subagentActivityWindow: TimeInterval = 90

    private var resolvedCache: [String: (offset: Int, ids: Set<String>)] = [:]
    private var progressCache: [String: SubagentProgress] = [:]
    private var journalCache: [String: (offset: Int, ids: Set<String>)] = [:]

    /// These three are parse-avoidance for files that only grow, so they hold ids for every
    /// session and sidecar ever polled. A machine left running for weeks reaches thousands; the
    /// sweep drops the ones whose file is gone and, past a ceiling, everything — a cold cache
    /// costs one scan, and one scan is what the incremental readers were built to survive.
    private func pruneParseCaches() {
        let ceiling = 4_000
        resolvedCache = resolvedCache.filter { FileManager.default.fileExists(atPath: $0.key) }
        progressCache = progressCache.filter { FileManager.default.fileExists(atPath: $0.key) }
        journalCache = journalCache.filter { FileManager.default.fileExists(atPath: $0.key) }
        if resolvedCache.count > ceiling { resolvedCache = [:] }
        if progressCache.count > ceiling { progressCache = [:] }
        if journalCache.count > ceiling { journalCache = [:] }
    }

    /// Incremental like ``resolvedTools``: only appended bytes are parsed, so polling a fan-out
    /// of forty sidecars every few seconds costs what changed, not forty full files.
    private func progress(atPath path: String) -> SubagentProgress {
        var cached = progressCache[path] ?? SubagentProgress()
        guard let handle = FileHandle(forReadingAtPath: path) else { return cached }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        if size < cached.offset { cached = SubagentProgress() }
        guard size > cached.offset else { return cached }
        try? handle.seek(toOffset: UInt64(cached.offset))
        guard let data = try? handle.read(upToCount: size - cached.offset) else { return cached }
        TranscriptParser.accumulateProgress(&cached, data: data)
        cached.offset = size
        progressCache[path] = cached
        return cached
    }

    /// Incremental: only bytes appended since the last call are scanned (with a small
    /// overlap so a marker split across reads isn't missed). A full-file scan of a
    /// growing transcript on every poll starves the actor for minutes.
    private func resolvedTools(transcriptPath: String) -> Set<String> {
        var cached = resolvedCache[transcriptPath] ?? (0, [])
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return cached.ids }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        if size < cached.offset { cached = (0, []) }
        guard size > cached.offset else { return cached.ids }
        let start = max(0, cached.offset - 64)
        try? handle.seek(toOffset: UInt64(start))
        guard let data = try? handle.read(upToCount: size - start) else { return cached.ids }
        cached.ids.formUnion(TranscriptParser.toolUseIDs(in: data))
        cached.offset = size
        resolvedCache[transcriptPath] = cached
        return cached.ids
    }

    /// Agent ids a workflow run's journal records a result for — the
    /// completion signal for workflow agents, which have no spawning Task
    /// tool call in the parent transcript.
    /// Incremental like ``resolvedTools``: a journal is append-only and this is asked for on every
    /// subagent poll, so only the bytes since the last look are parsed. A result already recorded
    /// stays recorded.
    private func journalCompletedAgentIDs(in dir: URL) -> Set<String> {
        let path = dir.appendingPathComponent("journal.jsonl").path
        var cached = journalCache[path] ?? (0, [])
        guard let handle = FileHandle(forReadingAtPath: path) else { return cached.ids }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        if size < cached.offset { cached = (0, []) }
        guard size > cached.offset else { return cached.ids }
        try? handle.seek(toOffset: UInt64(cached.offset))
        guard let data = try? handle.read(upToCount: size - cached.offset) else {
            return cached.ids
        }
        TranscriptParser.forEachJSONLine(in: data, dropIncompleteTail: false) { object in
            if object["type"] as? String == "result",
                let agentID = object["agentId"] as? String
            {
                cached.ids.insert(agentID)
            }
            return true
        }
        cached.offset += completeBytes(in: data)
        journalCache[path] = cached
        return cached.ids
    }

    /// How much of a read ends on a line boundary. A trailing partial line is read for what it
    /// already says and then left behind the offset, so the next look reads it whole; the ids are
    /// a set, so seeing the same result twice costs nothing.
    private func completeBytes(in data: Data) -> Int {
        guard let last = data.lastIndex(of: 0x0A) else { return 0 }
        return data.distance(from: data.startIndex, to: last) + 1
    }

    private func subagents(in dir: URL, threshold: Date, resolved: Set<String>)
        -> [SubagentSummary]
    {
        let journalCompleted = journalCompletedAgentIDs(in: dir)
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles)
        else { return [] }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { file -> SubagentSummary? in
                let name = file.deletingPathExtension().lastPathComponent
                guard name.hasPrefix("agent-") else { return nil }
                let lastContent =
                    TranscriptParser.lastContentDate(atPath: file.path)
                    ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                var title = "Agent"
                var agentType: String?
                var toolUseID: String?
                let metaURL = dir.appendingPathComponent("\(name).meta.json")
                if let data = try? Data(contentsOf: metaURL),
                    let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    if let description = meta["description"] as? String, !description.isEmpty {
                        title = description
                    }
                    agentType = meta["agentType"] as? String
                    toolUseID = meta["toolUseId"] as? String
                }
                if title == "Agent",
                    let prompt = TranscriptParser.firstUserPromptLine(atPath: file.path)
                {
                    title = prompt
                }
                let agentID = String(name.dropFirst("agent-".count))
                let completed =
                    toolUseID.map(resolved.contains) ?? false
                    || journalCompleted.contains(agentID)
                let active = !completed && lastContent > threshold
                var summary = SubagentSummary(
                    id: agentID,
                    title: title, agentType: agentType, toolUseID: toolUseID,
                    updatedAt: lastContent,
                    active: active,
                    completed: completed)
                if active {
                    let progress = progress(atPath: file.path)
                    summary.startedAt = progress.startedAt
                    summary.toolCount = progress.toolCount > 0 ? progress.toolCount : nil
                    summary.currentTool = progress.currentTool
                    summary.todosDone = progress.todosTotal != nil ? progress.todosDone : nil
                    summary.todosTotal = progress.todosTotal
                    summary.currentTodo = progress.currentTodo
                }
                return summary
            }
    }

    func subagentMessages(sessionID: String, agentID: String) async -> [Message]? {
        guard let transcriptPath = path(for: sessionID),
            agentID.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        for dir in Self.sidecarDirs(transcriptPath: transcriptPath) {
            let file = dir.appendingPathComponent("agent-\(agentID).jsonl")
            if FileManager.default.fileExists(atPath: file.path) {
                return await foldedMessages(atPath: file.path, includeSidechain: true)
            }
        }
        return nil
    }

    /// The picture a tool call handed the model, recovered from the transcript when the file it
    /// read no longer exists — a screenshot written to `/tmp` rarely outlives the turn, and a
    /// conversation has to keep showing what it was talking about. Searches the session's own
    /// transcript first, then its subagent sidecars: a picture a subagent looked at is docked in
    /// the conversation that spawned it.
    func imageBytes(session: String, toolID: String) async -> (data: Data, mime: String)? {
        if pathByID[session] == nil { scan() }
        guard let path = pathByID[session] else { return nil }
        let size = fileSize(path)
        if let known = imageOffsets[session], known.size == size,
            let mark = known.offsets[toolID],
            let found = TranscriptImage.bytes(
                transcriptPath: mark.path, toolID: toolID, at: mark.offset)
        {
            return found
        }
        let sidecars = Self.sidecarDirs(transcriptPath: path)
        let mapped = await Task.detached(priority: .userInitiated) {
            var offsets: [String: (path: String, offset: UInt64)] = [:]
            for (id, offset) in TranscriptImage.index(transcriptPath: path) {
                offsets[id] = (path, offset)
            }
            for dir in sidecars {
                let files =
                    (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                for name in files where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
                    let sidecar = dir.appendingPathComponent(name).path
                    for (id, offset) in TranscriptImage.index(transcriptPath: sidecar)
                    where offsets[id] == nil {
                        offsets[id] = (sidecar, offset)
                    }
                }
            }
            return offsets
        }.value
        imageOffsets[session] = (size: size, offsets: mapped)
        pruneImageOffsets()
        guard let mark = mapped[toolID] else { return nil }
        return TranscriptImage.bytes(
            transcriptPath: mark.path, toolID: toolID, at: mark.offset)
    }

    /// Where every picture of a conversation sits in the files that hold it. Built by one scan and
    /// spent by every later tap: a gallery is a walk through pictures the transcript already
    /// mentioned. Rebuilt whole when the transcript has grown, because a new turn's pictures are
    /// past the end of what was mapped.
    private var imageOffsets: [String: (size: UInt64, offsets: [String: (path: String, offset: UInt64)])] = [:]

    private func pruneImageOffsets() {
        guard imageOffsets.count > 24 else { return }
        imageOffsets = [:]
    }

    private func fileSize(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?
            .uint64Value ?? 0
    }

    /// Latest transcript mtime per session id, for freshening stored sessions
    /// whose conversation has since continued elsewhere.
    /// What each transcript's most recent answer ran with, for the stored sessions whose records
    /// were written when they were created and never hear about a `/model` typed into a terminal.
    func transcriptSettings() -> [String: TranscriptSettings] {
        scan()
        var settings: [String: TranscriptSettings] = [:]
        for slot in cache.values {
            guard let entry = slot.entry, entry.model != nil || entry.effort != nil else { continue }
            settings[entry.id] = TranscriptSettings(model: entry.model, effort: entry.effort)
        }
        return settings
    }

    func transcriptSettings(for id: String) -> TranscriptSettings? {
        guard let path = path(for: id), let entry = cache[path]?.entry else { return nil }
        guard entry.model != nil || entry.effort != nil else { return nil }
        return TranscriptSettings(model: entry.model, effort: entry.effort)
    }

    struct AnalyticsSource: Sendable {
        var path: String
        var id: String
        var title: String
        var directory: String?
        var createdAt: Date
        var mtime: Date
        var size: Int
    }

    /// Every transcript on the machine with just enough identity to aggregate it — the
    /// analytics walk decides for itself which files are worth opening.
    func analyticsSources() -> [AnalyticsSource] {
        scan()
        return cache.compactMap { path, slot in
            guard let entry = slot.entry else { return nil }
            return AnalyticsSource(
                path: path, id: entry.id, title: entry.title, directory: entry.directory,
                createdAt: entry.createdAt, mtime: slot.mtime, size: slot.size)
        }
    }

    func transcriptDates() -> [String: Date] {
        scan()
        var dates: [String: Date] = [:]
        for slot in cache.values {
            guard let entry = slot.entry else { continue }
            dates[entry.id] = slot.mtime
        }
        return dates
    }

    /// True when the transcript (or its subagent sidecars) was written within
    /// the window — someone's process is actively working in the session.
    func isWriting(_ id: String, within seconds: TimeInterval) -> Bool {
        guard let path = path(for: id) else { return false }
        let threshold = Date().addingTimeInterval(-seconds)
        if let content = TranscriptParser.lastContentDate(atPath: path), content > threshold {
            return true
        }
        return isSidecarActive(transcriptPath: path, after: threshold)
    }

    private func isSidecarActive(transcriptPath: String, after threshold: Date) -> Bool {
        guard let latest = sidecarLatest(transcriptPath: transcriptPath) else { return false }
        return latest > threshold
    }

    private struct SidecarProbe {
        var latest: Date?
        var dirStamps: [String: Date]
        var checkedAt: ContinuousClock.Instant
        var walkedAt: ContinuousClock.Instant
    }

    private var sidecarProbes: [String: SidecarProbe] = [:]
    private static let sidecarProbeDebounce: Duration = .milliseconds(900)
    private static let sidecarColdRecheck: Duration = .seconds(120)

    /// Latest sidecar write for a transcript, memoized so the sweep's several askers per second
    /// cost one directory walk only where agents might actually be working. A repeat inside the
    /// debounce answers from the cache outright — the same sweep asks through `activeIDs`, the
    /// listing and the agent scan, and the answer cannot have changed between them. A session
    /// whose sidecars wrote recently is re-walked every time: those are few, and their file
    /// mtimes are the very signal being read. A cold session — most of the machine, forever — is
    /// trusted while its sidecar directories' own mtimes stand still, because a new agent means a
    /// new file and a new file stamps its directory. The slow recheck backstops the one write no
    /// directory mtime can betray (an old file appended with no new neighbour), so even that
    /// heals inside two minutes.
    private func sidecarLatest(transcriptPath: String) -> Date? {
        let now = ContinuousClock.now
        if let probe = sidecarProbes[transcriptPath] {
            if now - probe.checkedAt < Self.sidecarProbeDebounce { return probe.latest }
            let warm =
                probe.latest.map {
                    Date().timeIntervalSince($0) < Self.subagentActivityWindow * 3
                } ?? false
            if !warm, now - probe.walkedAt < Self.sidecarColdRecheck,
                Self.sidecarDirStamps(transcriptPath: transcriptPath) == probe.dirStamps
            {
                sidecarProbes[transcriptPath]?.checkedAt = now
                return probe.latest
            }
        }
        let stamps = Self.sidecarDirStamps(transcriptPath: transcriptPath)
        let latest =
            stamps.isEmpty
            ? nil : TranscriptParser.sidecarActivity(transcriptPath: transcriptPath)
        sidecarProbes[transcriptPath] = SidecarProbe(
            latest: latest, dirStamps: stamps, checkedAt: now, walkedAt: now)
        return latest
    }

    /// The memoized probe for every known session at once, keyed by session id — one actor call
    /// for the observer's whole agent sweep instead of one uncached walk per session per tick.
    func sidecarLatestsByID() -> [String: Date] {
        scan()
        var latests: [String: Date] = [:]
        for (id, path) in pathByID {
            if let latest = sidecarLatest(transcriptPath: path) { latests[id] = latest }
        }
        return latests
    }

    /// The mtimes of the directories that can hold this session's sidecars — the cheap question
    /// whose answer changes whenever an agent file is created or removed. Empty means the session
    /// has never fanned out, which is most sessions and costs exactly one `stat`.
    nonisolated private static func sidecarDirStamps(transcriptPath: String) -> [String: Date] {
        guard transcriptPath.hasSuffix(".jsonl") else { return [:] }
        let root = String(transcriptPath.dropLast(".jsonl".count)) + "/subagents"
        var stamps: [String: Date] = [:]
        guard let rootStamp = statMtime(root) else { return stamps }
        stamps[root] = rootStamp
        let workflows = root + "/workflows"
        guard statMtime(workflows) != nil,
            let runs = try? FileManager.default.contentsOfDirectory(atPath: workflows)
        else { return stamps }
        for run in runs {
            let dir = workflows + "/" + run
            if let stamp = statMtime(dir) { stamps[dir] = stamp }
        }
        return stamps
    }

    /// One `stat` and nothing else: the probes run hundreds of times a second across the whole
    /// machine, and Foundation's attribute dictionaries are the cost being avoided.
    nonisolated static func statMtime(_ path: String) -> Date? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        #if os(Linux)
            let seconds = status.st_mtim
        #else
            let seconds = status.st_mtimespec
        #endif
        return Date(
            timeIntervalSince1970: TimeInterval(seconds.tv_sec)
                + TimeInterval(seconds.tv_nsec) / 1_000_000_000)
    }

    nonisolated static func statSize(_ path: String) -> Int? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return Int(status.st_size)
    }

    /// Parses the transcript into a `Session` suitable for display or adoption. Incremental:
    /// only bytes appended since the last fetch are read and folded.
    func session(_ id: String) async -> Session? {
        if pathByID[id] == nil { scan() }
        guard let path = pathByID[id], let slot = cache[path], let entry = slot.entry else {
            return nil
        }
        let messages = await foldedMessages(atPath: path)
        return Session(
            id: entry.id,
            title: entry.title,
            directory: entry.directory,
            claudeSessionID: entry.id,
            model: entry.model ?? defaults.model(),
            effort: entry.effort ?? "",
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            messages: messages,
            lastCostUSD: nil,
            lastTokens: nil,
            pendingFork: nil)
    }

    /// Messages folded from a transcript, served from a per-path incremental cache: the fold
    /// state persists between calls and only appended bytes are read and parsed. The read+parse
    /// runs off the actor, so a large first parse never blocks other index consumers.
    func foldedMessages(atPath path: String, includeSidechain: Bool = false) async -> [Message] {
        await advanceFold(atPath: path, includeSidechain: includeSidechain)?.fold.snapshot ?? []
    }

    /// Fold state advanced to end-of-file, handed to the watcher so tailing continues from the
    /// bytes history parsing already consumed instead of re-reading the whole file.
    func foldHandoff(atPath path: String) async -> FoldState? {
        await advanceFold(atPath: path, includeSidechain: false)
    }

    /// Transcript paths keyed by session id — the observer's sweep list.
    func pathsByID() -> [String: String] {
        scan()
        return pathByID
    }

    /// Advances the fold over appended bytes and reports exactly which messages they changed,
    /// so the observer publishes precise upserts instead of re-sending a transcript.
    func advanceReportingChanges(atPath path: String)
        async -> (messages: [Message], changed: Set<String>, goal: GoalStatus?)?
    {
        guard let state = await advanceFold(atPath: path, includeSidechain: false) else {
            return nil
        }
        return (state.fold.snapshot, state.lastChanged, state.fold.goal)
    }

    /// The session's current `/goal`, read from the same incremental fold that serves its messages.
    func goal(for id: String) async -> GoalStatus? {
        if pathByID[id] == nil { scan() }
        guard let path = pathByID[id] else { return nil }
        return await advanceFold(atPath: path, includeSidechain: false)?.fold.goal
    }

    /// Serialized per path by chaining onto the previous advance — never by
    /// polling a shared slot, which can livelock the actor when a waiter
    /// re-checks faster than the owner's continuation clears it.
    private func advanceFold(atPath path: String, includeSidechain: Bool) async -> FoldState? {
        let previous = foldTasks[path]
        let task = Task<FoldState?, Never> { [weak self] in
            _ = await previous?.value
            return await self?.performAdvance(path: path, includeSidechain: includeSidechain)
        }
        foldTasks[path] = task
        return await task.value
    }

    private func performAdvance(path: String, includeSidechain: Bool) async -> FoldState? {
        let prior = folds[path].flatMap { $0.includeSidechain == includeSidechain ? $0 : nil }
        let parse = Task.detached(priority: .userInitiated) {
            Self.advance(prior, path: path, includeSidechain: includeSidechain)
        }
        let state = await parse.value
        if let state {
            folds[path] = state
            touchFold(path)
        } else {
            folds[path] = nil
            foldOrder.removeAll { $0 == path }
            foldTasks[path] = nil
        }
        return state
    }

    private nonisolated static func advance(
        _ prior: FoldState?, path: String, includeSidechain: Bool
    ) -> FoldState? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let session = sessionID(forTranscriptPath: path)
        var state =
            prior
            ?? FoldState(
                fold: TranscriptFold(includeSidechain: includeSidechain, sessionID: session),
                offset: 0,
                includeSidechain: includeSidechain)
        if size < state.offset {
            state = FoldState(
                fold: TranscriptFold(includeSidechain: includeSidechain, sessionID: session),
                offset: 0,
                includeSidechain: includeSidechain)
        }
        guard size > state.offset else {
            state.lastChanged = []
            return state
        }
        try? handle.seek(toOffset: UInt64(state.offset))
        guard let data = try? handle.read(upToCount: size - state.offset), !data.isEmpty else {
            state.lastChanged = []
            return state
        }
        state.lastChanged = state.fold.consume(data)
        state.offset += data.count
        return state
    }

    private func touchFold(_ path: String) {
        foldOrder.removeAll { $0 == path }
        foldOrder.append(path)
        while foldOrder.count > Self.foldCacheLimit {
            let evicted = foldOrder.removeFirst()
            folds[evicted] = nil
            foldTasks[evicted] = nil
        }
    }

    static let activityWindow: TimeInterval = 180

    /// Model and effort come from the transcript's own last answer, never from the server
    /// default: a session the CLI switched with `/model` or `/effort` must not keep advertising
    /// what it was started with.
    private func summary(for entry: Entry, turnClosed: Bool) -> SessionSummary {
        let threshold = Date().addingTimeInterval(-Self.activityWindow)
        let active =
            (!turnClosed && entry.updatedAt > threshold)
            || isSidecarActive(transcriptPath: entry.path, after: threshold)
        let agents = active ? agentActivity(transcriptPath: entry.path) : nil
        return SessionSummary(
            id: entry.id,
            title: entry.title,
            directory: entry.directory,
            model: entry.model ?? defaults.model(),
            effort: entry.effort ?? "",
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            active: active,
            agents: agents?.count,
            agentTask: agents?.task)
    }

    /// A lookup for a session that has no transcript yet — every freshly created chat, until its
    /// first turn lands — misses `pathByID` and used to walk all of `~/.claude/projects` per
    /// request: two hundred stats twice per `GET /sessions/:id`, seconds of latency for a session
    /// that is empty by definition. A scan that just ran is still the truth for the next moment,
    /// so repeats inside the window are free; the watcher's sweep outruns the window anyway.
    private func scan() {
        if let last = lastScanAt, ContinuousClock.now - last < Self.scanDebounce { return }
        lastScanAt = ContinuousClock.now
        let fileManager = FileManager.default
        guard
            let projectDirs = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles)
        else { return }

        var seen = Set<String>()
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let files = try? fileManager.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: .skipsHiddenFiles)
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let name = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: name) != nil else { continue }
                seen.insert(file.path)
                refresh(file, id: name)
            }
        }

        for stale in cache.keys where !seen.contains(stale) {
            if let id = cache[stale]?.entry?.id { pathByID[id] = nil }
            cache[stale] = nil
            sidecarProbes[stale] = nil
        }
        pruneParseCaches()
    }

    private func refresh(_ file: URL, id: String) {
        guard
            let values = try? file.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey,
            ]),
            let mtime = values.contentModificationDate,
            let size = values.fileSize
        else { return }
        if let slot = cache[file.path], slot.mtime == mtime, slot.size == size { return }

        let contentDate = TranscriptParser.lastContentDate(atPath: file.path)
        var entry = TranscriptParser.entry(at: file, id: id, updatedAt: contentDate ?? mtime)
        // The prefix scan names the model that *started* the conversation; the tail names the one
        // answering now, which is what every badge in every client is claiming to show.
        let settings = TranscriptParser.lastSettings(atPath: file.path)
        if let model = settings.model { entry?.model = model }
        entry?.effort = settings.effort
        cache[file.path] = CacheSlot(
            mtime: mtime, size: size, entry: entry, contentDate: contentDate,
            turnClosed: TranscriptParser.isTurnClosed(atPath: file.path))
        if entry != nil { pathByID[id] = file.path }
    }
}

/// What a transcript's most recent answer ran with.
struct TranscriptSettings: Sendable, Equatable {
    var model: String?
    var effort: String?
}

/// What a subagent's sidecar says it is doing, accumulated incrementally: how many tools it has
/// run, which one is current, its todo list when it keeps one, and when it started.
struct SubagentProgress: Sendable {
    var offset = 0
    var startedAt: Date?
    var toolCount = 0
    var currentTool: String?
    var todosDone = 0
    var todosTotal: Int?
    var currentTodo: String?
}

/// Parses Claude Code CLI transcript files (`.jsonl`, one JSON object per line).
enum TranscriptParser {
    private static let summaryScanLimit = 512 * 1024
    static let toolOutputLimit = 10_000

    /// Cheap prefix scan: enough to produce a list row without reading the whole file.
    static func entry(at file: URL, id: String, updatedAt: Date) -> TranscriptIndex.Entry? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: summaryScanLimit)) ?? Data()

        var directory: String?
        var model: String?
        /// The reasoning effort the last answer actually ran at, read from the transcript — the
        /// CLI records it per line, and a `/effort` typed into a terminal never reaches any
        /// stored session record.
        var effort: String?
        var createdAt: Date?
        var title: String?
        var commandTitle: String?

        forEachJSONLine(in: data, dropIncompleteTail: data.count == summaryScanLimit) { line in
            if directory == nil, let cwd = line["cwd"] as? String { directory = cwd }
            if createdAt == nil, let stamp = line["timestamp"] as? String {
                createdAt = parseTimestamp(stamp)
            }
            let message = line["message"] as? [String: Any]
            if model == nil, let value = message?["model"] as? String, value != "<synthetic>" {
                model = value
            }
            guard title == nil, isRealLine(line), line["type"] as? String == "user",
                let content = message?["content"] as? String
            else { return true }
            if let typed = typedText(content) {
                title = deriveTitle(typed)
            } else if commandTitle == nil, let command = commandText(content) {
                commandTitle = deriveTitle(command)
            }
            return !(title != nil && directory != nil && model != nil)
        }

        guard let heading = title ?? commandTitle else { return nil }
        return TranscriptIndex.Entry(
            id: id, title: heading, directory: directory, model: model,
            createdAt: createdAt ?? updatedAt, updatedAt: updatedAt, path: file.path)
    }

    /// Timestamp of the last conversation line in a transcript. An interactive
    /// CLI left open keeps touching the file (trailing `last-prompt` metadata,
    /// no timestamp), so file mtime alone reads attached-but-idle sessions as
    /// active forever.
    static func lastContentDate(atPath path: String) -> Date? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let window = min(size, 64 * 1024)
        try? handle.seek(toOffset: UInt64(size - window))
        guard let data = try? handle.read(upToCount: window) else { return nil }
        var found: Date?
        forEachJSONLineReversed(in: data) { line in
            found = (line["timestamp"] as? String).flatMap(parseTimestamp)
            return found == nil
        }
        return found
    }

    /// The model and effort of the transcript's last real answer. Read from the tail because a
    /// conversation can change either mid-way — `/model`, `/effort`, or a client sending its own
    /// — and only the newest line says what is answering now. Widens the window once when the
    /// tail holds nothing but tool results.
    static func lastSettings(atPath path: String) -> TranscriptSettings {
        guard let handle = FileHandle(forReadingAtPath: path) else { return TranscriptSettings() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        for window in [256 * 1024, 4 * 1024 * 1024] {
            let span = min(size, window)
            try? handle.seek(toOffset: UInt64(size - span))
            guard let data = try? handle.read(upToCount: span) else { break }
            var settings: TranscriptSettings?
            forEachJSONLineReversed(in: data) { line in
                guard line["type"] as? String == "assistant",
                    line["isSidechain"] as? Bool != true,
                    let model = (line["message"] as? [String: Any])?["model"] as? String,
                    model != "<synthetic>"
                else { return true }
                settings = TranscriptSettings(model: model, effort: line["effort"] as? String)
                return false
            }
            if let settings { return settings }
            if span == size { break }
        }
        return TranscriptSettings()
    }

    /// First line of the first user prompt in a (sidecar) transcript — the
    /// task description a subagent was spawned with.
    static func firstUserPromptLine(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 32 * 1024)) ?? Data()
        var found: String?
        forEachJSONLine(in: data, dropIncompleteTail: true) { line in
            guard line["type"] as? String == "user",
                let content = (line["message"] as? [String: Any])?["content"] as? String
            else { return true }
            let first = content.split(separator: "\n").first.map(String.init) ?? content
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return true }
            found = String(trimmed.prefix(80))
            return false
        }
        return found
    }

    /// Whether the transcript's last meaningful line closes the turn: the CLI
    /// writes a `system`/`turn_duration` marker when a turn completes, and an
    /// interruption leaves a "[Request interrupted…" user line. Absence of
    /// both means a turn is (or may still be) in flight.
    static func isTurnClosed(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let window = min(size, 64 * 1024)
        try? handle.seek(toOffset: UInt64(size - window))
        guard let data = try? handle.read(upToCount: window) else { return false }
        var closed = false
        forEachJSONLineReversed(in: data) { line in
            switch line["type"] as? String {
            case "system":
                if line["subtype"] as? String == "turn_duration" {
                    closed = true
                    return false
                }
            case "user":
                if let content = (line["message"] as? [String: Any])?["content"] as? String,
                    content.hasPrefix("[Request interrupted")
                {
                    closed = true
                }
                return false
            case "assistant":
                return false
            default:
                break
            }
            return true
        }
        return closed
    }

    /// Folds appended sidecar bytes into a progress accumulator. The last TodoWrite wins whole;
    /// every other tool bumps the count and becomes "current" with a one-line description.
    static func accumulateProgress(_ progress: inout SubagentProgress, data: Data) {
        var carried = progress
        forEachJSONLine(in: data, dropIncompleteTail: false) { line in
            accumulate(&carried, line: line)
            return true
        }
        progress = carried
    }

    private static func accumulate(_ progress: inout SubagentProgress, line: [String: Any]) {
        if progress.startedAt == nil,
            let stamp = (line["timestamp"] as? String).flatMap(parseTimestamp)
        {
            progress.startedAt = stamp
        }
        guard line["type"] as? String == "assistant",
            let blocks = (line["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return }
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let name = block["name"] as? String else { continue }
            let input = block["input"] as? [String: Any]
            if name == "TodoWrite" {
                guard let todos = input?["todos"] as? [[String: Any]] else { continue }
                progress.todosTotal = todos.count
                progress.todosDone = todos.count { $0["status"] as? String == "completed" }
                progress.currentTodo =
                    todos.first { $0["status"] as? String == "in_progress" }?["content"]
                    as? String
                    ?? todos.first { $0["status"] as? String == "pending" }?["content"]
                    as? String
                continue
            }
            progress.toolCount += 1
            progress.currentTool = describeTool(name: name, input: input)
        }
    }

    private static func describeTool(name: String, input: [String: Any]?) -> String {
        let detail: String? =
            (input?["command"] as? String).map { firstLine($0) }
            ?? (input?["file_path"] as? String).map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
            ?? input?["description"] as? String
            ?? (input?["pattern"] as? String)
            ?? (input?["query"] as? String)
        guard let detail, !detail.isEmpty else { return name }
        return "\(name) \(String(detail.prefix(60)))"
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }

    /// Tool-use ids that already have a result recorded in the transcript — a subagent whose
    /// spawning Task call is resolved has finished. Byte scan, never a String walk:
    /// grapheme-aware searching of a transcript this size takes minutes.
    static func toolUseIDs(in data: Data) -> Set<String> {
        let marker = Data("\"tool_use_id\":\"".utf8)
        var ids = Set<String>()
        var search = data.startIndex
        while let range = data.range(of: marker, in: search..<data.endIndex) {
            let tail = data[range.upperBound...]
            guard let close = tail.firstIndex(of: 0x22) else { break }
            ids.insert(String(decoding: data[range.upperBound..<close], as: UTF8.self))
            search = close
        }
        return ids
    }

    /// Latest write across the session's subagent sidecar transcripts,
    /// including workflow-run agents one level deeper.
    static func sidecarActivity(transcriptPath: String) -> Date? {
        TranscriptIndex.sidecarDirs(transcriptPath: transcriptPath)
            .compactMap { dir -> Date? in
                guard
                    let files = try? FileManager.default.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                        options: .skipsHiddenFiles)
                else { return nil }
                return files
                    .filter { $0.pathExtension == "jsonl" }
                    .compactMap {
                        (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate
                    }
                    .max()
            }
            .max()
    }

    /// Full parse: folds transcript lines into the bridge's message model.
    static func messages(at file: URL, includeSidechain: Bool = false) -> [Message] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        var fold = TranscriptFold(
            includeSidechain: includeSidechain,
            sessionID: TranscriptIndex.sessionID(forTranscriptPath: file.path))
        _ = fold.consume(data)
        return fold.snapshot
    }

    private static func jsonLines(in data: Data, dropIncompleteTail: Bool) -> [[String: Any]] {
        var lines: [[String: Any]] = []
        forEachJSONLine(in: data, dropIncompleteTail: dropIncompleteTail) { line in
            lines.append(line)
            return true
        }
        return lines
    }

    /// Every line in order, parsed one at a time and abandoned the moment the caller has what it
    /// came for. Materializing the window first defeated every early exit above it: a prefix scan
    /// that stops at the title still paid for half a megabyte of dictionaries.
    /// - Parameter body: answers whether to keep going.
    static func forEachJSONLine(
        in data: Data, dropIncompleteTail: Bool, _ body: ([String: Any]) -> Bool
    ) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end == data.endIndex, dropIncompleteTail { return }
            if end > start,
                let object = try? JSONSerialization.jsonObject(with: data[start..<end])
                    as? [String: Any], !body(object)
            {
                return
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
    }

    /// The same, newest first. Every tail reader in this file wants the last line that answers
    /// some question, so walking back from the end parses one or two lines where reading the
    /// window forward and reversing it parsed hundreds.
    static func forEachJSONLineReversed(in data: Data, _ body: ([String: Any]) -> Bool) {
        var end = data.endIndex
        while end > data.startIndex {
            let previous = data[data.startIndex..<end].lastIndex(of: 0x0A)
            let start = previous.map { data.index(after: $0) } ?? data.startIndex
            if end > start,
                let object = try? JSONSerialization.jsonObject(with: data[start..<end])
                    as? [String: Any], !body(object)
            {
                return
            }
            guard let previous else { return }
            end = previous
        }
    }

    static func isRealLine(_ line: [String: Any]) -> Bool {
        line["isMeta"] as? Bool != true && line["isSidechain"] as? Bool != true
    }

    /// Human-typed prompt text; nil for command wrappers, caveats, and injected
    /// reminders. Background-task notifications condense to a one-line status
    /// instead of their raw XML payload.
    static func typedText(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("<task-notification") {
            return taskNotificationSummary(trimmed)
        }
        for marker in ["<command-", "<local-command", "<system-reminder", "Caveat:"]
        where trimmed.hasPrefix(marker) {
            return nil
        }
        return trimmed
    }

    static func taskNotificationSummary(_ content: String) -> String? {
        var lead = tagValue("summary", in: content)?
            .split(separator: "\n").first.map(String.init)
        if lead == nil, tagValue("status", in: content) != nil || tagValue("usage", in: content) != nil {
            lead = "Background agent finished"
        }
        guard var text = lead else { return nil }
        var stats: [String] = []
        if let ms = tagValue("duration_ms", in: content).flatMap(Double.init) {
            stats.append(compactDuration(ms / 1000))
        }
        if let tools = tagValue("tool_uses", in: content) {
            stats.append("\(tools) tools")
        }
        if let tokens = tagValue("subagent_tokens", in: content).flatMap(Int.init) {
            stats.append(tokens >= 1000 ? "\(tokens / 1000)k tokens" : "\(tokens) tokens")
        }
        if !stats.isEmpty { text += " · " + stats.joined(separator: " · ") }
        return text
    }

    static func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(max(seconds, 1))s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// Renders a slash-command invocation (`<command-name>/foo</command-name>…`) as `/foo args`.
    static func commandText(_ content: String) -> String? {
        guard let name = tagValue("command-name", in: content) else { return nil }
        let args = tagValue("command-args", in: content) ?? ""
        return args.isEmpty ? name : "\(name) \(args)"
    }

    private static func tagValue(_ tag: String, in content: String) -> String? {
        guard let open = content.range(of: "<\(tag)>"),
            let close = content.range(of: "</\(tag)>", range: open.upperBound..<content.endIndex)
        else { return nil }
        let value = content[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func deriveTitle(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return String(firstLine.prefix(60))
    }

    static func flatten(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    static let fractionalTimestamp = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true)

    static func parseTimestamp(_ raw: String) -> Date? {
        (try? Date(raw, strategy: fractionalTimestamp)) ?? (try? Date(raw, strategy: .iso8601))
    }
}
