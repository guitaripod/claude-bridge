import Foundation
import Testing

@testable import claude_bridge

@Suite("Hardening")
struct HardeningTests {
    @Test("A diff path that looks like an option is never read as one")
    func aDiffPathIsNeverAnOption() throws {
        let repo = makeTemporaryDirectory("diff-option")
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = Shell.run("git", ["init", "-q"], cwd: repo.path)
        let victim = repo.appendingPathComponent("notes.md")
        try "keep me\n".write(to: victim, atomically: true, encoding: .utf8)
        _ = Git.patch(directory: repo.path, path: "--output=\(victim.path)", staged: false)
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep me\n")
    }

    @Test("A store this bridge cannot read is kept aside, not overwritten")
    func anUnreadableStoreIsKeptAside() throws {
        let dir = makeTemporaryDirectory("unreadable-store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("sessions.json")
        try "{ not a store".write(to: store, atomically: true, encoding: .utf8)
        #expect(StoreWriter.load(from: store) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("sessions.unreadable-") }
        #expect(kept.count == 1)
    }

}
