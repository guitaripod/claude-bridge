import Foundation
import Testing

@testable import claude_bridge

/// The store on disk is what a restarted bridge comes back to, so the writer that moved off the
/// store's actor still has to leave exactly the file the store would have written, and never an
/// older one than it already wrote.
@Suite struct StoreWriterTests {
    private func session(_ id: String, _ text: String) -> Session {
        let json = #"""
            {"id":"\#(id)","title":"T \#(id)","model":"opus","effort":"high",
             "createdAt":"2026-11-04T10:00:00Z","updatedAt":"2026-11-04T10:05:00Z",
             "messages":[{"id":"m-\#(id)","role":"assistant","createdAt":"2026-11-04T10:01:00Z",
                          "parts":[{"kind":"text","text":"\#(text)"}]}]}
            """#
        return try! JSONCoding.decoder.decode(Session.self, from: Data(json.utf8))
    }

    private func read(_ url: URL) throws -> [Session] {
        try JSONCoding.decoder.decode([Session].self, from: Data(contentsOf: url))
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("store-writer-\(UUID().uuidString)")
            .appendingPathComponent("sessions.json")
    }

    @Test func theFileReadsBackAsTheSnapshotItWasGiven() throws {
        let url = scratch()
        let writer = StoreWriter(url: url)
        let first = [session("a", "one"), session("b", "two")]
        writer.write(first, generation: 1)
        #expect(try read(url) == first)

        let second = [session("a", "one"), session("b", "two, edited"), session("c", "three")]
        writer.write(second, generation: 2)
        #expect(try read(url) == second)

        let fewer = [session("c", "three")]
        writer.write(fewer, generation: 3)
        #expect(try read(url) == fewer)
    }

    @Test func aSnapshotOlderThanTheFileIsNeverWritten() throws {
        let url = scratch()
        let writer = StoreWriter(url: url)
        let newer = [session("a", "newer")]
        writer.write(newer, generation: 5)
        writer.write([session("a", "older")], generation: 4)
        writer.write([session("a", "same generation")], generation: 5)
        #expect(try read(url) == newer)
    }

    @Test func theFileIsTheArrayAWholeEncodingWouldWrite() throws {
        let url = scratch()
        let writer = StoreWriter(url: url)
        let sessions = (0..<5).map { session("s\($0)", "text \($0)") }
        writer.write(sessions, generation: 1)
        writer.write(sessions, generation: 2)
        let whole = try JSONCoding.decoder.decode(
            [Session].self, from: JSONCoding.encoder.encode(sessions))
        #expect(try read(url) == whole)
    }
}
