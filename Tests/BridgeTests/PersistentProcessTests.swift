import Foundation
import Testing

@testable import claude_bridge

/// A stand-in for the long-lived `claude -p --input-format stream-json`: it reads one prompt per
/// line off stdin and answers each with a turn, answers a control request the way the CLI does,
/// starts a turn of its own after a prompt that mentions background work, and holds a "slow"
/// turn open until it is interrupted. One process, many turns — which is the whole point.
private struct StdinClaude {
    let root: URL
    let binary: String
    let invocationLog: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        invocationLog = root.appendingPathComponent("invocations.log")
        _ = FileManager.default.createFile(atPath: invocationLog.path, contents: Data())
        let stop = root.appendingPathComponent("stop").path
        let script = root.appendingPathComponent("stdin-claude")
        let body = """
            #!/bin/sh
            P=/usr/bin/printf
            case "$*" in *--input-format*) ;; *) exit 0;; esac
            echo "start $$" >> "\(invocationLog.path)"
            while IFS= read -r line; do
              case "$line" in
                *control_request*)
                  rid=$(echo "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
                  touch "\(stop)"
                  $P '%s\\n' "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"success\\",\\"request_id\\":\\"$rid\\"}}"
                  [ -f "\(root.appendingPathComponent("hang").path)" ] || $P '%s\\n' '{"type":"result","subtype":"error_during_execution","is_error":true}'
                  ;;
                *\\"/effort*)
                  $P '%s\\n' '{"type":"system","subtype":"init","session_id":"persist-session"}'
                  $P '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Set effort level"}]}}'
                  $P '%s\\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":0}'
                  ;;
                *)
                  $P '%s\\n' '{"type":"system","subtype":"init","session_id":"persist-session"}'
                  case "$line" in
                    *slow*)
                      rm -f "\(stop)"
                      ( sleep 3; [ -f "\(stop)" ] || $P '%s\\n' '{"type":"result","subtype":"success","is_error":false}' ) &
                      ;;
                    *hang*)
                      touch "\(root.appendingPathComponent("hang").path)"
                      ;;
                    *)
                      $P '%s\\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}'
                      $P '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"answer"}}}'
                      case "$line" in
                        *carry*)
                          $P '%s\\n' '{"type":"system","subtype":"task_started","task_id":"c1","task_type":"local_bash","description":"sleep 60","is_backgrounded":true}'
                          $P '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"c1","task_type":"local_bash","description":"sleep 60"}]}'
                          ;;
                        *ambient*)
                          $P '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"m1","task_type":"local_bash","description":"tail -f log","ambient":true}]}'
                          ;;
                      esac
                      $P '%s\\n' '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01}'
                      case "$line" in
                        *carry*)
                          ( sleep 0.5
                            $P '%s\\n' '{"type":"system","subtype":"task_notification","task_id":"c1","status":"completed","summary":"slept"}'
                            $P '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[]}'
                            $P '%s\\n' '{"type":"system","subtype":"init","session_id":"persist-session"}'
                            $P '%s\\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}'
                            $P '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"it finished"}}}'
                            $P '%s\\n' '{"type":"result","subtype":"success","is_error":false}' ) &
                          ;;
                        *stray*)
                          ( sleep 0.3; $P '%s\\n' '{"type":"result","subtype":"success","is_error":false}' ) &
                          ;;
                        *background*)
                          ( sleep 0.4
                            $P '%s\\n' '{"type":"system","subtype":"task_notification","task_id":"t1","status":"completed","summary":"done"}'
                            $P '%s\\n' '{"type":"system","subtype":"init","session_id":"persist-session"}'
                            $P '%s\\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}'
                            $P '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"it finished"}}}'
                            $P '%s\\n' '{"type":"result","subtype":"success","is_error":false}' ) &
                          ;;
                      esac
                      ;;
                  esac
                  ;;
              esac
            done
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

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func makeStore(
    _ fake: StdinClaude, processTTL: TimeInterval = 1800, processPool: Int = 4,
    abortGrace: TimeInterval = 10
) -> SessionStore {
    SessionStore(
        runner: ClaudeRunner(
            claudePath: fake.binary, workdir: fake.root.path, permissionMode: "default"),
        defaults: MachineDefaults(
            modelOverride: "sonnet", effortOverride: "medium", home: NSTemporaryDirectory()),
        storeURL: fake.root.appendingPathComponent("sessions.json"),
        projectsDir: fake.root.path, processTTL: processTTL, processPool: processPool,
        abortGrace: abortGrace)
}

private func waitUntil(
    _ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private func assistantTexts(_ store: SessionStore, _ id: String) async -> [String] {
    (await store.get(id)?.messages ?? []).filter { $0.role == .assistant }.map { message in
        message.parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined()
    }
}

@Suite("One process per conversation")
struct PersistentProcessTests {
    @Test("Two turns run on one process, and the process is still there after them")
    func oneProcessServesTwoTurns() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "one"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        _ = await store.send(session.id, request: SendRequest(text: "two"))
        await waitUntil { await assistantTexts(store, session.id).count == 2 }
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }

        #expect(fake.starts == 1)
        #expect(await assistantTexts(store, session.id) == ["answer", "answer"])
        #expect(await store.get(session.id)?.claudeSessionID == "persist-session")
    }

    @Test("Background work ending between turns is a turn of its own, not silence")
    func backgroundWorkContinuesBetweenTurns() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))
        let caster = await store.broadcaster(for: session.id)
        let (_, events) = caster.subscribe()
        let statuses = Statuses()
        let watcher = Task {
            for await event in events {
                if case .status(let value) = event { await statuses.append(value) }
            }
        }
        defer { watcher.cancel() }

        _ = await store.send(session.id, request: SendRequest(text: "start background work"))
        await waitUntil { await assistantTexts(store, session.id).count == 2 }
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }

        #expect(await assistantTexts(store, session.id) == ["answer", "it finished"])
        #expect(await statuses.values == ["running", "idle", "running", "idle"])
        #expect(await store.get(session.id)?.messages.count(where: { $0.role == .user }) == 1)
        #expect(fake.starts == 1)
    }

    @Test("Work carried between turns is reported while it runs and cleared when it ends")
    func carriedWorkIsReported() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))
        let caster = await store.broadcaster(for: session.id)
        let (_, events) = caster.subscribe()
        let reports = Reports()
        let watcher = Task {
            for await event in events {
                if case .background(let work) = event { await reports.append(work) }
            }
        }
        defer { watcher.cancel() }

        _ = await store.send(session.id, request: SendRequest(text: "carry this on"))
        await waitUntil { await assistantTexts(store, session.id).count == 1 }
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        let carried = BackgroundWork(tasks: 1, task: "sleep 60")
        #expect(await store.backgroundWork(for: session.id) == carried)
        let row = await store.list().first { $0.id == session.id }
        #expect(row?.backgroundTasks == 1)
        #expect(row?.backgroundTask == "sleep 60")
        #expect(row?.active == false)

        await waitUntil { await assistantTexts(store, session.id).count == 2 }
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        #expect(await store.backgroundWork(for: session.id) == nil)
        #expect(await store.list().first { $0.id == session.id }?.backgroundTasks == nil)
        #expect(await reports.values == [carried, nil])
    }

    @Test("An ambient monitor is not work anybody is waiting on")
    func ambientMonitorIsNotBackgroundWork() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "start the ambient monitor"))
        await waitUntil { await assistantTexts(store, session.id).count == 1 }
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        #expect(await store.backgroundWork(for: session.id) == nil)
        #expect(await store.list().first { $0.id == session.id }?.backgroundTasks == nil)
    }

    @Test("Stop interrupts the turn and keeps the process")
    func stopInterruptsWithoutKillingTheProcess() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "a slow one"))
        try await Task.sleep(for: .milliseconds(300))
        let result = await store.abortTurn(session.id)
        #expect(result.stopped)
        await waitUntil(.seconds(2)) { await !store.hasQueuedOrRunningTurn(session.id) }
        #expect(await !store.hasQueuedOrRunningTurn(session.id))

        _ = await store.send(session.id, request: SendRequest(text: "two"))
        await waitUntil { await assistantTexts(store, session.id).count == 2 }
        #expect(await assistantTexts(store, session.id).last == "answer")
        #expect(fake.starts == 1)
    }

    @Test("A process idle past its keep is let go, and the next prompt starts another")
    func idleProcessIsReaped() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake, processTTL: 0.2)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "one"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        try await Task.sleep(for: .milliseconds(400))
        await store.reapIdleProcesses()
        _ = await store.send(session.id, request: SendRequest(text: "two"))
        await waitUntil { await assistantTexts(store, session.id).count == 2 }

        #expect(fake.starts == 2)
    }

    @Test("A different effort is set on the live process rather than costing a new one")
    func effortChangesInPlace() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "one"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        _ = await store.send(session.id, request: SendRequest(text: "two", effort: "high"))
        await waitUntil { await assistantTexts(store, session.id).count == 2 }

        #expect(await assistantTexts(store, session.id) == ["answer", "answer"])
        #expect(fake.starts == 1)
    }
}

private actor Statuses {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor Reports {
    private(set) var values: [BackgroundWork?] = []
    func append(_ value: BackgroundWork?) { values.append(value) }
}

@Suite("One process per conversation — the edges")
struct PersistentProcessEdgeTests {
    @Test("A turn that needs a new process gets it without the old one's exit closing the turn")
    func replacingTheProcessKeepsTheNewTurnOpen() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "one"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        _ = await store.send(session.id, request: SendRequest(text: "two", effort: "ultracode"))
        await waitUntil { await assistantTexts(store, session.id).count == 2 }
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }

        #expect(await assistantTexts(store, session.id) == ["answer", "answer"])
        #expect(fake.starts == 2)
        #expect(await store.liveProcessCount() == 1)
    }

    @Test("A result with no turn open is not a turn")
    func aStrayResultOpensNothing() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))
        let caster = await store.broadcaster(for: session.id)
        let (_, events) = caster.subscribe()
        let statuses = Statuses()
        let watcher = Task {
            for await event in events {
                if case .status(let value) = event { await statuses.append(value) }
            }
        }
        defer { watcher.cancel() }

        _ = await store.send(session.id, request: SendRequest(text: "a stray one"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        try await Task.sleep(for: .milliseconds(700))

        #expect(await assistantTexts(store, session.id) == ["answer"])
        #expect(await statuses.values == ["running", "idle"])
        #expect(await !store.hasQueuedOrRunningTurn(session.id))
    }

    @Test("Idle processes past the pool are let go, least recently used first")
    func idleProcessesBeyondThePoolAreReaped() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake, processPool: 1)
        let first = await store.create(CreateRequest(directory: fake.root.path))
        let second = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(first.id, request: SendRequest(text: "one"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(first.id) }
        try await Task.sleep(for: .milliseconds(50))
        _ = await store.send(second.id, request: SendRequest(text: "one"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(second.id) }
        #expect(await store.liveProcessCount() == 2)

        await store.reapIdleProcesses()
        #expect(await store.liveProcessCount() == 1)

        _ = await store.send(second.id, request: SendRequest(text: "two"))
        await waitUntil { await assistantTexts(store, second.id).count == 2 }
        #expect(fake.starts == 2)
    }

    @Test("A stop the CLI accepted but never closed ends the process after the grace")
    func aHungInterruptIsFinishedTheHardWay() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake, abortGrace: 0.5)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "hang here"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await store.hasQueuedOrRunningTurn(session.id))
        let result = await store.abortTurn(session.id)
        #expect(result.stopped)
        await waitUntil(.seconds(8)) { await !store.hasQueuedOrRunningTurn(session.id) }
        #expect(await !store.hasQueuedOrRunningTurn(session.id))
        await waitUntil(.seconds(2)) { await store.liveProcessCount() == 0 }
        #expect(await store.liveProcessCount() == 0)

        _ = await store.send(session.id, request: SendRequest(text: "two"))
        await waitUntil { await assistantTexts(store, session.id).count == 2 }
        #expect(fake.starts == 2)
    }
}
