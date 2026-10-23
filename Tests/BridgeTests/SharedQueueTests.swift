import Foundation
import Testing

@testable import claude_bridge

/// A stand-in for the `claude` CLI that holds each turn for a while and exits, counting how many
/// turns it was asked to run.
private struct QueueFakeClaude {
    let root: URL
    let binary: String
    let invocationLog: URL

    init(holdSeconds: Double = 4.0) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        invocationLog = root.appendingPathComponent("invocations.log")
        _ = FileManager.default.createFile(atPath: invocationLog.path, contents: Data())
        let script = root.appendingPathComponent("fake-claude")
        let body = """
            #!/bin/sh
            echo "start $$" >> "\(invocationLog.path)"
            /usr/bin/printf '%s\\n' '{"type":"system","subtype":"init","session_id":"queue-session"}'
            sleep \(holdSeconds)
            echo "end $$" >> "\(invocationLog.path)"
            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        binary = script.path
    }

    var starts: Int {
        let text = (try? String(contentsOf: invocationLog, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count { $0.hasPrefix("start") }
    }

    func makeStore() -> SessionStore {
        SessionStore(
            runner: ClaudeRunner(claudePath: binary, workdir: root.path, permissionMode: "default"),
            defaults: MachineDefaults(
                modelOverride: "sonnet", effortOverride: "medium", home: NSTemporaryDirectory()),
            storeURL: root.appendingPathComponent("sessions.json"), projectsDir: root.path)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func until(_ limit: Duration, _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private func userTexts(_ store: SessionStore, _ id: String) async -> [String] {
    (await store.get(id)?.messages ?? []).filter { $0.role == .user }.map { message in
        message.parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined()
    }
}

private func item(_ id: String, _ text: String, kind: String? = nil) -> EnqueueRequest {
    EnqueueRequest(id: id, text: text, kind: kind, model: nil, effort: nil, attachments: nil)
}

private func accepted(_ outcome: EnqueueOutcome) -> (started: Bool, snapshot: QueueSnapshot)? {
    guard case .accepted(let started, let snapshot) = outcome else { return nil }
    return (started, snapshot)
}

private func queueSnapshots(_ events: [BridgeEvent]) -> [QueueSnapshot] {
    events.compactMap { event in
        if case .queue(let snapshot) = event { return snapshot }
        return nil
    }
}

private actor EventLog {
    private(set) var events: [BridgeEvent] = []
    func add(_ event: BridgeEvent) { events.append(event) }
}

@Suite("Shared queue")
struct SharedQueueTests {

    @Test("An enqueue on an idle session starts at once and never appears in the queue")
    func idleEnqueueStarts() async throws {
        let fake = try QueueFakeClaude()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))

        let result = try #require(accepted(await store.enqueue(session.id, request: item("a", "hello"))))

        #expect(result.started)
        #expect(result.snapshot.queue.isEmpty)
        #expect(result.snapshot.paused == false)
        #expect(await userTexts(store, session.id) == ["hello"])
        #expect(await store.hasQueuedOrRunningTurn(session.id))
        try await until(.seconds(3)) { fake.starts >= 1 }
        #expect(fake.starts == 1)
    }

    @Test("An enqueue while a turn runs queues without a transcript echo, and the message lands when it starts")
    func queuedItemEchoesWhenItStarts() async throws {
        let fake = try QueueFakeClaude(holdSeconds: 4.0)
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "first"))
        let result = try #require(accepted(await store.enqueue(session.id, request: item("b", "second"))))

        #expect(result.started == false)
        #expect(result.snapshot.queue.map(\.id) == ["b"])
        #expect(result.snapshot.queue.first?.text == "second")
        #expect(await userTexts(store, session.id) == ["first"])

        try await until(.seconds(40)) { await userTexts(store, session.id).count == 2 }
        #expect(await userTexts(store, session.id) == ["first", "second"])
        #expect(await store.queueSnapshot(session.id).queue.isEmpty)
        try await until(.seconds(40)) { fake.starts >= 2 }
        #expect(fake.starts == 2)
    }

    @Test("Enqueueing the same id again changes nothing, queued or already started")
    func enqueueIsIdempotent() async throws {
        let fake = try QueueFakeClaude(holdSeconds: 4.0)
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "first"))
        _ = await store.enqueue(session.id, request: item("b", "second"))
        let again = try #require(accepted(await store.enqueue(session.id, request: item("b", "second"))))
        #expect(again.started == false)
        #expect(again.snapshot.queue.count == 1)

        try await until(.seconds(40)) { await userTexts(store, session.id).count == 2 }
        let replay = try #require(accepted(await store.enqueue(session.id, request: item("b", "second"))))
        #expect(replay.snapshot.queue.isEmpty)
        try await until(.seconds(40)) { await store.hasQueuedOrRunningTurn(session.id) == false }
        #expect(await userTexts(store, session.id) == ["first", "second"])
        #expect(fake.starts == 2)
    }

    @Test("A queued item can be edited and cancelled before it starts")
    func editAndCancelBeforeStart() async throws {
        let fake = try QueueFakeClaude(holdSeconds: 4.0)
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "first"))
        _ = await store.enqueue(session.id, request: item("keep", "original"))
        _ = await store.enqueue(session.id, request: item("drop", "never sent"))

        let edited = await store.editQueued(
            session.id, itemID: "keep",
            request: EditQueuedRequest(text: "edited", model: "opus", effort: "high"))
        guard case .changed(let editedSnapshot) = edited else {
            Issue.record("edit was refused: \(edited)")
            return
        }
        #expect(editedSnapshot.queue.first?.text == "edited")
        #expect(editedSnapshot.queue.first?.model == "opus")
        #expect(editedSnapshot.queue.first?.effort == "high")

        let remaining = QueueSnapshot(queue: [editedSnapshot.queue[0]], paused: false)
        let cancelled = await store.cancelQueued(session.id, itemID: "drop")
        #expect(cancelled == .changed(remaining))
        let retried = await store.cancelQueued(session.id, itemID: "drop")
        #expect(retried == .changed(remaining))

        try await until(.seconds(40)) { await userTexts(store, session.id).count == 2 }
        try await until(.seconds(40)) { await store.hasQueuedOrRunningTurn(session.id) == false }
        #expect(await userTexts(store, session.id) == ["first", "edited"])
    }

    @Test("Editing or cancelling an item that has started is refused")
    func startedItemIsRefused() async throws {
        let fake = try QueueFakeClaude(holdSeconds: 2.0)
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "first"))
        _ = await store.enqueue(session.id, request: item("b", "second"))
        try await until(.seconds(40)) { await userTexts(store, session.id).count == 2 }

        let edit = await store.editQueued(
            session.id, itemID: "b", request: EditQueuedRequest(text: "late"))
        let cancel = await store.cancelQueued(session.id, itemID: "b")
        let idleStart = await store.editQueued(
            session.id, itemID: "unknown", request: EditQueuedRequest(text: "x"))

        #expect(edit == .alreadyStarted)
        #expect(cancel == .alreadyStarted)
        #expect(idleStart == .alreadyStarted)
        try await until(.seconds(40)) { await store.hasQueuedOrRunningTurn(session.id) == false }
    }

    @Test("Stop pauses the queue and keeps its items")
    func stopPausesAndKeeps() async throws {
        let fake = try QueueFakeClaude(holdSeconds: 4.0)
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "first"))
        try await Task.sleep(for: .milliseconds(300))
        _ = await store.enqueue(session.id, request: item("b", "second"))

        let result = await store.abortTurn(session.id)
        #expect(result.stopped)
        #expect(result.paused)

        try await until(.seconds(30)) { await store.hasQueuedOrRunningTurn(session.id) == false }
        try await Task.sleep(for: .seconds(1))
        let snapshot = await store.queueSnapshot(session.id)
        #expect(snapshot.paused)
        #expect(snapshot.queue.map(\.id) == ["b"])
        #expect(fake.starts == 1)
        #expect(await userTexts(store, session.id) == ["first"])
    }

    @Test("Resume runs a paused queue, and so does a new enqueue")
    func resumeAndEnqueueClearThePause() async throws {
        let fake = try QueueFakeClaude(holdSeconds: 4.0)
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "first"))
        try await Task.sleep(for: .milliseconds(300))
        _ = await store.enqueue(session.id, request: item("b", "second"))
        _ = await store.abortTurn(session.id)
        try await until(.seconds(30)) { await store.hasQueuedOrRunningTurn(session.id) == false }
        #expect(await store.queueSnapshot(session.id).paused)

        let resumed = await store.resumeQueue(session.id)
        guard case .changed(let afterResume) = resumed else {
            Issue.record("resume was refused: \(resumed)")
            return
        }
        #expect(afterResume.paused == false)
        #expect(afterResume.queue.isEmpty)
        #expect(await userTexts(store, session.id).last == "second")
        try await until(.seconds(40)) { await store.hasQueuedOrRunningTurn(session.id) == false }

        _ = await store.send(session.id, request: SendRequest(text: "third"))
        try await Task.sleep(for: .milliseconds(200))
        _ = await store.enqueue(session.id, request: item("c", "fourth"))
        _ = await store.abortTurn(session.id)
        try await until(.seconds(30)) { await store.hasQueuedOrRunningTurn(session.id) == false }
        #expect(await store.queueSnapshot(session.id).paused)

        let result = try #require(accepted(await store.enqueue(session.id, request: item("d", "fifth"))))
        #expect(result.snapshot.paused == false)
        #expect(result.started == false)
        #expect(result.snapshot.queue.map(\.id) == ["d"])
        #expect(await userTexts(store, session.id).last == "fourth")
        try await until(.seconds(40)) { await store.hasQueuedOrRunningTurn(session.id) == false }
    }

    @Test("A legacy send while a turn runs becomes a queue item with no echo")
    func legacySendQueues() async throws {
        let fake = try QueueFakeClaude(holdSeconds: 4.0)
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "first"))
        let outcome = await store.send(session.id, request: SendRequest(text: "from an old client"))

        #expect(outcome == .queued(position: 1))
        let snapshot = await store.queueSnapshot(session.id)
        #expect(snapshot.queue.map(\.text) == ["from an old client"])
        #expect(snapshot.queue.first.map { !$0.id.isEmpty } == true)
        #expect(await userTexts(store, session.id) == ["first"])

        try await until(.seconds(40)) { await userTexts(store, session.id).count == 2 }
        #expect(await userTexts(store, session.id) == ["first", "from an old client"])
        try await until(.seconds(40)) { await store.hasQueuedOrRunningTurn(session.id) == false }
    }

    @Test("A queue restored after a restart comes back paused and runs nothing")
    func restoreComesBackPaused() async throws {
        let fake = try QueueFakeClaude(holdSeconds: 30)
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))
        _ = await store.send(session.id, request: SendRequest(text: "first"))
        let attachment = SendAttachment(
            mime: "image/png", filename: "a.png", dataBase64: Data([1, 2, 3, 4]).base64EncodedString())
        _ = await store.enqueue(
            session.id,
            request: EnqueueRequest(
                id: "b", text: "second", kind: nil, model: "opus", effort: "high",
                attachments: [attachment]))
        await store.flush()
        let before = await store.queueSnapshot(session.id)
        #expect(before.paused == false)

        let reborn = fake.makeStore()
        let after = await reborn.queueSnapshot(session.id)

        #expect(after.paused)
        #expect(after.queue.map(\.id) == ["b"])
        #expect(after.queue.first?.model == "opus")
        #expect(after.queue.first?.attachments == [QueueAttachment(mime: "image/png", filename: "a.png", size: 4)])
        #expect(await reborn.queueGreeting(session.id) == after)
        #expect(await reborn.hasQueuedOrRunningTurn(session.id) == false)
        try await Task.sleep(for: .milliseconds(500))
        #expect(fake.starts == 1)

        _ = await store.abortTurn(session.id)
    }

    @Test("A kept attachment travels with the item and shows in the transcript when it starts")
    func attachmentsSurviveUntilStart() async throws {
        let fake = try QueueFakeClaude(holdSeconds: 4.0)
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))
        _ = await store.send(session.id, request: SendRequest(text: "first"))
        let attachment = SendAttachment(
            mime: "image/png", filename: "a.png", dataBase64: Data([9, 9]).base64EncodedString())
        let result = try #require(
            accepted(
                await store.enqueue(
                    session.id,
                    request: EnqueueRequest(
                        id: "b", text: "look", kind: nil, model: nil, effort: nil,
                        attachments: [attachment]))))
        #expect(result.snapshot.queue.first?.attachments.first?.size == 2)

        try await until(.seconds(40)) { await userTexts(store, session.id).count == 2 }
        let last = try #require(await store.get(session.id)?.messages.last { $0.role == .user })
        let files = last.parts.compactMap { part -> FileRef? in
            if case .file(let file) = part { return file }
            return nil
        }
        #expect(files.count == 1)
        #expect(files.first.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        try await until(.seconds(40)) { await store.hasQueuedOrRunningTurn(session.id) == false }
    }

    @Test("Every change reaches subscribers as the full snapshot")
    func eventsCarryTheSnapshot() async throws {
        let fake = try QueueFakeClaude(holdSeconds: 4.0)
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))
        let log = EventLog()
        let subscription = await store.broadcaster(for: session.id).subscribe()
        let reader = Task { for await event in subscription.stream { await log.add(event) } }

        _ = await store.send(session.id, request: SendRequest(text: "first"))
        _ = await store.enqueue(session.id, request: item("b", "second"))
        _ = await store.enqueue(session.id, request: item("c", "third"))
        _ = await store.editQueued(session.id, itemID: "c", request: EditQueuedRequest(text: "third!"))
        _ = await store.cancelQueued(session.id, itemID: "b")
        _ = await store.abortTurn(session.id)
        try await until(.seconds(30)) { queueSnapshots(await log.events).last?.paused == true }
        reader.cancel()

        let snapshots = queueSnapshots(await log.events)
        #expect(snapshots.map { $0.queue.map(\.id) } == [["b"], ["b", "c"], ["b", "c"], ["c"], ["c"]])
        #expect(snapshots[2].queue.last?.text == "third!")
        #expect(snapshots.map(\.paused) == [false, false, false, false, true])
        let wire = try JSONCoding.encoder.encode(BridgeEvent.queue(snapshots[1]))
        let object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(object["type"] as? String == "queue")
        #expect(object["paused"] as? Bool == false)
        #expect((object["queue"] as? [[String: Any]])?.count == 2)
    }

    @Test("A bad enqueue is refused, an unknown session is not found")
    func refusals() async throws {
        let fake = try QueueFakeClaude()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let session = await store.create(CreateRequest(directory: fake.root.path))

        #expect(await store.enqueue("nope", request: item("a", "x")) == .unknownSession)
        guard case .invalid = await store.enqueue(session.id, request: item("", "x")) else {
            Issue.record("an empty id was accepted")
            return
        }
        guard case .invalid = await store.enqueue(session.id, request: item("a", "x", kind: "shout")) else {
            Issue.record("an unknown kind was accepted")
            return
        }
        guard case .invalid = await store.enqueue(session.id, request: item("a", "")) else {
            Issue.record("an empty item was accepted")
            return
        }
        #expect(await store.hasQueuedOrRunningTurn(session.id) == false)
    }
}
