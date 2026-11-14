import Foundation
import Testing

@testable import claude_bridge

@Suite("Hardening")
struct HardeningTests {
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
