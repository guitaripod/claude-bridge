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
                *stop_task*)
                  rid=$(echo "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
                  if [ -f "\(root.appendingPathComponent("nostop").path)" ]; then
                    $P '%s\\n' "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"error\\",\\"request_id\\":\\"$rid\\",\\"error\\":\\"stop_task is not supported in this context\\"}}"
                  else
                    pkill -f "sleep 900; echo \(root.lastPathComponent)" >/dev/null 2>&1
                    $P '%s\\n' "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"success\\",\\"request_id\\":\\"$rid\\",\\"response\\":{}}}"
                    $P '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[]}'
                  fi
                  ;;
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
                *mute*)
                  :
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
                        *hold*)
                          $P '%s\\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu-h1","name":"Bash","input":{"command":"sleep 900; echo \(root.lastPathComponent)","timeout":1000}}]}}'
                          case "$line" in *real*) /bin/sh -c "sleep 900; echo \(root.lastPathComponent)" < /dev/null > /dev/null 2>&1 & ;; esac
                          $P '%s\\n' '{"type":"system","subtype":"task_started","task_id":"h1","tool_use_id":"tu-h1","task_type":"local_bash","description":"sleep 900","is_backgrounded":true}'
                          $P '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"h1","task_type":"local_bash","description":"sleep 900"}]}'
                          $P '%s\\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu-h1","content":"Command running in background with ID: h1. Output is being written to: \(root.appendingPathComponent("h1.output").path). You will be notified when it completes."}]}}'
                          ;;
                        *creep*)
                          $P '%s\\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu-h2","name":"Bash","input":{"command":"sleep 900; echo \(root.lastPathComponent)","description":"Look for the widget","timeout":5000}}]}}'
                          /bin/sh -c "sleep 900; echo \(root.lastPathComponent)" < /dev/null > /dev/null 2>&1 &
                          $P '%s\\n' '{"type":"system","subtype":"task_started","task_id":"h2","tool_use_id":"tu-h2","task_type":"local_bash","description":"Look for the widget","is_backgrounded":false}'
                          $P '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"h2","task_type":"local_bash","description":"Look for the widget"}]}'
                          $P '%s\\n' '{"type":"system","subtype":"task_updated","task_id":"h2","patch":{"is_backgrounded":true}}'
                          $P '%s\\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu-h2","content":"Command did not complete within its 5s timeout and was moved to the background (ID: h2). Output is being written to: \(root.appendingPathComponent("h2.output").path)."}]}}'
                          ;;
                        *delegate*)
                          $P '%s\\n' '{"type":"system","subtype":"task_started","task_id":"a1","task_type":"local_agent","description":"Explore the repository","is_backgrounded":true}'
                          $P '%s\\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a1","task_type":"local_agent","description":"Explore the repository"}]}'
                          ;;
                        *settle*)
                          $P '%s\\n' '{"type":"system","subtype":"task_updated","task_id":"h1","patch":{"status":"completed","end_time":1788972349027}}'
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
    abortGrace: TimeInterval = 10, launchTimeout: TimeInterval = 300,
    turnSilenceTTL: TimeInterval = 7200
) -> SessionStore {
    SessionStore(
        runner: ClaudeRunner(
            claudePath: fake.binary, workdir: fake.root.path, permissionMode: "default"),
        defaults: MachineDefaults(
            modelOverride: "sonnet", effortOverride: "medium", home: NSTemporaryDirectory()),
        storeURL: fake.root.appendingPathComponent("sessions.json"),
        projectsDir: fake.root.path, processTTL: processTTL, processPool: processPool,
        abortGrace: abortGrace, launchTimeout: launchTimeout, turnSilenceTTL: turnSilenceTTL)
}

/// Whether a process whose command line carries `needle` is alive on this machine, read the
/// way the bridge reads it — off the process table, not off anything the fake CLI said.
private func shellAlive(_ needle: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", needle]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let own = String(ProcessInfo.processInfo.processIdentifier)
    return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        .contains { $0.trimmingCharacters(in: .whitespaces) != own }
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
        let carried = await store.backgroundWork(for: session.id)
        #expect(carried?.tasks == 1)
        #expect(carried?.task == "sleep 60")
        let row = await store.list().first { $0.id == session.id }
        #expect(row?.backgroundTasks == 1)
        #expect(row?.backgroundTask == "sleep 60")
        #expect(row?.active == false)

        await waitUntil { await assistantTexts(store, session.id).count == 2 }
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        #expect(await store.backgroundWork(for: session.id) == nil)
        #expect(await store.list().first { $0.id == session.id }?.backgroundTasks == nil)
        #expect(await reports.values.map { $0?.tasks } == [1, nil])
    }

    @Test("A launch that never speaks does not hold the turn open forever")
    func wedgedLaunchIsEnded() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake, launchTimeout: 0.2)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "mute"))
        await waitUntil { await store.hasQueuedOrRunningTurn(session.id) }
        try await Task.sleep(for: .milliseconds(400))
        await store.reapIdleProcesses()

        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        #expect(await !store.hasQueuedOrRunningTurn(session.id))
        #expect(
            await assistantTexts(store, session.id)
                .contains { $0.contains("stopped responding") })
    }

    @Test("A shell the CLI stops speaking about is retired once nothing is running")
    func vanishedShellTaskIsRetired() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "hold"))
        await waitUntil { await store.backgroundWork(for: session.id) != nil }
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        #expect(await store.backgroundWork(for: session.id)?.tasks == 1)

        // The fake never ends h1 and never mentions it again — the shape of a shell killed from
        // somewhere the CLI cannot see. Past the grace, the empty process table settles it.
        await store.reapIdleProcesses(now: Date().addingTimeInterval(120))
        #expect(await store.backgroundWork(for: session.id) == nil)
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

    @Test("A task the CLI only ever stamps an end on is off the set")
    func endedPatchRetiresBackgroundWork() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "hold something for me"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        let carried = await store.backgroundWork(for: session.id)
        #expect(carried?.tasks == 1)
        #expect(carried?.task == "sleep 900")
        #expect(carried?.since != nil)
        #expect(carried?.stalled == nil)

        _ = await store.send(session.id, request: SendRequest(text: "let it settle"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        #expect(await store.backgroundWork(for: session.id) == nil)
        #expect(await store.list().first { $0.id == session.id }?.backgroundTasks == nil)
        #expect(fake.starts == 1)
    }

    @Test("Work goes with the process that was carrying it")
    func replacedProcessTakesItsBackgroundWorkWithIt() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "hold something for me"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        #expect(await store.backgroundWork(for: session.id)?.tasks == 1)

        _ = await store.send(session.id, request: SendRequest(text: "ultracode this one"))
        await waitUntil { await assistantTexts(store, session.id).count == 2 }
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        #expect(fake.starts == 2)
        #expect(await store.backgroundWork(for: session.id) == nil)
        #expect(await store.list().first { $0.id == session.id }?.backgroundTasks == nil)
    }

    /// The harness never ends a background shell, and a shell blocked on a stdin nobody will
    /// write shows nothing for hours: no CPU time, no output. Past its budget and a whole window
    /// of nothing, the bridge ends it, says so in the chat, and the row settles.
    @Test("A shell past its budget with nothing moving for a window is ended and reported")
    func stalledShellIsEndedAndReported() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "hold something real for me"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        await waitUntil { shellAlive("echo \(fake.root.lastPathComponent)") }
        #expect(shellAlive("echo \(fake.root.lastPathComponent)"))

        let later = Date().addingTimeInterval(3600)
        await store.reapIdleProcesses(now: later)
        #expect(shellAlive("echo \(fake.root.lastPathComponent)"))
        #expect(await store.backgroundWork(for: session.id)?.stalled == nil)

        await store.reapIdleProcesses(now: later.addingTimeInterval(ClaudeProcess.stallWindow + 1))
        await waitUntil(.seconds(3)) { !shellAlive("echo \(fake.root.lastPathComponent)") }
        #expect(!shellAlive("echo \(fake.root.lastPathComponent)"))
        let notice = await assistantTexts(store, session.id).last ?? ""
        #expect(notice.contains("Ended a stuck shell"))
        #expect(notice.contains("sleep 900"))
        let written = (try? String(contentsOf: fake.root.appendingPathComponent("h1.output"), encoding: .utf8)) ?? ""
        #expect(written.contains("[claude-bridge] Ended this command"))

        await store.reapIdleProcesses(now: later.addingTimeInterval(ClaudeProcess.stallWindow + 60))
        #expect(await store.backgroundWork(for: session.id) == nil)
    }

    @Test("A shell that keeps producing is never mistaken for a stuck one")
    func busyShellIsLeftAlone() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "hold something real for me"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        await waitUntil { shellAlive("echo \(fake.root.lastPathComponent)") }

        let later = Date().addingTimeInterval(3600)
        await store.reapIdleProcesses(now: later)
        try "a line of output".write(
            to: fake.root.appendingPathComponent("h1.output"), atomically: true, encoding: .utf8)
        await store.reapIdleProcesses(now: later.addingTimeInterval(ClaudeProcess.stallWindow + 1))
        #expect(shellAlive("echo \(fake.root.lastPathComponent)"))
        #expect(await store.backgroundWork(for: session.id)?.stalled == nil)
        _ = await store.stopBackgroundWork(session.id)
    }

    @Test("Stopping background work from the app ends the shell and says so")
    func stopEndsBackgroundShells() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        #expect(await store.stopBackgroundWork(session.id).refusal != nil)

        _ = await store.send(session.id, request: SendRequest(text: "hold something real for me"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        await waitUntil { shellAlive("echo \(fake.root.lastPathComponent)") }

        let result = await store.stopBackgroundWork(session.id)
        #expect(result.ended == 1)
        #expect(result.refusal == nil)
        await waitUntil(.seconds(3)) { !shellAlive("echo \(fake.root.lastPathComponent)") }
        #expect(!shellAlive("echo \(fake.root.lastPathComponent)"))
        #expect((await assistantTexts(store, session.id).last ?? "").contains("Stopped background work"))
    }

    @Test("Background work that is an agent is stopped the same way a shell is")
    func stopEndsAgentWork() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "delegate this one"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        await waitUntil { await store.backgroundWork(for: session.id) != nil }

        let result = await store.stopBackgroundWork(session.id)
        #expect(result.ended == 1)
        #expect(result.refusal == nil)
        #expect(await store.backgroundWork(for: session.id) == nil)
        let notice = await assistantTexts(store, session.id).last ?? ""
        #expect(notice.contains("Stopped background work"))
        #expect(notice.contains("Explore the repository"))
    }

    @Test("A command the harness backgrounded is ended by hand when the CLI will not")
    func stopEndsHarnessBackgroundedShellWithoutTheCLI() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        try Data().write(to: fake.root.appendingPathComponent("nostop"))
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "creep along quietly"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        await waitUntil { shellAlive("sleep 900; echo \(fake.root.lastPathComponent)") }
        #expect(await store.backgroundWork(for: session.id)?.task == "Look for the widget")

        let result = await store.stopBackgroundWork(session.id)
        #expect(result.ended == 1)
        #expect(result.refusal == nil)
        await waitUntil(.seconds(3)) {
            !shellAlive("sleep 900; echo \(fake.root.lastPathComponent)")
        }
        #expect(!shellAlive("sleep 900; echo \(fake.root.lastPathComponent)"))
        let written =
            (try? String(contentsOf: fake.root.appendingPathComponent("h2.output"), encoding: .utf8))
            ?? ""
        #expect(written.contains("[claude-bridge] Ended this command"))
    }

    @Test("Work the CLI will not stop and the machine cannot find is refused in its own words")
    func stopSaysSoWhenNothingCouldBeEnded() async throws {
        let fake = try StdinClaude()
        defer { fake.cleanUp() }
        try Data().write(to: fake.root.appendingPathComponent("nostop"))
        let store = makeStore(fake)
        let session = await store.create(CreateRequest(directory: fake.root.path))

        _ = await store.send(session.id, request: SendRequest(text: "delegate this one"))
        await waitUntil { await !store.hasQueuedOrRunningTurn(session.id) }
        await waitUntil { await store.backgroundWork(for: session.id) != nil }

        let result = await store.stopBackgroundWork(session.id)
        #expect(result.ended == 0)
        #expect(result.refusal?.contains("did not answer the stop") == true)
        #expect(await store.backgroundWork(for: session.id) != nil)
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
