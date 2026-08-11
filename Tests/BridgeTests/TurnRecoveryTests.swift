import Foundation
import Testing

@testable import claude_bridge

/// A machine that stopped mid-turn, rebuilt on disk: a store, a transcript, and a journal that
/// says a turn was open. Every test here is about what the bridge decides on the way back up.
private struct Wreckage {
    let root: URL
    let storeURL: URL
    let projects: URL
    let claudeBinary: String
    /// Held for the life of the wreckage: the store keeps the index weakly, so an index handed in
    /// as a temporary is deallocated before recovery ever reads a transcript.
    let transcripts: TranscriptIndex

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        storeURL = root.appendingPathComponent("sessions.json")
        projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projects.appendingPathComponent("proj", isDirectory: true),
            withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-claude")
        let body = """
            #!/bin/sh
            /usr/bin/printf '%s\\n' '{"type":"system","subtype":"init","session_id":"resumed"}'
            exit 0
            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        claudeBinary = script.path
        transcripts = TranscriptIndex(
            root: projects,
            defaults: MachineDefaults(
                modelOverride: "sonnet", effortOverride: "medium", home: root.path))
    }

    func store(autoResumeDefault: Bool = false) -> SessionStore {
        SessionStore(
            runner: ClaudeRunner(
                claudePath: claudeBinary, workdir: root.path, permissionMode: "default"),
            defaults: MachineDefaults(modelOverride: "sonnet", effortOverride: "medium", home: root.path),
            storeURL: storeURL, projectsDir: projects.path,
            autoResumeDefault: autoResumeDefault)
    }

    func index() -> TranscriptIndex { transcripts }

    /// A transcript with one prompt and a half-finished answer: two tools out, some prose, and —
    /// unless `closed` — no turn-duration record, which is exactly what a killed turn leaves.
    @discardableResult
    func writeTranscript(id: String, closed: Bool, answer: String = "Editing the flaky test") throws
        -> String
    {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = [
            #"{"type":"user","uuid":"u1","cwd":"/tmp/work","timestamp":"\#(stamp)","message":{"content":"Fix the flaky test"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"\#(stamp)","message":{"model":"claude-opus-5","content":[{"type":"text","text":"\#(answer)"},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/tmp/work/Flaky.swift"}},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"swift test --filter Flaky"}}]}}"#,
        ]
        if closed {
            lines.append(#"{"type":"system","subtype":"turn_duration","uuid":"s1"}"#)
        }
        let file = projects.appendingPathComponent("proj", isDirectory: true)
            .appendingPathComponent("\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    func seedJournal(_ record: TurnRecord) {
        var journal = TurnJournal()
        journal.turns[record.sessionID] = record
        journal.write(to: TurnJournal.url(besides: storeURL))
    }

    func journal() -> TurnJournal {
        TurnJournal.load(from: TurnJournal.url(besides: storeURL))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func record(
    session: String, claudeID: String?, pid: Int32? = nil, startedAt: Date = Date(),
    queued: [QueuedRecord] = []
) -> TurnRecord {
    TurnRecord(
        turnID: "turn-1", sessionID: session, claudeSessionID: claudeID,
        prompt: "Fix the flaky test", displayPrompt: "Fix the flaky test", model: "opus",
        effort: "high", fork: false, directory: "/tmp/work", startedAt: startedAt, pid: pid,
        queued: queued)
}

@Suite("Turn journal")
struct TurnJournalTests {

    @Test("An open turn survives the process that opened it")
    func roundTrip() throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let open = record(
            session: "s1", claudeID: "c1", pid: 4242,
            queued: [QueuedRecord(prompt: "and then deploy", displayPrompt: "and then deploy")])
        wreck.seedJournal(open)
        let reloaded = wreck.journal().turns["s1"]
        #expect(reloaded?.turnID == "turn-1")
        #expect(reloaded?.pid == 4242)
        #expect(reloaded?.claudeSessionID == "c1")
        #expect(reloaded?.queued.first?.displayPrompt == "and then deploy")
    }
}

@Suite("Turn verdicts")
struct TurnVerdictTests {

    @Test("A transcript that closed the turn means the turn finished, whoever was watching")
    func closedWins() throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let id = UUID().uuidString
        let path = try wreck.writeTranscript(id: id, closed: true)
        let verdict = TurnRecovery.verdict(
            for: record(session: "s1", claudeID: id, pid: 1),
            transcriptPath: path, bootedAt: Date().addingTimeInterval(-3_600))
        #expect(verdict == .completed)
    }

    @Test("A pid written before the last boot is somebody else's, and is never adopted")
    func pidAcrossReboot() throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let id = UUID().uuidString
        let path = try wreck.writeTranscript(id: id, closed: false)
        let verdict = TurnRecovery.verdict(
            for: record(
                session: "s1", claudeID: id, pid: getpid(),
                startedAt: Date().addingTimeInterval(-7_200)),
            transcriptPath: path, bootedAt: Date().addingTimeInterval(-3_600))
        #expect(verdict == .interrupted)
    }

    @Test("An open transcript with nothing running is an interrupted turn")
    func openAndDead() throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let id = UUID().uuidString
        let path = try wreck.writeTranscript(id: id, closed: false)
        let verdict = TurnRecovery.verdict(
            for: record(session: "s1", claudeID: id, pid: nil),
            transcriptPath: path, bootedAt: Date().addingTimeInterval(-60))
        #expect(verdict == .interrupted)
    }

    @Test("Boot time it cannot read is a pid it will not trust")
    func noBootTimeNoTrust() {
        #expect(
            !TurnRecovery.trustsPID(
                record: record(session: "s1", claudeID: "c1", pid: 9), bootedAt: nil))
    }
}

@Suite("What the interrupted turn had done")
struct InterruptionProgressTests {

    @Test("The tools, the files and the commands come off the transcript, not off the prose")
    func readsProgress() throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let id = UUID().uuidString
        let path = try wreck.writeTranscript(id: id, closed: false)
        let progress = TurnRecovery.progress(transcriptPath: path, since: Date().addingTimeInterval(-60))
        #expect(progress.toolCount == 2)
        #expect(progress.lastTool == "Bash")
        #expect(progress.filesTouched == ["/tmp/work/Flaky.swift"])
        #expect(progress.commands == ["swift test --filter Flaky"])
        #expect(progress.partialAnswer == "Editing the flaky test")
        #expect(!progress.isEmpty)
    }

    @Test("No transcript is no evidence, not invented evidence")
    func emptyWithoutTranscript() {
        let progress = TurnRecovery.progress(transcriptPath: nil, since: Date())
        #expect(progress.isEmpty)
    }
}

@Suite("Resume briefing")
struct ResumeBriefTests {

    private func interruption(progress: InterruptionProgress, queued: [String] = []) -> Interruption {
        Interruption(
            turnID: "turn-1", prompt: "Fix the flaky test",
            startedAt: Date().addingTimeInterval(-600), detectedAt: Date(),
            claudeSessionID: "c1", progress: progress, queued: queued, resumedAt: nil)
    }

    @Test("It quotes the prompt, lists what landed, and forbids starting over")
    func statesEverything() {
        var progress = InterruptionProgress()
        progress.toolCount = 2
        progress.lastTool = "Bash"
        progress.filesTouched = ["/tmp/work/Flaky.swift"]
        progress.commands = ["swift test"]
        progress.partialAnswer = "Editing the flaky test"
        let brief = ResumeBrief.compose(interruption(progress: progress))
        #expect(brief.contains("Fix the flaky test"))
        #expect(brief.contains("/tmp/work/Flaky.swift"))
        #expect(brief.contains("swift test"))
        #expect(brief.contains("2 tool calls"))
        #expect(brief.contains("Do not start the whole task again"))
        #expect(brief.contains("10 minutes"))
    }

    @Test("Nothing recorded says so rather than implying work that never happened")
    func emptyProgressIsHonest() {
        let brief = ResumeBrief.compose(interruption(progress: InterruptionProgress()))
        #expect(brief.contains("had most likely not started"))
        #expect(!brief.contains("tool calls"))
    }

    @Test("Prompts that were queued behind the turn are carried, not lost")
    func carriesQueue() {
        let brief = ResumeBrief.compose(
            interruption(progress: InterruptionProgress(), queued: ["then deploy it"]))
        #expect(brief.contains("then deploy it"))
        #expect(brief.contains("never ran"))
    }
}

@Suite("Recovery on the way back up")
struct RecoveryTests {

    @Test("A turn nothing finished becomes an interruption the session can explain")
    func marksInterrupted() async throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let first = wreck.store()
        let session = await first.create(CreateRequest(title: "Flaky", directory: nil))
        let transcriptID = UUID().uuidString
        try wreck.writeTranscript(id: transcriptID, closed: false)
        wreck.seedJournal(
            record(
                session: session.id, claudeID: transcriptID,
                startedAt: Date().addingTimeInterval(-900),
                queued: [QueuedRecord(prompt: "then deploy", displayPrompt: "then deploy")]))

        let store = wreck.store()
        await store.attach(index: wreck.index())
        await store.recoverJournaledTurns()

        let recovered = await store.get(session.id)
        let interruption = try #require(recovered?.interruption)
        #expect(interruption.prompt == "Fix the flaky test")
        #expect(interruption.progress.toolCount == 2)
        #expect(interruption.queued == ["then deploy"])
        #expect(!interruption.isResumed)
        #expect(wreck.journal().turns.isEmpty)

        let listed = await store.list()
        #expect(listed.first { $0.id == session.id }?.interrupted == true)
    }

    @Test("A turn the transcript closed is taken back out of it rather than mourned")
    func settlesCompleted() async throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let first = wreck.store()
        let session = await first.create(CreateRequest(title: "Flaky", directory: nil))
        let transcriptID = UUID().uuidString
        try wreck.writeTranscript(id: transcriptID, closed: true, answer: "Fixed the ordering bug")
        wreck.seedJournal(record(session: session.id, claudeID: transcriptID))

        let store = wreck.store()
        await store.attach(index: wreck.index())
        await store.recoverJournaledTurns()

        let recovered = try #require(await store.get(session.id))
        #expect(recovered.interruption == nil)
        let answer = recovered.messages.last { $0.role == .assistant }
        let text = answer?.parts.compactMap { part -> String? in
            if case .text(let value) = part { return value }
            return nil
        }.joined()
        #expect(text?.contains("Fixed the ordering bug") == true)
        #expect(wreck.journal().turns.isEmpty)
    }

    @Test("A session the journal names but the store lost leaves nothing behind")
    func forgetsOrphanRecords() async throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        _ = wreck.store()
        wreck.seedJournal(record(session: "gone", claudeID: nil))
        let store = wreck.store()
        await store.attach(index: wreck.index())
        await store.recoverJournaledTurns()
        #expect(wreck.journal().turns.isEmpty)
        #expect(await store.get("gone") == nil)
    }
}

@Suite("Picking it back up")
struct ResumeTests {

    private func interrupted(_ wreck: Wreckage) async throws -> (SessionStore, String) {
        let first = wreck.store()
        let session = await first.create(CreateRequest(title: "Flaky", directory: nil))
        let transcriptID = UUID().uuidString
        try wreck.writeTranscript(id: transcriptID, closed: false)
        wreck.seedJournal(record(session: session.id, claudeID: transcriptID))
        let store = wreck.store()
        await store.attach(index: wreck.index())
        await store.recoverJournaledTurns()
        return (store, session.id)
    }

    @Test("The transcript gets one line, because nobody typed the briefing")
    func displayIsNotTheBrief() async throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let (store, id) = try await interrupted(wreck)
        #expect(await store.resumeInterrupted(id) == .started)
        let session = try #require(await store.get(id))
        let last = try #require(session.messages.last { $0.role == .user })
        let text = last.parts.compactMap { part -> String? in
            if case .text(let value) = part { return value }
            return nil
        }.joined()
        #expect(text == SessionStore.resumeDisplayText)
        #expect(!text.contains("Do not start"))
        #expect(session.interruption?.isResumed == true)
    }

    @Test("It is only picked up once")
    func resumeIsIdempotent() async throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let (store, id) = try await interrupted(wreck)
        #expect(await store.resumeInterrupted(id) == .started)
        #expect(await store.resumeInterrupted(id) == .noInterruption)
    }

    @Test("Nothing to pick up says so instead of sending an empty briefing")
    func nothingToResume() async throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let store = wreck.store()
        let session = await store.create(CreateRequest(title: "Clean", directory: nil))
        #expect(await store.resumeInterrupted(session.id) == .noInterruption)
        #expect(await store.resumeInterrupted("nope") == .unknownSession)
    }

    @Test("Letting it go clears the record without continuing the work")
    func dismiss() async throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let (store, id) = try await interrupted(wreck)
        #expect(await store.dismissInterruption(id))
        #expect(await store.interruption(id) == nil)
        #expect(await store.resumeInterrupted(id) == .noInterruption)
    }

    @Test("A session told to continue on its own does, without being asked")
    func autoResume() async throws {
        let wreck = try Wreckage()
        defer { wreck.cleanup() }
        let first = wreck.store()
        let session = await first.create(CreateRequest(title: "Flaky", directory: nil))
        let transcriptID = UUID().uuidString
        try wreck.writeTranscript(id: transcriptID, closed: false)
        wreck.seedJournal(record(session: session.id, claudeID: transcriptID))
        let store = wreck.store(autoResumeDefault: true)
        await store.attach(index: wreck.index())
        await store.recoverJournaledTurns()
        let recovered = try #require(await store.get(session.id))
        #expect(recovered.interruption?.isResumed == true)
        #expect(recovered.messages.contains { message in
            message.role == .user
                && message.parts.contains { part in
                    if case .text(let value) = part { return value == SessionStore.resumeDisplayText }
                    return false
                }
        })
    }
}
