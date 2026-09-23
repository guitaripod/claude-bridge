import Foundation
import Testing

@testable import claude_bridge

/// A transcript read with nothing new in it is answered by its tag, and the tag moves the moment
/// anything in the answer does.
@Suite struct ValidationTests {
    private func session(active: Bool) throws -> Session {
        let json = #"""
            {"id":"s1","title":"Tagged","model":"opus","effort":"high",
             "createdAt":"2026-09-23T10:00:00Z","updatedAt":"2026-09-23T10:05:00Z",
             "messages":[{"id":"m1","role":"assistant","createdAt":"2026-09-23T10:01:00Z",
                          "parts":[{"kind":"text","text":"Written — once"}]}],
             "active":\#(active),"turnOpen":false}
            """#
        return try JSONCoding.decoder.decode(Session.self, from: Data(json.utf8))
    }

    /// Foundation may write an object's keys in any order; the stable encoding may not, or one
    /// unchanged transcript would wear a new tag on every read and never be answered 304.
    @Test func anUnchangedSessionKeepsItsTag() throws {
        let value = try session(active: false)
        let tags = try (0..<8).map { _ in
            Validation.tag(of: try JSONCoding.stableEncoder.encode(value))
        }
        #expect(Set(tags).count == 1)
    }

    /// A turn opening changes no message, and it still has to reach a client holding the old copy.
    @Test func anyChangeInTheAnswerMovesTheTag() throws {
        let idle = try JSONCoding.stableEncoder.encode(try session(active: false))
        let busy = try JSONCoding.stableEncoder.encode(try session(active: true))
        #expect(Validation.tag(of: idle) != Validation.tag(of: busy))
    }

    @Test func aHeldCopyIsAnsweredWithoutItsBody() throws {
        let body = try JSONCoding.stableEncoder.encode(try session(active: false))
        let tag = Validation.tag(of: body)
        #expect(Validation.reply(body: body, ifNoneMatch: tag) == .unchanged(tag: tag))
        #expect(Validation.reply(body: body, ifNoneMatch: nil) == .full(body, tag: tag))
        #expect(Validation.reply(body: body, ifNoneMatch: "\"stale\"") == .full(body, tag: tag))
    }

    /// The header's own grammar: a list, a weak mark, or any copy at all.
    @Test func theHeaderIsReadTheWayHTTPWritesIt() {
        let tag = "\"abc\""
        #expect(Validation.matches("\"x\", \"abc\"", tag))
        #expect(Validation.matches("W/\"abc\"", tag))
        #expect(Validation.matches("*", tag))
        #expect(!Validation.matches("\"abcd\"", tag))
    }

    /// Quoted and the same length every time, so a client can hand it straight back.
    @Test func theTagIsAQuotedDigest() {
        let tag = Validation.tag(of: Data("x".utf8))
        #expect(tag.hasPrefix("\"") && tag.hasSuffix("\""))
        #expect(tag.count == 26)
    }
}
