import Foundation

/// A slash command a client can run in a session. `name` carries no leading slash.
struct AgentCommand: Codable, Sendable {
    var name: String
    var description: String
    var argumentHint: String?
    /// `builtin`, `user`, `project`, or `plugin` — lets a client group the catalog by where a
    /// command comes from.
    var source: String
    /// The plugin or project directory a non-builtin command came from.
    var scope: String?
}

/// Discovers the slash commands a headless `claude -p` run will actually resolve.
///
/// Two kinds ship here. The built-ins are hand-picked from the CLI's own registry: only commands
/// flagged `supportsNonInteractive` (or `type: "prompt"`, which is pure prompt expansion) survive
/// `-p`, and of those only the ones that mean something on a phone are listed — a `/model` or
/// `/clear` row would be a worse version of a control the app already has natively. The rest are
/// read off disk, because custom commands are per-machine and per-project and can only be
/// discovered, never hardcoded.
enum CommandCatalog {
    static func all(home: String, directory: String?) -> [AgentCommand] {
        builtins + userCommands(home: home) + projectCommands(directory: directory)
            + pluginCommands(home: home)
    }

    static let builtins: [AgentCommand] = [
        AgentCommand(
            name: "goal",
            description: "Keep working until a condition is met",
            argumentHint: "<condition> | clear", source: "builtin", scope: nil),
        AgentCommand(
            name: "recap",
            description: "One-line recap of where this session stands",
            argumentHint: nil, source: "builtin", scope: nil),
        AgentCommand(
            name: "compact",
            description: "Summarize the conversation so far to free up context",
            argumentHint: "[instructions]", source: "builtin", scope: nil),
        AgentCommand(
            name: "context",
            description: "Show what is filling the context window",
            argumentHint: nil, source: "builtin", scope: nil),
        AgentCommand(
            name: "usage",
            description: "Session cost and plan limits",
            argumentHint: nil, source: "builtin", scope: nil),
        AgentCommand(
            name: "init",
            description: "Write a CLAUDE.md documenting this codebase",
            argumentHint: nil, source: "builtin", scope: nil),
        AgentCommand(
            name: "review",
            description: "Review a GitHub pull request",
            argumentHint: "[pr number]", source: "builtin", scope: nil),
    ]

    private static func userCommands(home: String) -> [AgentCommand] {
        commands(in: "\(home)/.claude/commands", source: "user", scope: nil)
    }

    private static func projectCommands(directory: String?) -> [AgentCommand] {
        guard let directory, !directory.isEmpty else { return [] }
        return commands(
            in: "\(directory)/.claude/commands", source: "project",
            scope: (directory as NSString).lastPathComponent)
    }

    /// Enabled plugins each contribute `commands/*.md` under the namespace `plugin:command`.
    private static func pluginCommands(home: String) -> [AgentCommand] {
        let manifest = URL(fileURLWithPath: "\(home)/.claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: manifest),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let plugins = object["plugins"] as? [String: Any]
        else { return [] }
        return plugins.keys.sorted().flatMap { key -> [AgentCommand] in
            guard let installs = plugins[key] as? [[String: Any]],
                let path = installs.last?["installPath"] as? String
            else { return [] }
            let plugin = key.split(separator: "@").first.map(String.init) ?? key
            return commands(in: "\(path)/commands", source: "plugin", scope: plugin)
                .map { command in
                    var namespaced = command
                    namespaced.name = "\(plugin):\(command.name)"
                    return namespaced
                }
        }
    }

    /// Markdown command files, recursing one level of namespacing (`sub/foo.md` → `sub:foo`).
    private static func commands(in root: String, source: String, scope: String?, prefix: String = "")
        -> [AgentCommand]
    {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles)
        else { return [] }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { entry -> [AgentCommand] in
                let isDirectory =
                    (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                let stem = entry.deletingPathExtension().lastPathComponent
                if isDirectory {
                    guard prefix.isEmpty else { return [] }
                    return commands(
                        in: entry.path, source: source, scope: scope, prefix: "\(stem):")
                }
                guard entry.pathExtension == "md" else { return [] }
                let header = frontmatter(at: entry)
                return [
                    AgentCommand(
                        name: prefix + stem,
                        description: header.description ?? "Custom command",
                        argumentHint: header.argumentHint, source: source, scope: scope)
                ]
            }
    }

    private static func frontmatter(at url: URL) -> (description: String?, argumentHint: String?) {
        guard let handle = FileHandle(forReadingAtPath: url.path),
            let data = try? handle.read(upToCount: 4096)
        else { return (nil, nil) }
        try? handle.close()
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("---") else { return (nil, nil) }
        var description: String?
        var hint: String?
        for line in text.split(separator: "\n").dropFirst() {
            if line.hasPrefix("---") { break }
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch parts[0] {
            case "description": description = value.isEmpty ? nil : value
            case "argument-hint": hint = value.isEmpty ? nil : value
            default: break
            }
        }
        return (description, hint)
    }
}
