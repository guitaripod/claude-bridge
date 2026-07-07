import Foundation
import Hummingbird

func env(_ key: String, _ fallback: String) -> String {
    ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let port = Int(env("BRIDGE_PORT", "4098")) ?? 4098
let password = env("BRIDGE_PASSWORD", "")
let workdir = env("BRIDGE_WORKDIR", "\(home)/agentapi-workdir")
let claudePath = env("BRIDGE_CLAUDE", "\(home)/.local/bin/claude")
let defaultModel = env("BRIDGE_MODEL", "sonnet")
let defaultEffort = env("BRIDGE_EFFORT", "medium")
let storeURL = URL(fileURLWithPath: env("BRIDGE_STORE", "\(home)/.claude-bridge/sessions.json"))

try? FileManager.default.createDirectory(
    at: URL(fileURLWithPath: workdir), withIntermediateDirectories: true)

let store = SessionStore(
    runner: ClaudeRunner(claudePath: claudePath, workdir: workdir),
    defaultModel: defaultModel, defaultEffort: defaultEffort, storeURL: storeURL)

let router = Router()
if !password.isEmpty {
    router.middlewares.add(BasicAuthMiddleware(username: "claude", password: password))
}
registerRoutes(router, store: store, agentModel: defaultModel)

let app = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: port), serverName: "claude-bridge"))

print("claude-bridge listening on 0.0.0.0:\(port) — workdir \(workdir), claude \(claudePath)")
try await app.runService()
