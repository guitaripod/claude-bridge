import Foundation

/// What the expert store needs to know about one of its tasks, read from the session store.
struct ExpertTaskInfo: Sendable, Equatable {
    var sessionID: String
    var expertID: String
    var title: String
    var updatedAt: Date
    var active: Bool
    var claudeSessionID: String?
    var directory: String?
    var model: String
    /// How many of the person's messages the task holds.
    var userTurns: Int
}

/// The experts this machine keeps: each one's definition, notebook, journal, debriefs, guard runs
/// and the brief every task of it starts with. Files under `<state>/experts/<id>/`, written
/// atomically and readable by the person alone; an adopted notebook stays where it is.
actor ExpertStore {
    private let root: URL
    private let store: SessionStore
    private let claudePath: String
    private let now: @Sendable () -> Date
    private var experts: [String: Expert] = [:]
    private var benchCache: [String: [BenchItem]] = [:]
    /// Bumped whenever an expert's bench is redescribed, so a proof that began before the change
    /// is thrown away instead of writing the old items back.
    private var benchGeneration: [String: Int] = [:]
    private var guardRuns: [String: GuardBook] = [:]
    private var runningGuards: [String: Set<String>] = [:]
    private var drafting: Set<String> = []
    private var onChange: (@Sendable () -> Void)?
    private var onGuardFlip: (@Sendable (Expert, GuardItem, GuardRun) async -> Void)?
    private var watchesFor: (@Sendable (String) async -> [String])?
    private let ask: @Sendable (ExpertAsk.Request) async -> (answer: [String: Any]?, failure: String?)

    static let limit = 30
    static let charterLimit = 6_000
    static let benchLimit = 20
    static let guardLimit = 20
    static let skillLimit = 20
    static let tasksShown = 10
    static let journalKept = 400
    static let guardHistory = 30
    static let guardCatchUp: TimeInterval = 12 * 3_600

    struct GuardBook: Codable, Sendable {
        var lastScheduled: Date?
        var runs: [String: [GuardRun]]
    }

    init(
        root: URL, store: SessionStore, claudePath: String, now: @escaping @Sendable () -> Date = { Date() },
        ask: (@Sendable (ExpertAsk.Request) async -> (answer: [String: Any]?, failure: String?))? = nil
    ) {
        self.root = root
        self.store = store
        self.claudePath = claudePath
        self.now = now
        self.ask = ask ?? { request in await ExpertAsk.ask(claudePath: claudePath, request) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for id in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            let file = root.appendingPathComponent(id).appendingPathComponent("expert.json")
            guard let data = try? Data(contentsOf: file),
                let expert = try? AgentJSON.decoder.decode(Expert.self, from: data)
            else { continue }
            experts[expert.id] = expert
            let book = root.appendingPathComponent(id).appendingPathComponent("guards.json")
            if let data = try? Data(contentsOf: book), let read = try? AgentJSON.decoder.decode(GuardBook.self, from: data) {
                guardRuns[expert.id] = read
            }
        }
    }

    func observe(_ change: @escaping @Sendable () -> Void) { onChange = change }

    /// A turn ended somewhere on the machine; a task of an expert changes what its shelf says.
    func turnEnded(_ sessionID: String) async {
        if await store.expertTask(sessionID) != nil { changed() }
    }
    func observeGuardFlips(_ flip: @escaping @Sendable (Expert, GuardItem, GuardRun) async -> Void) { onGuardFlip = flip }
    func watches(_ lookup: @escaping @Sendable (String) async -> [String]) { watchesFor = lookup }

    // MARK: Reading

    func list() async -> [ExpertView] {
        var views: [ExpertView] = []
        for expert in experts.values.sorted(by: { $0.createdAt < $1.createdAt }) {
            views.append(await view(expert))
        }
        return views
    }

    func get(_ id: String) async -> ExpertView? {
        guard let expert = experts[id] else { return nil }
        return await view(expert)
    }

    func expert(_ id: String) -> Expert? { experts[id] }

    func notebook(for expert: Expert) -> Notebook {
        if let path = expert.notebookPath {
            return Notebook(folder: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), adopted: true)
        }
        return Notebook(folder: folder(expert.id).appendingPathComponent("notebook"), adopted: false)
    }

    func notes(_ id: String, retired: Bool) throws -> [Note] {
        guard let expert = experts[id] else { throw ExpertError.unknown }
        let book = notebook(for: expert)
        return retired ? book.retired(now: now()) : book.notes(now: now())
    }

    func note(_ id: String, _ noteID: String) throws -> Note? {
        guard let expert = experts[id] else { throw ExpertError.unknown }
        return notebook(for: expert).note(noteID, now: now())
    }

    func journal(_ id: String, limit: Int = 100) throws -> [JournalEntry] {
        guard experts[id] != nil else { throw ExpertError.unknown }
        return Array(readJournal(id).prefix(limit))
    }

    private func view(_ expert: Expert) async -> ExpertView {
        let tasks = await store.expertTasks(expert.id)
        var refs: [ExpertTaskRef] = []
        var running: ExpertTaskRef?
        var pending = 0
        for task in tasks {
            let debrief = readDebrief(task.sessionID)
            pending += debrief?.pending ?? 0
            let ref = ExpertTaskRef(
                sessionID: task.sessionID, title: task.title, updatedAt: task.updatedAt, active: task.active,
                debrief: debrief?.state)
            if refs.count < Self.tasksShown { refs.append(ref) }
            if running == nil, task.active { running = ref }
        }
        let book = notebook(for: expert)
        let bench = benchCache[expert.id] ?? expert.bench.map(\.described)
        let guards = servedGuards(expert)
        let journal = readJournal(expert.id)
        let brief = ExpertBrief.text(
            ExpertBrief.Inputs(
                expert: expert, notebookPath: book.folder.path, notes: book.notes(now: now()), journal: journal,
                bench: bench, guards: guards, timeZone: TimeZone(identifier: expert.timeZone) ?? .current))
        return ExpertView(
            id: expert.id, name: expert.name, glyph: expert.glyph, hue: expert.hue, purpose: expert.purpose,
            directory: expert.directory, model: expert.model, effort: expert.effort, charter: expert.charter,
            skills: expert.skills, notebookPath: expert.notebookPath, bench: bench, guards: guards,
            guardRule: expert.guardRule, guardNext: nextGuardRun(expert), timeZone: expert.timeZone,
            createdAt: expert.createdAt, updatedAt: expert.updatedAt, notebook: book.facts(now: now()),
            journal: Array(journal.prefix(ExpertBrief.journalShown)), task: running, tasks: refs,
            pending: pending, briefTokens: ExpertBrief.tokens(brief), watches: await watchesFor?(expert.id) ?? [])
    }

    private func servedGuards(_ expert: Expert) -> [GuardItem] {
        let book = guardRuns[expert.id]
        let running = runningGuards[expert.id] ?? []
        return expert.guards.map { item in
            var served = item.described
            let runs = book?.runs[item.id] ?? []
            served.last = runs.first
            served.history = Array(runs.prefix(Self.guardHistory))
            served.running = running.contains(item.id) ? true : nil
            return served
        }
    }

    // MARK: Making and changing

    func create(_ draft: ExpertDraft) throws -> Expert {
        guard experts.count < Self.limit else {
            throw ExpertError.invalid("This machine keeps at most \(Self.limit) experts.")
        }
        let moment = now()
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw ExpertError.invalid("An expert needs a name of at most 40 characters.") }
        var expert = Expert(
            id: UUID().uuidString, name: name, glyph: Self.glyph(draft.glyph, name: name),
            hue: Expert.hues.contains(draft.hue ?? "") ? draft.hue! : Self.hue(for: name),
            purpose: String((draft.purpose ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)),
            directory: nil, model: draft.model?.nilIfEmpty, effort: draft.effort?.nilIfEmpty,
            charter: "", skills: [], notebookPath: nil, bench: [], guards: [], guardRule: draft.guardRule,
            timeZone: draft.timeZone.flatMap(TimeZone.init(identifier:))?.identifier ?? TimeZone.current.identifier,
            createdAt: moment, updatedAt: moment)
        try apply(
            ExpertPatch(
                directory: draft.directory, charter: draft.charter ?? "", skills: draft.skills ?? [],
                notebookPath: draft.notebookPath, bench: draft.bench ?? [], guards: draft.guards ?? []),
            to: &expert)
        if let rule = expert.guardRule, let problem = rule.problem() { throw ExpertError.invalid(problem) }
        let book = notebook(for: expert)
        try? FileManager.default.createDirectory(at: book.folder, withIntermediateDirectories: true)
        for note in draft.notes ?? [] where note.lasting != false {
            try book.add(
                title: note.title, summary: note.summary, body: note.body, type: note.type,
                source: "tailscode-expert:\(expert.id):made", now: moment)
        }
        experts[expert.id] = expert
        try save(expert)
        changed()
        return expert
    }

    func update(_ id: String, _ patch: ExpertPatch) throws -> Expert {
        guard var expert = experts[id] else { throw ExpertError.unknown }
        try apply(patch, to: &expert)
        if let name = patch.name?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard !name.isEmpty, name.count <= 40 else {
                throw ExpertError.invalid("An expert needs a name of at most 40 characters.")
            }
            expert.name = name
        }
        if let glyph = patch.glyph { expert.glyph = Self.glyph(glyph, name: expert.name) }
        if let hue = patch.hue, Expert.hues.contains(hue) { expert.hue = hue }
        if let purpose = patch.purpose {
            expert.purpose = String(purpose.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        }
        if let model = patch.model { expert.model = model.nilIfEmpty }
        if let effort = patch.effort { expert.effort = effort.nilIfEmpty }
        if let zone = patch.timeZone.flatMap(TimeZone.init(identifier:)) { expert.timeZone = zone.identifier }
        if patch.guardsOnDemand == true {
            expert.guardRule = nil
        } else if let rule = patch.guardRule {
            if let problem = rule.problem() { throw ExpertError.invalid(problem) }
            expert.guardRule = rule
            guardRuns[id, default: GuardBook(lastScheduled: nil, runs: [:])].lastScheduled = now()
            saveGuards(id)
        }
        if let bench = patch.bench {
            let ids = Set(bench.map(\.id))
            benchCache[id] = benchCache[id]?.filter { ids.contains($0.id) }
            benchGeneration[id, default: 0] += 1
        }
        expert.updatedAt = now()
        experts[id] = expert
        try save(expert)
        changed()
        return expert
    }

    /// Checks and applies the parts of a patch that create and update share.
    private func apply(_ patch: ExpertPatch, to expert: inout Expert) throws {
        if let directory = patch.directory {
            let path = (directory as NSString).expandingTildeInPath
            if path.isEmpty {
                expert.directory = nil
            } else {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw ExpertError.invalid("The folder \(directory) is not on this machine.")
                }
                expert.directory = path
            }
        }
        if let charter = patch.charter {
            let trimmed = charter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= Self.charterLimit else {
                throw ExpertError.invalid("A charter is at most \(Self.charterLimit) characters: a map, not a manual.")
            }
            expert.charter = trimmed
        }
        if let skills = patch.skills {
            let cleaned = skills.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard cleaned.count <= Self.skillLimit else {
                throw ExpertError.invalid("An expert loads at most \(Self.skillLimit) skills.")
            }
            var seen: Set<String> = []
            expert.skills = cleaned.filter { seen.insert($0).inserted }
        }
        if let path = patch.notebookPath {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.isEmpty {
                expert.notebookPath = nil
            } else {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue
                else { throw ExpertError.invalid("The notebook folder \(path) is not on this machine.") }
                expert.notebookPath = expanded
            }
        }
        if let bench = patch.bench {
            guard bench.count <= Self.benchLimit else {
                throw ExpertError.invalid("A bench holds at most \(Self.benchLimit) items.")
            }
            var cleaned: [BenchItem] = []
            for item in bench {
                guard BenchItem.kinds.contains(item.kind) else { throw ExpertError.invalid("Unknown bench item \(item.kind).") }
                let name = item.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { throw ExpertError.invalid("Every bench item needs a name.") }
                if item.kind == "command", (item.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    throw ExpertError.invalid("\(name) needs the command that proves it.")
                }
                if item.kind == "port", !(1...65_535).contains(item.port ?? 0) {
                    throw ExpertError.invalid("\(name) needs a port between 1 and 65535.")
                }
                var kept = item.described
                kept.id = item.id.isEmpty ? UUID().uuidString : item.id
                kept.name = name
                cleaned.append(kept)
            }
            expert.bench = cleaned
        }
        if let guards = patch.guards {
            guard guards.count <= Self.guardLimit else {
                throw ExpertError.invalid("An expert keeps at most \(Self.guardLimit) guards.")
            }
            var cleaned: [GuardItem] = []
            for item in guards {
                let name = item.name.trimmingCharacters(in: .whitespaces)
                let command = item.command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !command.isEmpty else {
                    throw ExpertError.invalid("Every guard needs a name and a command.")
                }
                if let metric = item.metric {
                    guard (try? NSRegularExpression(pattern: metric.pattern)) != nil else {
                        throw ExpertError.invalid("\(name)'s pattern is not a regular expression this machine reads.")
                    }
                    guard metric.atMost != nil || metric.atLeast != nil else {
                        throw ExpertError.invalid("\(name) measures a number but has no line for it.")
                    }
                }
                if let timeout = item.timeout, !(10...(6 * 3_600)).contains(timeout) {
                    throw ExpertError.invalid("\(name) may run for between 10 seconds and 6 hours.")
                }
                var kept = item.described
                kept.id = item.id.isEmpty ? UUID().uuidString : item.id
                kept.name = name
                kept.command = command
                cleaned.append(kept)
            }
            expert.guards = cleaned
        }
    }

    func delete(_ id: String) -> Bool {
        guard experts[id] != nil else { return false }
        experts[id] = nil
        benchCache[id] = nil
        guardRuns[id] = nil
        let gone = root.appendingPathComponent(".deleted")
        try? FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(
            at: folder(id), to: gone.appendingPathComponent("\(id)-\(Int(now().timeIntervalSince1970))"))
        changed()
        return true
    }

    // MARK: Tasks and their brief

    /// Starts a task: a new conversation marked as the expert's, whose processes all start with
    /// the brief written now. A task the expert left unfinished is debriefed first, in the
    /// background, so a journal entry is never missing.
    func startTask(_ id: String, _ request: ExpertTaskRequest) async throws -> ExpertTaskStarted {
        guard let expert = experts[id] else { throw ExpertError.unknown }
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExpertError.invalid("A task needs words.") }
        let unfinished = await unfinishedTasks(id)
        let brief = await brief(for: expert, prove: true)
        let session = await store.createExpertTask(
            expertID: id, title: request.title?.nilIfEmpty, directory: request.directory?.nilIfEmpty ?? expert.directory,
            model: request.model?.nilIfEmpty ?? expert.model, effort: request.effort?.nilIfEmpty ?? expert.effort)
        guard experts[id] != nil else {
            await store.delete(session.id)
            throw ExpertError.unknown
        }
        writeBrief(brief, expert: id, session: session.id)
        let outcome = await store.sendExpertTask(
            session.id, text: request.text, model: request.model?.nilIfEmpty ?? expert.model,
            effort: request.effort?.nilIfEmpty ?? expert.effort)
        changed()
        if !unfinished.isEmpty {
            Task { for task in unfinished { _ = try? await self.debrief(task.sessionID) } }
        }
        let summary = await store.summary(session.id) ?? session.summary
        if case .queued(let position) = outcome { return ExpertTaskStarted(session: summary, queued: position) }
        return ExpertTaskStarted(session: summary, queued: nil)
    }

    /// The brief a conversation of this expert's starts with: the one written when its task began,
    /// or — for a conversation a watch made — one written now and kept for its next turns.
    func briefFor(session: String, expertID: String) async -> String? {
        let file = folder(expertID).appendingPathComponent("briefs").appendingPathComponent("\(session).md")
        if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        guard let expert = experts[expertID] else { return deletedBrief(session: session, expertID: expertID) }
        let text = await brief(for: expert, prove: true)
        writeBrief(text, expert: expertID, session: session)
        return text
    }

    /// The brief a task of a deleted expert started with, from the folder the expert was set aside
    /// in, so the task's later processes keep the brief its first one had.
    private func deletedBrief(session: String, expertID: String) -> String? {
        let gone = root.appendingPathComponent(".deleted")
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: gone.path)) ?? [])
            .filter { $0.hasPrefix("\(expertID)-") }.sorted().reversed()
        for name in folders {
            let file = gone.appendingPathComponent(name).appendingPathComponent("briefs").appendingPathComponent("\(session).md")
            if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        }
        return nil
    }

    func preview(_ id: String) async throws -> ExpertBriefPreview {
        guard let expert = experts[id] else { throw ExpertError.unknown }
        let text = await brief(for: expert, prove: false)
        return ExpertBriefPreview(text: text, tokens: ExpertBrief.tokens(text))
    }

    private func brief(for expert: Expert, prove: Bool) async -> String {
        let bench = prove ? await proveBench(expert.id) ?? [] : benchCache[expert.id] ?? expert.bench
        let book = notebook(for: expert)
        return ExpertBrief.text(
            ExpertBrief.Inputs(
                expert: expert, notebookPath: book.folder.path, notes: book.notes(now: now()),
                journal: readJournal(expert.id), bench: bench, guards: servedGuards(expert),
                timeZone: TimeZone(identifier: expert.timeZone) ?? .current))
    }

    private func writeBrief(_ text: String, expert: String, session: String) {
        guard experts[expert] != nil else { return }
        let directory = folder(expert).appendingPathComponent("briefs")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(session).md")
        try? Data(text.utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: Bench

    @discardableResult
    func proveBench(_ id: String) async -> [BenchItem]? {
        guard let expert = experts[id] else { return nil }
        let generation = benchGeneration[id] ?? 0
        let store = self.store
        let proven = await BenchProver.prove(expert.bench, now: now()) { pids in
            await store.sessionHolding(pids: pids)
        }
        guard experts[id] != nil else { return nil }
        guard (benchGeneration[id] ?? 0) == generation else { return await proveBench(id) }
        let changedState = benchCache[id].map { old in
            zip(old, proven).contains { $0.state != $1.state || $0.holder != $1.holder } || old.count != proven.count
        } ?? true
        benchCache[id] = proven
        if changedState { changed() }
        return proven
    }

    // MARK: Debriefs

    func debriefRecord(_ sessionID: String) -> Debrief? { readDebrief(sessionID) }

    /// Finishes a task: asks a fork of it, never saved, for the journal entry and the notebook
    /// changes it proposes. The journal entry is kept as written; the proposals wait.
    func debrief(_ sessionID: String, wait: Bool = true) async throws -> Debrief {
        guard let task = await store.expertTask(sessionID), let expert = experts[task.expertID] else {
            throw ExpertError.unknownSession
        }
        if drafting.contains(sessionID), let existing = readDebrief(sessionID) {
            return existing
        }
        guard let claudeID = task.claudeSessionID else {
            throw ExpertError.invalid("This task has not started yet, so there is nothing to debrief.")
        }
        guard !task.active else {
            throw ExpertError.busy("The task is still running. It can be finished once its turn ends.")
        }
        let previous = readDebrief(sessionID)
        if let previous, previous.state != "failed", previous.state != "drafting",
            previous.coveredTurns >= task.userTurns
        {
            return previous
        }
        let carried = previous?.state == "open" ? previous?.proposals.filter { $0.state == "pending" } ?? [] : []
        drafting.insert(sessionID)
        let record = Debrief(
            sessionID: sessionID, expertID: expert.id, at: now(), coveredTurns: task.userTurns, state: "drafting",
            failure: nil, journal: previous?.journal, proposals: carried)
        writeDebrief(record)
        changed()
        guard wait else {
            Task { await self.draftDebrief(record, carried: carried, previous: previous, task: task, claudeID: claudeID, expert: expert) }
            return record
        }
        return await draftDebrief(record, carried: carried, previous: previous, task: task, claudeID: claudeID, expert: expert)
    }

    /// Asks for the debrief and writes it. Proposals an earlier debrief of the same task still had
    /// waiting are carried into this one, after the new ones and without repeating a title, so a
    /// task that went on never loses what the person had not yet decided; if the new debrief
    /// cannot be written, the earlier one stands as it was.
    private func draftDebrief(
        _ started: Debrief, carried: [Proposal], previous: Debrief?, task: ExpertTaskInfo, claudeID: String,
        expert: Expert
    ) async -> Debrief {
        var record = started
        let sessionID = started.sessionID
        let book = notebook(for: expert)
        let request = ExpertAsk.Request(
            directory: task.directory ?? FileManager.default.homeDirectoryForCurrentUser.path, resume: claudeID,
            model: task.model.nilIfEmpty ?? expert.model ?? "opus",
            prompt: Self.debriefPrompt(expert: expert, notes: book.notes(now: now())), schema: Self.debriefSchema)
        var answer = await ask(request)
        if answer.answer == nil { answer = await ask(request) }
        drafting.remove(sessionID)
        guard let object = answer.answer else {
            if let previous, !carried.isEmpty {
                var kept = previous
                kept.failure = answer.failure ?? "The debrief could not be read."
                writeDebrief(kept)
                changed()
                return kept
            }
            record.state = "failed"
            record.proposals = []
            record.failure = answer.failure ?? "The debrief could not be read."
            writeDebrief(record)
            changed()
            return record
        }
        let parsed = Self.readDebrief(
            object, sessionID: sessionID, at: now(), notes: Set(book.notes().map(\.id)),
            fallbackTitle: task.title.nilIfEmpty ?? "Task")
        let fresh = Set(parsed.proposals.map { $0.title.lowercased() })
        record.journal = parsed.journal ?? previous?.journal
        record.proposals = parsed.proposals + carried.filter { !fresh.contains($0.title.lowercased()) }
        record.state = record.proposals.isEmpty ? "settled" : "open"
        record.at = now()
        if let entry = parsed.journal { keepJournal(entry, expert: expert.id) }
        writeDebrief(record)
        changed()
        return record
    }

    /// Writes what the person accepted, drops what they skipped, and closes the debrief.
    func decide(_ sessionID: String, _ decision: DebriefDecision) throws -> Debrief {
        guard var record = readDebrief(sessionID), let expert = experts[record.expertID] else {
            throw ExpertError.unknownSession
        }
        guard record.state == "open" else { throw ExpertError.invalid("This debrief has nothing waiting.") }
        let book = notebook(for: expert)
        let accepted = Set(decision.accepted)
        let skipped = Set(decision.skipped ?? [])
        let source = "tailscode-expert:\(expert.id):\(sessionID)"
        var failures: [String] = []
        for index in record.proposals.indices where record.proposals[index].state == "pending" {
            var proposal = record.proposals[index]
            if let edit = decision.edits?[proposal.id] {
                if let title = edit.title?.nilIfEmpty { proposal.title = title }
                if let summary = edit.summary?.nilIfEmpty { proposal.summary = summary }
                if let body = edit.body?.nilIfEmpty { proposal.body = body }
            }
            if accepted.contains(proposal.id) {
                do {
                    switch proposal.op {
                    case "add":
                        try book.add(
                            title: proposal.title, summary: proposal.summary, body: proposal.body, type: nil,
                            source: source, now: now())
                    case "change":
                        try book.change(
                            proposal.note ?? "", title: proposal.title, summary: proposal.summary, body: proposal.body,
                            source: source, now: now())
                    case "retire":
                        try book.retire(proposal.note ?? "", reason: proposal.reason, now: now())
                    default:
                        break
                    }
                    proposal.state = "accepted"
                } catch {
                    failures.append(String(describing: error))
                    continue
                }
            } else if skipped.contains(proposal.id) || decision.skipped == nil {
                proposal.state = "skipped"
            }
            record.proposals[index] = proposal
        }
        if !record.proposals.contains(where: { $0.state == "pending" }) { record.state = "settled" }
        record.failure = failures.isEmpty ? nil : failures.joined(separator: " ")
        writeDebrief(record)
        changed()
        return record
    }

    private func unfinishedTasks(_ expertID: String) async -> [ExpertTaskInfo] {
        await store.expertTasks(expertID).filter { task in
            guard !task.active, task.claudeSessionID != nil, task.userTurns > 0 else { return false }
            guard let record = readDebrief(task.sessionID) else { return true }
            if record.state == "drafting" { return !drafting.contains(task.sessionID) }
            return record.coveredTurns < task.userTurns
        }
    }

    static let debriefSchema = #"""
        {"type":"object","properties":{"journal":{"type":"object","properties":{"title":{"type":"string"},"outcome":{"type":"string"},"measured":{"type":"array","items":{"type":"string"}},"commits":{"type":"array","items":{"type":"string"}}},"required":["title","outcome","measured","commits"]},"proposals":{"type":"array","items":{"type":"object","properties":{"op":{"type":"string","enum":["add","change","retire"]},"note":{"type":"string"},"title":{"type":"string"},"summary":{"type":"string"},"body":{"type":"string"},"reason":{"type":"string"}},"required":["op","note","title","summary","body","reason"]}}},"required":["journal","proposals"]}
        """#

    static func debriefPrompt(expert: Expert, notes: [Note]) -> String {
        var index = notes.map { "- \($0.id): \($0.title) — \($0.summary)" }.joined(separator: "\n")
        if index.isEmpty { index = "(the notebook is empty)" }
        return """
            The task in this conversation is finished. You are the expert "\(expert.name)". Write its \
            debrief: a journal entry, and the changes you propose to your notebook. Answer only with the \
            JSON the schema asks for; do not edit any file.

            Journal entry:
            - title: what the task was, in at most six words.
            - outcome: one or two sentences on what changed and for whom, as a result, not a list of steps.
            - measured: the numbers this task actually measured, each with its unit and what it was \
            measured on ("Home first frame 2.5 s on the iPad Pro"); empty when nothing was measured.
            - commits: each commit this task made, as "<short hash> <subject>"; empty when there were none.

            Notebook proposals, at most five, only for facts that will still be true and useful in a \
            later task — never what happened today, never something that held only during this task (a \
            busy port, a device that was unplugged, a temporary state):
            - op "add" for a new fact; "change" when an existing note is now wrong or incomplete; \
            "retire" when an existing note is no longer true.
            - note: the existing note's file name for change and retire, from the index below; empty for add.
            - title: a few words. summary: one line. body: the fact, then a "**Why:**" line and a \
            "**How to apply:**" line. For retire, repeat the note's title and leave body empty.
            - reason: why this change, citing what this task showed.
            Return no proposals when nothing is worth keeping. Do not propose a fact the notebook already holds.

            Notebook index:
            \(index)
            """
    }

    static func readDebrief(
        _ object: [String: Any], sessionID: String, at: Date, notes: Set<String>, fallbackTitle: String = "Task"
    ) -> (journal: JournalEntry?, proposals: [Proposal]) {
        var journal: JournalEntry?
        if let entry = object["journal"] as? [String: Any] {
            let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallbackTitle
            journal = JournalEntry(
                id: UUID().uuidString, sessionID: sessionID, title: String(title.prefix(80)), at: at,
                outcome: String(((entry["outcome"] as? String) ?? "").prefix(600)),
                measured: ((entry["measured"] as? [String]) ?? []).prefix(12).map { String($0.prefix(200)) },
                commits: ((entry["commits"] as? [String]) ?? []).prefix(20).map { String($0.prefix(160)) })
        }
        var proposals: [Proposal] = []
        for raw in (object["proposals"] as? [[String: Any]] ?? []).prefix(8) {
            guard let op = raw["op"] as? String, ["add", "change", "retire"].contains(op),
                let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            else { continue }
            var note = (raw["note"] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            if let named = note, !named.hasSuffix(".md") { note = "\(named).md" }
            if op != "add" {
                guard let note, notes.contains(note) else { continue }
            } else {
                note = nil
            }
            proposals.append(
                Proposal(
                    id: UUID().uuidString, op: op, note: note, title: String(title.prefix(120)),
                    summary: String(((raw["summary"] as? String) ?? "").prefix(300)),
                    body: String(((raw["body"] as? String) ?? "").prefix(4_000)),
                    reason: String(((raw["reason"] as? String) ?? "").prefix(600)), state: "pending"))
        }
        return (journal, proposals)
    }

    // MARK: Drafts

    /// A draft expert to review: from a conversation (asked of a fork of it that is never saved)
    /// or from a skill on this machine. Nothing is saved.
    func draft(_ request: ExpertDraftRequest) async throws -> ExpertDraft {
        if let sessionID = request.session?.nilIfEmpty {
            guard let info = await store.draftSource(sessionID), let claudeID = info.claudeSessionID else {
                throw ExpertError.invalid("That conversation has nothing to draft an expert from yet.")
            }
            let answer = await ask(
                ExpertAsk.Request(
                    directory: info.directory ?? FileManager.default.homeDirectoryForCurrentUser.path, resume: claudeID,
                    model: info.model.nilIfEmpty ?? "opus", prompt: Self.draftPrompt(skill: nil), schema: Self.draftSchema))
            guard let object = answer.answer else {
                throw ExpertError.invalid(answer.failure ?? "The draft could not be read.")
            }
            var draft = Self.readDraft(object)
            draft.directory = info.directory
            draft.model = info.model.nilIfEmpty
            return draft
        }
        guard let name = request.skill?.nilIfEmpty, let skill = skills().first(where: { $0.name == name }) else {
            throw ExpertError.invalid("There is no such skill on this machine.")
        }
        let body = (try? String(contentsOfFile: skill.path, encoding: .utf8)) ?? skill.description
        let answer = await ask(
            ExpertAsk.Request(
                directory: FileManager.default.homeDirectoryForCurrentUser.path, resume: nil, model: "sonnet",
                prompt: Self.draftPrompt(skill: String(body.prefix(40_000))), schema: Self.draftSchema))
        var draft: ExpertDraft
        if let object = answer.answer {
            draft = Self.readDraft(object)
        } else {
            draft = ExpertDraft(
                name: Notebook.title(fromSlug: skill.name), purpose: skill.description,
                charter: "Load the \(skill.name) skill first and follow it.")
        }
        var skills = draft.skills ?? []
        if !skills.contains(skill.name) { skills.insert(skill.name, at: 0) }
        draft.skills = skills
        return draft
    }

    static let draftSchema = #"""
        {"type":"object","properties":{"name":{"type":"string"},"glyph":{"type":"string"},"purpose":{"type":"string"},"charter":{"type":"string"},"skills":{"type":"array","items":{"type":"string"}},"notes":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"summary":{"type":"string"},"body":{"type":"string"},"lasting":{"type":"boolean"}},"required":["title","summary","body","lasting"]}},"bench":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"kind":{"type":"string","enum":["appleDevice","command","port"]},"identifier":{"type":"string"},"command":{"type":"string"},"lock":{"type":"string"}},"required":["name","kind","identifier","command","lock"]}}},"required":["name","glyph","purpose","charter","skills","notes","bench"]}
        """#

    static func draftPrompt(skill: String?) -> String {
        let source =
            skill.map { "the skill below, which the expert will load first:\n\n\($0)\n\n" }
            ?? "this conversation. "
        return """
            Draft a Tailscode expert from \(source)An expert is a standing role on this machine: every task \
            it is given starts a fresh conversation with its charter, its skills, its notebook and its bench. \
            Answer only with the JSON the schema asks for; do not edit any file.
            - name: one or two words for the kind of work. glyph: two letters for its mark.
            - purpose: one sentence on what the expert is for.
            - charter: at most 300 words of standing instructions for this kind of work — a map, not a \
            manual: what good looks like, how work is verified, what never to do. No facts that belong in notes.
            - skills: the names of the skills this work loads.
            - notes: at most eight facts this work rests on, each with title, summary (one line), body (the \
            fact, then a "**Why:**" line and a "**How to apply:**" line), and lasting: false for a fact that \
            held only that day (a busy port, a device that happened to be unplugged), true otherwise.
            - bench: the devices and services the work used: kind appleDevice with its UDID or device \
            identifier when one was used, command with a shell command that exits 0 when the thing is \
            there, or port; lock: the lock file the work held around it, or empty; empty strings for \
            anything unknown.
            """
    }

    static func readDraft(_ object: [String: Any]) -> ExpertDraft {
        let name = ((object["name"] as? String)?.nilIfEmpty ?? "Expert").prefix(40)
        let notes = (object["notes"] as? [[String: Any]] ?? []).prefix(8).compactMap { raw -> DraftNote? in
            guard let title = (raw["title"] as? String)?.nilIfEmpty else { return nil }
            return DraftNote(
                title: String(title.prefix(120)), summary: String(((raw["summary"] as? String) ?? "").prefix(300)),
                body: String(((raw["body"] as? String) ?? "").prefix(4_000)), type: nil,
                lasting: raw["lasting"] as? Bool ?? true)
        }
        let bench = (object["bench"] as? [[String: Any]] ?? []).prefix(BenchLimit.items).compactMap { raw -> BenchItem? in
            guard let name = (raw["name"] as? String)?.nilIfEmpty, let kind = raw["kind"] as? String,
                BenchItem.kinds.contains(kind)
            else { return nil }
            let command = (raw["command"] as? String)?.nilIfEmpty
            if kind == "command", command == nil { return nil }
            if kind == "port" { return nil }
            return BenchItem(
                id: UUID().uuidString, name: String(name.prefix(60)), kind: kind,
                identifier: (raw["identifier"] as? String)?.nilIfEmpty, command: command, host: nil, port: nil,
                lock: (raw["lock"] as? String)?.nilIfEmpty)
        }
        return ExpertDraft(
            name: String(name), glyph: (object["glyph"] as? String).map { String($0.prefix(2)) },
            purpose: (object["purpose"] as? String).map { String($0.prefix(300)) },
            charter: (object["charter"] as? String).map { String($0.prefix(charterLimit)) },
            skills: ((object["skills"] as? [String]) ?? []).filter { !$0.isEmpty }.prefix(skillLimit).map { $0 },
            bench: Array(bench), notes: Array(notes))
    }

    private enum BenchLimit { static let items = 20 }

    // MARK: Skills

    /// The skills Claude Code loads on this machine, from the person's own folder.
    nonisolated func skills() -> [SkillInfo] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent(".claude/skills")
        var found: [SkillInfo] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
            let file = folder.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let parsed = FrontMatter(text)
            found.append(
                SkillInfo(
                    name: parsed.value("name") ?? name,
                    description: String((parsed.value("description") ?? "").prefix(400)), path: file.path))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Guards

    func start() {
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.tickGuards()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func nextGuardRun(_ expert: Expert) -> Date? {
        guard let rule = expert.guardRule, !expert.guards.isEmpty else { return nil }
        let after = guardRuns[expert.id]?.lastScheduled ?? expert.updatedAt
        return rule.next(after: after, calendar: Scheduler.calendar(TimeZone(identifier: expert.timeZone) ?? .current))
    }

    func tickGuards() async {
        let moment = now()
        for expert in experts.values {
            guard let due = nextGuardRun(expert), due <= moment else { continue }
            guardRuns[expert.id, default: GuardBook(lastScheduled: nil, runs: [:])].lastScheduled = moment
            saveGuards(expert.id)
            if moment.timeIntervalSince(due) <= Self.guardCatchUp {
                runGuards(expert.id, only: nil)
            }
        }
    }

    /// Runs the expert's guards (or one of them) one after another, away from the caller; a guard
    /// already running is not started twice.
    @discardableResult
    func runGuards(_ id: String, only: String?) -> Bool {
        guard let expert = experts[id] else { return false }
        let chosen = expert.guards.filter { only == nil || $0.id == only }
        let idle = chosen.filter { !(runningGuards[id]?.contains($0.id) ?? false) }
        guard !idle.isEmpty else { return false }
        runningGuards[id, default: []].formUnion(idle.map(\.id))
        changed()
        Task {
            for item in idle {
                let run = await GuardRunner.run(item, fallbackDirectory: expert.directory)
                await self.record(run, guard: item, expert: id)
            }
        }
        return true
    }

    private func record(_ run: GuardRun, guard item: GuardItem, expert id: String) async {
        runningGuards[id]?.remove(item.id)
        guard let expert = experts[id] else { return }
        var book = guardRuns[id] ?? GuardBook(lastScheduled: nil, runs: [:])
        let previous = book.runs[item.id]?.first
        var runs = book.runs[item.id] ?? []
        runs.insert(run, at: 0)
        book.runs[item.id] = Array(runs.prefix(Self.guardHistory))
        guardRuns[id] = book
        saveGuards(id)
        changed()
        if !run.passed, previous?.passed ?? true, let flip = onGuardFlip {
            await flip(expert, item, run)
        }
    }

    // MARK: Files

    private func folder(_ id: String) -> URL { root.appendingPathComponent(id) }

    private func save(_ expert: Expert) throws {
        let directory = folder(expert.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("expert.json")
        try AgentJSON.encoder.encode(expert).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func saveGuards(_ id: String) {
        guard let book = guardRuns[id], let data = try? AgentJSON.encoder.encode(book) else { return }
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try? data.write(to: folder(id).appendingPathComponent("guards.json"), options: .atomic)
    }

    private func readJournal(_ id: String) -> [JournalEntry] {
        guard let text = try? String(contentsOf: folder(id).appendingPathComponent("journal.jsonl"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap {
            try? AgentJSON.decoder.decode(JournalEntry.self, from: Data($0.utf8))
        }.sorted { $0.at > $1.at }
    }

    /// Writes a task's journal entry in place of any earlier one for the same task. Lines are kept
    /// as they were written, so one this build cannot read — a newer bridge's, or one edited by
    /// hand — survives instead of being dropped by the rewrite.
    private func keepJournal(_ entry: JournalEntry, expert id: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(entry) else { return }
        let url = folder(id).appendingPathComponent("journal.jsonl")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { line in
            guard let decoded = try? AgentJSON.decoder.decode(JournalEntry.self, from: Data(line.utf8)) else { return true }
            return decoded.sessionID == nil || decoded.sessionID != entry.sessionID
        }
        lines.append(String(decoding: encoded, as: UTF8.self))
        let readable = lines.indices.filter {
            (try? AgentJSON.decoder.decode(JournalEntry.self, from: Data(lines[$0].utf8))) != nil
        }
        if readable.count > Self.journalKept {
            let dropped = Set(readable.prefix(readable.count - Self.journalKept))
            lines = lines.indices.filter { !dropped.contains($0) }.map { lines[$0] }
        }
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }

    private func debriefURL(_ sessionID: String, expert: String) -> URL {
        folder(expert).appendingPathComponent("debriefs").appendingPathComponent("\(sessionID).json")
    }

    private func readDebrief(_ sessionID: String) -> Debrief? {
        for id in experts.keys {
            if let data = try? Data(contentsOf: debriefURL(sessionID, expert: id)),
                let record = try? AgentJSON.decoder.decode(Debrief.self, from: data)
            {
                return record
            }
        }
        return nil
    }

    private func writeDebrief(_ record: Debrief) {
        let url = debriefURL(record.sessionID, expert: record.expertID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? AgentJSON.encoder.encode(record).write(to: url, options: .atomic)
    }

    private func changed() { onChange?() }

    // MARK: Words a definition carries

    static func glyph(_ given: String?, name: String) -> String {
        if let given = given?.trimmingCharacters(in: .whitespaces), !given.isEmpty { return String(given.prefix(2)) }
        let letters = name.filter { $0.isLetter || $0.isNumber }
        guard let first = letters.first else { return "Ex" }
        let second = letters.dropFirst().first.map { String($0).lowercased() } ?? ""
        return String(first).uppercased() + second
    }

    static func hue(for name: String) -> String {
        let ordered = ["blue", "orange", "green", "purple", "pink", "teal", "indigo", "red", "yellow"]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return ordered[sum % ordered.count]
    }
}
