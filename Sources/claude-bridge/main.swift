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

let home = FileManager.default.homeDirectoryForCurrentUser.path
let port = Int(env("BRIDGE_PORT", "4098")) ?? 4098
let bindAddress = env("BRIDGE_BIND", "127.0.0.1")
let password = env("BRIDGE_PASSWORD", "")
let workdir = env("BRIDGE_WORKDIR", "\(home)/agentapi-workdir")
let claudePath = env("BRIDGE_CLAUDE", "\(home)/.local/bin/claude")
let defaultModel = env("BRIDGE_MODEL", "sonnet")
let defaultEffort = env("BRIDGE_EFFORT", "medium")
let storeURL = URL(fileURLWithPath: env("BRIDGE_STORE", "\(home)/.claude-bridge/sessions.json"))
let permissionMode = env("BRIDGE_PERMISSION", "bypassPermissions")
let projectsDir = env("BRIDGE_PROJECTS", "\(home)/.claude/projects")

enforceFailClosedStartup(password: password, permissionMode: permissionMode)

try? FileManager.default.createDirectory(
    at: URL(fileURLWithPath: workdir), withIntermediateDirectories: true)

let apnsKeyPath = env("BRIDGE_APNS_KEY", "")
let apnsConfig: LiveActivityPusher.Config? = {
    guard !apnsKeyPath.isEmpty,
        let pem = try? String(contentsOfFile: apnsKeyPath, encoding: .utf8)
    else { return nil }
    return LiveActivityPusher.Config(
        keyPEM: pem,
        keyID: env("BRIDGE_APNS_KEY_ID", ""),
        teamID: env("BRIDGE_APNS_TEAM_ID", ""),
        topic: env("BRIDGE_APNS_TOPIC", "com.guitaripod.tailscode.push-type.liveactivity"))
}()

let store = SessionStore(
    runner: ClaudeRunner(claudePath: claudePath, workdir: workdir, permissionMode: permissionMode),
    defaultModel: defaultModel, defaultEffort: defaultEffort, storeURL: storeURL,
    projectsDir: projectsDir, pusher: LiveActivityPusher(config: apnsConfig))

let router = Router()
if !password.isEmpty {
    router.middlewares.add(BasicAuthMiddleware(username: "claude", password: password))
}
let index = TranscriptIndex(
    root: URL(fileURLWithPath: projectsDir), defaultModel: defaultModel,
    defaultEffort: defaultEffort)
let watcher = TranscriptWatcher(index: index, store: store)
registerRoutes(router, store: store, index: index, watcher: watcher, agentModel: defaultModel)

let app = Application(
    router: router,
    configuration: .init(address: .hostname(bindAddress, port: port), serverName: "claude-bridge"))

print("claude-bridge listening on \(bindAddress):\(port) — workdir \(workdir), claude \(claudePath)")
try await app.runService()
