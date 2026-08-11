import Foundation
import Hummingbird

func env(_ key: String, _ fallback: String) -> String {
    ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
}

/// Refuses to start when the server would hand out an unauthenticated bypass-permissions Claude:
/// in that configuration any client that can reach the port can run arbitrary commands as this user.
func enforceFailClosedStartup(password: String, permissionMode: String) {
    guard password.isEmpty, permissionMode == "bypassPermissions" else { return }
    FileHandle.standardError.write(
        Data(
            """
            claude-bridge: refusing to start.

            BRIDGE_PASSWORD is empty while BRIDGE_PERMISSION=bypassPermissions (the default).
            In this mode Claude runs with --dangerously-skip-permissions, so any client that
            can reach this server can execute arbitrary shell commands as this user, with no
            authentication.

            Fix one of:
              1. Set BRIDGE_PASSWORD to a secret. Clients authenticate with HTTP Basic auth
                 (username "claude").
              2. Set BRIDGE_PERMISSION=default so Claude keeps its normal permission prompts.

            """.utf8))
    exit(1)
}

/// Notices external sessions going idle even when no SSE subscriber is attached
/// (the watcher's in-tail idle detection only runs while someone is streaming):
/// sweeps transcript activity and, on the active-to-idle edge, triggers the
/// coalesced silent usage push.
func startExternalIdleSweep(index: TranscriptIndex, store: SessionStore) {
    Task {
        var wasActive = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            let active = await index.anyActivity(within: 30)
            if wasActive, !active {
                await store.devicePusher.noteExternalIdle()
            }
            wasActive = active
        }
    }
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let port = Int(env("BRIDGE_PORT", "4098")) ?? 4098
let bindAddress = env("BRIDGE_BIND", "127.0.0.1")
let password = env("BRIDGE_PASSWORD", "")
let workdir = env("BRIDGE_WORKDIR", "\(home)/agentapi-workdir")
let claudePath = env("BRIDGE_CLAUDE", "\(home)/.local/bin/claude")
let machineDefaults = MachineDefaults(
    modelOverride: ProcessInfo.processInfo.environment["BRIDGE_MODEL"].flatMap {
        $0.isEmpty ? nil : $0
    },
    effortOverride: ProcessInfo.processInfo.environment["BRIDGE_EFFORT"].flatMap {
        $0.isEmpty ? nil : $0
    },
    home: home)
let storeURL = URL(fileURLWithPath: env("BRIDGE_STORE", "\(home)/.claude-bridge/sessions.json"))
let permissionMode = env("BRIDGE_PERMISSION", "bypassPermissions")
let projectsDir = env("BRIDGE_PROJECTS", "\(home)/.claude/projects")

enforceFailClosedStartup(password: password, permissionMode: permissionMode)

/// Read before anything can rewrite it. The stamp names the build that produced *this* process, and
/// an update landing later replaces the file — so a lazy first read halfway through the day would
/// hand back the version of a binary nobody has started yet, which is the one thing it exists to
/// prevent saying.
_ = BridgeVersion.running

try? FileManager.default.createDirectory(
    at: URL(fileURLWithPath: workdir), withIntermediateDirectories: true)

let apnsKeyPath = env("BRIDGE_APNS_KEY", "")
let apnsClient: APNSClient? = {
    guard !apnsKeyPath.isEmpty,
        let pem = try? String(contentsOfFile: apnsKeyPath, encoding: .utf8)
    else { return nil }
    return APNSClient(config: APNSClient.Config(
        keyPEM: pem,
        keyID: env("BRIDGE_APNS_KEY_ID", ""),
        teamID: env("BRIDGE_APNS_TEAM_ID", ""),
        topic: env("BRIDGE_APNS_TOPIC", "com.guitaripod.tailscode.push-type.liveactivity")))
}()

let store = SessionStore(
    runner: ClaudeRunner(claudePath: claudePath, workdir: workdir, permissionMode: permissionMode),
    defaults: machineDefaults, storeURL: storeURL,
    projectsDir: projectsDir,
    pusher: LiveActivityPusher(
        client: apnsClient,
        activitiesURL: storeURL.deletingLastPathComponent()
            .appendingPathComponent("live-activities.json")),
    devicePusher: DevicePusher(
        client: apnsClient,
        devicesURL: storeURL.deletingLastPathComponent().appendingPathComponent("devices.json")),
    autoResumeDefault: env("BRIDGE_AUTO_RESUME", "0") == "1")

let router = Router()
if !password.isEmpty {
    router.middlewares.add(BasicAuthMiddleware(username: "claude", password: password))
}
let index = TranscriptIndex(root: URL(fileURLWithPath: projectsDir), defaults: machineDefaults)
let watcher = TranscriptWatcher(index: index, store: store)
let hub = Hub()
await store.attach(index: index)
await store.installHubTap { id, event in
    Task { await hub.publish(.session(id: id, event: event)) }
}
let observer = ObserverLoop(index: index, store: store, hub: hub)
Task { await observer.run() }
Task { await hub.runHeartbeats() }
await store.pusher.endOrphans()
// Before anything is served: decide what became of every turn that was open when this process last
// stopped. A client that connects first would otherwise be told a cut-off conversation is idle.
await store.recoverJournaledTurns()
let updater = UpdateService(stateDirectory: storeURL.deletingLastPathComponent())
await updater.resume()
let auth = AuthService(claudePath: claudePath, workdir: workdir)
registerRoutes(
    router, store: store, index: index, watcher: watcher, updater: updater, auth: auth,
    hub: hub, observer: observer, defaults: machineDefaults, hasAuth: !password.isEmpty,
    projectsDir: projectsDir)
startExternalIdleSweep(index: index, store: store)

let app = Application(
    router: router,
    configuration: .init(address: .hostname(bindAddress, port: port), serverName: "claude-bridge"))

print("claude-bridge listening on \(bindAddress):\(port) — workdir \(workdir), claude \(claudePath)")
try await app.runService()
