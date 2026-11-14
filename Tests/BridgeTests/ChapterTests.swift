import Foundation
import Testing

@testable import claude_bridge

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func user(_ id: String, _ text: String, at minute: Double) -> Message {
    Message(id: id, role: .user, parts: [.text(text)], createdAt: epoch.addingTimeInterval(minute * 60))
}

private func answer(_ id: String, _ text: String, at minute: Double) -> Message {
    Message(id: id, role: .assistant, parts: [.text(text)], createdAt: epoch.addingTimeInterval(minute * 60))
}

private func conversation(turns: Int) -> [Message] {
    (1...turns).flatMap { turn in
        [user("u\(turn)", "prompt \(turn)", at: Double(turn * 10)),
         answer("a\(turn)", "answer \(turn)", at: Double(turn * 10 + 1))]
    }
}

private func session(_ messages: [Message] = [], title: String = "Fix the stream", chapters: [Chapter]? = nil)
    -> Session
{
    Session(
        id: "s", title: title, directory: nil, claudeSessionID: nil, model: "opus", effort: "high",
        createdAt: epoch, updatedAt: epoch, messages: messages, lastCostUSD: nil, lastTokens: nil,
        pendingFork: nil, chapters: chapters)
}

private func chapter(_ title: String, turn: Int, gist: String? = nil, by namer: Chapter.Namer = .model) -> Chapter {
    Chapter(
        title: title, turn: turn, messageID: "u\(turn)",
        startedAt: epoch.addingTimeInterval(Double(turn * 10) * 60), gist: gist, namedBy: namer)
}

@Suite("A look at the title says kept, renamed or moved, and where")
struct ChapterVerdictTests {
    @Test("MOVED names the message the new topic began at; out of range begins at the newest")
    func moved() {
        #expect(Titler.verdict(from: "MOVED 2: Bridge restart guard", current: "Fix the stream", count: 3)
            == .moved(title: "Bridge restart guard", start: 2))
        #expect(Titler.verdict(from: "moved 9: Chapters", current: "x", count: 3)
            == .moved(title: "Chapters", start: 3))
        #expect(Titler.verdict(from: "**MOVED 1: Fix the login redirect**", current: "x", count: 2)
            == .moved(title: "Fix the login redirect", start: 1))
        #expect(Titler.verdict(from: "MOVED 2: fix the stream", current: "Fix the stream", count: 3) == .kept)
    }

    @Test("A reworded title for the same work is a rename, never a move")
    func renamed() {
        #expect(Titler.verdict(from: "RENAME: Fix stream freeze on resume", current: "Fix stream freeze", count: 3)
            == .renamed("Fix stream freeze on resume"))
        #expect(Titler.verdict(from: "Fix stream freeze on resume", current: "Fix stream freeze", count: 3)
            == .renamed("Fix stream freeze on resume"))
        #expect(Titler.verdict(from: "3D picker fixes", current: "x", count: 2) == .renamed("3D picker fixes"))
        #expect(Titler.verdict(from: "rename: fix stream freeze", current: "Fix stream freeze", count: 3) == .kept)
    }

    @Test("KEEP keeps; silence, a stray colon and a paragraph are failures, never a keep")
    func keepsAndFails() {
        #expect(Titler.verdict(from: "KEEP", current: "Fix the stream", count: 3) == .kept)
        #expect(Titler.verdict(from: "Keep.", current: "Fix the stream", count: 3) == .kept)
        #expect(Titler.verdict(from: "  \n ", current: "Fix the stream", count: 3) == .failed)
        #expect(Titler.verdict(from: "2: Fix login", current: "Fix the stream", count: 3) == .failed)
        #expect(Titler.verdict(from: String(repeating: "word ", count: 20), current: "x", count: 3) == .failed)
    }

    @Test("A gist is the reply's first line, unquoted, and never a paragraph")
    func gistLine() {
        #expect(Titler.gistLine(from: "\n\"Traced the freeze to a 401 hang.\"\nmore") == "Traced the freeze to a 401 hang.")
        #expect(Titler.gistLine(from: "   \n  ") == nil)
        #expect(Titler.gistLine(from: String(repeating: "long ", count: 60)) == nil)
    }
}

@Suite("Chapters follow the conversation's names")
struct ChapterBookTests {
    @Test("The first message opens chapter one, named by whoever named it")
    func firstMessage() {
        var plain = session([user("u1", "Fix the stream", at: 0)])
        #expect(ChapterBook.recorded(&plain, message: plain.messages[0], priorTitle: "New chat"))
        #expect(plain.chapters == [
            Chapter(title: "Fix the stream", turn: 1, messageID: "u1", startedAt: epoch, gist: nil, namedBy: .prompt)
        ])

        var scheduled = session([user("u1", "Daily report", at: 0)], title: "Daily report")
        scheduled.scheduleID = "sched"
        scheduled.customTitle = true
        _ = ChapterBook.recorded(&scheduled, message: scheduled.messages[0], priorTitle: "Daily report")
        #expect(scheduled.chapters?.first?.namedBy == .schedule)

        var renamed = session([user("u1", "x", at: 0)], title: "Mine")
        renamed.customTitle = true
        _ = ChapterBook.recorded(&renamed, message: renamed.messages[0], priorTitle: "Mine")
        #expect(renamed.chapters?.first?.namedBy == .person)
    }

    @Test("A later message leaves the chapters alone unless it changed the title")
    func laterMessage() {
        var unchanged = session(conversation(turns: 2), chapters: [chapter("Fix the stream", turn: 1, by: .model)])
        #expect(!ChapterBook.recorded(&unchanged, message: unchanged.messages[2], priorTitle: "Fix the stream"))

        var pictureFirst = session(conversation(turns: 2), title: "Look at this", chapters: [chapter("New chat", turn: 1, by: .prompt)])
        #expect(ChapterBook.recorded(&pictureFirst, message: pictureFirst.messages[2], priorTitle: "New chat"))
        #expect(pictureFirst.chapters?.map(\.title) == ["Look at this"])
    }

    @Test("A rename renames the current chapter; history without chapters is first written as kept")
    func renames() {
        var going = session(conversation(turns: 5), chapters: [chapter("A", turn: 1), chapter("B", turn: 4)])
        #expect(ChapterBook.renamed(&going, to: "Mine", by: .person, priorTitle: "B"))
        #expect(going.chapters?.map(\.title) == ["A", "Mine"])
        #expect(going.chapters?.last?.namedBy == .person)
        #expect(!ChapterBook.renamed(&going, to: "Mine", by: .person, priorTitle: "Mine"))

        var old = session(conversation(turns: 5), title: "Old name")
        #expect(ChapterBook.renamed(&old, to: "Model name", by: .model, priorTitle: "Old name"))
        #expect(old.chapters?.count == 1)
        #expect(old.chapters?.first?.title == "Model name")
        #expect(old.chapters?.first?.messageID == "u1")

        var empty = session()
        #expect(!ChapterBook.renamed(&empty, to: "Mine", by: .person, priorTitle: "New chat"))
        #expect(empty.chapters == nil)
    }

    @Test("A moved topic opens a chapter at the message named and hands back the one it closed")
    func opens() {
        var going = session(conversation(turns: 6), chapters: [chapter("A", turn: 1)])
        let closed = ChapterBook.opened(&going, title: "B", at: going.messages[8], priorTitle: "A")
        #expect(closed == 0)
        #expect(going.chapters?.map(\.title) == ["A", "B"])
        #expect(going.chapters?.last?.turn == 5)
        #expect(going.chapters?.last?.messageID == "u5")
        #expect(going.chapters?.last?.startedAt == epoch.addingTimeInterval(50 * 60))
    }

    @Test("A boundary at or before the current chapter's start moves after it, or opens nothing")
    func clamps() {
        var going = session(conversation(turns: 6), chapters: [chapter("A", turn: 1), chapter("B", turn: 4)])
        #expect(ChapterBook.opened(&going, title: "C", at: going.messages[4], priorTitle: "B") == 1)
        #expect(going.chapters?.last?.turn == 5)

        var newest = session(conversation(turns: 4), chapters: [chapter("A", turn: 1), chapter("B", turn: 4)])
        #expect(ChapterBook.opened(&newest, title: "C", at: newest.messages[6], priorTitle: "B") == nil)
        #expect(newest.chapters?.count == 2)
    }

    @Test("A conversation older than chapters gets a kept first chapter before its second opens")
    func seedsBeforeOpening() {
        var old = session(conversation(turns: 6), title: "Old name")
        #expect(ChapterBook.opened(&old, title: "New topic", at: old.messages[10], priorTitle: "Old name") == 0)
        #expect(old.chapters?.map(\.title) == ["Old name", "New topic"])
        #expect(old.chapters?.first?.namedBy == .kept)
        #expect(old.chapters?.first?.turn == 1)
    }

    @Test("A fork carries the chapters and names the last one after itself")
    func forks() {
        let forked = ChapterBook.forked([chapter("A", turn: 1, gist: "Did A."), chapter("B", turn: 4, gist: "x")], title: "Fork of B")
        #expect(forked?.map(\.title) == ["A", "Fork of B"])
        #expect(forked?.last?.namedBy == .fork)
        #expect(forked?.last?.gist == nil)
        #expect(forked?.first?.gist == "Did A.")
        #expect(ChapterBook.forked(nil, title: "Fork of x") == nil)
    }

    @Test("A look is shown the messages since the last one, at most four, never the bridge's own notices")
    func recent() {
        let messages = conversation(turns: 9)
        #expect(ChapterBook.recent(messages, since: 6, through: 9).map(\.turn) == [7, 8, 9])
        #expect(ChapterBook.recent(messages, since: nil, through: 9).map(\.turn) == [6, 7, 8, 9])
        #expect(ChapterBook.recent(messages, since: 2, through: 7).map(\.turn) == [4, 5, 6, 7])
        var noticed = conversation(turns: 3)
        noticed.append(user("n4", "The work was cut off. Picking it back up.", at: 40))
        noticed.append(user("n5", "The session limit was reached. Picking the work back up at 17:00.", at: 50))
        #expect(ChapterBook.recent(noticed, since: 2, through: 5).map(\.message.id) == ["u3"])
    }

    @Test("The first model title is written from the current chapter's opening exchange")
    func opening() {
        let fresh = session(conversation(turns: 3))
        #expect(ChapterBook.opening(of: fresh)?.user == "prompt 1")
        let fork = session(conversation(turns: 5), chapters: [chapter("A", turn: 1), chapter("Fork of B", turn: 4, by: .fork)])
        #expect(ChapterBook.opening(of: fork)?.user == "prompt 4")
        #expect(ChapterBook.opening(of: fork)?.answer == "answer 4")
    }

    @Test("A closed chapter is summed up from its own messages and its last answer")
    func gistInput() {
        let going = session(conversation(turns: 6), chapters: [chapter("A", turn: 1), chapter("B", turn: 4)])
        let input = ChapterBook.gistInput(going, closed: 0)
        #expect(input?.prompts == ["prompt 1", "prompt 2", "prompt 3"])
        #expect(input?.answer == "answer 3")
        #expect(ChapterBook.gistInput(going, closed: 1) == nil)

        let long = session(conversation(turns: 16), chapters: [chapter("A", turn: 1), chapter("B", turn: 16)])
        #expect(ChapterBook.gistInput(long, closed: 0)?.prompts
            == [1, 3, 5, 7, 9, 11, 13, 15].map { "prompt \($0)" })

        var seamed = conversation(turns: 4)
        seamed.insert(
            Message(id: "seam", role: .assistant, parts: [.compaction(Compaction())], createdAt: epoch.addingTimeInterval(32 * 60)),
            at: 6)
        let seamedSession = session(seamed, chapters: [chapter("A", turn: 1), chapter("B", turn: 4)])
        #expect(ChapterBook.gistInput(seamedSession, closed: 0)?.answer == "answer 3")
    }

    @Test("A gist lands on the chapter it was written for, once")
    func summed() {
        let target = chapter("A", turn: 1)
        var going = session(conversation(turns: 6), chapters: [target, chapter("B", turn: 4)])
        #expect(ChapterBook.summed(&going, chapter: target, gist: "Did A."))
        #expect(going.chapters?.first?.gist == "Did A.")
        #expect(!ChapterBook.summed(&going, chapter: target, gist: "Again."))
        var cleared = session()
        #expect(!ChapterBook.summed(&cleared, chapter: target, gist: "Did A."))
    }
}

@Suite("Chapters on the wire")
struct ChapterWireTests {
    @Test("A chapters frame names its type and carries the whole list")
    func frame() throws {
        let event = BridgeEvent.chapters([chapter("A", turn: 1, gist: "Did A.")], revision: 4)
        let data = try JSONEncoder().encode(event)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["type"] as? String == "chapters")
        let list = object?["chapters"] as? [[String: Any]]
        #expect(list?.first?["namedBy"] as? String == "model")
        #expect(list?.first?["messageID"] as? String == "u1")
        #expect(object?["revision"] as? Int == 4)
        let back = try JSONDecoder().decode(BridgeEvent.self, from: data)
        guard case .chapters(let chapters, let revision) = back else {
            Issue.record("decoded \(back)")
            return
        }
        #expect(chapters.first?.gist == "Did A.")
        #expect(revision == 4)
    }

    @Test("A stored conversation from before chapters decodes without them")
    func oldStore() throws {
        let encoded = try JSONEncoder().encode(session(conversation(turns: 1)))
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(object["chapters"] == nil)
        object["chapters"] = nil
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.chapters == nil)
    }
}

@Suite("The store keeps chapters through renames, forks and clears")
struct ChapterStoreTests {
    private func makeStore(_ root: URL) -> SessionStore {
        SessionStore(
            runner: ClaudeRunner(claudePath: "/bin/false", workdir: root.path, permissionMode: "default"),
            defaults: MachineDefaults(modelOverride: "sonnet", effortOverride: "medium", home: NSTemporaryDirectory()),
            storeURL: root.appendingPathComponent("sessions.json"), projectsDir: root.path)
    }

    @Test("Rename renames the current chapter, fork carries them, clear drops them")
    func lifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chapters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        var seeded = session(conversation(turns: 6), title: "B", chapters: [chapter("A", turn: 1), chapter("B", turn: 4)])
        seeded.id = "chaptered"
        _ = await store.adopt(seeded)

        #expect(await store.rename("chaptered", title: "Mine"))
        let renamed = await store.get("chaptered")
        #expect(renamed?.chapters?.map(\.title) == ["A", "Mine"])
        #expect(renamed?.chapters?.last?.namedBy == .person)

        let fork = await store.fork("chaptered")
        #expect(fork?.chapters?.map(\.title) == ["A", "Fork of Mine"])

        let before = await store.get("chaptered")?.chaptersRevision ?? 0
        await store.clear("chaptered")
        #expect(await store.get("chaptered")?.chapters == nil)
        #expect((await store.get("chaptered")?.chaptersRevision ?? 0) > before)

        let reopened = makeStore(root)
        #expect(await reopened.get(fork?.id ?? "")?.chapters?.count == 2)
    }
}

@Suite("A history older than chapters is split into them once")
struct ChapterBackfillTests {
    @Test("A split reply is read into chapters that tile the messages")
    func readsSegments() {
        let raw = """
            1 | Blank feed after resume | Traced the blank feed to a 401 hang.
            garbage line
            4 | Deploys wait for idle uploads | Deploys now wait for idle uploads.
            3 | Backwards | Dropped.
            **7 | Release notes in settings |**
            """
        let segments = Titler.segments(from: raw, count: 8)
        #expect(segments?.map(\.start) == [1, 4, 7])
        #expect(segments?.map(\.title) == ["Blank feed after resume", "Deploys wait for idle uploads", "Release notes in settings"])
        #expect(segments?.first?.gist == "Traced the blank feed to a 401 hang.")
        #expect(segments?.last?.gist == nil)
        #expect(Titler.segments(from: "3 | Starts late | x", count: 8)?.first?.start == 1)
        #expect(Titler.segments(from: "nothing useful", count: 8) == nil)
        #expect(Titler.segments(from: "99 | Out of range | x", count: 8) == nil)
    }

    @Test("Chapters come from the split; the last keeps the chat's name; chapters already there win")
    func builds() {
        let messages = conversation(turns: 8)
        let shown = ChapterBook.backfillPrompts(messages)
        #expect(shown.count == 8)
        let segments = [
            Titler.Segment(start: 1, title: "A", gist: "Did A."),
            Titler.Segment(start: 5, title: "Model's B", gist: nil),
        ]
        let chapters = ChapterBook.backfilled(session(messages, title: "Chat's B"), segments: segments, shown: shown)
        #expect(chapters?.map(\.title) == ["A", "Chat's B"])
        #expect(chapters?.map(\.turn) == [1, 5])
        #expect(chapters?.map(\.messageID) == ["u1", "u5"])
        #expect(chapters?.first?.gist == "Did A.")
        #expect(ChapterBook.backfilled(
            session(messages, chapters: [chapter("Own", turn: 1)]), segments: segments, shown: shown) == nil)
    }

    @Test("A long history is thinned evenly and notices are left out")
    func thins() {
        var messages = conversation(turns: 400)
        messages.append(user("n", "The session limit was reached. Picking the work back up at 9:00.", at: 9000))
        let shown = ChapterBook.backfillPrompts(messages)
        #expect(shown.count == ChapterBook.backfillShown)
        #expect(shown.first?.turn == 1)
        #expect(shown.last?.turn == 400)
        #expect(!shown.contains { $0.message.id == "n" })
    }

    @Test("Reading a long conversation splits it once and hands clients the chapters")
    func storeBackfills() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backfill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("claude")
        let calls = root.appendingPathComponent("calls")
        let script = """
            #!/bin/sh
            echo call >> "\(calls.path)"
            printf '1 | Blank feed after resume | Traced the blank feed to a 401 hang.\\n5 | Release notes | \\n'
            """
        try writeExecutable(script, to: fake)
        let store = SessionStore(
            runner: ClaudeRunner(claudePath: fake.path, workdir: root.path, permissionMode: "default"),
            defaults: MachineDefaults(modelOverride: "sonnet", effortOverride: "medium", home: NSTemporaryDirectory()),
            storeURL: root.appendingPathComponent("sessions.json"), projectsDir: root.path)
        var long = session(conversation(turns: 8), title: "Release notes in settings")
        long.id = "long"
        _ = await store.adopt(long)
        var short = session(conversation(turns: 3), title: "Short")
        short.id = "short"
        _ = await store.adopt(short)

        await store.backfillChaptersIfNeeded("long")
        await store.backfillChaptersIfNeeded("short")
        let deadline = ContinuousClock.now + .seconds(10)
        while await store.get("long")?.chapters == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let chapters = await store.get("long")?.chapters
        #expect(chapters?.map(\.title) == ["Blank feed after resume", "Release notes in settings"])
        #expect(chapters?.map(\.turn) == [1, 5])
        #expect((await store.get("long")?.chaptersRevision ?? 0) > 0)
        #expect(await store.get("short")?.chapters == nil)

        await store.backfillChaptersIfNeeded("long")
        try await Task.sleep(for: .milliseconds(200))
        let made = (try? String(contentsOf: calls, encoding: .utf8))?.split(separator: "\n").count
        #expect(made == 1)
    }
}
