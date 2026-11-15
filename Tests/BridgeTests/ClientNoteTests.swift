import Foundation
import Testing

@testable import claude_bridge

/// The note that tells Claude its replies are read in Tailscode rides on every conversation's
/// command line as an append, never as a replacement of Claude Code's own prompt.
@Suite("Client note")
struct ClientNoteTests {
    private static let fresh = ClaudeLaunch(
        resume: nil, fork: false, directory: "/tmp/work", ultracode: false)

    private static func arguments(_ launch: ClaudeLaunch = fresh, note: Bool) -> [String] {
        ClaudeProcess.arguments(
            launch: launch, model: "sonnet", effort: "medium",
            permissionMode: "bypassPermissions", clientNote: note)
    }

    @Test func appendsTheNoteAndNeverReplacesThePrompt() throws {
        let arguments = Self.arguments(note: true)
        let flag = try #require(arguments.firstIndex(of: "--append-system-prompt"))
        #expect(arguments[flag + 1] == ClientNote.text)
        #expect(!arguments.contains("--system-prompt"))
        #expect(!arguments.contains("--system-prompt-file"))
    }

    @Test func leavesTheNoteOffWhenTurnedOff() {
        #expect(!Self.arguments(note: false).contains("--append-system-prompt"))
    }

    @Test func ridesAlongsideResumeForkAndUltracode() {
        let launch = ClaudeLaunch(
            resume: "abc", fork: true, directory: "/tmp/work", ultracode: true)
        let arguments = Self.arguments(launch, note: true)
        #expect(arguments.contains("--append-system-prompt"))
        #expect(arguments.suffix(3) == ["--resume", "abc", "--fork-session"])
        #expect(arguments.contains("--settings"))
    }

    @Test func isOneFixedLineSoItStaysCached() {
        #expect(!ClientNote.text.contains("\n"))
        #expect(ClientNote.text.hasPrefix("This session is driven from Tailscode"))
        #expect(ClientNote.text.hasSuffix("so lead with the outcome."))
        #expect(ClientNote.text.count < 800)
    }
}
