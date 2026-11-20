import Foundation
import Testing

@testable import claude_bridge

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("expert-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let day: TimeInterval = 24 * 3_600
private let november = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!

@Suite("Notebook")
struct NotebookTests {
    @Test("An adopted memory folder reads its titles from the index and its dates from the front matter")
    func readsAMemoryFolder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
            ---
            name: ipad-test-devices
            description: "iPad Pro sideways, mini upright: the bench"
            metadata:
              node_type: memory
              type: user
              modified: 2026-11-19T09:00:00.000Z
            ---

            The devices.
            """.write(to: root.appendingPathComponent("ipad-test-devices.md"), atomically: true, encoding: .utf8)
        try """
            ---
            name: old-fact
            description: Something from September
            metadata:
              type: project
              written: 2026-09-01
            ---

            Old.
            """.write(to: root.appendingPathComponent("old-fact.md"), atomically: true, encoding: .utf8)
        try "- [The test devices](ipad-test-devices.md) — the bench\n".write(
            to: root.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        let book = Notebook(folder: root, adopted: true)
        let notes = book.notes(now: november)
        #expect(notes.map(\.id) == ["ipad-test-devices.md", "old-fact.md"])
        #expect(notes[0].title == "The test devices")
        #expect(notes[0].summary == "iPad Pro sideways, mini upright: the bench")
        #expect(notes[0].type == "user")
        #expect(!notes[0].stale)
        #expect(notes[1].title == "Old fact")
        #expect(notes[1].stale)
        let facts = book.facts(now: november)
        #expect(facts.notes == 2 && facts.stale == 1 && facts.retired == 0 && facts.adopted)
    }

    @Test("Adding, changing and retiring keep the index in step and never delete a fact")
    func writesAndRetires() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Notebook(folder: root.appendingPathComponent("notebook"), adopted: false)
        let name = try book.add(
            title: "Open things the platform's way", summary: "Push or zoom: never a side column",
            body: "Fact.\n**Why:** it is native.", type: "feedback", source: "tailscode-expert:x:s1", now: november)
        #expect(name == "open-things-the-platform-s-way.md")
        let again = try book.add(
            title: "Open things the platform's way", summary: "Duplicate title", body: "B", type: nil,
            source: "s", now: november)
        #expect(again == "open-things-the-platform-s-way-2.md")
        var index = try String(contentsOf: book.folder.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(index.contains("- [Open things the platform's way](open-things-the-platform-s-way.md) — Push or zoom: never a side column"))

        try book.change(
            name, title: "Open things natively", summary: "Changed summary", body: "New body", source: "s2",
            now: november.addingTimeInterval(day))
        let changed = try #require(book.note(name, now: november))
        #expect(changed.title == "Open things natively")
        #expect(changed.summary == "Changed summary")
        #expect(changed.body == "New body")
        #expect(changed.type == "feedback")
        #expect(changed.confirmed != nil)

        try book.retire(again, reason: "Replaced by the zoom", now: november)
        index = try String(contentsOf: book.folder.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(!index.contains(again))
        #expect(book.notes(now: november).map(\.id) == [name])
        let retired = book.retired(now: november)
        #expect(retired.map(\.id) == [again])
        #expect(retired[0].retired?.reason == "Replaced by the zoom")
        #expect(book.note(again)?.retired != nil)
    }

    @Test("A title with brackets keeps its index line readable, and a file without front matter is no note")
    func bracketsAndPlainFiles() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Notebook(folder: root, adopted: true)
        try "# Project instructions\n\nKeep this.".write(
            to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let name = try book.add(
            title: "Flaccy [iOS 27] layout", summary: "s", body: "b", type: nil, source: "s", now: november)
        #expect(book.indexTitles()[name] == "Flaccy [iOS 27] layout")
        try book.change(name, title: "Flaccy [iOS 27] layouts", summary: "t", body: "c", source: "s", now: november)
        let index = try String(contentsOf: root.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(index.components(separatedBy: name).count == 2)
        #expect(book.notes(now: november).map(\.id) == [name])
        #expect(throws: ExpertError.self) {
            try book.change("CLAUDE.md", title: "x", summary: "y", body: "z", source: "s", now: november)
        }
        #expect(try String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8).contains("Keep this."))
    }

    @Test("Rewriting a folded description leaves no old continuation lines behind")
    func foldedDescription() {
        var parsed = FrontMatter("---\nname: n\ndescription: >-\n  first line\n  second line\nmetadata:\n  type: user\n  note: >\n    folded\n  modified: x\n---\n\nbody")
        parsed.set("description", FrontMatter.quoted("new"))
        parsed.setMetadata("note", "plain")
        #expect(parsed.rendered.contains("description: \"new\"\nmetadata:"))
        #expect(!parsed.rendered.contains("first line"))
        #expect(parsed.rendered.contains("  note: plain\n  modified: x"))
        #expect(parsed.value("type") == "user")
    }

    @Test("A note id never reaches outside the notebook")
    func refusesPathsOutside() {
        #expect(Notebook.safeName("../secrets") == nil)
        #expect(Notebook.safeName("a/b.md") == nil)
        #expect(Notebook.safeName(".hidden.md") == nil)
        #expect(Notebook.safeName("MEMORY.md") == nil)
        #expect(Notebook.safeName("fine") == "fine.md")
    }

    @Test("A quoted value survives a round trip through the front matter")
    func quoting() {
        let quoted = FrontMatter.quoted("He said \"no\": twice\nthen \\ left")
        let parsed = FrontMatter("---\ndescription: \(quoted)\n---\n\nbody")
        #expect(parsed.value("description") == "He said \"no\": twice then \\ left")
        #expect(parsed.body == "body")
    }
}

@Suite("Expert brief")
struct ExpertBriefTests {
    private func expert(charter: String = "Measure on the real iPads.") -> Expert {
        Expert(
            id: "e", name: "iPadOS", glyph: "iP", hue: "blue", purpose: "Makes the apps excellent on iPad.",
            directory: nil, model: nil, effort: nil, charter: charter, skills: ["ipados", "ios-dev"],
            notebookPath: nil, bench: [], guards: [], guardRule: nil, timeZone: "UTC", createdAt: november,
            updatedAt: november)
    }

    private func note(_ index: Int, summary: String = String(repeating: "word ", count: 30)) -> Note {
        Note(
            id: "note-\(index).md", title: "Note number \(index)", summary: summary, body: nil, type: nil,
            written: november, confirmed: nil, source: nil, stale: false, retired: nil)
    }

    @Test("A small expert's brief carries everything, the skills and the bench lock included")
    func everything() {
        let bench = [
            BenchItem(
                id: "p", name: "iPad Pro M1", kind: "appleDevice", identifier: "00008103", lock: "/tmp/ipad.lock",
                state: "ready", facts: ["transport": "wired", "osVersion": "27.3"])
        ]
        var failing = GuardItem(id: "g", name: "PadLayoutTests", command: "xcodebuild test")
        failing.last = GuardRun(
            at: november, passed: false, seconds: 41, exitCode: 65, value: nil, output: "2 tests failed",
            failure: "exit")
        let text = ExpertBrief.text(
            ExpertBrief.Inputs(
                expert: expert(), notebookPath: "/notes", notes: [note(1)],
                journal: [
                    JournalEntry(
                        id: "j", sessionID: "s", title: "Unrager posts", at: november, outcome: "Posts zoom.",
                        measured: ["280 tests"], commits: [])
                ], bench: bench, guards: [failing], timeZone: TimeZone(identifier: "UTC")!))
        #expect(text.contains("\"iPadOS\""))
        #expect(text.contains("Load these skills before you start work: ipados, ios-dev."))
        #expect(text.contains("Note number 1 — word"))
        #expect(text.contains("Unrager posts: Posts zoom. Measured: 280 tests."))
        #expect(text.contains("iPad Pro M1 (00008103): available, by cable, OS 27.3"))
        #expect(text.contains("lockf -k -t 3600 /tmp/ipad.lock"))
        #expect(text.contains("Failing since 20 Nov 12:00: PadLayoutTests"))
        #expect(text.contains("2 tests failed"))
    }

    @Test("Guards that never ran are not said to pass, and a probe says what it found")
    func unrunGuards() {
        let text = ExpertBrief.text(
            ExpertBrief.Inputs(
                expert: expert(), notebookPath: "/notes", notes: [], journal: [],
                bench: [BenchItem(id: "p", name: "Probe", kind: "command", command: "echo ok", state: "ready", facts: ["output": "ok"])],
                guards: [GuardItem(id: "g", name: "Never ran", command: "true")], timeZone: TimeZone(identifier: "UTC")!))
        #expect(text.contains("The guard has not run yet."))
        #expect(!text.contains("passed"))
        #expect(text.contains("- Probe: there (ok). Proved by `echo ok`."))
    }

    @Test("A big notebook drops summaries before titles and says how many more there are")
    func budget() {
        let many = (0..<800).map { note($0) }
        let text = ExpertBrief.text(
            ExpertBrief.Inputs(
                expert: expert(), notebookPath: "/notes", notes: many, journal: [], bench: [], guards: [],
                timeZone: TimeZone(identifier: "UTC")!))
        #expect(ExpertBrief.tokens(text) <= ExpertBrief.budgetTokens)
        #expect(!text.contains("Note number 0 — word"))
        #expect(text.contains("- Note number 0 ["))
        #expect(text.contains("more, listed in MEMORY.md."))
        #expect(text.contains("Measure on the real iPads."))
    }
}

@Suite("Expert debrief and draft answers")
struct ExpertAnswerTests {
    @Test("A change or retirement must name a note the notebook holds; an add never names one")
    func proposals() {
        let object: [String: Any] = [
            "journal": [
                "title": "Unrager posts", "outcome": "Posts zoom out of their card.", "measured": ["280 tests"],
                "commits": ["70829b0 feat(ios): open a post"],
            ],
            "proposals": [
                ["op": "add", "note": "ignored.md", "title": "Open natively", "summary": "s", "body": "b", "reason": "r"],
                ["op": "retire", "note": "column", "title": "Column", "summary": "", "body": "", "reason": "gone"],
                ["op": "change", "note": "missing.md", "title": "Nope", "summary": "", "body": "", "reason": ""],
                ["op": "delete", "note": "", "title": "Bad op", "summary": "", "body": "", "reason": ""],
            ],
        ]
        let read = ExpertStore.readDebrief(object, sessionID: "s1", at: november, notes: ["column.md"])
        #expect(read.journal?.title == "Unrager posts")
        #expect(read.journal?.commits == ["70829b0 feat(ios): open a post"])
        #expect(read.proposals.map(\.op) == ["add", "retire"])
        #expect(read.proposals[0].note == nil)
        #expect(read.proposals[1].note == "column.md")
        #expect(read.proposals.allSatisfy { $0.state == "pending" })
    }

    @Test("Claude's JSON answer is read from structured_output, then from the result text")
    func readsAnswers() {
        let structured = #"{"type":"result","is_error":false,"structured_output":{"a":1},"result":"{}"}"#
        #expect(ExpertAsk.read(structured).answer?["a"] as? Int == 1)
        let textOnly = #"{"type":"result","is_error":false,"result":"{\"b\":2}"}"#
        #expect(ExpertAsk.read(textOnly).answer?["b"] as? Int == 2)
        let failed = #"{"type":"result","is_error":true,"result":"Overloaded"}"#
        #expect(ExpertAsk.read(failed).failure == "Overloaded")
        #expect(ExpertAsk.read("not json").answer == nil)
    }

    @Test("A debrief question is a fork that is never saved, with read-only tools and no hooks")
    func askArguments() {
        let arguments = ExpertAsk.arguments(
            ExpertAsk.Request(directory: "/w", resume: "abc", model: "opus", prompt: "P", schema: "{}"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--fork-session"))
        let tools = arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] }
        #expect(tools == "Read,Grep,Glob")
        #expect(arguments.contains(#"{"disableAllHooks":true}"#))
        #expect(arguments.last == "P")
    }

    @Test("A draft keeps lasting notes ticked, drops ports and commands without a probe")
    func draft() {
        let draft = ExpertStore.readDraft([
            "name": "iPadOS", "glyph": "iPad", "purpose": "p", "charter": "c", "skills": ["ipados", ""],
            "notes": [
                ["title": "Devices", "summary": "s", "body": "b", "lasting": true],
                ["title": "Port 8795 is taken", "summary": "s", "body": "b", "lasting": false],
            ],
            "bench": [
                ["name": "iPad Pro", "kind": "appleDevice", "identifier": "0000", "command": "", "lock": "/tmp/l"],
                ["name": "Probe", "kind": "command", "identifier": "", "command": "", "lock": ""],
            ],
        ])
        #expect(draft.glyph == "iP")
        #expect(draft.skills == ["ipados"])
        #expect(draft.notes?.map(\.lasting) == [true, false])
        #expect(draft.bench?.map(\.name) == ["iPad Pro"])
        #expect(draft.bench?.first?.lock == "/tmp/l")
    }
}

@Suite("Guards and bench")
struct ExpertGuardTests {
    private func result(_ output: String, exit: Int32 = 0, timedOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: exit, output: output, seconds: 1.2, timedOut: timedOut, launched: true)
    }

    @Test("A measuring guard passes under its line, fails over it, and says when the number is missing")
    func metric() {
        let item = GuardItem(
            id: "g", name: "Resize", command: "bench",
            metric: GuardMetric(pattern: #"first frame ([0-9.]+) ms"#, atMost: 100, atLeast: nil, unit: "ms"))
        let pass = GuardRunner.verdict(item, result("first frame 140 ms\nfirst frame 83 ms"), at: november)
        #expect(pass.passed && pass.value == 83)
        let fail = GuardRunner.verdict(item, result("first frame 450 ms"), at: november)
        #expect(!fail.passed && fail.failure == "metric" && fail.value == 450)
        let missing = GuardRunner.verdict(item, result("nothing"), at: november)
        #expect(!missing.passed && missing.failure == "missing")
        let exit = GuardRunner.verdict(item, result("boom", exit: 65), at: november)
        #expect(exit.failure == "exit" && exit.output == "boom")
        let timeout = GuardRunner.verdict(item, result("", exit: 15, timedOut: true), at: november)
        #expect(timeout.failure == "timeout")
    }

    @Test("A number that is not finite, or written with a thousands separator, is not a measurement")
    func strangeNumbers() {
        let item = GuardItem(
            id: "g", name: "Throughput", command: "b",
            metric: GuardMetric(pattern: #"value: (\S+) ms"#, atMost: 100, atLeast: nil, unit: "ms"))
        #expect(GuardRunner.verdict(item, result("value: nan ms"), at: november).failure == "missing")
        #expect(GuardRunner.verdict(item, result("value: inf ms"), at: november).failure == "missing")
        let comma = GuardRunner.verdict(item, result("value: 1,234 ms"), at: november)
        #expect(!comma.passed && comma.failure == "missing")
    }

    @Test("A guard whose folder is gone fails saying so instead of running somewhere else")
    func missingFolder() async {
        let run = await GuardRunner.run(
            GuardItem(id: "g", name: "Pwd", command: "pwd", directory: "/no/such/folder"), fallbackDirectory: nil)
        #expect(!run.passed)
        #expect(run.output?.contains("/no/such/folder") == true)
    }

    @Test("A command that leaves a background process holding its output still ends")
    func backgroundHolder() async {
        let started = Date()
        let result = await CommandRunner.shell("(sleep 90 &) ; echo done", directory: nil, timeout: 120)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("done"))
        #expect(Date().timeIntervalSince(started) < 60)
    }

    @Test("A real command runs in the person's shell and its exit decides the guard")
    func shell() async {
        let item = GuardItem(id: "g", name: "Echo", command: "echo hello && exit 3")
        let run = await GuardRunner.run(item, fallbackDirectory: nil)
        #expect(!run.passed)
        #expect(run.exitCode == 3)
        #expect(run.output?.contains("hello") == true)
    }

    @Test("A program runs in its folder with the environment it was given, and its exit code is read")
    func environmentAndFolder() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await CommandRunner.run(
            "/bin/sh", ["-c", "pwd; echo \"$EXPERT_PROBE\"; exit 7"], directory: root.path, timeout: 30,
            environment: ["EXPERT_PROBE": "seen"])
        #expect(result.exitCode == 7)
        #expect(result.output.contains("seen"))
        #expect(result.output.contains(root.lastPathComponent))
        let killed = await CommandRunner.run("/bin/sh", ["-c", "kill -9 $$"], directory: nil, timeout: 30)
        #expect(killed.exitCode == 137)
    }

    @Test("A command past its time is stopped and counted as failed")
    func timeout() async {
        let started = Date()
        let result = await CommandRunner.shell("sleep 120", directory: nil, timeout: 1)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 60)
    }

    @Test("devicectl's listing reads as devices with their state and connection")
    func devicectl() throws {
        let json = #"""
            {"result":{"devices":[
              {"identifier":"CD771E70","hardwareProperties":{"udid":"00008103-0019","marketingName":"iPad Pro (11-inch)","platform":"iOS","reality":"physical"},
               "deviceProperties":{"name":"iPad Pro M1","osVersionNumber":"27.3"},
               "connectionProperties":{"tunnelState":"connected","pairingState":"paired","transportType":"wired"}},
              {"identifier":"D679","hardwareProperties":{"udid":"00008020","marketingName":"iPhone XS","reality":"physical"},
               "deviceProperties":{"name":"Marcus iPhone XS"},
               "connectionProperties":{"tunnelState":"disconnected","pairingState":"paired","transportType":"localNetwork"}},
              {"identifier":"W","hardwareProperties":{"udid":"0000","reality":"physical"},"deviceProperties":{"name":"Watch"},
               "connectionProperties":{"tunnelState":"unavailable","pairingState":"paired"}},
              {"identifier":"SIM","hardwareProperties":{"reality":"virtual"},"deviceProperties":{"name":"Sim"},"connectionProperties":{}}
            ]}}
            """#
        let devices = BenchProver.parseDevicectl(Data(json.utf8))
        #expect(devices.count == 3)
        #expect(devices[0].identifiers.contains("00008103-0019"))
        #expect(devices[0].identifiers.contains("ipad pro m1"))
        #expect(devices[0].state == "ready" && devices[0].transport == "wired")
        #expect(devices[1].state == "ready" && devices[1].transport == "network")
        #expect(devices[2].state == "absent")
    }

    @Test("pymobiledevice3's listing reads as devices on USB")
    func usbmux() {
        let json = #"[{"UniqueDeviceID":"00008160-0008","DeviceName":"iPad Mini","ProductType":"iPad19,1","ConnectionType":"USB","ProductVersion":"27.3"}]"#
        let devices = BenchProver.parseUsbmux(Data(json.utf8))
        #expect(devices.first?.transport == "usb")
        #expect(devices.first?.identifiers.contains("00008160-0008") == true)
    }

    @Test("A command probe proves an item; a lock someone holds marks it held")
    func probesAndLocks() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("device.lock").path
        FileManager.default.createFile(atPath: lock, contents: nil)
        let items = [
            BenchItem(id: "a", name: "Present", kind: "command", command: "echo here"),
            BenchItem(id: "b", name: "Missing", kind: "command", command: "exit 1"),
            BenchItem(id: "c", name: "Locked", kind: "command", command: "true", lock: lock),
        ]
        let holder = FileHandle(forReadingAtPath: lock)
        defer { try? holder?.close() }
        let proven = await BenchProver.prove(items, now: november) { pids in
            BenchHolder(sessionID: "s", title: "A task", pid: pids.first)
        }
        #expect(proven[0].state == "ready" && proven[0].facts?["output"] == "here")
        #expect(proven[1].state == "absent")
        #expect(proven[2].state == "held")
        #expect(proven[2].holder?.title == "A task")
    }

    @Test("A port probe tells a listening port from a closed one")
    func ports() {
        #expect(PortProbe.open(host: "127.0.0.1", port: 1, timeout: 1) == false)
    }
}

@Suite("Expert store")
struct ExpertStoreTests {
    private func makeStore(_ root: URL) -> SessionStore {
        SessionStore(
            runner: ClaudeRunner(claudePath: "/usr/bin/true", workdir: root.path, permissionMode: "default"),
            defaults: MachineDefaults(modelOverride: "sonnet", effortOverride: "medium", home: root.path),
            storeURL: root.appendingPathComponent("sessions.json"), projectsDir: root.path)
    }

    private func task(_ store: SessionStore, expert: String, turns: Int) async -> String {
        let id = UUID().uuidString
        var session = Session(
            id: id, title: "Unrager posts", directory: nil, claudeSessionID: "claude-\(id)", model: "opus",
            effort: "high", createdAt: november, updatedAt: november,
            messages: (0..<turns).map { Message(id: "m\($0)", role: .user, parts: [.text("Do it")], createdAt: november) },
            lastCostUSD: nil, lastTokens: nil, pendingFork: nil)
        session.expertID = expert
        return await store.adopt(session).id
    }

    @Test("Making an expert writes only lasting notes, and its view counts them")
    func create() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let experts = ExpertStore(
            root: root.appendingPathComponent("experts"), store: makeStore(root), claudePath: "/usr/bin/false",
            now: { november })
        let made = try await experts.create(
            ExpertDraft(
                name: "iPadOS", purpose: "Makes the apps excellent on iPad.", charter: "Measure.",
                skills: ["ipados", "ipados", " "],
                notes: [
                    DraftNote(title: "The devices", summary: "s", body: "b", lasting: true),
                    DraftNote(title: "Port 8795 is taken", summary: "s", body: "b", lasting: false),
                ]))
        #expect(made.glyph == "Ip")
        #expect(made.skills == ["ipados"])
        let view = try #require(await experts.get(made.id))
        #expect(view.notebook.notes == 1)
        #expect(!view.notebook.adopted)
        #expect(view.briefTokens > 0)
        #expect(view.pending == 0)
    }

    @Test("A patch refuses a folder that is not there and a pattern that is not a regular expression")
    func validates() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let experts = ExpertStore(
            root: root.appendingPathComponent("experts"), store: makeStore(root), claudePath: "/usr/bin/false")
        let made = try await experts.create(ExpertDraft(name: "Releases"))
        await #expect(throws: ExpertError.self) {
            try await experts.update(made.id, ExpertPatch(directory: "/no/such/folder"))
        }
        await #expect(throws: ExpertError.self) {
            try await experts.update(
                made.id,
                ExpertPatch(guards: [
                    GuardItem(
                        id: "", name: "Bad", command: "true",
                        metric: GuardMetric(pattern: "([", atMost: 1, atLeast: nil, unit: nil))
                ]))
        }
        let adopted = root.appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: adopted, withIntermediateDirectories: true)
        let changed = try await experts.update(made.id, ExpertPatch(notebookPath: adopted.path))
        #expect(changed.notebookPath == adopted.path)
        #expect(await experts.get(made.id)?.notebook.adopted == true)
    }

    @Test("A debrief keeps its journal entry at once, and only accepted proposals reach the notebook")
    func debrief() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = makeStore(root)
        let experts = ExpertStore(
            root: root.appendingPathComponent("experts"), store: sessions, claudePath: "/usr/bin/false",
            now: { november },
            ask: { request in
                #expect(request.resume?.hasPrefix("claude-") == true)
                #expect(request.prompt.contains("The task in this conversation is finished"))
                return (
                    [
                        "journal": ["title": "Unrager posts", "outcome": "Posts zoom.", "measured": [], "commits": []],
                        "proposals": [
                            ["op": "add", "note": "", "title": "Open natively", "summary": "s", "body": "b", "reason": "r"],
                            ["op": "add", "note": "", "title": "Skip me", "summary": "s", "body": "b", "reason": "r"],
                        ],
                    ], nil
                )
            })
        let made = try await experts.create(ExpertDraft(name: "iPadOS"))
        let session = await task(sessions, expert: made.id, turns: 2)
        let record = try await experts.debrief(session)
        #expect(record.state == "open")
        #expect(record.coveredTurns == 2)
        #expect(try await experts.journal(made.id).map(\.title) == ["Unrager posts"])
        #expect(await experts.get(made.id)?.pending == 2)
        let again = try await experts.debrief(session)
        #expect(again.proposals.map(\.id) == record.proposals.map(\.id))

        let settled = try await experts.decide(
            session,
            DebriefDecision(
                accepted: [record.proposals[0].id], skipped: nil,
                edits: [record.proposals[0].id: ProposalEdit(title: "Open things natively", summary: nil, body: nil)]))
        #expect(settled.state == "settled")
        #expect(settled.proposals.map(\.state) == ["accepted", "skipped"])
        let notes = try await experts.notes(made.id, retired: false)
        #expect(notes.map(\.title) == ["Open things natively"])
        #expect(await experts.get(made.id)?.pending == 0)
        await #expect(throws: ExpertError.self) {
            try await experts.decide(session, DebriefDecision(accepted: [], skipped: nil, edits: nil))
        }
    }

    @Test("A debrief a restart cut off is written again, with the task's title when the answer gives none")
    func interruptedAndContinued() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = makeStore(root)
        let asked = FlipCounter()
        let answer: @Sendable (ExpertAsk.Request) async -> (answer: [String: Any]?, failure: String?) = { _ in
            asked.increment()
            return (
                [
                    "journal": ["title": "", "outcome": "Done.", "measured": [], "commits": []],
                    "proposals": [["op": "add", "note": "", "title": "Keep", "summary": "s", "body": "b", "reason": "r"]],
                ], nil
            )
        }
        let experts = ExpertStore(
            root: root.appendingPathComponent("experts"), store: sessions, claudePath: "/usr/bin/false",
            now: { november }, ask: answer)
        let made = try await experts.create(ExpertDraft(name: "iPadOS"))
        let session = await task(sessions, expert: made.id, turns: 2)
        let stale = Debrief(
            sessionID: session, expertID: made.id, at: november, coveredTurns: 2, state: "drafting", failure: nil,
            journal: nil, proposals: [])
        let folder = root.appendingPathComponent("experts").appendingPathComponent(made.id).appendingPathComponent("debriefs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AgentJSON.encoder.encode(stale).write(to: folder.appendingPathComponent("\(session).json"))
        let redone = try await experts.debrief(session)
        #expect(redone.state == "open")
        #expect(redone.journal?.title == "Unrager posts")
        #expect(asked.value == 1)
        let again = try await experts.debrief(session)
        #expect(again.proposals.map(\.id) == redone.proposals.map(\.id))
        #expect(asked.value == 1)
    }

    @Test("A deleted expert's task keeps the brief it started with")
    func briefOutlivesTheExpert() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let experts = ExpertStore(
            root: root.appendingPathComponent("experts"), store: makeStore(root), claudePath: "/usr/bin/false")
        let made = try await experts.create(ExpertDraft(name: "iPadOS", charter: "Kept charter."))
        let first = await experts.briefFor(session: "s1", expertID: made.id)
        #expect(await experts.delete(made.id))
        #expect(await experts.briefFor(session: "s1", expertID: made.id) == first)
    }

    @Test("A debrief that cannot be read says so and can be asked again")
    func failedDebrief() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = makeStore(root)
        let experts = ExpertStore(
            root: root.appendingPathComponent("experts"), store: sessions, claudePath: "/usr/bin/false",
            now: { november }, ask: { _ in (nil, "Overloaded") })
        let made = try await experts.create(ExpertDraft(name: "iPadOS"))
        let session = await task(sessions, expert: made.id, turns: 1)
        let record = try await experts.debrief(session)
        #expect(record.state == "failed")
        #expect(record.failure == "Overloaded")
        #expect(try await experts.journal(made.id).isEmpty)
    }

    @Test("A task that never started has nothing to debrief")
    func nothingToDebrief() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = makeStore(root)
        let experts = ExpertStore(
            root: root.appendingPathComponent("experts"), store: sessions, claudePath: "/usr/bin/false")
        let made = try await experts.create(ExpertDraft(name: "iPadOS"))
        let session = await sessions.createExpertTask(
            expertID: made.id, title: nil, directory: nil, model: nil, effort: nil)
        await #expect(throws: ExpertError.self) { try await experts.debrief(session.id) }
        await #expect(throws: ExpertError.self) { try await experts.debrief("not-a-task") }
    }

    @Test("Guards run in the background, keep their history, and report a flip to failing once")
    func guards() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let experts = ExpertStore(
            root: root.appendingPathComponent("experts"), store: makeStore(root), claudePath: "/usr/bin/false")
        let flips = FlipCounter()
        await experts.observeGuardFlips { _, _, _ in flips.increment() }
        let made = try await experts.create(
            ExpertDraft(name: "Flaccy", guards: [GuardItem(id: "", name: "Fails", command: "exit 1")]))
        let guardID = try #require(made.guards.first?.id)
        #expect(await experts.runGuards(made.id, only: nil))
        try await waitFor { await experts.get(made.id)?.guards.first?.last != nil }
        #expect(await experts.runGuards(made.id, only: guardID))
        try await waitFor { (await experts.get(made.id)?.guards.first?.history?.count ?? 0) == 2 }
        let served = try #require(await experts.get(made.id)?.guards.first)
        #expect(served.last?.passed == false)
        #expect(served.running == nil)
        #expect(flips.value == 1)
    }

    @Test("A brief is written once per task and reused by every process of it")
    func briefIsStable() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let experts = ExpertStore(
            root: root.appendingPathComponent("experts"), store: makeStore(root), claudePath: "/usr/bin/false")
        let made = try await experts.create(ExpertDraft(name: "iPadOS", charter: "First charter."))
        let first = await experts.briefFor(session: "s1", expertID: made.id)
        _ = try await experts.update(made.id, ExpertPatch(charter: "Second charter."))
        let again = await experts.briefFor(session: "s1", expertID: made.id)
        #expect(first == again)
        #expect(first?.contains("First charter.") == true)
        let fresh = await experts.briefFor(session: "s2", expertID: made.id)
        #expect(fresh?.contains("Second charter.") == true)
    }

    @Test("The client note and an expert's brief ride in one appended prompt")
    func oneAppendedPrompt() {
        let launch = ClaudeLaunch(
            resume: nil, fork: false, directory: "/tmp/work", ultracode: false, appendix: "BRIEF")
        let arguments = ClaudeProcess.arguments(
            launch: launch, model: "opus", effort: "high", permissionMode: "bypassPermissions", clientNote: true)
        #expect(arguments.filter { $0 == "--append-system-prompt" }.count == 1)
        let flag = arguments.firstIndex(of: "--append-system-prompt")!
        #expect(arguments[flag + 1] == ClientNote.text + "\n\nBRIEF")
        let briefOnly = ClaudeProcess.arguments(
            launch: launch, model: "opus", effort: "high", permissionMode: "bypassPermissions", clientNote: false)
        #expect(briefOnly[briefOnly.firstIndex(of: "--append-system-prompt")! + 1] == "BRIEF")
    }

    private func waitFor(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out")
    }
}

private final class FlipCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
