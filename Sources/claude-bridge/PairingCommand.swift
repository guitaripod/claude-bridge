import Foundation
import PairingKit

/// `claude-bridge pair`: the link and code the Tailscode apps scan to find this bridge.
enum PairingCommand {
    struct Outcome: Equatable {
        var status: Int32
        var stdout = ""
        var stderr = ""
    }

    static let program = "claude-bridge"
    static let defaultPort = 4098

    static func isRequest(_ arguments: [String]) -> Bool {
        arguments.dropFirst().first == "pair"
    }

    /// What this bridge's settings say about who may reach it, read the way the service reads them:
    /// the environment first, then the file the installer wrote.
    struct Settings: Equatable {
        var port: Int
        var password: String
        var policy: TailnetPolicy
        var tailscaleOverride: String?
    }

    static func settings(_ context: PairingContext) -> Settings {
        let directory = context.environment["BRIDGE_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(context.home)/.claude-bridge"
        let file = PairingConfigFile.values(at: "\(directory)/config.env")
        return Settings(
            port: context.value("BRIDGE_PORT", file: file).flatMap { Int($0) } ?? defaultPort,
            password: context.value("BRIDGE_PASSWORD", file: file) ?? "",
            policy: TailnetPolicy.parse(context.value("BRIDGE_TAILNET_AUTH", file: file)),
            tailscaleOverride: context.value("BRIDGE_TAILSCALE", file: file))
    }

    /// Whether the password belongs in the link, and the sentence that says why or why not.
    ///
    /// The bridge lets in a device its tailnet vouches for, without a password, only while the
    /// policy is not `off`, a tailscale CLI is found where the service looks, and tailscaled answers
    /// it: exactly the three things `TailnetGate.probe` checks at startup. When any of them fails the
    /// password is the only key there is, and it goes in the link.
    static func keyDecision(_ settings: Settings, context: PairingContext) -> (key: String?, note: String) {
        let cli = context.serviceTailscale(override: settings.tailscaleOverride)
        let trusted = TailnetGate.probe(policy: settings.policy, cli: cli)
        if trusted {
            return (
                nil,
                "No password is in this link: this computer lets in devices signed into its Tailscale account."
            )
        }
        let reason: String
        if settings.policy == .off {
            reason = "BRIDGE_TAILNET_AUTH is off"
        } else if cli == nil {
            reason = "Tailscale is not installed on this computer"
        } else {
            reason = "Tailscale is not answering on this computer"
        }
        guard !settings.password.isEmpty else {
            return (nil, "No password is in this link because none is set (\(reason)).")
        }
        return (
            settings.password,
            "This link carries the password of this bridge because \(reason), so a device is let in only with it. Anyone who sees the link can use the bridge; keep it to yourself."
        )
    }

    static func run(arguments: [String], context: PairingContext) -> Outcome {
        guard let options = PairingOptions.parse(arguments) else {
            return Outcome(status: 2, stderr: "\(program) pair: \(PairingOptions.usage)\n")
        }
        let settings = settings(context)
        let cli = context.anyTailscale(override: settings.tailscaleOverride)
        let choice = PairingHostChoice.resolve(
            tailscaleFound: cli != nil, reading: context.reading(cli: cli),
            hostname: context.hostname, port: settings.port, agent: .claude)
        guard let choice else {
            return Outcome(
                status: 1,
                stderr:
                    "\(program) pair: this computer's name \"\(context.hostname)\" cannot be used in a pairing link.\n"
            )
        }
        var decision = keyDecision(settings, context: context)
        let name = PairingHostChoice.displayName(context.hostname)
        var link = PairingLink(
            host: choice.host, port: settings.port, agent: .claude, name: name, key: decision.key)
        if link == nil, decision.key != nil {
            decision = (nil, "The password is too long to go in a link; enter it in Tailscode by hand.")
            link = PairingLink(host: choice.host, port: settings.port, agent: .claude, name: name)
        }
        guard let link else {
            return Outcome(
                status: 1,
                stderr: "\(program) pair: port \(settings.port) cannot be used in a pairing link.\n")
        }
        let text = link.url.absoluteString
        let code = (try? QRCode.encode(text)) ?? (try? QRCode.encode(text, level: .low))
        if code == nil {
            decision.note += " The link is too long to draw as a code, so paste it into Tailscode instead."
        }
        let showQR = (options.anyHost || choice.onTailnet) && code != nil
        let plan = PairingPlan(
            link: link, choice: choice, keyIncluded: link.key != nil, keyNote: decision.note,
            again: context.invocation(program: program), qr: code)
        if options.json {
            return Outcome(status: 0, stdout: plan.json(showQR: showQR) + "\n")
        }
        if options.linkOnly {
            guard choice.onTailnet || options.anyHost else {
                return Outcome(
                    status: 3,
                    stderr: PairingPlan.offTailnetNote(reason: choice.offTailnet ?? "", qrShown: false)
                        + " Add --any-host to print the link anyway.\n")
            }
            return Outcome(status: 0, stdout: link.url.absoluteString + "\n")
        }
        let color: Bool
        switch options.color {
        case .always: color = true
        case .never: color = false
        case .auto: color = context.isTerminal
        }
        return Outcome(
            status: 0, stdout: plan.plain(color: color, environment: context.environment, showQR: showQR))
    }
}
