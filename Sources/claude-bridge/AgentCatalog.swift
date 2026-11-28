import Crypto
import Foundation

/// How an agent is started when it is not already on the machine's PATH, as the ACP registry
/// describes it: a Node package run by `npx`, a Python package run by `uvx`, or an archive per
/// platform downloaded once and checked against its sha256.
enum AgentDistribution: Sendable, Equatable, Codable {
    case npx(package: String, args: [String], env: [String: String])
    case uvx(package: String, command: String?, args: [String], env: [String: String])
    case binary(archive: String, command: String, args: [String], sha256: String?)

    var runtime: String? {
        switch self {
        case .npx: return "node"
        case .uvx: return "uv"
        case .binary: return nil
        }
    }

    var kindWord: String {
        switch self {
        case .npx: return "npx"
        case .uvx: return "uvx"
        case .binary: return "download"
        }
    }
}

/// How an agent that needs a model is given one. Hermes is set through its own config command;
/// an agent that reads an OpenAI-compatible endpoint from its environment is handed one there.
enum AgentBrainStyle: String, Sendable, Codable {
    case hermes
    case openAIEnvironment
}

/// What the bridge knows about one agent before it has ever run it.
struct AgentRecipe: Sendable {
    var id: String
    var name: String
    var description: String?
    /// Commands that, found on PATH, are this agent already installed — the person's own copy,
    /// signed in the way they signed it in.
    var commands: [String]
    /// What the found command is run with, for an agent the registry does not describe.
    var args: [String]
    var fallback: AgentDistribution?
    /// Where a copy comes from when the machine has none and neither npx nor uvx carries one.
    var release: AgentRelease?
    var keys: [AgentKeySpec] = []
    var brain: AgentBrainStyle?
    var website: String?
    /// The first version that speaks ACP. A copy on PATH older than this is not this agent yet.
    var minimumVersion: String?
    /// Whether the agent's own sign-in is the way in and a key only another way, so an agent that
    /// asks to be signed in reads as needing a sign-in rather than a key.
    var signInFirst = false
    /// Whether the machine's list names this agent before anybody added it.
    var featured = false
}

struct AgentKeySpec: Sendable, Codable, Equatable {
    var env: String
    var name: String
    var url: String?
    /// The agent's own sign-in method this key answers, which the bridge chooses for it whenever
    /// the agent asks to be signed in and the key is kept.
    var method: String?
}

/// The newest release of a GitHub repository, as the place an agent is downloaded from: the
/// archive named for this machine, checked against the digest GitHub publishes beside it.
struct AgentRelease: Sendable, Equatable {
    var repository: String
    /// The archive's name for each platform the registry would name (`linux-x86_64`, …).
    var assets: [String: String]
    /// The executable inside the archive.
    var command: String
    var args: [String]

    var address: String { "https://api.github.com/repos/\(repository)/releases/latest" }

    var runsHere: Bool { assets[AgentPlatform.current.key] != nil }

    /// GitHub's answer for the newest release, read into the version and the download for this
    /// machine. An archive with no published digest is not offered: nothing would prove it arrived
    /// whole.
    func resolve(_ data: Data, platform: String = AgentPlatform.current.key)
        -> (version: String, distribution: AgentDistribution)?
    {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["tag_name"] as? String, !version.isEmpty,
            let wanted = assets[platform],
            let asset = (object["assets"] as? [[String: Any]])?.first(where: { $0["name"] as? String == wanted }),
            let archive = asset["browser_download_url"] as? String,
            let digest = asset["digest"] as? String, digest.hasPrefix("sha256:")
        else { return nil }
        return (
            version.hasPrefix("v") ? String(version.dropFirst()) : version,
            .binary(
                archive: archive, command: command, args: args,
                sha256: String(digest.dropFirst("sha256:".count)))
        )
    }
}

/// A version as dotted numbers, compared number by number: `1.5.18` is newer than `1.5.2`.
enum AgentVersion {
    static func numbers(_ text: String) -> [Int]? {
        let token = text.split(whereSeparator: { $0.isWhitespace }).first { word in
            word.first?.isNumber == true || (word.first == "v" && word.dropFirst().first?.isNumber == true)
        }
        guard let token else { return nil }
        let parts = token.drop { $0 == "v" }.prefix { $0.isNumber || $0 == "." }
            .split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }

    static func isOlder(_ version: String, than minimum: String) -> Bool {
        guard let have = numbers(version), let need = numbers(minimum) else { return false }
        for index in 0..<max(have.count, need.count) {
            let left = index < have.count ? have[index] : 0
            let right = index < need.count ? need[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// One row of the ACP registry, as much of it as this bridge reads.
struct RegistryAgent: Sendable, Codable, Equatable {
    var id: String
    var name: String
    var version: String
    var description: String?
    var icon: String?
    var website: String?
    var authors: [String]?
    var distribution: AgentDistribution?

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, icon, website, authors, distribution
    }

    init(
        id: String, name: String, version: String, description: String? = nil,
        icon: String? = nil, website: String? = nil, authors: [String]? = nil,
        distribution: AgentDistribution? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.icon = icon
        self.website = website
        self.authors = authors
        self.distribution = distribution
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = (try? container.decode(String.self, forKey: .version)) ?? ""
        description = try? container.decode(String.self, forKey: .description)
        icon = try? container.decode(String.self, forKey: .icon)
        website = try? container.decode(String.self, forKey: .website)
        authors = try? container.decode([String].self, forKey: .authors)
        distribution = try? container.decode(AgentDistribution.self, forKey: .distribution)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(website, forKey: .website)
        try container.encodeIfPresent(authors, forKey: .authors)
        try container.encodeIfPresent(distribution, forKey: .distribution)
    }
}

extension AgentDistribution {
    private struct Wire: Codable {
        struct Package: Codable {
            var package: String
            var args: [String]?
            var env: [String: String]?
        }
        struct Archive: Codable {
            var archive: String
            var cmd: String
            var args: [String]?
            var sha256: String?
        }
        var npx: Package?
        var uvx: Package?
        var binary: [String: Archive]?
    }

    init(from decoder: Decoder) throws {
        let wire = try Wire(from: decoder)
        if let archives = wire.binary, let archive = archives[AgentPlatform.current.key] {
            self = .binary(
                archive: archive.archive, command: archive.cmd, args: archive.args ?? [],
                sha256: archive.sha256)
        } else if let npx = wire.npx {
            self = .npx(package: npx.package, args: npx.args ?? [], env: npx.env ?? [:])
        } else if let uvx = wire.uvx {
            self = .uvx(package: uvx.package, command: nil, args: uvx.args ?? [], env: uvx.env ?? [:])
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "no distribution for this platform"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var wire = Wire()
        switch self {
        case .npx(let package, let args, let env):
            wire.npx = .init(package: package, args: args, env: env)
        case .uvx(let package, _, let args, let env):
            wire.uvx = .init(package: package, args: args, env: env)
        case .binary(let archive, let command, let args, let sha256):
            wire.binary = [
                AgentPlatform.current.key: .init(archive: archive, cmd: command, args: args, sha256: sha256)
            ]
        }
        try wire.encode(to: encoder)
    }
}

/// The registry's name for this machine: `linux-x86_64`, `darwin-aarch64`, …
struct AgentPlatform: Sendable {
    var os: String
    var arch: String
    var key: String { "\(os)-\(arch)" }

    static let current: AgentPlatform = {
        #if os(macOS)
            let os = "darwin"
        #else
            let os = "linux"
        #endif
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let arch = (machine == "arm64" || machine == "aarch64") ? "aarch64" : "x86_64"
        return AgentPlatform(os: os, arch: arch)
    }()
}

/// The agents this bridge knows by heart. Claude Code is not among them: it is native here, and
/// the ACP adapter for it would be a second, worse road to the same CLI.
enum AgentRecipes {
    static let all: [AgentRecipe] = [
        AgentRecipe(
            id: "hermes", name: "Hermes",
            description: "Nous Research's agent that remembers, learns skills and runs on any model.",
            commands: ["hermes"], args: ["acp"],
            fallback: .uvx(package: "hermes-agent[acp]", command: "hermes", args: ["acp"], env: [:]),
            brain: .hermes, website: "https://hermes-agent.nousresearch.com", featured: true),
        AgentRecipe(
            id: "gemini", name: "Gemini CLI", commands: ["gemini"], args: ["--acp"],
            fallback: .npx(package: "@google/gemini-cli", args: ["--acp"], env: [:]),
            keys: [
                AgentKeySpec(
                    env: "GEMINI_API_KEY", name: "Gemini API key",
                    url: "https://aistudio.google.com/apikey")
            ]),
        AgentRecipe(
            id: "codex-acp", name: "Codex", commands: ["codex-acp"], args: [],
            fallback: .npx(package: "@agentclientprotocol/codex-acp", args: [], env: [:]),
            keys: [
                AgentKeySpec(
                    env: "OPENAI_API_KEY", name: "OpenAI API key",
                    url: "https://platform.openai.com/api-keys")
            ]),
        AgentRecipe(
            id: "deepseek-harness", name: "DeepSeek Harness",
            description: "DeepSeek's open-source coding agent, on DeepSeek V4 or any provider it is set up with.",
            commands: ["dsh"], args: ["--profile", "acp"],
            fallback: .npx(package: "@deepseek-ai/dsh", args: ["--profile", "acp"], env: [:]),
            keys: [
                AgentKeySpec(
                    env: "DEEPSEEK_API_KEY", name: "DeepSeek API key",
                    url: "https://platform.deepseek.com/api_keys")
            ],
            website: "https://github.com/deepseek-ai/deepseek-harness"),
        AgentRecipe(
            id: "antigravity-acp", name: "Antigravity",
            description: "Google's coding agent on Gemini, with your Google AI plan or a Gemini API key.",
            commands: ["agy", "antigravity"], args: ["acp"],
            release: AgentRelease(
                repository: "google-antigravity/antigravity-cli",
                assets: [
                    "linux-x86_64": "agy_cli_linux_x64.tar.gz",
                    "linux-aarch64": "agy_cli_linux_arm64.tar.gz",
                    "darwin-aarch64": "agy_cli_mac_arm64.tar.gz",
                    "darwin-x86_64": "agy_cli_mac_x64.tar.gz",
                ],
                command: "./antigravity", args: ["acp"]),
            keys: [
                AgentKeySpec(
                    env: "GEMINI_API_KEY", name: "Gemini API key",
                    url: "https://aistudio.google.com/apikey", method: "gemini-api-key")
            ],
            website: "https://antigravity.google", minimumVersion: "1.5.0", signInFirst: true,
            featured: true),
        AgentRecipe(id: "goose", name: "goose", commands: ["goose"], args: ["acp"]),
        AgentRecipe(id: "kimi", name: "Kimi CLI", commands: ["kimi"], args: ["acp"]),
        AgentRecipe(
            id: "qwen-code", name: "Qwen Code", commands: ["qwen"], args: ["--acp"],
            fallback: .npx(package: "@qwen-code/qwen-code", args: ["--acp"], env: [:]),
            brain: .openAIEnvironment),
        AgentRecipe(
            id: "github-copilot-cli", name: "GitHub Copilot", commands: ["copilot"], args: ["--acp"]),
        AgentRecipe(id: "opencode", name: "OpenCode", commands: ["opencode"], args: ["acp"]),
        AgentRecipe(id: "cursor", name: "Cursor", commands: ["cursor-agent"], args: ["acp"]),
        AgentRecipe(id: "kiro", name: "Kiro CLI", commands: ["kiro-cli"], args: ["acp"]),
        AgentRecipe(id: "auggie", name: "Auggie CLI", commands: ["auggie"], args: ["--acp"]),
        AgentRecipe(id: "mistral-vibe", name: "Mistral Vibe", commands: ["vibe-acp"], args: []),
    ]

    static let excludedRegistryIDs: Set<String> = ["claude-acp", "opencode-v2"]

    static func recipe(_ id: String) -> AgentRecipe? { all.first { $0.id == id } }
}

/// What this bridge remembers about agents between runs: which were added, where an installed one
/// lives, what the last proof found, and what brain each was given. Keys are not here — they live
/// one file per agent, readable only by this user.
struct AgentLedger: Codable, Sendable, Equatable {
    struct Probe: Codable, Sendable, Equatable {
        var state: String
        var checkedAt: Date
        var version: String?
        var models: [AcpSessionFacts.Choice]
        var currentModel: String?
        var efforts: [AcpSessionFacts.Choice]
        var failure: String?
        var authMethods: [AcpAgentFacts.AuthMethod]
        /// The thinking levels each model takes, for an agent whose models do not all take the
        /// same ones. Absent for an agent that offers one list for every model.
        var modelEfforts: [String: [String]]?
    }

    struct Installed: Codable, Sendable, Equatable {
        var version: String
        var executable: String
        var args: [String]
    }

    struct Brain: Codable, Sendable, Equatable {
        var kind: String
        var name: String
        var baseURL: String?
        var model: String?
        var provider: String?
    }

    var added: [String] = []
    var installed: [String: Installed] = [:]
    var probes: [String: Probe] = [:]
    var brains: [String: Brain] = [:]
    /// Agents someone added from a custom command line, by id.
    var custom: [String: CustomAgent] = [:]

    struct CustomAgent: Codable, Sendable, Equatable {
        var name: String
        var command: String
        var args: [String]
    }

    static func load(from url: URL) -> AgentLedger {
        guard let data = try? Data(contentsOf: url),
            let ledger = try? AgentJSON.decoder.decode(AgentLedger.self, from: data)
        else { return AgentLedger() }
        return ledger
    }

    func write(to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? AgentJSON.encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum AgentJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A key handed to one agent: `KEY=value` lines in `<state>/agents/<id>.env`, mode 0600, never sent
/// back to any client — a listing says only whether each key is set.
enum AgentKeys {
    static func url(in directory: URL, agent: String) -> URL {
        directory.appendingPathComponent("\(agent).env")
    }

    static func read(in directory: URL, agent: String) -> [String: String] {
        guard let text = try? String(contentsOf: url(in: directory, agent: agent), encoding: .utf8)
        else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...])
            if !key.isEmpty { values[key] = value }
        }
        return values
    }

    static func write(_ values: [String: String], in directory: URL, agent: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "\n")
        let target = url(in: directory, agent: agent)
        FileManager.default.createFile(
            atPath: target.path, contents: Data((text + "\n").utf8),
            attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// Only a variable name a shell would accept, so a key can never smuggle a line of its own.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && name.count <= 64
    }

    static func isValidValue(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 4_096 && !value.contains(where: \.isNewline)
    }
}

/// Where a command lives, read the way a login shell would find it: the service's own PATH plus
/// the places installers put things for one user, which a systemd unit or a launch agent does not
/// have on its PATH.
enum CommandLocator {
    static func searchPath(home: String) -> [String] {
        let environment = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let extra = [
            "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
            "\(home)/.opencode/bin", "\(home)/go/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "/bin",
        ]
        var seen: Set<String> = []
        return (environment.split(separator: ":").map(String.init) + extra).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    static func find(_ command: String, home: String) -> String? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        for directory in searchPath(home: home) {
            let candidate = (directory as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The environment an agent is started in: the service's own, with a PATH a login shell would
    /// have, so an agent that shells out to `node` or `git` finds them.
    static func environment(home: String, extra: [String: String]) -> [String: String] {
        var environment = extra
        environment["PATH"] = searchPath(home: home).joined(separator: ":")
        return environment
    }
}

enum AgentChecksum {
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
