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
/// Three kinds ship here. The built-ins are hand-picked from the CLI's own registry: only commands
/// flagged `supportsNonInteractive` (or `type: "prompt"`, which is pure prompt expansion) survive
/// `-p`, and of those only the ones that mean something on a phone are listed — a `/model` or
/// `/clear` row would be a worse version of a control the app already has natively. Command files
/// are read off disk, because custom commands are per-machine and per-project and can only be
/// discovered, never hardcoded. And skills are slash commands too: a typed `/name` expands a
/// `SKILL.md` (user, project, or plugin) or runs a saved workflow exactly the same way under `-p`,
/// so a catalog without them would hide most of what the machine can actually do.
enum CommandCatalog {
    static func all(home: String, directory: String?) -> [AgentCommand] {
        var catalog =
            builtins + userCommands(home: home) + projectCommands(directory: directory)
            + pluginCommands(home: home)
        var names = Set(catalog.map(\.name))
        let skills =
            userSkills(home: home) + projectSkills(directory: directory)
            + pluginSkills(home: home) + workflows(home: home)
        for skill in skills where names.insert(skill.name).inserted {
            catalog.append(skill)
        }
        return catalog
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
        plugins(home: home).flatMap { plugin in
            commands(in: "\(plugin.path)/commands", source: "plugin", scope: plugin.name)
                .map { command in
                    var namespaced = command
                    namespaced.name = "\(plugin.name):\(command.name)"
                    return namespaced
                }
        }
    }

    private static func userSkills(home: String) -> [AgentCommand] {
        skills(in: "\(home)/.claude/skills", scope: nil)
    }

    private static func projectSkills(directory: String?) -> [AgentCommand] {
        guard let directory, !directory.isEmpty else { return [] }
        return skills(
            in: "\(directory)/.claude/skills",
            scope: (directory as NSString).lastPathComponent)
    }

    /// Plugin skills live beside plugin commands and share their namespace: `plugin:skill`.
    private static func pluginSkills(home: String) -> [AgentCommand] {
        plugins(home: home).flatMap { plugin in
            skills(in: "\(plugin.path)/skills", scope: plugin.name)
                .map { skill in
                    var namespaced = skill
                    namespaced.name = "\(plugin.name):\(skill.name)"
                    return namespaced
                }
        }
    }

    private static func plugins(home: String) -> [(name: String, path: String)] {
        let manifest = URL(fileURLWithPath: "\(home)/.claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: manifest),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let plugins = object["plugins"] as? [String: Any]
        else { return [] }
        return plugins.keys.sorted().compactMap { key in
            guard let installs = plugins[key] as? [[String: Any]],
                let path = installs.last?["installPath"] as? String
            else { return nil }
            return (key.split(separator: "@").first.map(String.init) ?? key, path)
        }
    }

    /// One skill per `<root>/<name>/SKILL.md`, unless its author marked it not user-invocable.
    private static func skills(in root: String, scope: String?) -> [AgentCommand] {
        directoryEntries(root)
            .compactMap { entry -> AgentCommand? in
                let manifest = entry.appendingPathComponent("SKILL.md")
                guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
                let header = frontmatter(at: manifest)
                guard header.userInvocable else { return nil }
                return AgentCommand(
                    name: entry.lastPathComponent,
                    description: header.description ?? "Skill",
                    argumentHint: header.argumentHint, source: "skill", scope: scope)
            }
    }

    /// Saved workflows (`~/.claude/workflows/*.js`) resolve as slash commands too. Each script
    /// opens with a pure-literal `export const meta = {...}`, so its name and description read
    /// out with a string scan rather than a JavaScript engine.
    private static func workflows(home: String) -> [AgentCommand] {
        directoryEntries("\(home)/.claude/workflows")
            .compactMap { entry -> AgentCommand? in
                guard entry.pathExtension == "js" else { return nil }
                let meta = workflowMeta(at: entry)
                return AgentCommand(
                    name: meta.name ?? entry.deletingPathExtension().lastPathComponent,
                    description: meta.description ?? "Saved workflow",
                    argumentHint: nil, source: "skill", scope: "workflow")
            }
    }

    private static func workflowMeta(at url: URL) -> (name: String?, description: String?) {
        guard let handle = FileHandle(forReadingAtPath: url.path),
            let data = try? handle.read(upToCount: 8192)
        else { return (nil, nil) }
        try? handle.close()
        let text = String(decoding: data, as: UTF8.self)
        return (metaString("name", in: text), metaString("description", in: text))
    }

    private static func metaString(_ key: String, in text: String) -> String? {
        guard let match = text.range(of: "\\b\(key)\\s*:\\s*[\"'`]", options: .regularExpression)
        else { return nil }
        let quote = text[text.index(before: match.upperBound)]
        guard let close = text[match.upperBound...].firstIndex(of: quote) else { return nil }
        let value = String(text[match.upperBound..<close])
        return value.isEmpty ? nil : value
    }

    /// Markdown command files, recursing one level of namespacing (`sub/foo.md` → `sub:foo`).
    private static func commands(in root: String, source: String, scope: String?, prefix: String = "")
        -> [AgentCommand]
    {
        directoryEntries(root)
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

    /// Sorted directory listing that survives the root being a symlink — `~/.claude/skills` and
    /// `~/.claude/workflows` typically link into a dotfiles checkout, and on Linux, Foundation's
    /// URL-based `contentsOfDirectory` answers a symlinked root with nothing.
    private static func directoryEntries(_ root: String) -> [URL] {
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: resolved, includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles)
        else { return [] }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private struct Frontmatter {
        var description: String?
        var argumentHint: String?
        var userInvocable = true
    }

    private static func frontmatter(at url: URL) -> Frontmatter {
        guard let handle = FileHandle(forReadingAtPath: url.path),
            let data = try? handle.read(upToCount: 8192)
        else { return Frontmatter() }
        try? handle.close()
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("---") else { return Frontmatter() }
        var header = Frontmatter()
        for line in text.split(separator: "\n").dropFirst() {
            if line.hasPrefix("---") { break }
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch parts[0] {
            case "description": header.description = value.isEmpty ? nil : value
            case "argument-hint": header.argumentHint = value.isEmpty ? nil : value
            case "user-invocable": header.userInvocable = value != "false"
            default: break
            }
        }
        return header
    }
}
