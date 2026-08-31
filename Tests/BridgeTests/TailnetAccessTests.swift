import Foundation
import Testing

@testable import claude_bridge

/// A tailnet peer is admitted by who Tailscale says it is, not by a secret it retyped. What these
/// pin is the reading of tailscaled's own answer and the one rule the policy applies to it — the
/// door itself is a socket address away and cannot be exercised without a tailnet.
@Suite("Tailnet access")
struct TailnetAccessTests {
    private let whois = Data(
        """
        {"Node":{"Name":"macbook.taila1a09.ts.net.","ComputedName":"macbook","Tags":null,
        "Hostinfo":{"OS":"macOS"}},"UserProfile":{"LoginName":"me@example.com","DisplayName":"me"}}
        """.utf8)

    @Test("whois is read down to login, node and OS")
    func readsWhois() {
        let peer = TailnetPeer(whoisJSON: whois)
        #expect(peer?.login == "me@example.com")
        #expect(peer?.node == "macbook")
        #expect(peer?.os == "macOS")
        #expect(peer?.tags.isEmpty == true)
    }

    @Test("a peer tailscaled does not know is no peer")
    func unknownPeer() {
        #expect(TailnetPeer(whoisJSON: Data("peer not found\n".utf8)) == nil)
        #expect(TailnetPeer(whoisJSON: Data()) == nil)
    }

    @Test("the policy is spelled the way an env var is")
    func parsesPolicy() {
        #expect(TailnetPolicy.parse(nil) == .sameUser)
        #expect(TailnetPolicy.parse("") == .sameUser)
        #expect(TailnetPolicy.parse("on") == .sameUser)
        #expect(TailnetPolicy.parse("off") == .off)
        #expect(TailnetPolicy.parse("0") == .off)
        #expect(
            TailnetPolicy.parse("Me@Example.com, tag:agents")
                == .allow(["me@example.com", "tag:agents"]))
    }

    @Test("same-user admits the node's own account and nobody else")
    func sameUser() {
        let mine = TailnetPeer(login: "Me@Example.com")
        let theirs = TailnetPeer(login: "guest@example.com")
        let tagged = TailnetPeer(login: nil, tags: ["tag:server"])
        #expect(TailnetPolicy.sameUser.admits(mine, selfLogin: "me@example.com"))
        #expect(!TailnetPolicy.sameUser.admits(theirs, selfLogin: "me@example.com"))
        #expect(!TailnetPolicy.sameUser.admits(tagged, selfLogin: "me@example.com"))
        #expect(!TailnetPolicy.sameUser.admits(mine, selfLogin: nil))
    }

    @Test("an allow list names logins and tags")
    func allowList() {
        let policy = TailnetPolicy.allow(["guest@example.com", "tag:agents"])
        #expect(policy.admits(TailnetPeer(login: "guest@example.com"), selfLogin: "me@example.com"))
        #expect(policy.admits(TailnetPeer(login: nil, tags: ["tag:agents"]), selfLogin: nil))
        #expect(!policy.admits(TailnetPeer(login: "me@example.com"), selfLogin: "me@example.com"))
    }

    @Test("off admits nobody, whoever they are")
    func off() {
        #expect(!TailnetPolicy.off.admits(TailnetPeer(login: "me@example.com"), selfLogin: "me@example.com"))
    }

    @Test("the grant tells a client what let it in")
    func encodesGrant() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let tailnet = try String(
            decoding: encoder.encode(AccessGrant.tailnet(TailnetPeer(login: "me@example.com", node: "iphone", os: "iOS"))),
            as: UTF8.self)
        #expect(tailnet == #"{"login":"me@example.com","mode":"tailnet","node":"iphone","os":"iOS"}"#)
        #expect(try String(decoding: encoder.encode(AccessGrant.password), as: UTF8.self) == #"{"mode":"password"}"#)
    }
}
