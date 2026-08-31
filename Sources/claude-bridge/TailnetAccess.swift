import Foundation
import Hummingbird
import Logging
import NIOCore

/// The request context every route runs in. It carries the peer's socket address — which is what
/// a tailnet identity is looked up by — and, once the access middleware has ruled, how the request
/// was let in, so a route can tell the client what admitted it.
struct BridgeRequestContext: RequestContext, RemoteAddressRequestContext {
    var coreContext: CoreRequestContextStorage
    let remoteAddress: SocketAddress?
    var access: AccessGrant?

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        remoteAddress = source.channel.remoteAddress
    }
}

/// How a request got past the door. A client shows this on its server screen so a machine that
/// wanted no password can say why rather than looking unprotected.
enum AccessGrant: Encodable, Sendable, Equatable {
    case password
    case tailnet(TailnetPeer)
    case open

    private enum Keys: String, CodingKey { case mode, login, node, os }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .password:
            try container.encode("password", forKey: .mode)
        case .open:
            try container.encode("open", forKey: .mode)
        case .tailnet(let peer):
            try container.encode("tailnet", forKey: .mode)
            try container.encodeIfPresent(peer.login, forKey: .login)
            try container.encodeIfPresent(peer.node, forKey: .node)
            try container.encodeIfPresent(peer.os, forKey: .os)
        }
    }
}

/// What tailscaled says about the machine on the other end of a socket: which tailnet user it
/// belongs to (or which tags, for a node that belongs to nobody), what it is called, what it runs.
struct TailnetPeer: Sendable, Equatable {
    var login: String?
    var tags: [String]
    var node: String?
    var os: String?

    /// Decodes `tailscale whois --json`. A peer tailscaled does not know is not an error but an
    /// answer — "not on this tailnet" — so the initializer fails rather than throwing.
    init?(whoisJSON data: Data) {
        guard let raw = try? JSONDecoder().decode(Whois.self, from: data) else { return nil }
        login = raw.UserProfile?.LoginName
        tags = raw.Node?.Tags ?? []
        let name = raw.Node?.ComputedName ?? raw.Node?.Name
        node = name.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        os = raw.Node?.Hostinfo?.OS
    }

    init(login: String?, tags: [String] = [], node: String? = nil, os: String? = nil) {
        self.login = login
        self.tags = tags
        self.node = node
        self.os = os
    }

    private struct Whois: Decodable {
        struct Profile: Decodable { let LoginName: String? }
        struct Hostinfo: Decodable { let OS: String? }
        struct Node: Decodable {
            let Name: String?
            let ComputedName: String?
            let Tags: [String]?
            let Hostinfo: Hostinfo?
        }
        let Node: Node?
        let UserProfile: Profile?
    }
}

/// Who on the tailnet may use this bridge without a password. Read from `BRIDGE_TAILNET_AUTH`:
/// unset means the machine's own user — the person who signed this node in is the person the
/// bridge runs as — `off` disables it, and anything else is a list of login names and `tag:` names.
enum TailnetPolicy: Sendable, Equatable {
    case off
    case sameUser
    case allow(Set<String>)

    static func parse(_ raw: String?) -> TailnetPolicy {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "", "1", "on", "true", "same-user", "self":
            return .sameUser
        case "0", "off", "false", "none":
            return .off
        default:
            let names = value.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            return names.isEmpty ? .sameUser : .allow(Set(names))
        }
    }

    /// The rule applied to one peer. A node that carries tags belongs to no user, so it is admitted
    /// only by naming its tag; a tailnet with a single user is the same-user case exactly.
    func admits(_ peer: TailnetPeer, selfLogin: String?) -> Bool {
        switch self {
        case .off:
            return false
        case .sameUser:
            guard let selfLogin, let login = peer.login, peer.tags.isEmpty else { return false }
            return login.lowercased() == selfLogin.lowercased()
        case .allow(let names):
            if let login = peer.login, names.contains(login.lowercased()) { return true }
            return peer.tags.contains { names.contains($0.lowercased()) }
        }
    }
}

/// Asks tailscaled who is on the other end of a connection. Tailscale already authenticated that
/// node with a key and an account; a password on top of it asks the same person to prove the same
/// thing twice. The lookup goes through the `tailscale` CLI because the local API's socket lives in
/// a different place on every platform and the CLI knows all of them.
actor TailnetGate {
    private let policy: TailnetPolicy
    private let cli: String?
    private var selfLogin: (value: String?, at: Date)?
    private var cache: [String: (peer: TailnetPeer?, at: Date)] = [:]
    private var logged: Set<String> = []

    static let hitTTL: TimeInterval = 60
    static let missTTL: TimeInterval = 5
    static let selfTTL: TimeInterval = 600

    init(policy: TailnetPolicy, cli: String?) {
        self.policy = policy
        self.cli = cli
    }

    /// The CLI to ask, wherever this platform keeps it. Nil means tailscale is not on this machine,
    /// in which case there is no tailnet to trust and the gate stays shut.
    static func locateCLI(override: String?) -> String? {
        var candidates = [
            "/usr/bin/tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        if let override, !override.isEmpty { candidates.insert(override, at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether the gate can rule at all: the policy is on, the CLI exists, and tailscaled answered.
    /// Decided once at startup so the fail-closed guard has a fact to reason from.
    static func probe(policy: TailnetPolicy, cli: String?) -> Bool {
        guard policy != .off, let cli else { return false }
        return Self.readSelfLogin(cli: cli) != nil
    }

    var isActive: Bool { policy != .off && cli != nil }

    func grant(for address: SocketAddress?, logger: Logger) async -> AccessGrant? {
        guard isActive, let cli, let ip = address?.ipAddress else { return nil }
        guard let peer = await lookup(ip, cli: cli) else { return nil }
        let own = await currentSelfLogin(cli: cli)
        guard policy.admits(peer, selfLogin: own) else {
            if logged.insert("deny:\(ip)").inserted {
                logger.info(
                    "tailnet peer refused",
                    metadata: [
                        "ip": "\(ip)", "login": "\(peer.login ?? "-")",
                        "tags": "\(peer.tags.joined(separator: ","))",
                    ])
            }
            return nil
        }
        if logged.insert("allow:\(ip)").inserted {
            logger.info(
                "tailnet peer admitted",
                metadata: [
                    "ip": "\(ip)", "login": "\(peer.login ?? "-")", "node": "\(peer.node ?? "-")",
                ])
        }
        return .tailnet(peer)
    }

    private func lookup(_ ip: String, cli: String) async -> TailnetPeer? {
        if let hit = cache[ip] {
            let ttl = hit.peer == nil ? Self.missTTL : Self.hitTTL
            if Date().timeIntervalSince(hit.at) < ttl { return hit.peer }
        }
        let peer = await Task.detached(priority: .userInitiated) {
            TailnetPeer(whoisJSON: Shell.data(cli, ["whois", "--json", ip], timeout: 4))
        }.value
        cache[ip] = (peer, Date())
        if cache.count > 256 { cache = cache.filter { Date().timeIntervalSince($0.value.at) < Self.hitTTL } }
        return peer
    }

    private func currentSelfLogin(cli: String) async -> String? {
        if let selfLogin, Date().timeIntervalSince(selfLogin.at) < Self.selfTTL {
            return selfLogin.value
        }
        let value = await Task.detached(priority: .userInitiated) { Self.readSelfLogin(cli: cli) }.value
        selfLogin = (value, Date())
        return value
    }

    /// The login this node was signed in with, from `tailscale status --json`.
    static func readSelfLogin(cli: String) -> String? {
        let data = Shell.data(cli, ["status", "--json"], timeout: 4)
        guard let status = try? JSONDecoder().decode(Status.self, from: data),
            let id = status.me?.UserID
        else { return nil }
        return status.User?["\(id)"]?.LoginName
    }

    private struct Status: Decodable {
        struct Node: Decodable { let UserID: Int64? }
        struct User: Decodable { let LoginName: String? }
        let me: Node?
        let User: [String: User]?

        private enum CodingKeys: String, CodingKey {
            case me = "Self"
            case User
        }
    }
}

/// The door. A request is admitted by the password when one is set, by the tailnet when its peer
/// is someone the policy names, and otherwise refused with the same challenge as before — plus a
/// header saying the refusal was the tailnet's, so a client does not ask for a password that does
/// not exist.
struct AccessMiddleware: RouterMiddleware {
    typealias Context = BridgeRequestContext

    private let expected: String?
    private let gate: TailnetGate?

    init(password: String, gate: TailnetGate?) {
        if password.isEmpty {
            expected = nil
        } else {
            let raw = Data("claude:\(password)".utf8).base64EncodedString()
            expected = "Basic \(raw)"
        }
        self.gate = gate
    }

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        var context = context
        if let expected, request.headers[.authorization] == expected {
            context.access = .password
            return try await next(request, context)
        }
        if let gate, let grant = await gate.grant(for: context.remoteAddress, logger: context.logger) {
            context.access = grant
            return try await next(request, context)
        }
        if expected == nil, gate == nil {
            context.access = .open
            return try await next(request, context)
        }
        var headers = HTTPFields()
        headers[.wwwAuthenticate] = "Basic realm=\"claude-bridge\""
        guard let gate, await gate.isActive else {
            return Response(status: .unauthorized, headers: headers)
        }
        headers[.contentType] = "application/json"
        let refusal: [String: String]
        if expected == nil {
            headers[.init("X-Bridge-Access")!] = "tailnet-only"
            refusal = [
                "error": "tailnet-only",
                "detail": "this bridge admits only devices signed into its own tailnet account and has no password",
            ]
        } else {
            headers[.init("X-Bridge-Access")!] = "tailnet,password"
            refusal = ["error": "unauthorized", "detail": "sign this device into the bridge's tailnet account, or send its password"]
        }
        let body = try JSONEncoder().encode(refusal)
        return Response(status: .unauthorized, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: body)))
    }
}
